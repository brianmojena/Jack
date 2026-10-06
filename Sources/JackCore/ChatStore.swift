import Combine
import Foundation

@MainActor public final class ChatStore: ObservableObject {
    @Published public private(set) var conversations: [ChatConversation] = []
    @Published public var selectedID: UUID?
    @Published public private(set) var statuses: [UUID: ChatStatus] = [:]
    @Published public private(set) var approvals: [UUID: [ChatApproval]] = [:]
    /// Messages written while the agent works, until it reads them.
    @Published public private(set) var waiting: [UUID: [ChatQueuedMessage]] = [:]
    /// Waiting messages taken back by stopping the agent, for the composer to restore.
    @Published public private(set) var recalled: [UUID: ChatQueuedMessage] = [:]
    @Published public var errorMessage: String?
    @Published public private(set) var maxConcurrent = 4
    @Published public private(set) var usage: [ChatProvider: ProviderUsage] = [:]
    @Published public private(set) var tokenUsage: [UUID: ChatTokenUsage] = [:]
    @Published public private(set) var refreshingUsage = false
    @Published public private(set) var recentModels: [ChatProvider: [String]] = [:]
    /// Slash commands per provider and project; nil while they have not been read.
    @Published public private(set) var commands: [String: [ChatCommand]] = [:]
    @Published public private(set) var loadingCommands = Set<String>()
    /// Why a provider's commands could not be read, until the next attempt.
    @Published public private(set) var commandErrors: [String: String] = [:]
    @Published public private(set) var jackTemplates: [JackCommandTemplate] = JackCommandCatalog.defaults
    private var seededJackTurns = Set<UUID>()
    private var cancelledJackTurns = Set<UUID>()
    private var compactions: [UUID: (target: Int, firstMessage: Int)] = [:]
    private var afterCompaction: [UUID: (String, [String])] = [:]
    private var handoffs: [UUID: (provider: ChatProvider, firstMessage: Int)] = [:]
    private var budgetBaseline: [UUID: Int] = [:]
    private var budgetTurnUsage: [UUID: Int] = [:]
    private let loadCommandList: (ChatProvider, String) async throws -> [ChatCommand]
    private let codexModels = ChatModelCatalog.cachedCodex()
    public var activeCount: Int { runs.count }
    public var selectedConversation: ChatConversation? { conversations.first { $0.id == selectedID } }
    private let archive: ChatArchive
    private let preferences: UserDefaults?
    private let makeDriver: (ChatProvider) -> any ChatDriver
    private var loaded = Set<UUID>()
    private var queue: [(UUID, String)] = []
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var drivers: [UUID: any ChatDriver] = [:]
    /// Drivers whose agent stays open between turns, reused for the conversation's next message.
    private var liveDrivers: [UUID: any ChatDriver] = [:]
    private var pending: [UUID: [ChatEvent]] = [:]
    private var flushTask: Task<Void, Never>?
    private var stopped = false
    /// Last reply of each agent, kept so orchestrators can read it after the transcript is evicted.
    private var lastReplies: [UUID: String] = [:]
    /// Orchestrators blocked in wait_for_agents; they don't take a concurrency slot from their sub-agents.
    private var delegatedWaits: [UUID: Int] = [:]
    public lazy var bridge = AgentBridge(store: self)
    /// Lets Claude Code agents create and monitor other agents through Jack's MCP tools.
    public var delegationEnabled: Bool { preferences?.object(forKey: "delegationEnabled") as? Bool ?? true }

