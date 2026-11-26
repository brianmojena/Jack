import Foundation

/// A persistent teammate: one long-lived conversation with its own name, instructions and folder.
public struct BotAgent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var instructions: String
    public var projectPath: String
    public var provider: ChatProvider
    /// Empty uses the provider's default model.
    public var model: String
    /// Created with the first message and kept for good.
    public var conversationID: UUID?
    /// Lets scripts message this agent through the local API.
    public var allowScripts: Bool
    /// The «Jack» agent of the table: the one that proposes teams. At most one is meant to exist.
    public var isPrincipal: Bool? = nil
    /// Set on agents the principal created (with the user's approval): who made them.
    public var parentID: UUID? = nil

    public init(id: UUID = UUID(), name: String, instructions: String = "", projectPath: String, provider: ChatProvider,
                model: String = "", conversationID: UUID? = nil, allowScripts: Bool = false,
                isPrincipal: Bool? = nil, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.instructions = instructions; self.projectPath = projectPath; self.provider = provider
        self.model = model; self.conversationID = conversationID; self.allowScripts = allowScripts
        self.isPrincipal = isPrincipal; self.parentID = parentID
    }
}

/// An instruction sent to a bot agent on a schedule. It replaces `Automation`, which started a new agent every time.
public struct BotRoutine: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var name: String
    public var instruction: String
    public var frequency: AutomationFrequency
    public var startAt: Date
    public var weekday: Int
    public var intervalMinutes: Int
    public var paused: Bool
    /// Runs only when a script calls it through the local API: a local webhook, with no schedule.
    public var apiOnly: Bool? = nil
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastError: String?

    public init(id: UUID = UUID(), agentID: UUID, name: String, instruction: String, frequency: AutomationFrequency = .daily,
                startAt: Date, weekday: Int = 2, intervalMinutes: Int = 60, paused: Bool = false, apiOnly: Bool? = nil,
                createdAt: Date = Date(), lastRunAt: Date? = nil) {
        self.id = id; self.agentID = agentID; self.name = name; self.instruction = instruction; self.frequency = frequency
        self.startAt = startAt; self.weekday = weekday; self.intervalMinutes = max(1, intervalMinutes); self.paused = paused
        self.apiOnly = apiOnly; self.createdAt = createdAt; self.lastRunAt = lastRunAt
    }

    /// An agent answers with only this when a scheduled run has nothing to report; the run then stays quiet.
    public static let quietMarker = "[[no-update]]"
    static let quietNote = "\n\n(Si no hay nada nuevo que contar, responde únicamente con \(quietMarker).)"

    /// Same rules as `Automation.nextRun`, which it borrows rather than copies.
    public func nextRun(calendar: Calendar = .current, now: Date = Date()) -> Date? {
        guard apiOnly != true else { return nil }
        var schedule = Automation(name: name, prompt: instruction, projectPath: "", provider: .claude, frequency: frequency,
                                  startAt: startAt, weekday: weekday, intervalMinutes: intervalMinutes, enabled: !paused, createdAt: createdAt)
        schedule.lastRunAt = lastRunAt
        return schedule.nextRun(calendar: calendar, now: now)
    }
}

/// One line of a channel's shared history. `authorID` is nil when the user wrote it.
public struct BotChannelMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var authorID: UUID?
    public var text: String
    public var at: Date
    public init(id: UUID = UUID(), authorID: UUID?, text: String, at: Date = Date()) {
        self.id = id; self.authorID = authorID; self.text = text; self.at = at
    }
}

/// A shared thread with one task owner. Only the owner hears the user; the other members join by explicit delegation.
public struct BotChannel: Identifiable, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, stopped, archived }
    /// Older lines are dropped, so a long-lived channel stays small on disk.
    public static let maxMessages = 200
    public var id: UUID
    public var name: String
    public var memberIDs: [UUID]
    public var ownerID: UUID
    public var state: State
    public var messages: [BotChannelMessage]

    public init(id: UUID = UUID(), name: String, memberIDs: [UUID], ownerID: UUID, state: State = .active, messages: [BotChannelMessage] = []) {
        self.id = id; self.name = name; self.memberIDs = memberIDs; self.ownerID = ownerID; self.state = state; self.messages = messages
    }
}

