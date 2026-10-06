import Combine
import Foundation

@MainActor public final class ChatStore: ObservableObject {
    @Published public private(set) var conversations: [ChatConversation] = []
    @Published public var selectedID: UUID?
    @Published public private(set) var statuses: [UUID: ChatStatus] = [:]
    @Published public private(set) var approvals: [UUID: [ChatApproval]] = [:]
    @Published public var errorMessage: String?
    @Published public private(set) var maxConcurrent = 4
    @Published public private(set) var usage: [ChatProvider: ProviderUsage] = [:]
    @Published public private(set) var tokenUsage: [UUID: ChatTokenUsage] = [:]
    @Published public private(set) var refreshingUsage = false
    @Published public private(set) var recentModels: [ChatProvider: [String]] = [:]
    /// Slash commands per provider and project; nil while they have not been read.
    @Published public private(set) var commands: [String: [ChatCommand]] = [:]
    @Published public private(set) var loadingCommands = Set<String>()
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
    public func refreshUsage() async {
        guard !refreshingUsage else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }
        await withTaskGroup(of: ProviderUsage.self) { group in
            for provider in ChatProvider.allCases { group.addTask { await ChatUsageService.read(provider) } }
            for await result in group { mergeUsage(result) }
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
    public func select(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if !loaded.contains(id) {
            do { if let transcript = try archive.load(id) { conversations[index].messages = transcript.messages }; loaded.insert(id) }
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
    /// Reads the provider's commands once per project; runs also refresh them as they report changes.
    public func loadCommands(for conversation: ChatConversation) {
        let key = Self.commandKey(conversation.provider, conversation.projectPath)
        guard commands[key] == nil, !loadingCommands.contains(key) else { return }
        loadingCommands.insert(key)
        Task { [weak self] in
            let list = (try? await self?.loadCommandList(conversation.provider, conversation.projectPath)) ?? []
            guard let self else { return }
            self.loadingCommands.remove(key)
            if self.commands[key] == nil || !list.isEmpty { self.commands[key] = list }
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
    public func send(_ prompt: String, attachments: [String] = [], to id: UUID) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }), runs[id] == nil, !queue.contains(where: { $0.0 == id }), !stopped else { return }
        if !loaded.contains(id) {
            if let transcript = try? archive.load(id) { conversations[index].messages = transcript.messages }
            loaded.insert(id)
        }
        conversations[index].messages.append(ChatMessage(role: "user", text: text, attachments: attachments.isEmpty ? nil : attachments))
        if conversations[index].title == "Nuevo agente" {
            let title = text.isEmpty ? attachments.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") : text
            conversations[index].title = String(title.prefix(55)).replacingOccurrences(of: "\n", with: " ")
        }
        conversations[index].updatedAt = Date()
        save(id)
        statuses[id] = .queued
        queue.append((id, text))
        drainQueue()
    }
    public func stop(_ id: UUID) {
        queue.removeAll { $0.0 == id }
        if let driver = drivers[id] {
            driver.stop()
            runs[id]?.cancel()
        } else { statuses[id] = .idle }
        approvals[id] = []
    }
    public func respond(conversationID id: UUID, approvalID: String, allow: Bool) {
        guard let driver = drivers[id] else { return }
        Task { [weak self] in
            do {
                try await driver.respond(approvalID: approvalID, allow: allow)
                self?.approvals[id]?.removeAll { $0.id == approvalID }
                self?.statuses[id] = self?.approvals[id]?.isEmpty == false ? .waiting : .running
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
                self?.approvals[id]?.removeAll { $0.id == approvalID }
                self?.statuses[id] = self?.approvals[id]?.isEmpty == false ? .waiting : .running
            } catch { self?.errorMessage = "No se pudo enviar la respuesta: \(error.localizedDescription)" }
        }
    }
    public func remove(_ id: UUID) {
        guard runs[id] == nil, !queue.contains(where: { $0.0 == id }) else { return }
        conversations.removeAll { $0.id == id }; loaded.remove(id); statuses.removeValue(forKey: id); approvals.removeValue(forKey: id)
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
        guard runs[id] == nil, !queue.contains(where: { $0.0 == id }),
              let index = conversations.firstIndex(where: { $0.id == id }),
              mode == nil || supported.contains(where: { $0.id == mode }) else { return }
        conversations[index].mode = mode
        save(id)
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
        archive.flush()
    }
    private func drainQueue() {
        guard !stopped else { return }
        while (maxConcurrent == 0 || runs.count - delegatedWaits.count < maxConcurrent), !queue.isEmpty {
            let (id, prompt) = queue.removeFirst()
            guard let conversation = conversations.first(where: { $0.id == id }) else { continue }
            let driver = makeDriver(conversation.provider)
            drivers[id] = driver; statuses[id] = .running
            // Only top-level agents may delegate, so sub-agents cannot spawn more agents.
            let delegates = conversation.parentID == nil && delegationEnabled
            runs[id] = Task { [weak self] in
                do {
                    let delegation = delegates ? try? await self?.bridge.delegation(for: id) : nil
                    try await driver.run(conversation: conversation, prompt: prompt, delegation: delegation) { [weak self] event in self?.receive(event, for: id) }
                } catch {
                    if !Task.isCancelled { self?.receive(.failure(error.localizedDescription), for: id) }
                }
                guard let self else { return }
                self.flush(id)
                self.settleActivities(id)
                if self.statuses[id] != .failed { self.statuses[id] = .idle }
                self.approvals[id] = []
                self.finishTurn(id)
                self.drivers.removeValue(forKey: id); self.runs.removeValue(forKey: id)
                self.save(id); self.evictInactiveTranscripts(); self.drainQueue()
            }
        }
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
        case .tokens(let value): tokenUsage[id] = value; conversations[index].tokenUsage = value
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
