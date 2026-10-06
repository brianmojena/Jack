import Foundation

public enum ChatProvider: String, Codable, CaseIterable, Identifiable {
    case codex, claude, opencode
    public var id: String { rawValue }
    public var title: String { switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .opencode: return "OpenCode" } }
    public var defaultModel: String { switch self { case .codex: return "gpt-6-luna"; case .claude: return "sonnet"; case .opencode: return "" } }
}
public enum ChatStatus: String, Codable { case idle, queued, running, waiting, failed }
public struct ChatMessage: Identifiable, Codable, Equatable {
    public var id: String
    public var role: String
    public var text: String
    public var detail: String
    public var status: String
    /// Paths of the files the user attached to this message.
    public var attachments: [String]? = nil
    public init(id: String = UUID().uuidString, role: String, text: String, detail: String = "", status: String = "", attachments: [String]? = nil) { self.id = id; self.role = role; self.text = text; self.detail = detail; self.status = status; self.attachments = attachments }
}
public struct ChatApproval: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var questions: [ChatInputQuestion] = []
    public init(id: String, title: String, detail: String) { self.id = id; self.title = title; self.detail = detail }
}
public struct ChatInputQuestion: Identifiable, Decodable, Equatable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [ChatInputOption]?
    public var isSecret: Bool?
}
public struct ChatInputOption: Decodable, Equatable {
    public var label: String
    public var description: String
}
public struct ChatConversation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var projectPath: String
    public var provider: ChatProvider
    public var model: String
    public var effort: String
    public var variant: String? = nil
    public var mode: String? = nil
    public var sessionID: String?
    public var messages: [ChatMessage]
    public var updatedAt: Date
    public var tokenUsage: ChatTokenUsage? = nil
    /// How full the model's context window was after the last request.
    public var contextUsage: ChatContextUsage? = nil
    /// Short summary of the last turn, kept in the index so the sidebar works without loading transcripts.
    public var preview: String? = nil
    /// The last turn finished while the conversation was not selected.
    public var hasUnread: Bool? = nil
    /// The agent that delegated this one through Jack, if any.
    public var parentID: UUID? = nil
    /// Folders outside the project the agent may also read and edit.
    public var extraDirectories: [String]? = nil
    public init(id: UUID = UUID(), title: String = "Nuevo agente", projectPath: String, provider: ChatProvider = .codex, model: String? = nil, effort: String = "high", sessionID: String? = nil, messages: [ChatMessage] = [], updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.projectPath = projectPath; self.provider = provider; self.model = model ?? provider.defaultModel; self.effort = effort; self.sessionID = sessionID; self.messages = messages; self.updatedAt = updatedAt
    }
}
public extension ChatConversation {
    /// Extra folders, without the project itself or duplicates.
    var additionalDirectories: [String] {
        var seen: Set<String> = [projectPath]
        return (extraDirectories ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
public struct ChatRunMode: Identifiable, Equatable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
    public static func choices(for provider: ChatProvider) -> [ChatRunMode] {
        switch provider {
        case .codex: return [.init(id: "default", title: "Normal"), .init(id: "plan", title: "Plan"), .init(id: "auto", title: "Auto")]
        case .claude: return [.init(id: "manual", title: "Manual"), .init(id: "plan", title: "Plan"), .init(id: "auto", title: "Auto"), .init(id: "acceptEdits", title: "Aceptar ediciones"), .init(id: "dontAsk", title: "Sin preguntas")]
        case .opencode: return []
        }
    }
}
public enum ChatEvent {
    case session(String)
    case text(id: String, text: String, replace: Bool)
    case tool(id: String, title: String, detail: String, status: String)
    case reasoning(id: String, text: String, replace: Bool)
    case toolOutput(id: String, text: String)
    case usage(ProviderUsage)
    case tokens(ChatTokenUsage)
    /// Tokens in the context window after the latest request; either value may be unknown.
    case context(used: Int?, window: Int?)
    case commands([ChatCommand])
    case approval(ChatApproval)
    case approvalResolved(String)
    case completed
    case failure(String)
}
public struct UsageWindow: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var observedAt: Date
    public var remainingPercent: Double? {
        if let resetsAt, resetsAt <= Date() { return nil }
        return usedPercent.map { max(0, min(100, 100 - $0)) }
    }
    public init(id: String, title: String, usedPercent: Double?, resetsAt: Date? = nil, observedAt: Date = Date()) {
        self.id = id; self.title = title; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.observedAt = observedAt
    }
}
public struct ProviderUsage: Codable, Equatable {
    public var provider: ChatProvider
    public var windows: [UsageWindow]
    public var note: String
    public var isCached: Bool
    public init(provider: ChatProvider, windows: [UsageWindow] = [], note: String = "", isCached: Bool = false) { self.provider = provider; self.windows = windows; self.note = note; self.isCached = isCached }
}
public struct ChatTokenUsage: Codable, Equatable {
    public var input: Int
    public var output: Int
    public var cached: Int
    public var reasoning: Int
    public var costUSD: Double?
    public init(input: Int = 0, output: Int = 0, cached: Int = 0, reasoning: Int = 0, costUSD: Double? = nil) { self.input = input; self.output = output; self.cached = cached; self.reasoning = reasoning; self.costUSD = costUSD }
}
public struct ChatContextUsage: Codable, Equatable {
    public var used: Int
    public var window: Int?
    public init(used: Int, window: Int? = nil) { self.used = used; self.window = window }
    public var fraction: Double? { window.flatMap { $0 > 0 ? min(1, Double(used) / Double($0)) : nil } }
}
/// A slash command the provider runs itself, such as `/compact` or a skill.
public struct ChatCommand: Identifiable, Codable, Equatable {
    public var name: String
    public var description: String
    public var argumentHint: String
    public var id: String { name }
    public init(name: String, description: String = "", argumentHint: String = "") {
        self.name = name; self.description = description; self.argumentHint = argumentHint
    }
    /// Splits `/name arguments` into its parts; anything else is a plain prompt.
    public static func parse(_ prompt: String) -> (name: String, arguments: String)? {
        guard prompt.hasPrefix("/") else { return nil }
        let body = prompt.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return (String(name), body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
@MainActor public protocol ChatDriver: AnyObject {
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws
    /// Runs a turn with Jack's delegation tools attached, for providers that support them.
    func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws
    func respond(approvalID: String, allow: Bool) async throws
    func answer(approvalID: String, answers: [String: String]) async throws
    func stop()
}
public extension ChatDriver {
    func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, onEvent: onEvent)
    }
    func answer(approvalID: String, answers: [String: String]) async throws {
        throw NSError(domain: "Jack", code: 1, userInfo: [NSLocalizedDescriptionKey: "Este proveedor no admite preguntas interactivas."])
    }
}