/// Bot agents and their routines, saved beside the chats and checked while Jack runs.
@MainActor public final class BotStore: ObservableObject {
    @Published public private(set) var agents: [BotAgent] = []
    @Published public private(set) var routines: [BotRoutine] = []
    @Published public private(set) var channels: [BotChannel] = []
    /// Whether the old automations were already turned into agents and routines.
    public private(set) var migrated = false
    /// Sends a routine's instruction to its agent's conversation and returns that conversation, or why it could not.
    public var run: (BotAgent, BotRoutine) -> Result<UUID, ScheduleCenter.ScheduleError> = { _, _ in .failure(.init("Sin agente")) }
    /// Puts a text into an agent's own conversation and returns that conversation, or why it could not.
    public var deliver: (BotAgent, String) -> Result<UUID, ScheduleCenter.ScheduleError> = { _, _ in .failure(.init("Sin agente")) }
    public var onError: (String) -> Void = { _ in }
    private let url: URL
    private var ticker: Task<Void, Never>?
    private let writer = DispatchQueue(label: "dev.jack.bot.persistence", qos: .utility)

    private struct Saved: Codable, Sendable { var agents: [BotAgent]; var routines: [BotRoutine]; var migrated: Bool; var channels: [BotChannel]? }

    public init(directory: URL) {
        url = directory.appendingPathComponent("jackbot.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            agents = saved.agents; routines = saved.routines; migrated = saved.migrated; channels = saved.channels ?? []
        }
    }

    public func routines(of agent: UUID) -> [BotRoutine] { routines.filter { $0.agentID == agent } }

    public func upsert(_ agent: BotAgent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        save()
    }
    /// Removes the agent and its routines. Its conversation stays, as a normal chat the caller decides about.
    public func remove(agent id: UUID) {
        agents.removeAll { $0.id == id }; routines.removeAll { $0.agentID == id }
        for index in channels.indices where channels[index].memberIDs.contains(id) {
            channels[index].memberIDs.removeAll { $0 == id }
            if let next = channels[index].memberIDs.first { if channels[index].ownerID == id { channels[index].ownerID = next } }
            else { channels[index].state = .archived }
        }
        save()
    }

    /// Agents whose name equals the reference, or else whose id starts with it (at least 4 characters).
    public func agents(matching reference: String) -> [BotAgent] { Self.match(agents, reference, name: \.name) }
    public func channels(matching reference: String) -> [BotChannel] { Self.match(channels, reference, name: \.name) }
    private static func match<T: Identifiable>(_ items: [T], _ reference: String, name: KeyPath<T, String>) -> [T] where T.ID == UUID {
        let key = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        let byName = items.filter { $0[keyPath: name].lowercased() == key }
        if byName.count == 1 || key.count < 4 { return byName }
        let byID = items.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        return byID.isEmpty ? byName : byID
    }

    // MARK: Channels

