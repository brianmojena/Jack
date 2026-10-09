import Foundation

/// A message the user left in a conversation to be sent at a given time.
public struct ScheduledMessage: Identifiable, Codable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var text: String
    public var attachments: [String]
    public var fireAt: Date
    public init(id: UUID = UUID(), conversationID: UUID, text: String, attachments: [String] = [], fireAt: Date) {
        self.id = id; self.conversationID = conversationID; self.text = text; self.attachments = attachments; self.fireAt = fireAt
    }
}

public enum AutomationFrequency: String, Codable, CaseIterable, Identifiable {
    case once, interval, daily, weekdays, weekly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .once: return "Una vez"
        case .interval: return "Cada cierto tiempo"
        case .daily: return "Cada día"
        case .weekdays: return "De lunes a viernes"
        case .weekly: return "Cada semana"
        }
    }
}

/// A prompt Jack sends to a fresh agent on a schedule.
public struct Automation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var prompt: String
    public var projectPath: String
    public var provider: ChatProvider
    /// Empty uses the provider's default model.
    public var model: String
    public var frequency: AutomationFrequency
    /// `once`: when it runs. Daily, weekdays and weekly: only its time of day counts. Interval: the first run.
    public var startAt: Date
    /// 1 = Sunday … 7 = Saturday, for weekly runs.
    public var weekday: Int
    public var intervalMinutes: Int
    public var enabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastConversationID: UUID?
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, prompt: String, projectPath: String, provider: ChatProvider, model: String = "",
                frequency: AutomationFrequency = .daily, startAt: Date, weekday: Int = 2, intervalMinutes: Int = 60,
                enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.prompt = prompt; self.projectPath = projectPath; self.provider = provider; self.model = model
        self.frequency = frequency; self.startAt = startAt; self.weekday = weekday; self.intervalMinutes = max(1, intervalMinutes)
        self.enabled = enabled; self.createdAt = createdAt
    }

    /// When it should run next, or nil when it will not run again. A run missed while Jack was closed is due at once.
    public func nextRun(calendar: Calendar = .current, now: Date = Date()) -> Date? {
        guard enabled else { return nil }
        switch frequency {
        case .once:
            return lastRunAt == nil ? startAt : nil
        case .interval:
            return lastRunAt.map { $0.addingTimeInterval(Double(intervalMinutes) * 60) } ?? startAt
        case .daily, .weekdays, .weekly:
            var parts = calendar.dateComponents([.hour, .minute], from: startAt)
            if frequency == .weekly { parts.weekday = weekday }
            let reference = lastRunAt ?? createdAt
            var candidate = reference
            // Weekdays skip Saturday and Sunday; a handful of steps always reaches one.
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: candidate, matching: parts, matchingPolicy: .nextTime) else { return nil }
                if frequency != .weekdays || !calendar.isDateInWeekend(next) { return next }
                candidate = next
            }
            return nil
        }
    }
}

/// Messages left for later and automations, saved beside the chats and checked while Jack runs.
@MainActor public final class ScheduleCenter: ObservableObject {
    @Published public private(set) var messages: [ScheduledMessage] = []
    @Published public private(set) var automations: [Automation] = []
    /// Sends a scheduled message; false when its conversation is gone.
    public var deliver: (ScheduledMessage) -> Bool = { _ in false }
    /// Starts an automation's agent and returns it, or throws why it could not start.
    public var launch: (Automation) -> Result<UUID, ScheduleError> = { _ in .failure(.init("Sin agente")) }
    public var onError: (String) -> Void = { _ in }
    private let url: URL
    private var ticker: Task<Void, Never>?
    private let writer = DispatchQueue(label: "dev.jack.schedules.persistence", qos: .utility)

    public struct ScheduleError: Error { public let message: String; public init(_ message: String) { self.message = message } }
    private struct Saved: Codable { var messages: [ScheduledMessage]; var automations: [Automation] }

    public init(directory: URL) {
        url = directory.appendingPathComponent("schedules.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            messages = saved.messages; automations = saved.automations
        }
    }

    public func messages(for conversation: UUID) -> [ScheduledMessage] {
        messages.filter { $0.conversationID == conversation }.sorted { $0.fireAt < $1.fireAt }
    }
    public func schedule(_ text: String, attachments: [String] = [], in conversation: UUID, at date: Date) {
        messages.append(ScheduledMessage(conversationID: conversation, text: text, attachments: attachments, fireAt: date))
        save()
    }
    public func cancelMessage(_ id: UUID) { messages.removeAll { $0.id == id }; save() }
    public func discardMessages(of conversation: UUID) {
        guard messages.contains(where: { $0.conversationID == conversation }) else { return }
        messages.removeAll { $0.conversationID == conversation }; save()
    }

    public func upsert(_ automation: Automation) {
        if let index = automations.firstIndex(where: { $0.id == automation.id }) { automations[index] = automation }
        else { automations.append(automation) }
        save()
    }
    public func removeAutomation(_ id: UUID) { automations.removeAll { $0.id == id }; save() }
    public func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].enabled = enabled
        // Re-enabling must not catch up on what passed while it was off.
        if enabled { automations[index].createdAt = Date() }
        save()
    }
    /// Runs an automation now, whatever its schedule says.
    public func runNow(_ id: UUID) {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        run(index)
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
        for message in messages.filter({ $0.fireAt <= now }) {
            messages.removeAll { $0.id == message.id }
            if !deliver(message) { onError("No se pudo enviar el mensaje programado: la conversación ya no existe.") }
        }
        for index in automations.indices {
            guard let next = automations[index].nextRun(now: now), next <= now else { continue }
            run(index, now: now)
        }
        save()
    }

    private func run(_ index: Int, now: Date = Date()) {
        automations[index].lastRunAt = now
        switch launch(automations[index]) {
        case .success(let id): automations[index].lastConversationID = id; automations[index].lastError = nil
        case .failure(let error):
            automations[index].lastError = error.message
            onError("Automatización «\(automations[index].name)»: \(error.message)")
        }
        save()
    }

    private func save() {
        let snapshot = Saved(messages: messages, automations: automations)
        let url = url
        writer.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {}
        }
    }
}