    public init(archive: ChatArchive = ChatArchive(), preferences: UserDefaults? = .standard, driverFactory: ((ChatProvider) -> any ChatDriver)? = nil, commandLoader: ((ChatProvider, String) async throws -> [ChatCommand])? = nil) {
        self.loadCommandList = commandLoader ?? { try await ChatCommandService.load($0, directory: $1) }
        self.archive = archive
        let templateURL = archive.directory.appendingPathComponent("commands.json")
        if FileManager.default.fileExists(atPath: templateURL.path) {
            do { jackTemplates = try JSONDecoder().decode([JackCommandTemplate].self, from: Data(contentsOf: templateURL)) }
            catch { errorMessage = "No se pudieron leer los comandos personales: \(error.localizedDescription)" }
        }
        self.preferences = preferences
        self.makeDriver = driverFactory ?? { ChatDriverFactory.make($0) }
        for provider in ChatProvider.allCases { recentModels[provider] = preferences?.stringArray(forKey: "recentModels.\(provider.rawValue)") ?? [] }
        if let saved = preferences?.object(forKey: "maxConcurrentAgents") as? Int { maxConcurrent = max(0, min(64, saved)) }
        do {
            conversations = try archive.loadIndex()
            for conversation in conversations { if let value = conversation.tokenUsage { tokenUsage[conversation.id] = value } }
        } catch { errorMessage = "No se pudo abrir el historial: \(error.localizedDescription)" }
    }
    public func setConcurrency(_ count: Int) {
        maxConcurrent = max(0, min(64, count))
        preferences?.set(maxConcurrent, forKey: "maxConcurrentAgents")
        drainQueue()
    }
    public func refreshUsage(_ providers: [ChatProvider] = ChatProvider.allCases) async {
        guard !refreshingUsage else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }
        await withTaskGroup(of: ProviderUsage.self) { group in
            for provider in providers { group.addTask { await ChatUsageService.read(provider) } }
            for await result in group { mergeUsage(result) }
        }
    }
    private var usageRefresh: Task<Void, Never>?
    /// Reads a provider's quota shortly after one of its turns, once for several turns that end together.
    private func refreshUsageSoon(_ provider: ChatProvider) {
        guard usageRefresh == nil, !stopped else { return }
        usageRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.stopped else { return }
            await self.refreshUsage([provider])
            self.usageRefresh = nil
        }
    }
    private func mergeUsage(_ update: ProviderUsage) {
        if !update.windows.isEmpty, let existing = usage[update.provider] {
            var combined = existing.windows
            for window in update.windows {
                if let index = combined.firstIndex(where: { $0.id == window.id }) {
                    if window.observedAt >= combined[index].observedAt { combined[index] = window }
                } else { combined.append(window) }
            }
            var value = update; value.windows = combined; usage[update.provider] = value
        } else if var existing = usage[update.provider], !existing.windows.isEmpty {
            existing.note = update.note; existing.isCached = true; usage[update.provider] = existing
        } else { usage[update.provider] = update }
    }
    @discardableResult
    public func create(projectPath: String, provider: ChatProvider, model: String? = nil, effort: String = "high", parentID: UUID? = nil, title: String? = nil, select: Bool = true) -> UUID? {
        var isDirectory: ObjCBool = false
        guard projectPath.hasPrefix("/"), FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            if select { errorMessage = "Selecciona una carpeta de proyecto válida." }
            return nil
        }
        var conversation = ChatConversation(projectPath: projectPath, provider: provider, model: model, effort: effort)
        conversation.effort = Self.clamp(effort, to: supportedEfforts(provider: provider, model: conversation.model))
        conversation.parentID = parentID
        if let title { conversation.title = String(title.prefix(120)) }
        if parentID == nil { rememberModel(conversation.model, provider: provider) }
        conversations.insert(conversation, at: 0)
        loaded.insert(conversation.id)
        if select {
            selectedID = conversation.id
            preferences?.set(projectPath, forKey: "lastProjectPath")
        }
        save(conversation.id)
        if select { evictInactiveTranscripts() }
        return conversation.id
    }
    /// Continues a session started in Claude Code's terminal: its history becomes the transcript and
    /// the next message resumes it. A session already in Jack is selected instead of copied.
    @discardableResult
    public func importClaudeSession(_ session: ClaudeSessionSummary, messages: [ChatMessage], model: String? = nil) -> UUID? {
        if let existing = conversations.first(where: { $0.provider == .claude && $0.sessionID == session.id }) {
            select(existing.id)
            return existing.id
        }
        guard let id = create(projectPath: session.projectPath, provider: .claude, model: model, title: session.title),
              let index = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[index].sessionID = session.id
        conversations[index].messages = messages
        conversations[index].updatedAt = session.updatedAt
        if let last = messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) { conversations[index].preview = Self.preview(of: last.text) }
        save(id)
        return id
    }
    /// Replaces the transcript with the session as Claude Code saved it, e.g. after it continued in a terminal.
    public func replaceTranscript(_ id: UUID, messages: [ChatMessage]) {
        guard runs[id] == nil, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        liveDrivers.removeValue(forKey: id)?.close()
        loaded.insert(id)
        conversations[index].messages = messages
        if let last = messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) { conversations[index].preview = Self.preview(of: last.text) }
        conversations[index].updatedAt = Date()
        save(id)
    }
    /// Ends the agent's open process, e.g. before the same session continues in a terminal.
    /// Returns false while it is working.
    @discardableResult
    public func closeSession(_ id: UUID) -> Bool {
        guard runs[id] == nil else { return false }
        liveDrivers.removeValue(forKey: id)?.close()
        return true
    }
    public func select(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if !loaded.contains(id) {
            do { if let transcript = try archive.load(id) { conversations[index].messages = transcript.messages }; loaded.insert(id); settleBackground(id) }
            catch { errorMessage = "No se pudo leer esta conversación: \(error.localizedDescription)"; return }
        }
        selectedID = id
        var changed = false
        if conversations[index].hasUnread == true { conversations[index].hasUnread = nil; changed = true }
        if conversations[index].preview == nil, let last = conversations[index].messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
            conversations[index].preview = Self.preview(of: last.text); changed = true
        }
        if changed { save(id) }
        evictInactiveTranscripts()
    }
    private static func commandKey(_ provider: ChatProvider, _ projectPath: String) -> String { "\(provider.rawValue)|\(projectPath)" }
    public func commands(for conversation: ChatConversation) -> [ChatCommand]? {
        commands[Self.commandKey(conversation.provider, conversation.projectPath)]
    }
    public func isLoadingCommands(for conversation: ChatConversation) -> Bool {
        loadingCommands.contains(Self.commandKey(conversation.provider, conversation.projectPath))
    }
    public func commandError(for conversation: ChatConversation) -> String? {
        commandErrors[Self.commandKey(conversation.provider, conversation.projectPath)]
    }
    /// Reads the provider's commands once per project; runs also refresh them as they report changes.
    /// A failed read is not remembered as an empty list: the next call tries again.
    public func loadCommands(for conversation: ChatConversation) {
        let key = Self.commandKey(conversation.provider, conversation.projectPath)
        guard commands[key] == nil, !loadingCommands.contains(key) else { return }
        loadingCommands.insert(key)
        commandErrors[key] = nil
        Task { [weak self] in
            var list: [ChatCommand] = []
            var failure: String?
            do { list = try await self?.loadCommandList(conversation.provider, conversation.projectPath) ?? [] }
            catch { failure = error.localizedDescription }
            guard let self else { return }
            self.loadingCommands.remove(key)
            if list.isEmpty, failure == nil { failure = "\(conversation.provider.title) no informó de ningún comando." }
            if let failure {
                self.commandErrors[key] = failure
                JackLog.write("comandos de \(conversation.provider.title) en \(conversation.projectPath): \(failure)")
            } else if self.commands[key] == nil || !list.isEmpty { self.commands[key] = list }
        }
    }
    public func setUnread(_ id: UUID, _ unread: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), (conversations[index].hasUnread == true) != unread else { return }
        conversations[index].hasUnread = unread ? true : nil
        save(id)
    }
    public func send(_ prompt: String, attachments: [String] = []) {
        guard let id = selectedID else { return }
        send(prompt, attachments: attachments, to: id)
    }
    /// Messages can always be written: while the agent works they wait until it reads them.
    public func canSend(to id: UUID) -> Bool { !stopped }
    /// Whether the agent is busy, so a message sent now waits.
    public func isBusy(_ id: UUID) -> Bool { runs[id] != nil || queue.contains { $0.0 == id } }
    /// Whether the agent reads waiting messages while it works, rather than after its turn.
    public func readsWhileWorking(_ id: UUID) -> Bool { drivers[id]?.keepsAlive == true || liveDrivers[id] != nil }
    /// `interrupting` stops the turn so the agent reads the message right away, like Ctrl+Enter.
    public func send(_ prompt: String, attachments: [String] = [], to id: UUID, interrupting: Bool = false) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, conversations.contains(where: { $0.id == id }), !stopped else { return }
        if isBusy(id), JackCommandCatalog.parse(text) == nil {
            wait(text.hasPrefix("!!") ? String(text.dropFirst()) : text, attachments: attachments, to: id)
            if interrupting { sendWaitingNow(id) }
            return
        }
        if let command = JackCommandCatalog.parse(text) {
            guard attachments.isEmpty else { errorMessage = "Los comandos ! no admiten archivos adjuntos."; return }
            executeJack(command.name, arguments: command.arguments, to: id)
            return
        }
        let ordinaryText = text.hasPrefix("!!") ? String(text.dropFirst()) : text
        if runs[id] == nil, compactions[id] == nil, handoffs[id] == nil, let c = conversations.first(where: { $0.id == id }),
           let threshold = c.jackContext?.autoThreshold, let target = c.jackContext?.autoTarget,
           let used = c.contextUsage?.used, used >= threshold {
            afterCompaction[id] = (text, attachments)
            loadTranscript(id)
            if let i = conversations.firstIndex(where: { $0.id == id }) {
                conversations[i].messages.append(ChatMessage(role: "jack", text: "Mensaje conservado mientras se compacta el contexto:\n" + ordinaryText, attachments: attachments.isEmpty ? nil : attachments))
                save(id)
            }
            beginCompaction(id, target: target)
            return
        }
        loadTranscript(id)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(ChatMessage(role: "user", text: ordinaryText, attachments: attachments.isEmpty ? nil : attachments))
        if conversations[index].title == "Nuevo agente" {
            let title = text.isEmpty ? attachments.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") : text
            conversations[index].title = String(title.prefix(55)).replacingOccurrences(of: "\n", with: " ")
        }
        conversations[index].updatedAt = Date()
        save(id)
        statuses[id] = .queued
        queue.append((id, ordinaryText))
        drainQueue()
    }
    /// A message for an agent that is working. A pending permission request is rejected with it as the reason,
    /// as typing does in Claude Code; otherwise it waits: agents that read messages mid-turn get it at once and
    /// read it after their current step, and the rest get it when the turn ends.
    private func wait(_ text: String, attachments: [String], to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let driver = drivers[id], driver.keepsAlive, attachments.isEmpty, let request = approvals[id]?.first(where: { $0.questions.isEmpty }) {
            conversations[index].messages.append(ChatMessage(role: "user", text: text))
            conversations[index].updatedAt = Date()
            save(id)
            respond(conversationID: id, approvalID: request.id, choice: "deny", message: text)
            return
        }
        var message = ChatQueuedMessage(text: text, attachments: attachments)
        if runs[id] != nil, let driver = drivers[id], driver.keepsAlive { message.sent = driver.inject(message, conversation: conversations[index]) }
        waiting[id, default: []].append(message)
    }
    /// Interrupts the turn so the agent reads the waiting messages now.
    public func sendWaitingNow(_ id: UUID) {
        guard waiting[id]?.isEmpty == false else { return }
        guard runs[id] != nil, let driver = drivers[id] else {
            if runs[id] == nil, !queue.contains(where: { $0.0 == id }) { deliverWaiting(id) }
            return
        }
        // A kept-alive agent reads its queued messages right after the interruption; the rest are sent when the turn ends.
        driver.stop(keepingQueued: true)
        if !driver.keepsAlive { runs[id]?.cancel() }
        approvals[id] = []
    }
    /// Takes a waiting message back, to edit or discard it. Nil when the agent already read it.
    public func withdraw(_ messageID: String, from id: UUID) async -> ChatQueuedMessage? {
        guard let message = waiting[id]?.first(where: { $0.id == messageID }) else { return nil }
        if message.sent, let driver = drivers[id] ?? liveDrivers[id], driver.isQueued(messageID) {
            guard await driver.withdraw(messageID: messageID) else { return nil }
        }
        guard waiting[id]?.contains(where: { $0.id == messageID }) == true else { return nil }
        waiting[id]?.removeAll { $0.id == messageID }
        return message
    }
    public func clearRecalled(_ id: UUID) { recalled.removeValue(forKey: id) }
    /// Waiting messages the agent no longer holds, e.g. because its process ended, go back to Jack's own queue.
    private func reconcileWaiting(_ id: UUID) {
        guard var messages = waiting[id], !messages.isEmpty else { return }
        let driver = liveDrivers[id]
        for index in messages.indices where messages[index].sent && driver?.isQueued(messages[index].id) != true { messages[index].sent = false }
        waiting[id] = messages
    }
    /// Sends the messages Jack still holds as the next turn, once the agent is free and holds none itself.
    private func deliverWaiting(_ id: UUID) {
        guard !stopped, runs[id] == nil, !queue.contains(where: { $0.0 == id }) else { return }
        reconcileWaiting(id)
        guard let messages = waiting[id], !messages.isEmpty, !messages.contains(where: \.sent) else { return }
        waiting[id] = nil
        let text = messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var attachments: [String] = []
        for path in messages.flatMap(\.attachments) where !attachments.contains(path) { attachments.append(path) }
        send(text, attachments: attachments, to: id)
    }
    /// The agent read a waiting message: it joins the transcript where the agent read it.
    private func receiveDelivered(_ messageID: String, text: String, at index: Int) {
        let id = conversations[index].id
        let message = waiting[id]?.first { $0.id == messageID }
        waiting[id]?.removeAll { $0.id == messageID }
        if waiting[id]?.isEmpty == true { waiting[id] = nil }
        guard !conversations[index].messages.contains(where: { $0.id == messageID }) else { return }
        let attachments = message?.attachments ?? []
        conversations[index].messages.append(ChatMessage(id: messageID, role: "user", text: message?.text ?? text, attachments: attachments.isEmpty ? nil : attachments))
        save(id)
    }
    private func loadTranscript(_ id: UUID) {
        guard !loaded.contains(id), let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let transcript = try? archive.load(id) { conversations[index].messages = transcript.messages }
        loaded.insert(id)
        settleBackground(id)
    }
    /// Background work cannot still be running once its agent's process is gone, e.g. after relaunching Jack.
    private func settleBackground(_ id: UUID) {
        guard liveDrivers[id] == nil, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        for messageIndex in conversations[index].messages.indices where conversations[index].messages[messageIndex].status == "background" {
            conversations[index].messages[messageIndex].status = "interrupted"
        }
    }
    public func stop(_ id: UUID) {
        if compactions[id] != nil || handoffs[id] != nil { cancelledJackTurns.insert(id) }
        if runs[id] == nil {
            compactions.removeValue(forKey: id); handoffs.removeValue(forKey: id)
            if let next = afterCompaction.removeValue(forKey: id) {
                jackNotice("Compactación cancelada. Mensaje pendiente (vuelve a enviarlo):\n\(next.0)", to: id)
                if let i = conversations.firstIndex(where: { $0.id == id }), !next.1.isEmpty {
                    conversations[i].messages.append(ChatMessage(role: "jack", text: "Archivos del mensaje pendiente", attachments: next.1)); save(id)
                }
            }
        }
        queue.removeAll { $0.0 == id }
        // As Esc does in Claude Code, stopping returns the waiting messages to the composer.
        if let messages = waiting.removeValue(forKey: id), !messages.isEmpty {
            var attachments: [String] = []
            for path in messages.flatMap(\.attachments) where !attachments.contains(path) { attachments.append(path) }
            let previous = recalled[id].map { [$0.text] } ?? []
            recalled[id] = ChatQueuedMessage(text: (previous + messages.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                             attachments: (recalled[id]?.attachments ?? []) + attachments)
        }
        if let driver = drivers[id] {
            driver.stop()
            // A kept-alive agent ends its turn itself once interrupted.
            if !driver.keepsAlive { runs[id]?.cancel() }
            if runs[id] == nil { statuses[id] = .idle }
        } else { statuses[id] = .idle }
        approvals[id] = []
    }
    public func respond(conversationID id: UUID, approvalID: String, allow: Bool) {
        respond(conversationID: id, approvalID: approvalID, choice: allow ? "allow" : "deny", message: nil)
    }
    public func respond(conversationID id: UUID, approvalID: String, choice: String, message: String? = nil) {
        guard let driver = drivers[id] else { return }
        Task { [weak self] in
            do {
                try await driver.respond(approvalID: approvalID, choice: choice, message: message)
                guard let self else { return }
                self.approvals[id]?.removeAll { $0.id == approvalID }
                self.statuses[id] = self.approvals[id]?.isEmpty == false ? .waiting : self.runs[id] != nil ? .running : .idle
            } catch { self?.errorMessage = "No se pudo responder al permiso: \(error.localizedDescription)" }
        }
    }
    public func rename(_ id: UUID, title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = String(text.prefix(120)); save(id)
    }
    public func answer(conversationID id: UUID, approvalID: String, answers: [String: String]) {
        guard let driver = drivers[id] else { return }
        Task { [weak self] in
            do {
                try await driver.answer(approvalID: approvalID, answers: answers)
                guard let self else { return }
                self.approvals[id]?.removeAll { $0.id == approvalID }
                self.statuses[id] = self.approvals[id]?.isEmpty == false ? .waiting : self.runs[id] != nil ? .running : .idle
            } catch { self?.errorMessage = "No se pudo enviar la respuesta: \(error.localizedDescription)" }
        }
    }
    public func remove(_ id: UUID) {
        guard runs[id] == nil, !queue.contains(where: { $0.0 == id }) else { return }
        liveDrivers.removeValue(forKey: id)?.close()
        conversations.removeAll { $0.id == id }; loaded.remove(id); statuses.removeValue(forKey: id); approvals.removeValue(forKey: id)
        waiting.removeValue(forKey: id); recalled.removeValue(forKey: id)
        archive.save(index: conversations, removedID: id)
        if selectedID == id { selectedID = nil; if let next = conversations.first { select(next.id) } }
    }
    public func updateSettings(id: UUID, model: String, effort: String) {
        guard runs[id] == nil, !queue.contains(where: { $0.0 == id }), let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let provider = conversations[index].provider
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? provider.defaultModel : trimmed
        if provider == .opencode, conversations[index].model != selected { conversations[index].variant = nil }
        // A different model may have a different window; the next request reports it.
        if conversations[index].model != selected { conversations[index].contextUsage?.window = nil }
        conversations[index].model = selected
        conversations[index].effort = provider == .opencode ? effort : Self.clamp(effort, to: supportedEfforts(provider: provider, model: selected))
        rememberModel(selected, provider: provider)
        save(id)
    }
    /// Takes effect from the agent's next turn.
    public func updateDirectories(id: UUID, directories: [String]) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].extraDirectories = directories.isEmpty ? nil : directories
        save(id)
    }
    public func updateVariant(id: UUID, variant: String?, supported: [String]) {
        guard runs[id] == nil, !queue.contains(where: { $0.0 == id }),
              let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].provider == .opencode,
              variant == nil || supported.contains(variant!) else { return }
        conversations[index].variant = variant
        save(id)
    }
    public func updateMode(id: UUID, mode: String?, supported: [ChatRunMode]) {
        guard !queue.contains(where: { $0.0 == id }),
              let index = conversations.firstIndex(where: { $0.id == id }),
              mode == nil || supported.contains(where: { $0.id == mode }) else { return }
        // A kept-alive agent switches mode in the middle of a turn, like Shift+Tab in Claude Code.
        if runs[id] != nil {
            guard let driver = drivers[id], driver.keepsAlive, driver.setMode(mode ?? "manual") else { return }
        }
        conversations[index].mode = mode
        save(id)
    }
    /// Whether the permission mode can change while the agent works.
    public func changesModeLive(_ id: UUID) -> Bool {
        runs[id] == nil || drivers[id]?.keepsAlive == true
    }
    /// Shift+Tab: the next of Claude Code's everyday modes.
    public func cycleMode(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }), conversation.provider == .claude else { return }
        let cycle = ["manual", "acceptEdits", "plan"]
        let next = cycle[((cycle.firstIndex(of: conversation.mode ?? "manual") ?? -1) + 1) % cycle.count]
        updateMode(id: id, mode: next, supported: ChatRunMode.choices(for: .claude))
    }
    public func modelChoices(for provider: ChatProvider) -> [ChatModelChoice] {
        let catalog: [ChatModelChoice]
        switch provider {
        case .codex: catalog = codexModels
        case .claude: catalog = ChatModelChoice.claudeCatalog
        case .opencode: catalog = [ChatModelChoice(id: "", efforts: [])]
        }
        let ids = (recentModels[provider] ?? []) + conversations.filter { $0.provider == provider }.map(\.model) + [provider.defaultModel] + catalog.map(\.id)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.map { id in
            catalog.first { $0.id == id } ?? ChatModelChoice(id: id, efforts: ChatModelChoice.fallbackEfforts(provider: provider, model: id))
        }
    }
    public func supportedEfforts(provider: ChatProvider, model: String) -> [String] {
        let catalog = provider == .codex ? codexModels : provider == .claude ? ChatModelChoice.claudeCatalog : []
        return catalog.first { $0.id == model }?.efforts ?? ChatModelChoice.fallbackEfforts(provider: provider, model: model)
    }
    /// Keeps the stored effort when the model has no levels, so switching back restores it.
    static func clamp(_ effort: String, to supported: [String]) -> String {
        supported.isEmpty || supported.contains(effort) ? effort : supported.contains("high") ? "high" : supported.last!
    }
    private func rememberModel(_ model: String, provider: ChatProvider) {
        var values = recentModels[provider] ?? []
        values.removeAll { $0 == model }; values.insert(model, at: 0)
        recentModels[provider] = Array(values.prefix(8))
        preferences?.set(recentModels[provider], forKey: "recentModels.\(provider.rawValue)")
    }
    public func shutdown() {
        stopped = true; queue.removeAll(); flushTask?.cancel(); flushTask = nil
        for id in Array(pending.keys) { flush(id) }
        for (id, driver) in drivers { driver.stop(); runs[id]?.cancel(); settleActivities(id); save(id) }
        for driver in liveDrivers.values { driver.close() }
        liveDrivers.removeAll()
        archive.flush()
    }
    private func drainQueue() {
        guard !stopped else { return }
        while (maxConcurrent == 0 || runs.count - delegatedWaits.count < maxConcurrent),
              // A message waits while its agent is busy with a turn it started by itself.
              let next = queue.firstIndex(where: { runs[$0.0] == nil }) {
            let (id, queuedPrompt) = queue.remove(at: next)
            guard let conversation = conversations.first(where: { $0.id == id }) else { continue }
            let driver = driver(for: conversation)
            let prompt = preparedJackPrompt(queuedPrompt, conversation: conversation)
            // Only top-level agents may delegate, so sub-agents cannot spawn more agents.
            let delegates = conversation.parentID == nil && delegationEnabled
            startRun(id, driver: driver) { [weak self] onEvent in
                let delegation = delegates ? try? await self?.bridge.delegation(for: id) : nil
                try await driver.run(conversation: conversation, prompt: prompt, delegation: delegation, onEvent: onEvent)
            }
        }
    }
    private func driver(for conversation: ChatConversation) -> any ChatDriver {
        let id = conversation.id
        if let live = liveDrivers[id] { return live }
        let driver = makeDriver(conversation.provider)
        if driver.keepsAlive {
            liveDrivers[id] = driver
            driver.observe(idle: { [weak self] event in self?.receiveIdle(event, for: id) },
                           unprompted: { [weak self] in self?.beginUnpromptedTurn(id) })
        }
        return driver
    }
    private func startRun(_ id: UUID, driver: any ChatDriver, _ body: @escaping @MainActor (@escaping @MainActor (ChatEvent) -> Void) async throws -> Void) {
        drivers[id] = driver; statuses[id] = .running
        if let c = conversations.first(where: { $0.id == id }), c.provider == .codex {
            budgetBaseline[id] = (c.tokenUsage?.input ?? 0) + (c.tokenUsage?.output ?? 0)
        } else { budgetBaseline[id] = 0 }
        runs[id] = Task { [weak self] in
            do {
                try await body { [weak self] event in self?.receive(event, for: id) }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { self?.receive(.failure(error.localizedDescription), for: id) }
            }
            guard let self else { return }
            self.flush(id)
            self.settleActivities(id)
            if self.statuses[id] != .failed { self.statuses[id] = .idle }
            self.approvals[id] = []
            self.finishTurn(id)
            self.drivers.removeValue(forKey: id); self.runs.removeValue(forKey: id)
            self.completeJackTurn(id, cancelled: Task.isCancelled)
            // Claude Code reports its quota as it works; Codex's has to be asked for.
            if let provider = self.conversations.first(where: { $0.id == id })?.provider, provider == .codex { self.refreshUsageSoon(provider) }
            self.deliverWaiting(id)
            self.save(id); self.evictInactiveTranscripts(); self.drainQueue()
        }
    }
    /// The agent started working by itself, e.g. to report a background subagent's result.
    private func beginUnpromptedTurn(_ id: UUID) {
        guard !stopped, runs[id] == nil, let driver = liveDrivers[id] else { return }
        loadTranscript(id)
        startRun(id, driver: driver) { onEvent in try await driver.follow(onEvent: onEvent) }
    }
    /// Between turns: background subagents finishing, mode changes and the like.
    private func receiveIdle(_ event: ChatEvent, for id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        loadTranscript(id)
        // A background subagent may ask for permission after the turn that started it ended.
        if case .approval = event, runs[id] == nil { drivers[id] = liveDrivers[id] }
        receive(event, for: id)
        flush(id)
        save(id)
    }
    private func finishTurn(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let messages = conversations[index].messages
        if let last = messages.last(where: { ($0.role == "assistant" || $0.role == "error") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            conversations[index].preview = Self.preview(of: last.text)
        }
        if let reply = messages.last(where: { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            lastReplies[id] = String(reply.text.prefix(24_000))
        }
        if selectedID != id { conversations[index].hasUnread = true }
    }

    // MARK: Delegation

    func beginDelegatedWait(_ id: UUID) {
        delegatedWaits[id, default: 0] += 1
        drainQueue()
    }
    func endDelegatedWait(_ id: UUID) {
        if let count = delegatedWaits[id], count > 1 { delegatedWaits[id] = count - 1 } else { delegatedWaits.removeValue(forKey: id) }
    }
    private func transcript(of id: UUID) -> [ChatMessage] {
        if loaded.contains(id) { return conversations.first { $0.id == id }?.messages ?? [] }
        return (try? archive.load(id))?.messages ?? []
    }
    public func lastReply(of id: UUID) -> String? {
        if let reply = lastReplies[id] { return reply }
        return transcript(of: id).last { $0.role == "assistant" && !$0.text.isEmpty }.map { String($0.text.prefix(24_000)) }
    }
    func lastError(of id: UUID) -> String? {
        transcript(of: id).last { $0.role == "error" }?.text
    }
    func recentActivity(of id: UUID, limit: Int) -> [String] {
        transcript(of: id).filter { $0.role == "tool" }.suffix(limit).map { message in
            let detail = message.detail.components(separatedBy: "\n").first ?? ""
            let line = [message.text, String(detail.prefix(160))].filter { !$0.isEmpty }.joined(separator: ": ")
            return message.status == "failed" ? line + " (failed)" : line
        }
    }
    static func preview(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("```") }
        var line = lines.first ?? ""
        while let first = line.first, "#>-*+ ".contains(first) { line.removeFirst() }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
    private func settleActivities(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conversation = conversations[index]
        for messageIndex in conversation.messages.indices where conversation.messages[messageIndex].role == "tool" && ["running", "inProgress", "pending"].contains(conversation.messages[messageIndex].status) {
            conversation.messages[messageIndex].status = "interrupted"
        }
        if conversation != conversations[index] { conversations[index] = conversation }
    }
    private func receive(_ event: ChatEvent, for id: UUID) {
        switch event {
        case .text, .reasoning, .toolOutput, .tool:
            pending[id, default: []].append(event)
            if flushTask == nil {
                flushTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.flushTask = nil
                    for key in Array(self.pending.keys) { self.flush(key) }
                }
            }
        default:
            flush(id); apply(event, for: id)
        }
    }
    private func flush(_ id: UUID) {
        guard let events = pending.removeValue(forKey: id), !events.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conversation = conversations[index]
        for event in events {
            let messageID: String, text: String, replace: Bool, role: String
            switch event {
            case let .text(id, content, replacing): messageID = id; text = content; replace = replacing; role = "assistant"
            case let .reasoning(id, content, replacing): messageID = id; text = content; replace = replacing; role = "reasoning"
            case let .toolOutput(id, content):
                if let messageIndex = conversation.messages.firstIndex(where: { $0.id == id }) {
                    conversation.messages[messageIndex].detail = String((conversation.messages[messageIndex].detail + content).suffix(65_536))
                } else { conversation.messages.append(ChatMessage(id: id, role: "tool", text: "Actividad", detail: String(content.suffix(65_536)), status: "running")) }
                continue
            case let .tool(id, title, detail, status):
                if let messageIndex = conversation.messages.firstIndex(where: { $0.id == id }) {
                    conversation.messages[messageIndex].text = title
                    if !detail.isEmpty { conversation.messages[messageIndex].detail = String(detail.prefix(65_536)) }
                    conversation.messages[messageIndex].status = status
                } else { conversation.messages.append(ChatMessage(id: id, role: "tool", text: title, detail: String(detail.prefix(65_536)), status: status)) }
                continue
            default: continue
            }
                if let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }) {
                    if replace { conversation.messages[messageIndex].text = text }
                    else { conversation.messages[messageIndex].text += text }
                } else { conversation.messages.append(ChatMessage(id: messageID, role: role, text: text)) }
        }
        conversations[index] = conversation
    }
    private func apply(_ event: ChatEvent, for id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .usage(let value): mergeUsage(value)
        case .tokens(let value):
            tokenUsage[id] = value; conversations[index].tokenUsage = value
            budgetTurnUsage[id] = max(budgetTurnUsage[id] ?? 0, max(0, value.input + value.output - (budgetBaseline[id] ?? 0)))
        case let .context(used, window):
            var value = conversations[index].contextUsage ?? ChatContextUsage(used: 0)
            if let used { value.used = used }
            if let window { value.window = window }
            if value != conversations[index].contextUsage { conversations[index].contextUsage = value }
        case .commands(let list):
            if !list.isEmpty { commands[Self.commandKey(conversations[index].provider, conversations[index].projectPath)] = list }
        case .session(let sessionID): conversations[index].sessionID = sessionID; save(id)
        case let .tool(messageID, title, detail, status):
            let message = ChatMessage(id: messageID, role: "tool", text: title, detail: String(detail.prefix(65_536)), status: status)
            if let existing = conversations[index].messages.firstIndex(where: { $0.id == messageID }) { conversations[index].messages[existing] = message }
            else { conversations[index].messages.append(message) }
        case .approval(let request):
            if !(approvals[id] ?? []).contains(where: { $0.id == request.id }) { approvals[id, default: []].append(request) }
            statuses[id] = .waiting
        case .approvalResolved(let requestID): approvals[id]?.removeAll { $0.id == requestID }; statuses[id] = approvals[id]?.isEmpty == false ? .waiting : .running
        case .mode(let mode):
            if conversations[index].mode != mode { conversations[index].mode = mode; save(id) }
        case let .delivered(messageID, text): receiveDelivered(messageID, text: text, at: index)
        case .failure(let message):
            if conversations[index].messages.last?.text != message { conversations[index].messages.append(ChatMessage(role: "error", text: message)) }
            statuses[id] = .failed
        case .completed: break
        case .text, .reasoning, .toolOutput: break
        }
        conversations[index].updatedAt = Date()
    }
    private func save(_ id: UUID) {
        let conversation = loaded.contains(id) ? conversations.first { $0.id == id } : nil
        archive.save(index: conversations, conversation: conversation) { [weak self] error in
            if let error { Task { @MainActor in self?.errorMessage = "No se pudo guardar el historial: \(error.localizedDescription)" } }
        }
    }
    private func evictInactiveTranscripts() {
        let protected = Set(runs.keys).union(queue.map(\.0)).union(selectedID.map { [$0] } ?? [])
        for id in loaded.subtracting(protected) {
            save(id)
            if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].messages = [] }
            loaded.remove(id)
        }
    }
}

