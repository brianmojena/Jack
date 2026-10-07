import Foundation

public enum ChatProvider: String, Codable, CaseIterable, Identifiable {
    case codex, claude, opencode, stellar
    public var id: String { rawValue }
    public var title: String { switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .opencode: return "OpenCode"; case .stellar: return "Stellar Code" } }
    /// Jack's own agent; it runs local models and needs no executable.
    public var isBuiltIn: Bool { self == .stellar }
    /// Shown on its cards while it is being built.
    public var isBeta: Bool { self == .stellar }
    public var defaultModel: String { switch self { case .codex: return "gpt-6-luna"; case .claude: return "sonnet"; case .opencode, .stellar: return "" } }
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
    /// The tool asking, when `detail` is its input as JSON, so the request can be previewed like the transcript shows it.
    public var tool: String? = nil
    /// Ways to answer besides allowing once and rejecting, such as "always allow".
    public var choices: [ChatApprovalChoice] = []
    /// A plan to review: `detail` is Markdown and `choices` replace allowing and rejecting.
    public var isPlan = false
    public init(id: String, title: String, detail: String) { self.id = id; self.title = title; self.detail = detail }
}
public struct ChatApprovalChoice: Identifiable, Equatable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
/// A message written while the agent works. It waits until the agent reads it: agents that take messages
/// mid-turn get it at once and read it when they finish their current step; others get it when the turn ends.
public struct ChatQueuedMessage: Identifiable, Equatable {
    public var id: String
    public var text: String
    public var attachments: [String]
    /// Already handed to the agent, which holds it until it reads it.
    public var sent = false
    public init(id: String = UUID().uuidString.lowercased(), text: String, attachments: [String] = []) {
        self.id = id; self.text = text; self.attachments = attachments
    }
}
public struct ChatInputQuestion: Identifiable, Decodable, Equatable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [ChatInputOption]?
    public var isSecret: Bool?
    /// Several options may be chosen; the answer joins them with ", ".
    public var multiSelect: Bool?
    public init(id: String, header: String, question: String, options: [ChatInputOption]? = nil, isSecret: Bool? = nil, multiSelect: Bool? = nil) {
        self.id = id; self.header = header; self.question = question; self.options = options; self.isSecret = isSecret; self.multiSelect = multiSelect
    }
}
public struct ChatInputOption: Decodable, Equatable {
    public var label: String
    public var description: String
    public init(label: String, description: String) { self.label = label; self.description = description }
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
    public var jackContext: JackContextSettings? = nil
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
    /// Brought from Claude Code without its history, which is read from the session the first time it opens.
    public var pendingClaudeHistory: Bool? = nil
    /// Runs this agent on another machine over SSH instead of locally. Only Claude Code supports it.
    public var remote: ChatRemoteEndpoint? = nil
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

/// Where a Claude Code agent runs when it is not on this Mac: Jack opens it
/// over SSH and forwards its stdio, so the stream-json protocol is unchanged.
/// A reverse tunnel lets the remote agent reach Jack's delegation tools.
/// Without `remotePath` Jack discovers the remote projects itself, like it
/// does locally, from what the user asks about.
public struct ChatRemoteEndpoint: Codable, Equatable {
    /// SSH destination: `user@host`, an IP or a `~/.ssh/config` alias.
    public var destination: String
    /// SSH port; nil uses the default (22).
    public var sshPort: Int?
    /// Working directory on the remote machine, where `claude` runs. Nil until resolved.
    public var remotePath: String?
    public init(destination: String, sshPort: Int? = nil, remotePath: String? = nil) {
        self.destination = destination; self.sshPort = sshPort; self.remotePath = remotePath
    }
    /// Ready to use: a destination. The folder may resolve later, automatically.
    public var isValid: Bool {
        !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Whether the remote folder is already known (set by hand or discovered).
    public var isResolved: Bool {
        (remotePath ?? "").hasPrefix("/")
    }
    public var displayName: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        case .stellar: return [.init(id: "manual", title: "Manual"), .init(id: "acceptEdits", title: "Aceptar ediciones"), .init(id: "auto", title: "Auto")]
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
    case suggestion(String)
    case approval(ChatApproval)
    case approvalResolved(String)
    /// The agent switched its permission mode itself, e.g. after the user approved a plan.
    case mode(String)
    /// The agent read a queued message; `text` is what it received.
    case delivered(id: String, text: String)
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
    /// Answers with one of the approval's `choices`, "allow" or "deny"; `message` tells the agent why it was rejected.
    func respond(approvalID: String, choice: String, message: String?) async throws
    func answer(approvalID: String, answers: [String: String]) async throws
    /// Ends the current turn; drivers that keep their agent alive interrupt it instead of ending the process.
    func stop()

    /// The agent's process outlives each turn: the driver is reused, and the agent may start turns on its own,
    /// for example when a background task it launched finishes.
    var keepsAlive: Bool { get }
    /// `idle` receives events between turns; `unprompted` is called when the agent starts a turn by itself,
    /// which the caller consumes with `follow`.
    func observe(idle: @escaping @MainActor (ChatEvent) -> Void, unprompted: @escaping @MainActor () -> Void)
    func follow(onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws
    /// Hands the agent a message to read when it finishes its current step; `.delivered` reports when it does.
    /// Returns false when the driver cannot.
    func inject(_ message: ChatQueuedMessage, conversation: ChatConversation) -> Bool
    /// Takes back a message handed over with `inject`. Returns false when the agent already read it.
    func withdraw(messageID: String) async -> Bool
    /// Whether the agent still holds this message unread.
    func isQueued(_ messageID: String) -> Bool
    /// Interrupts the turn; with `keepingQueued` the agent then reads its queued messages instead of dropping them.
    func stop(keepingQueued: Bool)
    /// Changes the permission mode, even in the middle of a turn. Returns false when the driver cannot.
    func setMode(_ mode: String) -> Bool
    /// Ends the agent's process.
    func close()
    /// Only Light changes idle lifetime; pending/background work must remain alive.
    func setEnergySaving(_ enabled: Bool)
}
public extension ChatDriver {
    func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, onEvent: onEvent)
    }
    func respond(approvalID: String, choice: String, message: String?) async throws {
        try await respond(approvalID: approvalID, allow: choice != "deny")
    }
    func answer(approvalID: String, answers: [String: String]) async throws {
        throw NSError(domain: "Jack", code: 1, userInfo: [NSLocalizedDescriptionKey: "Este proveedor no admite preguntas interactivas."])
    }
    var keepsAlive: Bool { false }
    func observe(idle: @escaping @MainActor (ChatEvent) -> Void, unprompted: @escaping @MainActor () -> Void) {}
    func follow(onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {}
    func inject(_ message: ChatQueuedMessage, conversation: ChatConversation) -> Bool { false }
    func withdraw(messageID: String) async -> Bool { false }
    func isQueued(_ messageID: String) -> Bool { false }
    func stop(keepingQueued: Bool) { stop() }
    func setMode(_ mode: String) -> Bool { false }
    func close() { stop() }
    func setEnergySaving(_ enabled: Bool) {}
}

/// Jack commands are local to the app; provider slash commands retain their own routing.
public struct JackContextSettings: Codable, Equatable {
    public var seed: String? = nil
    public var seedDelivered: Bool? = nil
    public var pinned: [String] = []
    public var autoThreshold: Int? = nil
    public var autoTarget: Int? = nil
    public var budget: Int? = nil
    public var spent: Int = 0
    public var budgetWarned = false
    public init() {}
}
public struct JackCommandTemplate: Codable, Equatable {
    public var name: String
    public var prompt: String
    public init(name: String, prompt: String) { self.name = name; self.prompt = prompt }
}
public enum JackCommandCatalog {
    public static let builtins: [ChatCommand] = [
        .init(name: "btw", description: "Pregunta al margen sin interrumpir al agente ni entrar en su historial (⌥↩)", argumentHint: "pregunta"),
        .init(name: "compact", description: "Reduce el contexto mediante un resumen; conserva el historial", argumentHint: "8000"),
        .init(name: "autocompact", description: "Compacta antes del siguiente mensaje al superar el umbral", argumentHint: "30000 8000 | off"),
        .init(name: "contexto", description: "Muestra contexto y presupuesto"),
        .init(name: "fijar", description: "Conserva instrucciones en futuras sesiones", argumentHint: "texto | listar | quitar número"),
        .init(name: "resumen", description: "Resume decisiones, avances y pendientes"),
        .init(name: "checkpoint", description: "Guarda una copia o restaura en otra conversación", argumentHint: "nombre | restaurar nombre"),
        .init(name: "rama", description: "Crea una conversación independiente con el contexto actual", argumentHint: "nombre"),
        .init(name: "traspasar", description: "Prepara un resumen para otro modelo o proveedor", argumentHint: "codex | claude | opencode (opcional)"),
        .init(name: "plan", description: "Activa Plan y prepara la tarea", argumentHint: "tarea"),
        .init(name: "revisar", description: "Revisa los cambios del proyecto", argumentHint: "instrucciones opcionales"),
        .init(name: "presupuesto", description: "Avisa al acercarse al presupuesto de tokens", argumentHint: "20000 | off"),
        .init(name: "comandos", description: "Lista, crea o elimina plantillas personales", argumentHint: "crear nombre texto | eliminar nombre")
    ]
    public static let defaults: [JackCommandTemplate] = [
        .init(name: "revisar-pr", prompt: "Revisa los cambios actuales como una pull request: errores, regresiones y pruebas que faltan. No modifiques archivos. {{args}}"),
        .init(name: "documentar", prompt: "Documenta los cambios actuales siguiendo el estilo del proyecto. {{args}}"),
        .init(name: "preparar-release", prompt: "Prepara una propuesta de notas de versión y una lista de pasos para publicar; no publiques ni despliegues. {{args}}")
    ]
    public static func parse(_ text: String) -> (name: String, arguments: String)? {
        guard text.hasPrefix("!"), !text.hasPrefix("!!") else { return nil }
        let body = text.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        return (String(name).lowercased(), body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public static func estimatedTokens(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }
}