    /// A channel needs its owner among its members and at least one member.
    public func upsert(_ channel: BotChannel) {
        guard channel.memberIDs.contains(channel.ownerID) else { return }
        if let index = channels.firstIndex(where: { $0.id == channel.id }) { channels[index] = channel } else { channels.append(channel) }
        save()
    }
    public func remove(channel id: UUID) { channels.removeAll { $0.id == id }; save() }
    public func setState(_ state: BotChannel.State, for id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].state = state; save()
    }
    /// Hands the task to another member; a non-member is ignored.
    public func setOwner(_ owner: UUID, in id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].memberIDs.contains(owner) else { return }
        channels[index].ownerID = owner; save()
    }

    /// The user writes in a channel; the owner hears it unless the channel is stopped. Returns why it was not delivered.
    @discardableResult
    public func post(_ text: String, inChannel id: UUID) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = channels.firstIndex(where: { $0.id == id }) else { return nil }
        guard channels[index].state != .archived else { return "El canal está archivado." }
        append(BotChannelMessage(authorID: nil, text: text), to: index)
        guard channels[index].state == .active, let owner = agents.first(where: { $0.id == channels[index].ownerID }) else { return nil }
        let note = "Canal «\(channels[index].name)». El usuario escribe:\n\(text)\n\nEres el dueño de esta tarea. Si necesitas a otro miembro, delégale con channel_post (delegate_to)."
        if case .failure(let error) = deliver(owner, note) { return "No se pudo avisar a \(owner.name): \(error.message)" }
        return nil
    }

    /// An agent writes in a channel it belongs to, and may hand work to another member.
    public func post(_ text: String, from author: UUID, inChannel id: UUID, delegateTo target: UUID? = nil) -> Result<String, ScheduleCenter.ScheduleError> {
        typealias Failure = ScheduleCenter.ScheduleError
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(Failure("El mensaje está vacío.")) }
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].memberIDs.contains(author) else {
            return .failure(Failure("No eres miembro de ese canal."))
        }
        guard channels[index].state == .active else {
            return .failure(Failure(channels[index].state == .stopped ? "El canal está detenido: no publiques hasta que el usuario lo reanude." : "El canal está archivado."))
        }
        var recipient: BotAgent?
        if let target {
            guard target != author, channels[index].memberIDs.contains(target), let agent = agents.first(where: { $0.id == target }) else {
                return .failure(Failure("Solo puedes delegar en otro miembro del canal."))
            }
            recipient = agent
        }
        append(BotChannelMessage(authorID: author, text: text), to: index)
        guard let recipient else { return .success("Publicado en el canal.") }
        let name = agents.first(where: { $0.id == author })?.name ?? "un agente"
        let note = "Canal «\(channels[index].name)». «\(name)» te delega:\n\(text)"
        switch deliver(recipient, note) {
        case .success: return .success("Publicado y delegado en \(recipient.name).")
        case .failure(let error): return .failure(Failure("Publicado, pero no se pudo avisar a \(recipient.name): \(error.message)"))
        }
    }

    private func append(_ message: BotChannelMessage, to index: Int) {
        channels[index].messages.append(message)
        if channels[index].messages.count > BotChannel.maxMessages { channels[index].messages.removeFirst(channels[index].messages.count - BotChannel.maxMessages) }
        save()
    }
    public func upsert(_ routine: BotRoutine) {
        guard agents.contains(where: { $0.id == routine.agentID }) else { return }
        if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index] = routine } else { routines.append(routine) }
        save()
    }
    public func setConversation(_ conversation: UUID, for agent: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == agent }), agents[index].conversationID != conversation else { return }
        agents[index].conversationID = conversation; save()
    }
    public func remove(routine id: UUID) { routines.removeAll { $0.id == id }; save() }
    public func setPaused(_ paused: Bool, for id: UUID) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].paused = paused
        // Resuming must not catch up on what passed while it was paused.
        if !paused { routines[index].createdAt = Date() }
        save()
    }
    /// Runs a routine now, whatever its schedule says.
    public func runNow(_ id: UUID) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        fire(index)
    }

    /// Turns each old automation into an agent with one routine. Written to disk before returning, so the caller can
    /// clear the old automations only after this succeeded.
    @discardableResult
    public func migrate(_ automations: [Automation]) -> Bool {
        guard !migrated else { return true }
        for old in automations {
            let agent = BotAgent(name: old.name, projectPath: old.projectPath, provider: old.provider, model: old.model)
            agents.append(agent)
            // Keeping createdAt and lastRunAt means the next run is exactly the one the automation had.
            routines.append(BotRoutine(agentID: agent.id, name: old.name, instruction: old.prompt, frequency: old.frequency,
                                       startAt: old.startAt, weekday: old.weekday, intervalMinutes: old.intervalMinutes,
                                       paused: !old.enabled, createdAt: old.createdAt, lastRunAt: old.lastRunAt))
        }
        migrated = true
        do { try Self.write(snapshot(), to: url) } catch {
            agents.removeLast(automations.count); routines.removeLast(automations.count); migrated = false
            onError("No se pudieron migrar las automatizaciones a Jack Bot: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// Checks every 20 seconds: cheap, and robust to the Mac sleeping through a due time.
    public func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.fireDue()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
    public func stop() { ticker?.cancel(); ticker = nil }

    func fireDue(now: Date = Date()) {
        for index in routines.indices {
            guard let next = routines[index].nextRun(now: now), next <= now else { continue }
            fire(index, now: now)
        }
    }

    private func fire(_ index: Int, now: Date = Date()) {
        let routine = routines[index]
        routines[index].lastRunAt = now
        guard let agentIndex = agents.firstIndex(where: { $0.id == routine.agentID }) else {
            routines[index].lastError = "el agente ya no existe"; save(); return
        }
        switch run(agents[agentIndex], routine) {
        case .success(let conversation): agents[agentIndex].conversationID = conversation; routines[index].lastError = nil
        case .failure(let error):
            routines[index].lastError = error.message
            onError("Rutina «\(routine.name)»: \(error.message)")
        }
        save()
    }

    private func snapshot() -> Saved { Saved(agents: agents, routines: routines, migrated: migrated, channels: channels) }

    private nonisolated static func write(_ snapshot: Saved, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func save() {
        let snapshot = snapshot(), url = url
        writer.async { try? Self.write(snapshot, to: url) }
    }
}
