import Foundation

/// Creates the native, structured driver for a chat provider.
public enum ChatDriverFactory {
    /// Minutes an idle Claude Code process stays open after a turn; 0 closes it at once.
    public static let claudeKeepAliveKey = "claudeKeepAliveMinutes"

    @MainActor
    public static func make(_ provider: ChatProvider) -> any ChatDriver {
        switch provider {
        case .codex: return CodexChatDriver()
        case .claude: return ClaudeChatDriver()
        case .opencode: return OpenCodeChatDriver()
        }
    }
}

@MainActor
private class ProcessChatDriver: ChatDriver {
    var child: StructuredChild?
    var runGeneration = UUID()
    var pendingApprovals: [String: PendingApproval] = [:]

    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        fatalError("abstract")
    }

    func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, onEvent: onEvent)
    }

    func respond(approvalID: String, allow: Bool) async throws {
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else {
            throw ChatDriverError.invalidApproval(approvalID)
        }
        try await resolve(pending, allow: allow)
    }
    func answer(approvalID: String, answers: [String: String]) async throws {
        throw ChatDriverError.unsupportedApproval
    }

    func stop() {
        runGeneration = UUID()
        child?.terminate()
        child = nil
        pendingApprovals.removeAll()
    }

    func resolve(_ pending: PendingApproval, allow: Bool) async throws {
        throw ChatDriverError.unsupportedApproval
    }

    // Declared here, not only in the protocol extension, so subclasses can override them.
    func respond(approvalID: String, choice: String, message: String?) async throws {
        try await respond(approvalID: approvalID, allow: choice != "deny")
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

    func begin(_ executable: String, arguments: [String], directory: String, environment: [String: String] = [:]) throws -> StructuredChild {
        let process = try StructuredChild(executable: executable, arguments: arguments, directory: directory, environment: environment)
        child = process
        return process
    }

    func finish(_ process: StructuredChild, generation: UUID) async {
        process.terminate()
        await process.waitForExit()
        if runGeneration == generation { child = nil; pendingApprovals.removeAll() }
    }

    func emit(_ event: ChatEvent, generation: UUID, to onEvent: @escaping @MainActor (ChatEvent) -> Void) {
        guard runGeneration == generation else { return }
        onEvent(event)
    }
}

struct PendingApproval {
    let payload: [String: Any]
    let provider: String
}

private enum ChatDriverError: LocalizedError {
    case executableMissing(String), invalidApproval(String), unsupportedApproval
    case process(String), protocolFailure(String)
    var errorDescription: String? {
        switch self {
        case .executableMissing(let name): return "No se encontró \(name). Instálalo o indica su ruta en Ajustes."
        case .invalidApproval(let id): return "No pending approval has id \(id)."
        case .unsupportedApproval: return "This provider cannot resolve that approval request."
        case .process(let detail), .protocolFailure(let detail): return detail
        }
    }
}

enum CodexProtocol {
    static func event(_ object: [String: Any], session: inout String?, approvals: inout [String: PendingApproval]) -> [ChatEvent] {
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if method == "item/tool/requestUserInput", let rpcID = object["id"],
               let data = try? JSONSerialization.data(withJSONObject: params["questions"] ?? []),
               let questions = try? JSONDecoder().decode([ChatInputQuestion].self, from: data) {
                let approvalID = "codex-input-\(String(describing: rpcID))"
                approvals[approvalID] = PendingApproval(payload: ["rpcID": rpcID, "method": method, "questionIDs": questions.map(\.id)], provider: "codex")
                var approval = ChatApproval(id: approvalID, title: "Preguntas del agente", detail: "")
                approval.questions = questions
                return [.approval(approval)]
            }
            if method == "account/rateLimits/updated" { return [.usage(UsageDecoder.codex(params))] }
            if method == "thread/tokenUsage/updated", let usage = params["tokenUsage"] as? [String: Any] {
                let value = usage["total"] as? [String: Any] ?? usage["last"] as? [String: Any] ?? usage
                let last = (usage["last"] as? [String: Any])?["totalTokens"] as? Int
                return [.context(used: last, window: usage["modelContextWindow"] as? Int), .tokens(ChatTokenUsage(input: value["inputTokens"] as? Int ?? 0, output: value["outputTokens"] as? Int ?? 0, cached: value["cachedInputTokens"] as? Int ?? 0, reasoning: value["reasoningOutputTokens"] as? Int ?? 0))]
            }
            if method == "item/reasoning/summaryTextDelta" || method == "item/reasoning/textDelta", let delta = params["delta"] as? String {
                let suffix = method.contains("summary") ? "summary" : "reasoning"
                return [.reasoning(id: "\(params["itemId"] as? String ?? "reasoning"):\(suffix)", text: delta, replace: false)]
            }
            if method == "item/commandExecution/outputDelta", let delta = params["delta"] as? String { return [.toolOutput(id: params["itemId"] as? String ?? "command", text: delta)] }
            if method == "item/mcpToolCall/progress" { return [.toolOutput(id: params["itemId"] as? String ?? "mcp", text: (params["message"] as? String ?? boundedJSON(params)) + "\n")] }
            if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                guard let rpcID = object["id"] else { return [] }
                let approvalID = "codex-\(String(describing: rpcID))"
                approvals[approvalID] = PendingApproval(payload: ["rpcID": rpcID, "method": method, "params": params], provider: "codex")
                let command = params["command"] as? String ?? ""
                let reason = params["reason"] as? String ?? ""
                return [.approval(ChatApproval(id: approvalID, title: method.contains("fileChange") ? "Codex requests file changes" : "Codex requests command approval", detail: [reason, command].filter { !$0.isEmpty }.joined(separator: "\n")))]
            }
            if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
                let id = params["itemId"] as? String ?? "codex-message"
                return [.text(id: id, text: delta, replace: false)]
            }
            if method == "item/started" || method == "item/completed" {
                let item = params["item"] as? [String: Any] ?? [:]
                let type = item["type"] as? String ?? "tool"
                if type == "reasoning" {
                    let id = item["id"] as? String ?? "reasoning"
                    let summary = (item["summary"] as? [String] ?? []).joined(separator: "\n")
                    if !summary.isEmpty { return [.reasoning(id: "\(id):summary", text: summary, replace: true)] }
                    if method == "item/started" { return [.reasoning(id: "\(id):summary", text: "", replace: false)] }
                    return []
                }
                if type == "exitedReviewMode", method == "item/completed", let review = item["review"] as? String, !review.isEmpty {
                    return [.text(id: item["id"] as? String ?? "codex-review", text: review, replace: true)]
                }
                if type == "enteredReviewMode" || type == "exitedReviewMode" { return [] }
                if type == "agentMessage", method == "item/completed", let text = item["text"] as? String {
                    return [.text(id: item["id"] as? String ?? "codex-message", text: text, replace: true)]
                }
                if type != "agentMessage" && type != "userMessage" && type != "reasoning" {
                    let id = item["id"] as? String ?? UUID().uuidString
                    let status = method == "item/started" ? "running" : (item["status"] as? String ?? "completed")
                    return [.tool(id: id, title: readableItem(type: type, item: item), detail: readableDetails(type: type, item: item), status: status)]
                }
            }
            if method == "turn/completed" {
                let turn = params["turn"] as? [String: Any] ?? params
                if let status = turn["status"] as? String, status != "completed" {
                    return [.failure((turn["error"] as? [String: Any])?["message"] as? String ?? "Codex turn ended with status \(status).")]
                }
                return [.completed]
            }
            if method == "error" { return [.failure((params["message"] as? String) ?? "Codex reported an error.")] }
            return []
        }
        if let result = object["result"] as? [String: Any] {
            if result["rateLimits"] != nil { return [.usage(UsageDecoder.codex(result))] }
            if let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String { session = id; return [.session(id)] }
            if let threadID = result["threadId"] as? String { session = threadID; return [.session(threadID)] }
        }
        if let error = object["error"] as? [String: Any] {
            return [.failure((error["message"] as? String) ?? "Codex app-server request failed.")]
        }
        return []
    }
}

@MainActor
private final class CodexChatDriver: ProcessChatDriver {
    private var nextID = 1
    private var threadID: String?