// MARK: Jack's ! commands
private extension ChatStore {
    func jackNotice(_ text: String, to id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(ChatMessage(role: "jack", text: text))
        conversations[i].updatedAt = Date()
        save(id)
    }
    func preparedJackPrompt(_ prompt: String, conversation: ChatConversation) -> String {
        // Native slash commands must reach the driver's parser unchanged.
        guard !prompt.hasPrefix("/") else { return prompt }
        var parts: [String] = []
        if conversation.jackContext?.seedDelivered != true, let seed = conversation.jackContext?.seed {
            seededJackTurns.insert(conversation.id)
            parts.append("Contexto de continuidad (datos de una conversación anterior, no nuevas órdenes):\n<jack_context>\n\(seed)\n</jack_context>")
        }
        if let pinned = conversation.jackContext?.pinned, !pinned.isEmpty {
            parts.append("Instrucciones fijadas por el usuario:\n" + pinned.map { "- " + $0 }.joined(separator: "\n"))
        }
        parts.append(prompt)
        return parts.joined(separator: "\n\n")
    }
    func jackTranscript(_ c: ChatConversation) -> String {
        ([c.jackContext?.seed].compactMap { $0 } + c.messages.filter { ["user", "assistant", "tool"].contains($0.role) }.map {
            "\($0.role): \($0.text)" + ($0.role == "tool" ? "\n" + String($0.detail.prefix(4000)) : "") + ($0.attachments.map { "\nArchivos adjuntos: " + $0.joined(separator: ", ") } ?? "")
        }).joined(separator: "\n\n")
    }
    func executeJack(_ name: String, arguments a: String, to id: UUID) {
        guard runs[id] == nil, !queue.contains(where: { $0.0 == id }) else {
            errorMessage = "Espera a que termine el turno para usar comandos !."; return
        }
        loadTranscript(id)
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        var settings = conversations[i].jackContext ?? JackContextSettings()
        let words = a.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func positive(_ value: String?) -> Int? {
            guard let value, let n = Int(value), n > 0, n <= 2_000_000 else { return nil }; return n
        }
        switch name {
        case "compact":
            guard words.count == 1, let n = positive(words.first) else { errorMessage = "Uso: !compact 8000 (1–2000000 tokens)."; return }
            beginCompaction(id, target: n); return
        case "autocompact":
            if a == "off" { settings.autoThreshold = nil; settings.autoTarget = nil }
            else {
                guard words.count == 2, let threshold = positive(words.first), let target = positive(words.last), target < threshold else {
                    errorMessage = "Uso: !autocompact 30000 8000; el objetivo debe ser menor que el umbral. O !autocompact off."; return
                }
                settings.autoThreshold = threshold; settings.autoTarget = target
            }
        case "contexto":
            let c = conversations[i]
            let usage = c.contextUsage.map { "\($0.used)" + ($0.window.map { " / \($0)" } ?? "") + " tokens reportados por el proveedor" }
                ?? "≈\(JackCommandCatalog.estimatedTokens(jackTranscript(c))) tokens estimados del historial visible; el contexto real no está disponible"
            jackNotice("Contexto: \(usage).\nInstrucciones fijadas: \(settings.pinned.count).\nAutocompact: \(settings.autoThreshold.map(String.init) ?? "off") → \(settings.autoTarget.map(String.init) ?? "—").\nPresupuesto: \(settings.spent) / \(settings.budget.map(String.init) ?? "sin límite") tokens observados (aproximados).\nEl proveedor no informa un desglose exacto por mensajes, herramientas o instrucciones.", to: id); return
        case "fijar":
            if a == "listar" {
                jackNotice(settings.pinned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n").nilIfEmpty ?? "No hay instrucciones fijadas.", to: id); return
            } else if words.first == "quitar" {
                guard words.count == 2, let n = Int(words[1]), settings.pinned.indices.contains(n - 1) else { errorMessage = "Uso: !fijar quitar número (consulta !fijar listar)."; return }
                settings.pinned.remove(at: n - 1)
            } else {
                guard !a.isEmpty else { errorMessage = "Uso: !fijar texto | listar | quitar número."; return }
                if !settings.pinned.contains(a) { settings.pinned.append(a) }
            }
        case "presupuesto":
            guard a == "off" || (words.count == 1 && positive(a) != nil) else { errorMessage = "Uso: !presupuesto 20000 | off."; return }
            settings.budget = a == "off" ? nil : positive(a); settings.spent = 0; settings.budgetWarned = false
        case "resumen":
            send("Resume el objetivo, avances, decisiones y tareas pendientes de esta conversación. No uses herramientas ni modifiques archivos. " + a, to: id); return
        case "revisar":
            send("Revisa los cambios actuales del proyecto buscando errores y regresiones. Explica hallazgos con archivos y líneas; no modifiques archivos. " + a, to: id); return
        case "plan":
            guard !a.isEmpty else { errorMessage = "Uso: !plan tarea."; return }
            conversations[i].mode = "plan"
            liveDrivers[id]?.close(); liveDrivers.removeValue(forKey: id)
            save(id)
            send("Planifica la siguiente tarea. No modifiques archivos ni ejecutes acciones con efectos secundarios: " + a, to: id); return
        case "checkpoint":
            do {
                if a.hasPrefix("restaurar ") {
                    let label = String(a.dropFirst("restaurar ".count))
                    guard !label.isEmpty, label.utf8.count <= 120 else { errorMessage = "Indica el nombre del checkpoint."; return }
                    let c = try JSONDecoder().decode(ChatConversation.self, from: Data(contentsOf: checkpointURL(id, name: label)))
                    forkJack(c, title: label, seed: jackTranscript(c))
                } else {
                    guard !a.isEmpty, a.utf8.count <= 120 else { errorMessage = "Uso: !checkpoint nombre | restaurar nombre (máximo 120 bytes)."; return }
                    let url = checkpointURL(id, name: a)
                    guard !FileManager.default.fileExists(atPath: url.path) else { errorMessage = "Ya existe ese checkpoint. Usa otro nombre."; return }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(conversations[i]).write(to: url, options: .atomic)
                    jackNotice("Checkpoint «\(a)» guardado. !checkpoint restaurar \(a) lo abre en una conversación nueva; no revierte archivos del proyecto.", to: id)
                }
            } catch { errorMessage = "No se pudo acceder al checkpoint: \(error.localizedDescription)" }
            return
        case "rama":
            guard !a.isEmpty else { errorMessage = "Uso: !rama nombre."; return }
            forkJack(conversations[i], title: a, seed: jackTranscript(conversations[i])); return
        case "traspasar":
            if !a.isEmpty {
                guard let provider = ChatProvider(rawValue: a) else { errorMessage = "Uso: !traspasar [codex | claude | opencode]."; return }
                cancelledJackTurns.remove(id)
                handoffs[id] = (provider, conversations[i].messages.count)
            }
            send("Prepara un resumen de traspaso para continuar con otro agente: objetivo, decisiones, archivos relevantes, estado y pendientes. Incluye instrucciones fijadas. No uses herramientas ni modifiques archivos.", to: id); return
        case "comandos":
            manageJackTemplates(a, id: id); return
        default:
            guard let template = jackTemplates.first(where: { $0.name == name }) else { errorMessage = "Comando !\(name) desconocido. Consulta !comandos. Para enviar un ! literal escribe !!."; return }
            let prompt = template.prompt.contains("{{args}}") ? template.prompt.replacingOccurrences(of: "{{args}}", with: a) : template.prompt + (a.isEmpty ? "" : "\n" + a)
            send(prompt.hasPrefix("!") ? "!" + prompt : prompt, to: id); return
        }
        conversations[i].jackContext = settings
        jackNotice("!\(name): configuración guardada.", to: id)
    }
    func beginCompaction(_ id: UUID, target: Int) {
        loadTranscript(id)
        guard let c = conversations.first(where: { $0.id == id }) else { return }
        cancelledJackTurns.remove(id)
        compactions[id] = (target, c.messages.count)
        let history = c.sessionID == nil ? "\n\nHistorial a resumir:\n" + jackTranscript(c) : ""
        send("Resume el contexto de esta conversación para continuar en una sesión nueva con aproximadamente \(target) tokens. Conserva objetivos, decisiones, restricciones, archivos relevantes y tareas pendientes. Incluye las instrucciones fijadas. Devuelve únicamente el resumen. No uses herramientas ni modifiques archivos." + history, to: id)
    }
    func completeJackTurn(_ id: UUID, cancelled: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let budget = conversations[i].jackContext?.budget {
            conversations[i].jackContext?.spent += budgetTurnUsage[id] ?? 0
            let spent = conversations[i].jackContext?.spent ?? 0
            if spent >= Int(Double(budget) * 0.8), conversations[i].jackContext?.budgetWarned != true {
                conversations[i].jackContext?.budgetWarned = true
                jackNotice("Presupuesto: \(spent) / \(budget) tokens observados. Aviso al superar el 80 %; el seguimiento es aproximado y no detiene al agente.", to: id)
            }
        }
        budgetTurnUsage.removeValue(forKey: id)
        budgetBaseline.removeValue(forKey: id)
        let explicitlyCancelled = cancelledJackTurns.remove(id) != nil
        let success = !cancelled && !explicitlyCancelled && statuses[id] != .failed
        if seededJackTurns.remove(id) != nil, success { conversations[i].jackContext?.seedDelivered = true }
        if let operation = compactions.removeValue(forKey: id) {
            let summary = conversations[i].messages.dropFirst(operation.firstMessage).last(where: { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
            if success, let summary {
                var settings = conversations[i].jackContext ?? JackContextSettings(); settings.seed = summary; settings.seedDelivered = false
                conversations[i].jackContext = settings
                conversations[i].sessionID = nil; conversations[i].contextUsage = nil; conversations[i].tokenUsage = nil
                tokenUsage.removeValue(forKey: id)
                liveDrivers.removeValue(forKey: id)?.close()
                jackNotice("Contexto compactado: resumen de ≈\(JackCommandCatalog.estimatedTokens(summary)) tokens (objetivo: ≈\(operation.target)). La próxima respuesta usará una sesión nueva. El historial sigue disponible.", to: id)
                if let next = afterCompaction.removeValue(forKey: id) {
                    // Do not trigger compaction twice while the new session has no telemetry.
                    send(next.0, attachments: next.1, to: id)
                }
            } else {
                if let next = afterCompaction.removeValue(forKey: id) {
                    jackNotice("La compactación no terminó. Mensaje pendiente (vuelve a enviarlo):\n\(next.0)", to: id)
                    if !next.1.isEmpty { conversations[i].messages.append(ChatMessage(role: "jack", text: "Archivos del mensaje pendiente", attachments: next.1)) }
                }
                jackNotice("No se sustituyó el contexto: la compactación falló o se canceló.", to: id)
            }
        }
        if let handoff = handoffs.removeValue(forKey: id), success,
           let reply = conversations[i].messages.dropFirst(handoff.firstMessage).last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text {
            forkJack(conversations[i], title: "Traspaso a " + handoff.provider.title, seed: reply, provider: handoff.provider)
        }
    }
    func forkJack(_ source: ChatConversation, title: String, seed: String, provider: ChatProvider? = nil) {
        var c = source
        c.id = UUID(); c.title = String(title.prefix(120)); c.sessionID = nil; c.parentID = source.id
        c.updatedAt = Date(); c.hasUnread = nil; c.contextUsage = nil; c.tokenUsage = nil
        var settings = source.jackContext ?? JackContextSettings(); settings.seed = seed; settings.seedDelivered = false; settings.spent = 0; settings.budgetWarned = false
        c.jackContext = settings
        if let provider, provider != source.provider { c.provider = provider; c.model = provider.defaultModel; c.mode = nil; c.variant = nil; c.effort = Self.clamp("high", to: supportedEfforts(provider: provider, model: c.model)) }
        conversations.insert(c, at: 0); loaded.insert(c.id); save(c.id); select(c.id)
        jackNotice("Conversación independiente creada. El contexto anterior se enviará al escribir el primer mensaje.", to: c.id)
    }
    func checkpointURL(_ id: UUID, name: String) -> URL {
        // A bounded, reversible file name prevents paths escaping the archive.
        let encoded = Data(name.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return archive.directory.appendingPathComponent("Checkpoints/" + id.uuidString, isDirectory: true).appendingPathComponent(encoded + ".json")
    }
    func manageJackTemplates(_ arguments: String, id: UUID) {
        let parts = arguments.split(maxSplits: 2, whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.isEmpty {
            let rows = JackCommandCatalog.builtins.map { "!\($0.name) \($0.argumentHint) — \($0.description)" } + jackTemplates.map { "!\($0.name) — \($0.prompt)" }
            jackNotice(rows.joined(separator: "\n") + "\n\nPlantillas: !comandos crear nombre texto ({{args}} inserta argumentos); !comandos eliminar nombre.", to: id); return
        }
        var templates = jackTemplates
        if parts.count == 3, parts[0] == "crear" {
            let name = parts[1].lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), !JackCommandCatalog.builtins.contains(where: { $0.name == name }) else { errorMessage = "Usa un nombre con letras, números, - o _, sin ! y distinto a los comandos integrados."; return }
            templates.removeAll { $0.name == name }; templates.append(.init(name: name, prompt: parts[2]))
        } else if parts.count == 2, parts[0] == "eliminar", templates.contains(where: { $0.name == parts[1] }) {
            templates.removeAll { $0.name == parts[1] }
        } else { errorMessage = "Uso: !comandos crear nombre texto | eliminar nombre."; return }
        do {
            try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(templates).write(to: archive.directory.appendingPathComponent("commands.json"), options: .atomic)
            jackTemplates = templates; jackNotice("Plantillas personales actualizadas.", to: id)
        } catch { errorMessage = "No se pudieron guardar los comandos: \(error.localizedDescription)" }
    }
}
public extension ChatStore {
    var jackCommands: [ChatCommand] { JackCommandCatalog.builtins + jackTemplates.map { .init(name: $0.name, description: $0.prompt, argumentHint: "argumentos opcionales") } }
}
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
