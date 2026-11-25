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

    public init(id: UUID = UUID(), name: String, instructions: String = "", projectPath: String, provider: ChatProvider,
                model: String = "", conversationID: UUID? = nil, allowScripts: Bool = false) {
        self.id = id; self.name = name; self.instructions = instructions; self.projectPath = projectPath; self.provider = provider
        self.model = model; self.conversationID = conversationID; self.allowScripts = allowScripts
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
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastError: String?

    public init(id: UUID = UUID(), agentID: UUID, name: String, instruction: String, frequency: AutomationFrequency = .daily,
                startAt: Date, weekday: Int = 2, intervalMinutes: Int = 60, paused: Bool = false, createdAt: Date = Date(),
                lastRunAt: Date? = nil) {
        self.id = id; self.agentID = agentID; self.name = name; self.instruction = instruction; self.frequency = frequency
        self.startAt = startAt; self.weekday = weekday; self.intervalMinutes = max(1, intervalMinutes); self.paused = paused
        self.createdAt = createdAt; self.lastRunAt = lastRunAt
    }

    /// Same rules as `Automation.nextRun`, which it borrows rather than copies.
    public func nextRun(calendar: Calendar = .current, now: Date = Date()) -> Date? {
        var schedule = Automation(name: name, prompt: instruction, projectPath: "", provider: .claude, frequency: frequency,
                                  startAt: startAt, weekday: weekday, intervalMinutes: intervalMinutes, enabled: !paused, createdAt: createdAt)
        schedule.lastRunAt = lastRunAt
        return schedule.nextRun(calendar: calendar, now: now)
    }
}

/// Bot agents and their routines, saved beside the chats and checked while Jack runs.
@MainActor public final class BotStore: ObservableObject {
    @Published public private(set) var agents: [BotAgent] = []
    @Published public private(set) var routines: [BotRoutine] = []
    /// Whether the old automations were already turned into agents and routines.
    public private(set) var migrated = false
    /// Sends a routine's instruction to its agent's conversation and returns that conversation, or why it could not.
    public var run: (BotAgent, BotRoutine) -> Result<UUID, ScheduleCenter.ScheduleError> = { _, _ in .failure(.init("Sin agente")) }
    public var onError: (String) -> Void = { _ in }
    private let url: URL
    private var ticker: Task<Void, Never>?
    private let writer = DispatchQueue(label: "dev.jack.bot.persistence", qos: .utility)

    private struct Saved: Codable, Sendable { var agents: [BotAgent]; var routines: [BotRoutine]; var migrated: Bool }

    public init(directory: URL) {
        url = directory.appendingPathComponent("jackbot.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            agents = saved.agents; routines = saved.routines; migrated = saved.migrated
        }
    }

    public func routines(of agent: UUID) -> [BotRoutine] { routines.filter { $0.agentID == agent } }

    public func upsert(_ agent: BotAgent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        save()
    }
    /// Removes the agent and its routines. Its conversation stays, as a normal chat the caller decides about.
    public func remove(agent id: UUID) {
        agents.removeAll { $0.id == id }; routines.removeAll { $0.agentID == id }; save()
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

    private func snapshot() -> Saved { Saved(agents: agents, routines: routines, migrated: migrated) }

    private nonisolated static func write(_ snapshot: Saved, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func save() {
        let snapshot = snapshot(), url = url
        writer.async { try? Self.write(snapshot, to: url) }
    }
}