    override func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, delegation: nil, onEvent: onEvent)
    }

    override func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        stop()
        let generation = UUID(); runGeneration = generation
        guard let executable = ExecutableResolver.resolve("codex", override: UserDefaults.standard.string(forKey: "providerExecutablePath.codex")) else { throw ChatDriverError.executableMissing("codex") }
        let arguments = ["app-server", "--listen", "stdio://"] + (delegation.map(ChatRunConfiguration.codexDelegation) ?? [])
        // The token travels in the environment, not in the command line other processes can read.
        let process = try begin(executable, arguments: arguments, directory: conversation.projectPath, environment: delegation.map { ["JACK_MCP_TOKEN": $0.token] } ?? [:])
        let reader = StructuredLineReader(process.lines)
        do {
        let initID = id(); try process.writeJSON(["id": initID, "method": "initialize", "params": ["clientInfo": ["name": "jack", "title": "Jack", "version": "1"], "capabilities": ["experimentalApi": true]]])
        let initTimeout = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { process.terminate() } }
        try await waitForResponse(id: initID, process: process, reader: reader, generation: generation, onEvent: onEvent)
        initTimeout.cancel()
        try process.writeJSON(["method": "initialized", "params": [:]])
        if let saved = conversation.sessionID, !saved.isEmpty {
            var params: [String: Any] = ["threadId": saved]
            if delegation != nil { params["developerInstructions"] = ChatDelegation.instructions }
            let requestID = id(); try process.writeJSON(["id": requestID, "method": "thread/resume", "params": params])
            try await waitForResponse(id: requestID, process: process, reader: reader, generation: generation, onEvent: onEvent)
            threadID = saved
        } else {
            let requestID = id()
            var params: [String: Any] = ["cwd": conversation.projectPath, "model": nonempty(conversation.model), "approvalPolicy": "on-request", "sandbox": "workspace-write"]
            if delegation != nil { params["developerInstructions"] = ChatDelegation.instructions }
            try process.writeJSON(["id": requestID, "method": "thread/start", "params": params])
            try await waitForResponse(id: requestID, process: process, reader: reader, generation: generation, onEvent: onEvent)
        }
        guard let threadID else { throw ChatDriverError.protocolFailure("Codex did not return a thread id.") }
        let command = ChatCommand.parse(prompt)
        var skill: [String: Any]?
        if let command, !CodexCommands.builtin.contains(where: { $0.name == command.name }) {
            let listID = id()
            try process.writeJSON(["id": listID, "method": "skills/list", "params": ["cwds": [conversation.projectPath]]])
            let response = try await waitForResponse(id: listID, process: process, reader: reader, generation: generation, onEvent: onEvent)
            skill = CodexCommands.skills(from: response).first { $0["name"] as? String == command.name }
        }
        let requestID = id()
        switch command?.name {
        case "compact" where skill == nil:
            try process.writeJSON(["id": requestID, "method": "thread/compact/start", "params": ["threadId": threadID]])
        case "review" where skill == nil:
            let arguments = command?.arguments ?? ""
            let target: [String: Any] = arguments.isEmpty ? ["type": "uncommittedChanges"] : ["type": "custom", "instructions": arguments]
            try process.writeJSON(["id": requestID, "method": "review/start", "params": ["threadId": threadID, "target": target]])
        default:
            try process.writeJSON(["id": requestID, "method": "turn/start", "params": ChatRunConfiguration.codexTurn(conversation, threadID: threadID, prompt: prompt, skill: skill)])
        }
        var completed = false
        while let line = try await reader.next() {
            try Task.checkCancellation()
            guard runGeneration == generation else { throw CancellationError() }
            guard let object = jsonObject(line) else { continue }
            let events = CodexProtocol.event(object, session: &self.threadID, approvals: &pendingApprovals)
            for event in events {
                emit(event, generation: generation, to: onEvent)
                if case .completed = event { completed = true }
                if case .failure(let message) = event { throw ChatDriverError.protocolFailure(message) }
            }
            if let rpcID = object["id"], let method = object["method"] as? String {
                let known = pendingApprovals.values.contains { String(describing: $0.payload["rpcID"] ?? "") == String(describing: rpcID) && $0.payload["method"] as? String == method }
                if !known { try process.writeJSON(["id": rpcID, "error": ["code": -32601, "message": "Unsupported app-server request: \(method)"]]) }
            }
            if completed { break }
        }
        if !completed { throw ChatDriverError.process(await process.failureDescription(default: "Codex app-server ended before the turn completed.")) }
        await finish(process, generation: generation)
        } catch {
            await finish(process, generation: generation)
            throw error
        }
    }

    override func resolve(_ pending: PendingApproval, allow: Bool) async throws {
        guard let process = child, let rpcID = pending.payload["rpcID"] else { throw ChatDriverError.invalidApproval("expired") }
        let result: [String: Any] = ["decision": allow ? "accept" : "decline"]
        try process.writeJSON(["id": rpcID, "result": result])
    }
    override func answer(approvalID: String, answers: [String: String]) async throws {
        guard let process = child, let pending = pendingApprovals[approvalID],
              pending.payload["method"] as? String == "item/tool/requestUserInput",
              let rpcID = pending.payload["rpcID"], let questionIDs = pending.payload["questionIDs"] as? [String],
              questionIDs.allSatisfy({ !(answers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ChatDriverError.invalidApproval(approvalID)
        }
        let result = answers.mapValues { ["answers": [$0]] }
        try process.writeJSON(["id": rpcID, "result": ["answers": result]])
        pendingApprovals.removeValue(forKey: approvalID)
    }

    private func id() -> Int { defer { nextID += 1 }; return nextID }

    @discardableResult
    private func waitForResponse(id: Int, process: StructuredChild, reader: StructuredLineReader, generation: UUID, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws -> [String: Any] {
        while let line = try await reader.next() {
            guard runGeneration == generation else { throw CancellationError() }
            guard let object = jsonObject(line) else { continue }
            let events = CodexProtocol.event(object, session: &threadID, approvals: &pendingApprovals)
            for event in events { emit(event, generation: generation, to: onEvent) }
            if object["id"] as? Int == id {
                if let error = object["error"] as? [String: Any] { throw ChatDriverError.protocolFailure((error["message"] as? String) ?? "Codex initialization failed.") }
                if let method = object["method"] as? String {
                    let known = pendingApprovals.values.contains { String(describing: $0.payload["rpcID"] ?? "") == String(describing: object["id"] ?? "") && $0.payload["method"] as? String == method }
                    if !known { try process.writeJSON(["id": object["id"]!, "error": ["code": -32601, "message": "Unsupported app-server request: \(method)"]]) }
                    continue
                }
                return object
            }
        }
        throw ChatDriverError.process(await process.failureDescription(default: "Codex app-server closed during initialization."))
    }
}

enum CodexCommands {
    static let builtin = [
        ChatCommand(name: "compact", description: "Resume la conversación para liberar ventana de contexto."),
        ChatCommand(name: "review", description: "Revisa los cambios sin confirmar, o lo que indiques.", argumentHint: "[instrucciones]"),
    ]
    static func skills(from response: [String: Any]) -> [[String: Any]] {
        let entries = (response["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return entries.flatMap { $0["skills"] as? [[String: Any]] ?? [] }.filter { $0["enabled"] as? Bool != false }
    }
    static func commands(from response: [String: Any]) -> [ChatCommand] {
        var seen = Set<String>()
        return builtin + skills(from: response).compactMap { skill in
            guard let name = skill["name"] as? String, seen.insert(name).inserted else { return nil }
            let summary = skill["shortDescription"] as? String ?? (skill["interface"] as? [String: Any])?["shortDescription"] as? String
            return ChatCommand(name: name, description: summary ?? skill["description"] as? String ?? "")
        }
    }
}

enum ClaudeProtocol {
    /// Everything the request sent plus what it generated, which is what stays in context.
    static func contextTokens(_ usage: [String: Any]) -> Int {
        ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
    }
    /// Built-in commands such as /compact come first; skills and plugins follow in the CLI's order.
    static func commands(_ values: [[String: Any]]) -> [ChatCommand] {
        let ordered = values.filter { $0["builtin"] as? Bool == true } + values.filter { $0["builtin"] as? Bool != true }
        return ordered.compactMap { value in
            guard let name = value["name"] as? String, !name.isEmpty, !name.hasPrefix("__") else { return nil }
            return ChatCommand(name: name, description: value["description"] as? String ?? "", argumentHint: value["argumentHint"] as? String ?? "")
        }
    }
    /// Calls that are bookkeeping rather than work, such as loading another tool's schema.
    static let hiddenTools: Set<String> = ["ToolSearch"]

    /// Claude Code reports Jack's "manual" mode as "default".
    static func jackMode(_ mode: String) -> String { mode == "default" ? "manual" : mode }
    static func cliMode(_ mode: String) -> String { mode == "manual" ? "default" : mode }

    /// A tool result as text: plain, or the text blocks of a content list.
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return boundedJSON(content ?? [])
    }

    /// What a permission request asks for, as the sidebar and the request's header show it.
    static func permissionTitle(tool: String, input: [String: Any]) -> String {
        let file = ((input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Bash": return "Ejecutar un comando"
        case "Edit", "MultiEdit", "NotebookEdit": return file.map { "Editar \($0)" } ?? "Editar un archivo"
        case "Write": return file.map { "Escribir \($0)" } ?? "Escribir un archivo"
        case "Read": return file.map { "Leer \($0)" } ?? "Leer un archivo"
        case "WebFetch": return (input["url"] as? String).flatMap { URL(string: $0)?.host }.map { "Abrir \($0)" } ?? "Abrir una página web"
        case "WebSearch": return "Buscar en la web"
        case "Agent", "Task": return "Lanzar un subagente"
        default:
            if tool.hasPrefix("mcp__") { return "Usar " + tool.dropFirst(5).replacingOccurrences(of: "__", with: " · ") }
            return "Usar \(tool)"
        }
    }

    /// The "don't ask again" answer Claude Code offers with a request, from the permission updates it suggests.
    static func alwaysChoice(_ suggestions: [[String: Any]]) -> ChatApprovalChoice? {
        func scope(_ destination: Any?) -> String {
            switch destination as? String {
            case "session": return "en esta sesión"
            case "userSettings": return "en todos tus proyectos"
            case "projectSettings": return "en este proyecto, para todo el equipo"
            default: return "en este proyecto"
            }
        }
        for suggestion in suggestions where suggestion["type"] as? String == "addRules" {
            let rules = (suggestion["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
                guard let tool = rule["toolName"] as? String else { return nil }
                return (rule["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
            }
            if !rules.isEmpty { return ChatApprovalChoice(id: "always", title: "Permitir siempre \(rules.joined(separator: ", ")) \(scope(suggestion["destination"]))") }
        }
        if let mode = suggestions.first(where: { $0["type"] as? String == "setMode" }), mode["mode"] as? String == "acceptEdits" {
            return ChatApprovalChoice(id: "always", title: "Aceptar todas las ediciones \(scope(mode["destination"]))")
        }
        if let folders = suggestions.first(where: { $0["type"] as? String == "addDirectories" }), let list = folders["directories"] as? [String], !list.isEmpty {
            return ChatApprovalChoice(id: "always", title: "Permitir siempre \(list.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")) \(scope(folders["destination"]))")
        }
        return nil
    }

    static let planChoices = [
        ChatApprovalChoice(id: "plan.acceptEdits", title: "Sí, y aceptar las ediciones"),
        ChatApprovalChoice(id: "plan.manual", title: "Sí, revisando cada edición"),
        ChatApprovalChoice(id: "deny", title: "No, seguir planificando"),
    ]

    /// How Jack answers a `can_use_tool` request with one of its choices.
    static func permissionResponse(_ pending: PendingApproval, choice: String, message: String?) -> [String: Any] {
        let input = pending.payload["input"] ?? [String: Any]()
        let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch choice {
        case "deny":
            if pending.payload["plan"] as? Bool == true {
                return ["behavior": "deny", "message": reason.map { "The user wants to keep planning and said: \($0)" } ?? "The user wants to keep planning. Ask what should change in the plan."]
            }
            return ["behavior": "deny", "message": reason.map { "The user rejected this action and said: \($0)" } ?? "User denied this action."]
        case "always":
            return ["behavior": "allow", "updatedInput": input, "updatedPermissions": pending.payload["suggestions"] ?? [Any]()]
        case "plan.acceptEdits", "plan.manual":
            let mode = choice == "plan.acceptEdits" ? "acceptEdits" : "default"
            return ["behavior": "allow", "updatedInput": input, "updatedPermissions": [["type": "setMode", "mode": mode, "destination": "session"]]]
        default:
            return ["behavior": "allow", "updatedInput": input]
        }
    }

    /// AskUserQuestion is allowed with the answers added to its input, keyed by question.
    static func questionResponse(_ pending: PendingApproval, answers: [String: String]) -> [String: Any] {
        var input = pending.payload["input"] as? [String: Any] ?? [:]
        input["answers"] = answers
        return ["behavior": "allow", "updatedInput": input]
    }

    /// A line or the start of a turn the agent begins by itself, outside any turn Jack started.
    static func startsTurn(_ object: [String: Any]) -> Bool {
        let parent = object["parent_tool_use_id"]
        let topLevel = parent == nil || parent is NSNull
        switch object["type"] as? String {
        case "assistant", "stream_event": return topLevel
        case "system": return object["subtype"] as? String == "status" && object["status"] as? String == "requesting"
        default: return false
        }
    }

    struct Decoder {
        var sessionID: String?
        var messageID = "claude-message"
        var emittedTextByBlock: [String: String] = [:]
        var emittedReasoningByBlock: [String: String] = [:]
        var tools: [String: (id: String, name: String)] = [:]
        var toolNames: [String: String] = [:]
        var toolInputs: [String: String] = [:]
        /// What each block id holds, so a snapshot never reuses an id that belongs to another kind of block.
        var blockKinds: [String: String] = [:]
        var approvals: [String: PendingApproval] = [:]
        var hiddenBlocks: Set<String> = []
        /// Tools still working after their call returned, such as background subagents, until their task ends.
        var backgroundTools: Set<String> = []
        /// What each subagent has done so far, by the id of the call that started it.
        var subagentActivity: [String: [String]] = [:]
        /// Background tasks still running, which keep the process alive between turns.
        var backgroundTaskCount = 0

        mutating func events(_ object: [String: Any]) -> [ChatEvent] {
            let type = object["type"] as? String ?? ""
            if let parent = object["parent_tool_use_id"] as? String, ["assistant", "user", "stream_event"].contains(type) {
                return subagentEvents(object, parent: parent)
            }
            if type == "rate_limit_event", let usage = UsageDecoder.claudeEvent(object) { return [.usage(usage)] }
            if type == "prompt_suggestion", let suggestion = object["suggestion"] as? String,
               !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [.suggestion(suggestion)] }
            if type == "user", let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                return blocks.compactMap { block in
                    guard block["type"] as? String == "tool_result", let nativeID = block["tool_use_id"] as? String, let tool = tools[nativeID],
                          !backgroundTools.contains(nativeID) else { return nil }
                    return .tool(id: tool.id, title: tool.name, detail: detail(nativeID, ClaudeProtocol.resultText(block["content"])),
                                 status: block["is_error"] as? Bool == true ? "failed" : "completed")
                }
            }
            if type == "system" {
                switch object["subtype"] as? String {
                case "commands_changed":
                    if let commands = object["commands"] as? [[String: Any]] { return [.commands(ClaudeProtocol.commands(commands))] }
                case "init":
                    guard let id = object["session_id"] as? String else { break }
                    sessionID = id
                    return [.session(id)] + ((object["permissionMode"] as? String).map { [.mode(ClaudeProtocol.jackMode($0))] } ?? [])
                case "status":
                    if let mode = object["permissionMode"] as? String { return [.mode(ClaudeProtocol.jackMode(mode))] }
                case "background_tasks_changed":
                    backgroundTaskCount = (object["tasks"] as? [Any])?.count ?? 0
                case "task_started":
                    // "background" is not a running status, so ending the turn leaves the row as it is.
                    if object["is_backgrounded"] as? Bool == true, let id = object["tool_use_id"] as? String, let tool = tools[id] {
                        backgroundTools.insert(id)
                        return [.tool(id: tool.id, title: tool.name, detail: detail(id, ""), status: "background")]
                    }
                case "task_notification":
                    guard let id = object["tool_use_id"] as? String, backgroundTools.remove(id) != nil, let tool = tools[id] else { break }
                    let status: String
                    switch object["status"] as? String {
                    case "completed": status = "completed"
                    case "failed": status = "failed"
                    default: status = "interrupted"
                    }
                    return [.tool(id: tool.id, title: tool.name, detail: detail(id, object["summary"] as? String ?? ""), status: status)]
                default: break
                }
                return []
            }
            if type == "stream_event" {
                let event = object["event"] as? [String: Any] ?? [:]
                if event["type"] as? String == "message_start", let message = event["message"] as? [String: Any], let id = message["id"] as? String { messageID = id }
                let delta = event["delta"] as? [String: Any] ?? [:]
                let index = event["index"].map(String.init(describing:)) ?? "0"
                let blockID = "\(messageID):\(index)"
                if hiddenBlocks.contains(blockID) { return [] }
                if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any] {
                    if block["type"] as? String == "tool_use" {
                        let name = block["name"] as? String ?? "Herramienta"
                        if ClaudeProtocol.hiddenTools.contains(name) { hiddenBlocks.insert(blockID); return [] }
                        toolNames[blockID] = name
                        blockKinds[blockID] = "tool"
                        if let id = block["id"] as? String { tools[id] = (blockID, name) }
                        return [.tool(id: blockID, title: name, detail: "", status: "running")]
                    }
                    if block["type"] as? String == "thinking" { blockKinds[blockID] = "thinking"; return [.reasoning(id: blockID, text: block["thinking"] as? String ?? "", replace: true)] }
                }
                if let thinking = delta["thinking"] as? String {
                    blockKinds[blockID] = "thinking"
                    emittedReasoningByBlock[blockID, default: ""].append(thinking)
                    return [.reasoning(id: blockID, text: thinking, replace: false)]
                }
                if let text = delta["text"] as? String {
                    blockKinds[blockID] = "text"
                    emittedTextByBlock[blockID, default: ""].append(text)
                    return [.text(id: blockID, text: text, replace: false)]
                }
                if delta["type"] as? String == "input_json_delta" {
                    return [.toolOutput(id: blockID, text: delta["partial_json"] as? String ?? "")]
                }
            }
            if type == "assistant" {
                let message = object["message"] as? [String: Any] ?? [:]
                // Local commands answer with a synthetic message whose usage is all zeros.
                let used = message["model"] as? String == "<synthetic>" ? 0 : ClaudeProtocol.contextTokens(message["usage"] as? [String: Any] ?? [:])
                let context: [ChatEvent] = used > 0 ? [.context(used: used, window: nil)] : []
                let content = message["content"] as? [[String: Any]] ?? []
                let messageID = message["id"] as? String ?? self.messageID
                // The CLI sends one snapshot per block, so a block's position in `content` is not its stream index.
                let prefix = "\(messageID):"
                return context + content.enumerated().compactMap { index, block in
                    let kind = block["type"] as? String ?? ""
                    func snapshotID(_ kind: String) -> String {
                        let id = "\(messageID):\(index)"
                        if let existing = blockKinds[id], existing != kind { return "\(messageID):\(kind):\(index)" }
                        blockKinds[id] = kind
                        return id
                    }
                    if kind == "tool_use" {
                        let name = block["name"] as? String ?? "Herramienta"
                        if ClaudeProtocol.hiddenTools.contains(name) { return nil }
                        let input = boundedJSON(block["input"] ?? [:])
                        let nativeID = block["id"] as? String
                        let id = nativeID.flatMap { tools[$0]?.id } ?? snapshotID("tool")
                        if let nativeID { tools[nativeID] = (id, name); toolInputs[nativeID] = input }
                        return .tool(id: id, title: name, detail: input, status: "running")
                    }
                    if kind == "thinking", let thinking = block["thinking"] as? String {
                        if emittedReasoningByBlock.contains(where: { $0.key.hasPrefix(prefix) && $0.value == thinking }) { return nil }
                        let id = snapshotID("thinking")
                        emittedReasoningByBlock[id] = thinking
                        return .reasoning(id: id, text: thinking, replace: true)
                    }
                    if kind == "text", let text = block["text"] as? String {
                        if emittedTextByBlock.contains(where: { $0.key.hasPrefix(prefix) && $0.value == text }) { return nil }
                        let id = snapshotID("text")
                        emittedTextByBlock[id] = text
                        return .text(id: id, text: text, replace: true)
                    }
                    return nil
                }
            }
            if type == "control_request" {
                let id = object["request_id"] as? String ?? UUID().uuidString
                let request = object["request"] as? [String: Any] ?? [:]
                if request["subtype"] as? String == "can_use_tool" { return [.approval(approval(id: id, request: request))] }
            }
            if type == "result" {
                if let error = object["is_error"] as? Bool, error { return [.failure((object["result"] as? String) ?? "Claude reported an error.")] }
                let value = object["usage"] as? [String: Any] ?? [:]
                let window = (object["modelUsage"] as? [String: [String: Any]] ?? [:]).values.compactMap { $0["contextWindow"] as? Int }.max()
                let last = ClaudeProtocol.contextTokens((value["iterations"] as? [[String: Any]])?.last ?? [:])
                let context: [ChatEvent] = window != nil || last > 0 ? [.context(used: last > 0 ? last : nil, window: window)] : []
                return context + [.tokens(ChatTokenUsage(input: value["input_tokens"] as? Int ?? 0, output: value["output_tokens"] as? Int ?? 0, cached: value["cache_read_input_tokens"] as? Int ?? 0, costUSD: object["total_cost_usd"] as? Double)), .completed]
            }
            return []
        }

        /// A tool's input as JSON, then what its subagent did, then its result.
        private func detail(_ nativeID: String, _ result: String) -> String {
            let activity = subagentActivity[nativeID].map { $0.joined(separator: "\n") + (result.isEmpty ? "" : "\n\n") } ?? ""
            return (toolInputs[nativeID].map { $0 + "\n" } ?? "") + activity + result
        }

        /// A subagent's own tool calls are listed under the call that started it instead of joining the transcript.
        private mutating func subagentEvents(_ object: [String: Any], parent: String) -> [ChatEvent] {
            guard object["type"] as? String == "assistant", let tool = tools[parent],
                  let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            let calls = blocks.filter { $0["type"] as? String == "tool_use" && !ClaudeProtocol.hiddenTools.contains($0["name"] as? String ?? "") }
            guard !calls.isEmpty else { return [] }
            for call in calls {
                let input = call["input"] as? [String: Any] ?? [:]
                let subject = ["command", "file_path", "pattern", "url", "query", "description"].lazy.compactMap { input[$0] as? String }.first ?? ""
                let line = "› \(call["name"] as? String ?? "Herramienta")" + (subject.isEmpty ? "" : " " + subject.replacingOccurrences(of: "\n", with: " "))
                subagentActivity[parent, default: []].append(String(line.prefix(160)))
            }
            return [.tool(id: tool.id, title: tool.name, detail: detail(parent, ""), status: backgroundTools.contains(parent) ? "background" : "running")]
        }

        private mutating func approval(id: String, request: [String: Any]) -> ChatApproval {
            let name = request["tool_name"] as? String ?? "tool"
            let input = request["input"] as? [String: Any] ?? [:]
            var payload: [String: Any] = ["requestID": id, "input": input]
            var approval: ChatApproval
            if name == "AskUserQuestion", let list = input["questions"] as? [[String: Any]], !list.isEmpty {
                approval = ChatApproval(id: id, title: "Claude tiene preguntas", detail: "")
                approval.questions = list.compactMap { question in
                    guard let text = question["question"] as? String else { return nil }
                    let options = (question["options"] as? [[String: Any]])?.compactMap { option in
                        (option["label"] as? String).map { ChatInputOption(label: $0, description: option["description"] as? String ?? "") }
                    }
                    return ChatInputQuestion(id: text, header: question["header"] as? String ?? "", question: text, options: options, multiSelect: question["multiSelect"] as? Bool)
                }
            } else if name == "ExitPlanMode" {
                approval = ChatApproval(id: id, title: "Plan listo para revisar", detail: input["plan"] as? String ?? "")
                approval.isPlan = true
                approval.choices = ClaudeProtocol.planChoices
                payload["plan"] = true
            } else {
                let suggestions = request["permission_suggestions"] as? [[String: Any]] ?? []
                payload["suggestions"] = suggestions
                approval = ChatApproval(id: id, title: ClaudeProtocol.permissionTitle(tool: name, input: input), detail: boundedJSON(input))
                approval.tool = name
                approval.choices = ClaudeProtocol.alwaysChoice(suggestions).map { [$0] } ?? []
            }
            approvals[id] = PendingApproval(payload: payload, provider: "claude")
            return approval
        }
    }
}

/// Claude Code stays open between turns, as it does in a terminal: the next message skips its startup,
/// background subagents and commands keep working after a reply, and stopping interrupts the turn
/// instead of ending the process. An idle process closes after a few minutes to free its memory;
/// the next message resumes the session.
@MainActor
private final class ClaudeChatDriver: ProcessChatDriver {
    private var decoder = ClaudeProtocol.Decoder()
    /// The launch settings the running process was started with; mode and model change live.
    private var launch: [String] = []
    private var liveMode: String?
    private var liveModel: String?
    private var reader: Task<Void, Never>?
    private var sink: (@MainActor (ChatEvent) -> Void)?
    private var turnEnded: CheckedContinuation<Void, Error>?
    private var idleSink: (@MainActor (ChatEvent) -> Void)?
    private var unprompted: (@MainActor () -> Void)?
    /// Events of a turn the agent started by itself, until the caller follows it.
    private var unpromptedEvents: [ChatEvent]?
    private var interrupting: Task<Void, Never>?
    private var idleClose: Task<Void, Never>?
    private var requests = 0
    private var replies: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
    /// Messages handed over mid-turn that the agent has not read yet, by id.
    private var queued: [String: String] = [:]
    /// Delegated agents close right after their turn: an orchestrator may start several, and memory is scarce.
    private var closesWhenIdle = false

    override var keepsAlive: Bool { true }

    override func observe(idle: @escaping @MainActor (ChatEvent) -> Void, unprompted: @escaping @MainActor () -> Void) {
        idleSink = idle
        self.unprompted = unprompted
    }

    override func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, delegation: nil, onEvent: onEvent)
    }

    override func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        guard sink == nil else { throw ChatDriverError.process("Claude Code ya está trabajando en esta conversación.") }
        idleClose?.cancel()
        closesWhenIdle = conversation.parentID != nil
        let process = try session(for: conversation, delegation: delegation)
        _ = setMode(conversation.mode ?? "manual")
        if !conversation.model.isEmpty, conversation.model != liveModel {
            control(["subtype": "set_model", "model": conversation.model])
            liveModel = conversation.model
        }
        let buffered = unpromptedEvents ?? []
        unpromptedEvents = nil
        try await awaitTurn(onEvent) {
            buffered.forEach(self.deliver)
            do { try process.writeJSON(Self.userMessage(conversation, prompt: prompt)) }
            catch { self.endTurn(ChatDriverError.process("No se pudo escribir a Claude Code: \(error.localizedDescription)")) }
        }
    }

    override func follow(onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        guard sink == nil, let buffered = unpromptedEvents else { return }
        unpromptedEvents = nil
        try await awaitTurn(onEvent) { buffered.forEach(self.deliver) }
    }

    /// Claude Code keeps the message in its queue and reads it between steps, as when typing in its terminal while it works.
    override func inject(_ message: ChatQueuedMessage, conversation: ChatConversation) -> Bool {
        guard sink != nil || unpromptedEvents != nil, let child else { return false }
        var line = Self.userMessage(conversation, prompt: message.text, attachments: message.attachments)
        line["uuid"] = message.id
        guard (try? child.writeJSON(line)) != nil else { return false }
        idleClose?.cancel()
        queued[message.id] = message.text
        return true
    }

    override func withdraw(messageID: String) async -> Bool {
        guard queued[messageID] != nil else { return true }
        let response = await request(["subtype": "cancel_async_message", "message_uuid": messageID])
        guard response?["cancelled"] as? Bool == true else { return false }
        queued.removeValue(forKey: messageID)
        return true
    }

    override func isQueued(_ messageID: String) -> Bool { queued[messageID] != nil }

    override func setMode(_ mode: String) -> Bool {
        guard child != nil else { return true }
        if liveMode == mode { return true }
        guard control(["subtype": "set_permission_mode", "mode": ClaudeProtocol.cliMode(mode)]) else { return false }
        liveMode = mode
        return true
    }

    /// Interrupts the turn as Esc does in the terminal, dropping queued messages; the process and its background tasks stay.
    override func stop() { stop(keepingQueued: false) }

    override func stop(keepingQueued: Bool) {
        guard sink != nil, interrupting == nil else { return }
        pendingApprovals.removeAll()
        var interrupt: [String: Any] = ["subtype": "interrupt"]
        if !keepingQueued { interrupt["cancel_queued"] = true; queued.removeAll() }
        guard control(interrupt) else { closeSession(); endTurn(nil); return }
        interrupting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.sink != nil else { return }
            // It did not stop in time: end the process; the next message resumes the session.
            self.closeSession()
            self.endTurn(nil)
        }
    }

    override func close() {
        idleClose?.cancel()
        closeSession()
        unpromptedEvents = nil
        if sink != nil { endTurn(CancellationError()) }
    }

    override func respond(approvalID: String, choice: String, message: String?) async throws {
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else { throw ChatDriverError.invalidApproval(approvalID) }
        try reply(pending, ClaudeProtocol.permissionResponse(pending, choice: choice, message: message))
    }

    override func resolve(_ pending: PendingApproval, allow: Bool) async throws {
        try reply(pending, ClaudeProtocol.permissionResponse(pending, choice: allow ? "allow" : "deny", message: nil))
    }

    override func answer(approvalID: String, answers: [String: String]) async throws {
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else { throw ChatDriverError.invalidApproval(approvalID) }
        try reply(pending, ClaudeProtocol.questionResponse(pending, answers: answers))
    }

    private func reply(_ pending: PendingApproval, _ response: [String: Any]) throws {
        guard let child, let requestID = pending.payload["requestID"] as? String else { throw ChatDriverError.invalidApproval("expired") }
        try child.writeJSON(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    static func userMessage(_ conversation: ChatConversation, prompt: String, attachments: [String]? = nil) -> [String: Any] {
        let content = ChatRunConfiguration.claudeContent(prompt: prompt, attachments: attachments ?? conversation.turnAttachments)
        return ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull()]
    }

    // MARK: Process

    /// The running process when it was started with these settings, otherwise a new one that resumes the session.
    private func session(for conversation: ChatConversation, delegation: ChatDelegation?) throws -> StructuredChild {
        guard let executable = ExecutableResolver.resolve("claude", override: UserDefaults.standard.string(forKey: "providerExecutablePath.claude")) else { throw ChatDriverError.executableMissing("claude") }
        let delegationArgs = delegation.map(ChatRunConfiguration.claudeDelegation) ?? []
        let signature = [executable] + ChatRunConfiguration.claudeLaunchSignature(conversation) + delegationArgs
        // Restarting would end background subagents; new settings wait until they finish.
        if let child, signature == launch || decoder.backgroundTaskCount > 0 { return child }
        closeSession()
        // The SDK's permission channel, which also enables AskUserQuestion and plan approval.
        var args = ["--print", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    // Echoes each message when the agent reads it, so a queued message moves into the chat at that moment.
                    "--replay-user-messages", "--prompt-suggestions"]
            + ChatRunConfiguration.claudeSettings(conversation)
        if let saved = conversation.sessionID, !saved.isEmpty { args += ["--resume", saved] }
        // Claude Code turns prompt suggestions off when it is not interactive unless asked to; delegated agents have no one to suggest to.
        var environment: [String: String] = conversation.parentID == nil ? ["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "true"] : [:]
        if delegation != nil {
            args += delegationArgs
            // wait_for_agents may hold a call open for up to 15 minutes.
            environment["MCP_TOOL_TIMEOUT"] = "960000"
        }
        let process = try begin(executable, arguments: args, directory: conversation.projectPath, environment: environment)
        launch = signature
        liveMode = conversation.mode ?? "manual"
        liveModel = conversation.model
        decoder = ClaudeProtocol.Decoder()
        reader = Task { [weak self] in
            do { for try await line in process.lines { self?.handle(line) } } catch {}
            await self?.ended(process)
        }
        return process
    }

    private func closeSession() {
        reader?.cancel(); reader = nil
        launch = []
        dropPending()
        guard let process = child else { return }
        child = nil
        process.terminate()
        Task { await process.waitForExit() }
    }

    private func ended(_ process: StructuredChild) async {
        guard child === process else { return }
        child = nil; launch = []; reader = nil
        unpromptedEvents = nil
        dropPending()
        guard sink != nil else { return }
        let message = await process.failureDescription(default: "Claude Code se cerró antes de terminar.")
        if sink != nil, child == nil { endTurn(ChatDriverError.process(message)) }
    }

    @discardableResult
    private func control(_ request: [String: Any]) -> Bool { send(request) != nil }

    private func send(_ request: [String: Any]) -> String? {
        guard let child else { return nil }
        requests += 1
        let id = "jack-\(requests)"
        return (try? child.writeJSON(["type": "control_request", "request_id": id, "request": request])) != nil ? id : nil
    }

    /// A control request whose answer matters; nil when the process ends or does not answer in time.
    private func request(_ request: [String: Any]) async -> [String: Any]? {
        guard let id = send(request) else { return nil }
        return await withCheckedContinuation { continuation in
            replies[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.replies.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    /// The process is gone: nothing it held will be read, and no request will be answered.
    private func dropPending() {
        queued.removeAll()
        let waiting = replies.values
        replies.removeAll()
        waiting.forEach { $0.resume(returning: nil) }
    }

    // MARK: Turns

    private func handle(_ line: Data) {
        guard let object = jsonObject(line) else { return }
        switch object["type"] as? String {
        case "control_response":
            let response = object["response"] as? [String: Any] ?? [:]
            if let id = response["request_id"] as? String { replies.removeValue(forKey: id)?.resume(returning: response["response"] as? [String: Any] ?? [:]) }
            return
        case "command_lifecycle":
            if let id = object["command_uuid"] as? String, ["cancelled", "dropped"].contains(object["state"] as? String) { queued.removeValue(forKey: id) }
            return
        case "user" where object["isReplay"] as? Bool == true:
            // A queued message the agent is reading now; replays of messages Jack sent as a turn are already shown.
            if let id = object["uuid"] as? String, let text = queued.removeValue(forKey: id) {
                deliver(.delivered(id: id, text: text))
            }
            return
        default: break
        }
        if sink == nil, unpromptedEvents == nil, ClaudeProtocol.startsTurn(object) {
            idleClose?.cancel()
            unpromptedEvents = []
            unprompted?()
        }
        for var event in decoder.events(object) {
            if case .approval(let approval) = event { pendingApprovals[approval.id] = decoder.approvals[approval.id] }
            if case .mode(let mode) = event { liveMode = mode }
            // An interrupted turn ends with an error result; it is the stop the user asked for.
            if interrupting != nil, case .failure = event { event = .completed }
            deliver(event)
        }
        if sink == nil, unpromptedEvents == nil, object["subtype"] as? String == "background_tasks_changed" { scheduleIdleClose() }
    }

    private func deliver(_ event: ChatEvent) {
        if let sink {
            sink(event)
            if case .completed = event { endTurn(nil) }
            if case .failure(let message) = event { endTurn(ChatDriverError.protocolFailure(message)) }
        } else if unpromptedEvents != nil {
            unpromptedEvents?.append(event)
        } else {
            idleSink?(event)
        }
    }

    private func awaitTurn(_ onEvent: @escaping @MainActor (ChatEvent) -> Void, then start: @escaping () -> Void) async throws {
        sink = onEvent
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                turnEnded = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.sink != nil else { return }
                self.control(["subtype": "interrupt"])
                self.endTurn(CancellationError())
            }
        }
    }

    private func endTurn(_ error: Error?) {
        sink = nil
        interrupting?.cancel(); interrupting = nil
        pendingApprovals.removeAll()
        let continuation = turnEnded
        turnEnded = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        scheduleIdleClose()
    }

    /// Closes the idle process after the configured minutes, but never while a background task runs.
    private func scheduleIdleClose() {
        idleClose?.cancel()
        // Queued messages start a turn of their own as soon as the agent reads them.
        guard child != nil, sink == nil, queued.isEmpty else { return }
        let minutes = closesWhenIdle ? 0 : UserDefaults.standard.object(forKey: ChatDriverFactory.claudeKeepAliveKey) as? Int ?? 5
        let seconds = decoder.backgroundTaskCount > 0 ? max(60, minutes * 60) : minutes * 60
        idleClose = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self, self.sink == nil, self.unpromptedEvents == nil, self.queued.isEmpty else { return }
            if self.decoder.backgroundTaskCount > 0 { self.scheduleIdleClose() } else { self.closeSession() }
        }
    }
}

@MainActor
private final class OpenCodeChatDriver: ProcessChatDriver {
    private var baseURL: URL?
    private var sessionID: String?
    private var serverGeneration: UUID?
    private var serverPassword: String?
    private var streamTask: Task<Void, Error>?
    /// Context window of each `provider/model`, read once per run.
    private var contextLimits: [String: Int] = [:]

    override func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, delegation: nil, onEvent: onEvent)
    }

    override func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        stop(); let generation = UUID(); runGeneration = generation; serverGeneration = generation
        guard let executable = ExecutableResolver.resolve("opencode", override: UserDefaults.standard.string(forKey: "providerExecutablePath.opencode")) else { throw ChatDriverError.executableMissing("opencode") }
        let port = try availableLoopbackPort()
        let password = UUID().uuidString + UUID().uuidString
        var environment = ["OPENCODE_SERVER_USERNAME": "jack", "OPENCODE_SERVER_PASSWORD": password]
        if let config = ChatRunConfiguration.openCodeConfig(conversation, delegation: delegation) { environment["OPENCODE_CONFIG_CONTENT"] = config }
        let process = try begin(executable, arguments: ["serve", "--hostname", "127.0.0.1", "--port", String(port), "--pure"], directory: conversation.projectPath, environment: environment)
        do {
        let root = URL(string: "http://127.0.0.1:\(port)")!
        baseURL = root
        serverPassword = password
        try await waitUntilHealthy(root, generation: generation)
        if let (data, _) = try? await request(root, path: "/provider", method: "GET", body: nil, password: password) { contextLimits = OpenCodeCommands.contextLimits(from: data) }
        let streamReady = AsyncStream<Void>.makeStream()
        let streamTask = Task { try await self.consumeEvents(root, generation: generation, connected: streamReady.continuation, onEvent: onEvent) }
        self.streamTask = streamTask
        do {
            for await _ in streamReady.stream { break }
            let session: [String: Any]
            if let saved = conversation.sessionID, !saved.isEmpty {
                session = ["id": saved]
                sessionID = saved
            } else {
                session = try await requestJSON(root, path: "/session", method: "POST", body: ["title": conversation.title], password: password)
                guard let id = session["id"] as? String else { throw ChatDriverError.protocolFailure("OpenCode did not return a session id.") }
                sessionID = id; emit(.session(id), generation: generation, to: onEvent)
            }
            guard let id = session["id"] as? String else { throw ChatDriverError.protocolFailure("OpenCode session id is missing.") }
            let sessionPath = "/session/\(pathComponent(id))"
            if let command = ChatCommand.parse(prompt),
               let (route, body) = try await OpenCodeCommands.request(command, conversation: conversation, session: sessionPath, root: root, password: password) {
                // Commands answer when they finish; the event stream reports progress meanwhile.
                Task { [weak self] in
                    do { try await requestNoContent(root, path: sessionPath + route, method: "POST", body: body, password: password, timeout: 24 * 60 * 60) }
                    catch {
                        guard let self, self.runGeneration == generation else { return }
                        self.emit(.failure("OpenCode no pudo ejecutar /\(command.name): \(error.localizedDescription)"), generation: generation, to: onEvent)
                        streamTask.cancel()
                    }
                }
            } else {
                var body = ChatRunConfiguration.openCodePrompt(conversation, prompt: prompt)
                if delegation != nil { body["system"] = ChatDelegation.instructions }
                try await requestNoContent(root, path: sessionPath + "/prompt_async", method: "POST", body: body, password: password)
            }
            try await streamTask.value
        } catch {
            streamTask.cancel()
            throw error
        }
        self.streamTask = nil
        await finish(process, generation: generation)
        } catch {
            await finish(process, generation: generation)
            throw error
        }
    }

    override func respond(approvalID: String, allow: Bool) async throws {
        guard let separator = approvalID.firstIndex(of: ":"), let root = baseURL else { throw ChatDriverError.invalidApproval(approvalID) }
        let permission = String(approvalID[approvalID.index(after: separator)...])
        guard pendingApprovals.removeValue(forKey: approvalID) != nil, let session = sessionID else { throw ChatDriverError.invalidApproval(approvalID) }
        // OpenCode consumes a structured, one-time permission decision on its session API.
        try await requestNoContent(root, path: "/permission/\(pathComponent(permission))/reply", method: "POST", body: ["reply": allow ? "once" : "reject"], password: serverPassword)
        _ = session
    }

    override func resolve(_ pending: PendingApproval, allow: Bool) async throws {
        throw ChatDriverError.unsupportedApproval
    }

    override func stop() {
        serverGeneration = nil; baseURL = nil; sessionID = nil; serverPassword = nil
        streamTask?.cancel(); streamTask = nil
        super.stop()
    }

    private func waitUntilHealthy(_ root: URL, generation: UUID) async throws {
        let deadline = Date().addingTimeInterval(12)
        var lastError: Error?
        while Date() < deadline {
            try Task.checkCancellation()
            guard runGeneration == generation else { throw CancellationError() }
            do {
                var request = URLRequest(url: root.appendingPathComponent("global/health"))
                addAuthorization(to: &request, password: serverPassword)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, jsonObject(data)?["healthy"] as? Bool == true else { throw ChatDriverError.protocolFailure("OpenCode server health check failed.") }
                return
            } catch { lastError = error; try await Task.sleep(for: .milliseconds(100)) }
        }
        throw ChatDriverError.process("OpenCode server did not become ready: \(lastError?.localizedDescription ?? "timeout")")
    }

    private func consumeEvents(_ root: URL, generation: UUID, connected: AsyncStream<Void>.Continuation, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        do {
            var request = URLRequest(url: root.appendingPathComponent("event"))
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 24 * 60 * 60
            addAuthorization(to: &request, password: serverPassword)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatDriverError.protocolFailure("OpenCode SSE connection failed.") }
            var connectedOnce = false
            var messageRoles: [String: String] = [:]
            var partTypes: [String: String] = [:]
            var hasActivity = false
            for try await line in bytes.lines {
                try Task.checkCancellation(); guard runGeneration == generation else { throw CancellationError() }
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard payload.utf8.count <= 1024 * 1024 else { throw ChatDriverError.protocolFailure("OpenCode sent an oversized SSE event.") }
                guard let data = payload.data(using: .utf8), let object = jsonObject(data) else { continue }
                if OpenCodeProtocol.isConnected(object), !connectedOnce { connectedOnce = true; connected.yield(()) }
                let event = object["payload"] as? [String: Any] ?? object
                let properties = event["properties"] as? [String: Any] ?? [:]
                let type = event["type"] as? String ?? ""
                if type == "message.updated", let info = properties["info"] as? [String: Any], let id = info["id"] as? String { messageRoles[id] = info["role"] as? String }
                if let part = properties["part"] as? [String: Any], let id = part["id"] as? String { partTypes[id] = part["type"] as? String }
                if type == "session.status", properties["sessionID"] as? String == sessionID, (properties["status"] as? [String: Any])?["type"] as? String == "busy" { hasActivity = true }
                let events = OpenCodeProtocol.events(object, sessionID: sessionID, approvals: &pendingApprovals, messageRoles: messageRoles, partTypes: partTypes, contextLimits: contextLimits)
                for event in events {
                    if case .text = event { hasActivity = true }
                    if case .completed = event {
                        guard hasActivity else { continue }
                        emit(event, generation: generation, to: onEvent); connected.finish(); return
                    }
                    if case .failure(let message) = event { throw ChatDriverError.protocolFailure(message) }
                    emit(event, generation: generation, to: onEvent)
                }
            }
            throw ChatDriverError.process("OpenCode event stream ended before the session completed.")
        } catch {
            connected.finish()
            throw error
        }
    }
}

enum OpenCodeCommands {
    static let compact = ChatCommand(name: "compact", description: "Resume la conversación para liberar ventana de contexto.")
    static func contextLimits(from data: Data) -> [String: Int] {
        var limits: [String: Int] = [:]
        for provider in jsonObject(data)?["all"] as? [[String: Any]] ?? [] {
            guard let id = provider["id"] as? String else { continue }
            for (key, model) in provider["models"] as? [String: [String: Any]] ?? [:] {
                if let context = (model["limit"] as? [String: Any])?["context"] as? Int, context > 0 { limits["\(id)/\(model["id"] as? String ?? key)"] = context }
            }
        }
        return limits
    }
    static func commands(from data: Data) -> [ChatCommand] {
        let listed = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap { value -> ChatCommand? in
            guard let name = value["name"] as? String, !name.isEmpty else { return nil }
            let hints = (value["hints"] as? [String] ?? []).joined(separator: " ")
            return ChatCommand(name: name, description: value["description"] as? String ?? "", argumentHint: hints)
        }
        return listed.contains { $0.name == compact.name } ? listed : [compact] + listed
    }
    /// The route and body that run a slash command, or nil when OpenCode does not know it.
    static func request(_ command: (name: String, arguments: String), conversation: ChatConversation, session: String, root: URL, password: String) async throws -> (String, [String: Any])? {
        let (data, _) = try await OpenCodeCommands.fetch(root, path: "/command", password: password)
        if commands(from: data).contains(where: { $0.name == command.name && $0 != compact }) {
            var body: [String: Any] = ["command": command.name, "arguments": command.arguments]
            if conversation.model.contains("/") { body["model"] = conversation.model }
            if let variant = conversation.variant, !variant.isEmpty { body["variant"] = variant }
            if let mode = conversation.mode, !mode.isEmpty { body["agent"] = mode }
            return ("/command", body)
        }
        guard command.name == compact.name else { return nil }
        var model = conversation.model
        if !model.contains("/") { model = (try? await requestJSON(root, path: "/config", method: "GET", password: password))?["model"] as? String ?? "" }
        // Without a configured default, compact with the model the session last answered with.
        if !model.contains("/"), let (data, _) = try? await fetch(root, path: session + "/message", password: password) {
            let messages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            if let info = messages.compactMap({ $0["info"] as? [String: Any] }).last(where: { $0["role"] as? String == "assistant" }),
               let provider = info["providerID"] as? String, let id = info["modelID"] as? String { model = "\(provider)/\(id)" }
        }
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ChatDriverError.protocolFailure("Elige un modelo de OpenCode para compactar la conversación.") }
        return ("/summarize", ["providerID": parts[0], "modelID": parts[1]])
    }
    fileprivate static func fetch(_ root: URL, path: String, password: String) async throws -> (Data, URLResponse) {
        try await JackCore.request(root, path: path, method: "GET", body: nil, password: password)
    }
}

enum OpenCodeProtocol {
    static func isConnected(_ object: [String: Any]) -> Bool {
        let payload = object["payload"] as? [String: Any] ?? object
        return payload["type"] as? String == "server.connected"
    }

    static func events(_ object: [String: Any], sessionID: String?, approvals: inout [String: PendingApproval], messageRoles: [String: String] = [:], partTypes: [String: String] = [:], contextLimits: [String: Int] = [:]) -> [ChatEvent] {
        let payload = object["payload"] as? [String: Any] ?? object
        let type = payload["type"] as? String ?? ""
        let properties = payload["properties"] as? [String: Any] ?? [:]
        let eventSession = (properties["sessionID"] as? String) ?? ((properties["info"] as? [String: Any])?["sessionID"] as? String) ?? ((properties["part"] as? [String: Any])?["sessionID"] as? String)
        if let eventSession, let sessionID, eventSession != sessionID { return [] }
        if type == "message.updated", let info = properties["info"] as? [String: Any], info["role"] as? String == "assistant" {
            let value = info["tokens"] as? [String: Any] ?? [:]
            let cache = value["cache"] as? [String: Any] ?? [:]
            let used = ["input", "output", "reasoning"].reduce(0) { $0 + (value[$1] as? Int ?? 0) } + (cache["read"] as? Int ?? 0) + (cache["write"] as? Int ?? 0)
            let model = [info["providerID"] as? String, info["modelID"] as? String].compactMap { $0 }.joined(separator: "/")
            let context: [ChatEvent] = used > 0 ? [.context(used: used, window: contextLimits[model])] : []
            return context + [.tokens(ChatTokenUsage(input: value["input"] as? Int ?? 0, output: value["output"] as? Int ?? 0, cached: cache["read"] as? Int ?? 0, reasoning: value["reasoning"] as? Int ?? 0, costUSD: info["cost"] as? Double))]
        }
        if type == "permission.replied", let id = properties["requestID"] as? String { return [.approvalResolved("opencode:\(id)")] }
        if type == "session.status", let status = properties["status"] as? [String: Any], status["type"] as? String == "retry" { return [.tool(id: "retry:\(sessionID ?? "")", title: "Reintentando conexión", detail: boundedJSON(status), status: "running")] }
        if (type == "permission.asked" || type == "permission.updated"), let permissionID = (properties["id"] as? String) ?? (properties["permission"] as? [String: Any])?["id"] as? String {
            let session = eventSession ?? sessionID ?? ""
            let id = "opencode:\(permissionID)"
            approvals[id] = PendingApproval(payload: ["permissionID": permissionID, "sessionID": session], provider: "opencode")
            let title = properties["title"] as? String ?? "OpenCode requests permission"
            return [.approval(ChatApproval(id: id, title: title, detail: boundedJSON(properties["metadata"] ?? properties["patterns"] ?? [:])))]
        }
        if type == "message.part.updated" || type == "message.part.delta" {
            let part = properties["part"] as? [String: Any] ?? properties
            let id = part["id"] as? String ?? properties["partID"] as? String ?? "opencode-part"
            if let messageID = part["messageID"] as? String ?? properties["messageID"] as? String, messageRoles[messageID] == "user" { return [] }
            let kind = part["type"] as? String ?? partTypes[id] ?? "text"
            if kind == "reasoning", let text = properties["delta"] as? String ?? part["text"] as? String { return [.reasoning(id: id, text: text, replace: type == "message.part.updated")] }
            if type == "message.part.delta", properties["field"] as? String == "text", kind == "text", let text = properties["delta"] as? String { return [.text(id: id, text: text, replace: false)] }
            if part["type"] as? String == "text", let text = (properties["delta"] as? String) ?? (part["text"] as? String) {
                return [.text(id: id, text: text, replace: type == "message.part.updated")]
            }
            if part["type"] as? String == "tool" {
                let state = part["state"] as? [String: Any] ?? [:]
                let detail = [boundedJSON(state["input"] ?? [:]), state["output"] as? String ?? state["error"] as? String ?? ""].joined(separator: "\n")
                // MCP tools report an empty title, and Jack's own tools are recognized by name.
                let tool = part["tool"] as? String
                let stateTitle = (state["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let title = tool?.hasPrefix("jack_") == true ? tool! : stateTitle ?? tool ?? "Herramienta"
                return [.tool(id: id, title: title, detail: detail, status: state["status"] as? String ?? "running")]
            }
        }
        if type == "session.idle", (properties["sessionID"] as? String) == sessionID { return [.completed] }
        if type == "session.error", (properties["sessionID"] as? String) == sessionID { return [.failure(boundedJSON(properties["error"] ?? "OpenCode reported an error."))] }
        return []
    }
}

public enum OpenCodeModelService {
    public static func list(directory: String) async throws -> [OpenCodeProviderModels] {
        try await load(directory: directory).providers
    }
    public static func load(directory: String) async throws -> OpenCodeCatalog {
        try await withServer(directory: directory) { root, password in
            let (data, response) = try await request(root, path: "/provider", method: "GET", body: nil, password: password)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ChatDriverError.protocolFailure("No se pudieron consultar los modelos de OpenCode.")
            }
            let (modeData, modeResponse) = try await request(root, path: "/agent", method: "GET", body: nil, password: password)
            guard (modeResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw ChatDriverError.protocolFailure("No se pudieron consultar los modos de OpenCode.")
            }
            return OpenCodeCatalog(providers: try connectedModels(from: data), modes: try primaryModes(from: modeData))
        }
    }
    /// Starts a short-lived OpenCode server for catalog queries; it never runs a prompt.
    static func withServer<T>(directory: String, _ body: (URL, String) async throws -> T) async throws -> T {
        guard let executable = ExecutableResolver.resolve("opencode", override: UserDefaults.standard.string(forKey: "providerExecutablePath.opencode")) else {
            throw ChatDriverError.executableMissing("opencode")
        }
        let port = try availableLoopbackPort()
        let password = UUID().uuidString + UUID().uuidString
        let child = try StructuredChild(executable: executable,
            arguments: ["serve", "--hostname", "127.0.0.1", "--port", String(port), "--pure"],
            directory: directory,
            environment: ["OPENCODE_SERVER_USERNAME": "jack", "OPENCODE_SERVER_PASSWORD": password])
        defer { child.terminate(); Task { await child.waitForExit() } }
        let root = URL(string: "http://127.0.0.1:\(port)")!
        let deadline = Date().addingTimeInterval(12)
        var ready = false
        while Date() < deadline {
            try Task.checkCancellation()
            var health = URLRequest(url: root.appendingPathComponent("global/health"))
            health.timeoutInterval = 1
            addAuthorization(to: &health, password: password)
            if let (data, response) = try? await URLSession.shared.data(for: health),
               (response as? HTTPURLResponse)?.statusCode == 200,
               jsonObject(data)?["healthy"] as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard ready else { throw ChatDriverError.process("OpenCode no pudo iniciar para consultar su catálogo.") }
        return try await body(root, password)
    }

    static func connectedModels(from data: Data) throws -> [OpenCodeProviderModels] {
        guard let root = jsonObject(data), let providers = root["all"] as? [[String: Any]],
              let connected = root["connected"] as? [String] else {
            throw ChatDriverError.protocolFailure("El catálogo de modelos de OpenCode no es válido.")
        }
        let connectedIDs = Set(connected)
        return providers.compactMap { provider -> OpenCodeProviderModels? in
            guard let id = provider["id"] as? String, connectedIDs.contains(id),
                  let models = provider["models"] as? [String: [String: Any]] else { return nil }
            let choices = models.map { key, model in
                ChatModelChoice(id: "\(id)/\(model["id"] as? String ?? key)",
                    title: model["name"] as? String ?? key, efforts: variantNames(model))
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            guard !choices.isEmpty else { return nil }
            return OpenCodeProviderModels(id: id, title: provider["name"] as? String ?? id, models: choices)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private static func variantNames(_ model: [String: Any]) -> [String] {
        let variants = model["variants"] as? [String: [String: Any]] ?? [:]
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        return variants.filter { $0.value["disabled"] as? Bool != true }.map(\.key).sorted {
            let left = order.firstIndex(of: $0) ?? order.count
            let right = order.firstIndex(of: $1) ?? order.count
            return left == right ? $0.localizedStandardCompare($1) == .orderedAscending : left < right
        }
    }
    static func primaryModes(from data: Data) throws -> [ChatRunMode] {
        guard let agents = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ChatDriverError.protocolFailure("El catálogo de modos de OpenCode no es válido.")
        }
        return agents.compactMap { agent in
            guard agent["hidden"] as? Bool != true, agent["mode"] as? String != "subagent",
                  let name = agent["name"] as? String else { return nil }
            return ChatRunMode(id: name, title: name == "plan" ? "Plan" : name == "build" ? "Build" : name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// Lists each provider's slash commands without starting a turn or spending tokens.
public enum ChatCommandService {
    public static func load(_ provider: ChatProvider, directory: String) async throws -> [ChatCommand] {
        switch provider {
        case .claude: return try await claude(directory: directory)
        case .codex: return try await codex(directory: directory)
        case .opencode:
            return try await OpenCodeModelService.withServer(directory: directory) { root, password in
                let (data, response) = try await request(root, path: "/command", method: "GET", body: nil, password: password)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatDriverError.protocolFailure("No se pudieron consultar los comandos de OpenCode.") }
                return OpenCodeCommands.commands(from: data)
            }
        }
    }
    /// Claude Code announces its commands at startup, before it reads any message.
    private static func claude(directory: String) async throws -> [ChatCommand] {
        guard let executable = ExecutableResolver.resolve("claude", override: UserDefaults.standard.string(forKey: "providerExecutablePath.claude")) else { throw ChatDriverError.executableMissing("claude") }
        let child = try StructuredChild(executable: executable, arguments: ["--print", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--no-session-persistence"], directory: directory)
        defer { child.terminate(); Task { await child.waitForExit() } }
        let timeout = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { child.terminate() } }
        defer { timeout.cancel() }
        for try await line in child.lines {
            guard let object = jsonObject(line), object["subtype"] as? String == "commands_changed", let commands = object["commands"] as? [[String: Any]] else { continue }
            return ClaudeProtocol.commands(commands)
        }
        throw ChatDriverError.process(await child.failureDescription(default: "Claude Code se cerró sin informar de sus comandos (¿tardó más de 45 s?)"))
    }
    private static func codex(directory: String) async throws -> [ChatCommand] {
        guard let executable = ExecutableResolver.resolve("codex", override: UserDefaults.standard.string(forKey: "providerExecutablePath.codex")) else { throw ChatDriverError.executableMissing("codex") }
        let child = try StructuredChild(executable: executable, arguments: ["app-server", "--listen", "stdio://"], directory: directory)
        defer { child.terminate(); Task { await child.waitForExit() } }
        let timeout = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { child.terminate() } }
        defer { timeout.cancel() }
        try child.writeJSON(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "jack", "title": "Jack", "version": "1"], "capabilities": ["experimentalApi": true]]])
        for try await line in child.lines {
            guard let object = jsonObject(line), let id = object["id"] as? Int, object["method"] == nil else { continue }
            if id == 1 {
                try child.writeJSON(["method": "initialized", "params": [:]])
                try child.writeJSON(["id": 2, "method": "skills/list", "params": ["cwds": [directory]]])
            } else if id == 2 { return CodexCommands.commands(from: object) }
        }
        throw ChatDriverError.process(await child.failureDescription(default: "Codex no informó de sus skills."))
    }
}

enum ChatRunConfiguration {
    static func codexTurn(_ conversation: ChatConversation, threadID: String, prompt: String, skill: [String: Any]? = nil) -> [String: Any] {
        let mode = conversation.mode ?? "default"
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        // Codex mentions skills as `$name`; the skill item tells it which file to load.
        if let skill, let name = skill["name"] as? String, let path = skill["path"] as? String {
            input = [["type": "text", "text": "$" + prompt.dropFirst()], ["type": "skill", "name": name, "path": path]]
        }
        let attachments = conversation.turnAttachments
        if !attachments.isEmpty {
            input[0]["text"] = ChatAttachments.promptText(input[0]["text"] as? String ?? prompt, attachments: attachments)
            input += attachments.filter { ChatAttachments.imageType($0) != nil }.map { ["type": "localImage", "path": $0] }
        }
        return ["threadId": threadID, "input": input,
            "cwd": conversation.projectPath, "approvalPolicy": mode == "auto" ? "never" : "on-request",
            "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": [conversation.projectPath] + conversation.additionalDirectories, "networkAccess": false],
            "model": nonempty(conversation.model), "effort": conversation.effort, "summary": "detailed",
            "collaborationMode": ["mode": mode == "plan" ? "plan" : "default", "settings": [
                "model": nonempty(conversation.model), "reasoning_effort": conversation.effort,
                "developer_instructions": NSNull()]]]
    }
    static func codexDelegation(_ delegation: ChatDelegation) -> [String] {
        // Values are TOML; the bearer token is read from JACK_MCP_TOKEN.
        ["-c", "mcp_servers.jack.url=\"\(delegation.url.absoluteString)\"",
         "-c", "mcp_servers.jack.bearer_token_env_var=\"JACK_MCP_TOKEN\"",
         "-c", "mcp_servers.jack.tool_timeout_sec=960",
         "-c", "mcp_servers.jack.default_tools_approval_mode=\"approve\""]
    }
    /// Inline OpenCode config: the Jack MCP server when delegating and the extra folders it may touch.
    static func openCodeConfig(_ conversation: ChatConversation, delegation: ChatDelegation?) -> String? {
        var config: [String: Any] = delegation.map(openCodeDelegationConfig) ?? [:]
        let directories = conversation.additionalDirectories + conversation.attachmentDirectories
        if !directories.isEmpty {
            var rules: [String: String] = [:]
            for directory in directories { rules[directory] = "allow"; rules[directory + "/**"] = "allow" }
            config["permission"] = ["external_directory": rules]
        }
        guard !config.isEmpty else { return nil }
        return (try? JSONSerialization.data(withJSONObject: config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    static func openCodeDelegation(_ delegation: ChatDelegation) -> String {
        (try? JSONSerialization.data(withJSONObject: openCodeDelegationConfig(delegation))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    private static func openCodeDelegationConfig(_ delegation: ChatDelegation) -> [String: Any] {
        let config: [String: Any] = [
            "mcp": ["jack": ["type": "remote", "url": delegation.url.absoluteString, "enabled": true, "timeout": 960_000,
                             "headers": ["Authorization": "Bearer \(delegation.token)"]]],
            "experimental": ["mcp_timeout": 960_000],
        ]
        return config
    }
    static func claudeDelegation(_ delegation: ChatDelegation) -> [String] {
        let server: [String: Any] = ["type": "http", "url": delegation.url.absoluteString, "headers": ["Authorization": "Bearer \(delegation.token)"]]
        let config = (try? JSONSerialization.data(withJSONObject: ["mcpServers": ["jack": server]])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Each list flag is followed by another flag, so the variadic options stop where intended.
        return ["--mcp-config", config, "--allowedTools", "mcp__jack", "--append-system-prompt", ChatDelegation.instructions]
    }
    static func claudeSettings(_ conversation: ChatConversation) -> [String] {
        let effort = ChatModelChoice.claudeEfforts(for: conversation.model).contains(conversation.effort) ? ["--effort", conversation.effort] : []
        // `--add-dir` is variadic, so each one is followed by another flag.
        let directories = (conversation.additionalDirectories + conversation.attachmentDirectories).flatMap { ["--add-dir", $0] }
        return directories + ["--permission-mode", conversation.mode ?? "manual", "--model", nonempty(conversation.model)] + effort
    }
    /// The launch settings a running Claude Code process cannot change. Mode and model change live, and the
    /// folders of one message's attachments are left out so attaching a file does not restart the session.
    static func claudeLaunchSignature(_ conversation: ChatConversation) -> [String] {
        let effort = ChatModelChoice.claudeEfforts(for: conversation.model).contains(conversation.effort) ? conversation.effort : ""
        return [conversation.projectPath, effort] + conversation.additionalDirectories
    }
    /// Plain text, or text plus image blocks when the message carries attachments.
    static func claudeContent(_ conversation: ChatConversation, prompt: String) -> Any {
        claudeContent(prompt: prompt, attachments: conversation.turnAttachments)
    }
    static func claudeContent(prompt: String, attachments: [String]) -> Any {
        guard !attachments.isEmpty else { return prompt }
        var blocks: [[String: Any]] = [["type": "text", "text": ChatAttachments.promptText(prompt, attachments: attachments)]]
        for path in attachments {
            guard let image = ChatAttachments.inlineImage(path) else { continue }
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]])
        }
        return blocks
    }
    static func openCodePrompt(_ conversation: ChatConversation, prompt: String) -> [String: Any] {
        let attachments = conversation.turnAttachments
        var parts: [[String: Any]] = [["type": "text", "text": ChatAttachments.promptText(prompt, attachments: attachments)]]
        for path in attachments {
            guard let image = ChatAttachments.inlineImage(path) else { continue }
            parts.append(["type": "file", "mime": image.mediaType, "filename": URL(fileURLWithPath: path).lastPathComponent,
                          "url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"])
        }
        var body: [String: Any] = ["parts": parts]
        let model = conversation.model.split(separator: "/", maxSplits: 1).map(String.init)
        if model.count == 2 { body["model"] = ["providerID": model[0], "modelID": model[1]] }
        if let variant = conversation.variant, !variant.isEmpty { body["variant"] = variant }
        if let mode = conversation.mode, !mode.isEmpty { body["agent"] = mode }
        return body
    }
}

private func requestJSON(_ root: URL, path: String, method: String, body: [String: Any]? = nil, password: String? = nil) async throws -> [String: Any] {
    let (data, response) = try await request(root, path: path, method: method, body: body, password: password)
    guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), let value = jsonObject(data) else { throw ChatDriverError.protocolFailure("OpenCode \(method) \(path) returned an invalid response (\((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
    return value
}

private func requestNoContent(_ root: URL, path: String, method: String, body: [String: Any]? = nil, password: String? = nil, timeout: TimeInterval = 60) async throws {
    let (_, response) = try await request(root, path: path, method: method, body: body, password: password, timeout: timeout)
    guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw ChatDriverError.protocolFailure("OpenCode \(method) \(path) failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
}

private func request(_ root: URL, path: String, method: String, body: [String: Any]?, password: String? = nil, timeout: TimeInterval = 60) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: root.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = timeout
    addAuthorization(to: &request, password: password)
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    return try await URLSession.shared.data(for: request)
}

private func addAuthorization(to request: inout URLRequest, password: String?) {
    guard let password, let credentials = "jack:\(password)".data(using: .utf8) else { return }
    request.setValue("Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization")
}

private func pathComponent(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?"))) ?? value }

private func availableLoopbackPort() throws -> UInt16 {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ChatDriverError.process("Could not allocate a loopback socket for OpenCode.") }
    defer { close(descriptor) }
    let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { throw ChatDriverError.process("Could not reserve a loopback port for OpenCode.") }
    var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &actual) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    guard result == 0 else { throw ChatDriverError.process("Could not read the OpenCode loopback port.") }
    return UInt16(bigEndian: actual.sin_port)
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func boundedJSON(_ value: Any, limit: Int = 64 * 1024) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return String(describing: value).prefix(limit).description }
    if data.count <= limit { return String(data: data, encoding: .utf8) ?? "" }
    return String(data: data.prefix(limit), encoding: .utf8).map { $0 + "\n… output truncated at 64 KB" } ?? "[output truncated at 64 KB]"
}

private func readableItem(type: String, item: [String: Any]) -> String {
    switch type {
    case "commandExecution": return "Ejecutar comando"
    case "fileChange": return "Editar archivos"
    case "mcpToolCall":
        let tool = item["tool"] as? String ?? "Herramienta"
        return item["server"] as? String == "jack" ? "mcp__jack__\(tool)" : "MCP · \(tool)"
    case "webSearch": return "Buscar en la web"
    case "imageView": return "Ver imagen"
    case "contextCompaction": return "Compactar contexto"
    default: return type.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

private func readableDetails(type: String, item: [String: Any]) -> String {
    if type == "commandExecution" {
        let command = item["command"] as? String ?? ""
        let cwd = item["cwd"] as? String ?? ""
        let output = item["aggregatedOutput"] as? String
        let code = item["exitCode"] as? Int
        return [command, cwd.isEmpty ? nil : "Carpeta: \(cwd)", output, code.map { "Salida: \($0)" }].compactMap { $0 }.joined(separator: "\n").suffix(64 * 1024).description
    }
    if type == "fileChange", let changes = item["changes"] as? [[String: Any]] {
        return changes.map { change in
            let path = change["path"] as? String ?? change["filePath"] as? String ?? "file"
            let kind = change["kind"] as? String ?? (change["kind"] as? [String: Any])?["type"] as? String ?? "change"
            let diff = change["diff"] as? String ?? ""
            return "\(kind): \(path)\n\(diff)"
        }.joined(separator: "\n").prefix(64 * 1024).description
    }
    if type == "mcpToolCall", item["server"] as? String == "jack" {
        // Same shape as Claude: the input as JSON, then the result text.
        let input = boundedJSON(item["arguments"] ?? [:])
        let result = item["result"] as? [String: Any]
        let texts = (result?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        let error = (item["error"] as? [String: Any])?["message"] as? String ?? item["error"] as? String
        return ([input] + texts + [error].compactMap { $0 }).joined(separator: "\n").prefix(64 * 1024).description
    }
    return boundedJSON(item)
}

private func nonempty(_ value: String) -> String { value.isEmpty ? "" : value }

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
