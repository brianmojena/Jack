import Foundation
import Network

/// How a driver connects an orchestrating agent to Jack's delegation tools.
public struct ChatDelegation: Equatable {
    public var url: URL
    public var token: String
    /// The agent may create and manage other agents.
    public var delegates: Bool
    /// The agent may create images with Image Playground.
    public var images: Bool
    public init(url: URL, token: String, delegates: Bool = true, images: Bool = false) {
        self.url = url; self.token = token; self.delegates = delegates; self.images = images
    }

    /// Tells every agent with the `jack` tools when to create an image.
    public static let imageInstructions = """
    The `jack` MCP server's generate_image tool creates images with Apple's Image Playground on this Mac. Use it when \
    the task needs a specific picture (a photo for a page, an illustration, a placeholder that should look real) \
    instead of searching the web or drawing it in code.
    - Write the prompt as a short, concrete description of what is visible: subject, setting, light and framing. It is \
    photorealistic by default; pass style for animation, illustration or sketch.
    - Image Playground refuses real people's names, brands, logos, text in the image and violence. When the result says \
    it closed without an image, write a different, simpler prompt and try again, up to three times.
    - Pass path with where the image belongs in the project, and width and height when the size matters.
    - The user picks the result in Image Playground, so the call waits for them.
    """

    /// Tells the orchestrator what the `jack` tools are for. Sub-agents never see this conversation.
    public static let instructions = """
    You are running inside Jack, the user's macOS agent manager. Besides your own tools, the `jack` MCP server lets you \
    delegate work to other coding agents (Codex, Claude Code or OpenCode). Each one runs as its own session that the user \
    can watch in Jack's sidebar, nested under you.
    - Delegate when the user asks for it, or when the work splits into clearly independent parts.
    - Sub-agents do not see this conversation: give each one a complete, self-contained task with the files, goal and \
    constraints it needs.
    - Sub-agents in the same folder share its files. Give them non-overlapping files and never edit those files yourself \
    while they work.
    - After delegating, call wait_for_agents instead of polling, then read get_agent_result and check their work before you \
    report back. Use send_message for follow-ups to an agent that already finished.
    - If a sub-agent is waiting for the user's permission, tell the user to review it in Jack.
    """

    /// Appended to every delegated task so sub-agents play safe in a shared folder, whatever the orchestrator wrote.
    public static let subAgentGuidance = """
    ---
    Notes from Jack (you were started by another agent):
    - Other agents may be working in this same folder at the same time.
    - Only change the files your task needs. Do not reformat, move or delete anything else.
    - Do not run git commands that change state (stash, checkout, reset, rebase, commit, push).
    - If a build or test fails because of files outside your task, report it in your answer instead of fixing it.
    """
}

/// Loopback MCP server (streamable HTTP with JSON responses) that lets an agent create and monitor other agents.
/// Every orchestrator gets its own bearer token, which also identifies which conversation is calling.
@MainActor public final class AgentBridge {
    public static let maxChildren = 8
    private weak var store: ChatStore?
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: [CheckedContinuation<UInt16, Error>] = []
    private var callers: [String: UUID] = [:]
    private var tokens: [UUID: String] = [:]
    /// What each caller may do: the token stays the same, so a later run can change it.
    private var permissions: [UUID: (delegates: Bool, images: Bool)] = [:]

    init(store: ChatStore) { self.store = store }

    /// Starts the server on first use; agents that never delegate cost nothing.
    public func delegation(for conversationID: UUID, delegates: Bool = true, images: Bool = false) async throws -> ChatDelegation {
        let port = try await ensureListening()
        let token = tokens[conversationID] ?? {
            let value = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
            tokens[conversationID] = value; callers[value] = conversationID
            return value
        }()
        permissions[conversationID] = (delegates, images)
        return ChatDelegation(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, token: token, delegates: delegates, images: images)
    }

    public func stop() {
        listener?.cancel(); listener = nil; port = nil
    }

    private func ensureListening() async throws -> UInt16 {
        if let port { return port }
        return try await withCheckedThrowingContinuation { continuation in
            starting.append(continuation)
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                parameters.acceptLocalOnly = true
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.listenerChanged(state) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    let handler = HTTPConnection(connection) { request in
                        guard let self else { return .status(503) }
                        return await self.handle(request)
                    }
                    handler.start()
                }
                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                resumeStarting(.failure(error))
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            if let port { resumeStarting(.success(port)) }
        case .failed(let error):
            listener?.cancel(); listener = nil; port = nil
            resumeStarting(.failure(error))
        case .cancelled:
            listener = nil; port = nil
        default: break
        }
    }

    private func resumeStarting(_ result: Result<UInt16, Error>) {
        let waiting = starting; starting = []
        for continuation in waiting { continuation.resume(with: result) }
    }

    // MARK: HTTP and JSON-RPC

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else { return .status(404) }
        let authorization = request.headers["authorization"] ?? ""
        guard authorization.hasPrefix("Bearer "), let caller = callers[String(authorization.dropFirst(7))] else { return .status(401) }
        switch request.method {
        case "POST": break
        case "DELETE": return .status(200)
        default: return .status(405)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = payload as? [[String: Any]] {
            var responses: [[String: Any]] = []
            for message in batch { if let response = await rpc(message, caller: caller) { responses.append(response) } }
            return responses.isEmpty ? .status(202) : .json(responses)
        }
        guard let message = payload as? [String: Any] else { return .json(Self.error(id: NSNull(), code: -32600, message: "Invalid request")) }
        guard let response = await rpc(message, caller: caller) else { return .status(202) }
        return .json(response)
    }

    func rpc(_ message: [String: Any], caller: UUID) async -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            return Self.result(id: id, [
                "protocolVersion": requested.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "jack", "version": "1.0"],
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let allowed = permissions[caller] ?? (true, false)
            let tools = (allowed.delegates ? Self.tools : []) + (allowed.images ? [Self.imageTool] : [])
            return Self.result(id: id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, failed) = await call(name, arguments: arguments, caller: caller)
            return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func result(id: Any, _ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        tool("create_agent", "Create a sub-agent in Jack and start it on a task right away. Returns its agent_id. It runs in parallel with you and does not see this conversation, so the task must be self-contained.", [
            "provider": ["type": "string", "enum": ["codex", "claude", "opencode"], "description": "Which coding agent runs the task."],
            "task": ["type": "string", "description": "Complete instructions for the sub-agent."],
            "title": ["type": "string", "description": "Short name shown in Jack's sidebar."],
            "model": ["type": "string", "description": "Optional model id. Omit to use the provider's default."],
            "effort": ["type": "string", "enum": ["low", "medium", "high", "xhigh", "max"], "description": "Reasoning effort. Defaults to high. xhigh and max apply only to models that support them; otherwise the closest supported level is used."],
            "directory": ["type": "string", "description": "Absolute folder to work in. Defaults to your own project folder."],
        ], required: ["provider", "task"]),
        tool("send_message", "Send a follow-up message to one of your sub-agents. It must not be working at the moment.", [
            "agent_id": ["type": "string"],
            "message": ["type": "string"],
        ], required: ["agent_id", "message"]),
        tool("wait_for_agents", "Block until your sub-agents finish (or until the timeout), then report each one's status. Prefer this over polling.", [
            "agent_ids": ["type": "array", "items": ["type": "string"], "description": "Agents to wait for. Defaults to all your working sub-agents."],
            "mode": ["type": "string", "enum": ["all", "any"], "description": "Return when all finish (default) or when any finishes."],
            "timeout_seconds": ["type": "integer", "description": "Maximum wait, 10–900 seconds. Defaults to 600."],
        ], required: []),
        tool("get_agent_result", "Read a sub-agent's status, its final reply and its recent activity.", [
            "agent_id": ["type": "string"],
            "include_activity": ["type": "boolean", "description": "Also list its recent tool calls. Defaults to true."],
        ], required: ["agent_id"]),
        tool("list_agents", "List the sub-agents you created and their current status.", [:], required: []),
        tool("stop_agent", "Stop a sub-agent that is working or queued.", [
            "agent_id": ["type": "string"],
        ], required: ["agent_id"]),
    ]

    static let imageTool = tool("generate_image", "Create an image with Apple's Image Playground on this Mac and save it to a file. The user sees Image Playground with your prompt and picks a result, so the call waits for them (up to 15 minutes). Photorealistic unless you pass another style. If it returns that Image Playground closed without an image, the prompt was probably refused: write a different one and try again.", [
        "prompt": ["type": "string", "description": "Short, concrete description of what the image shows: subject, setting, light, framing. No real people's names, brands or text."],
        "style": ["type": "string", "enum": ChatImageRequest.Style.allCases.map(\.rawValue), "description": "Defaults to realistic."],
        "path": ["type": "string", "description": "Where to save it, absolute or relative to your folder; a folder gets a file named after the prompt. Defaults to generated-images/ in your folder. Existing files are never overwritten."],
        "width": ["type": "integer", "description": "Wanted width in pixels; Image Playground uses the closest size it supports. Defaults to 1024."],
        "height": ["type": "integer", "description": "Wanted height in pixels. Defaults to 1024."],
        "reference_image": ["type": "string", "description": "Optional path of an image to start from."],
    ], required: ["prompt"])

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> (String, Bool) {
        guard let store else { return ("Jack is closing.", true) }
        guard let parent = store.conversations.first(where: { $0.id == caller }) else { return ("The calling conversation no longer exists.", true) }
        if name == "generate_image" { return await generateImage(arguments, caller: parent, store: store) }
        guard permissions[caller]?.delegates ?? true else { return ("Only the agent the user talks to can manage other agents.", true) }
        let children = store.conversations.filter { $0.parentID == caller }

        func child(_ value: Any?) -> ChatConversation? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
            return children.first { $0.id.uuidString.lowercased().hasPrefix(text) }
        }
        func notFound(_ value: Any?) -> (String, Bool) {
            ("No sub-agent with id \(value as? String ?? "(missing)"). Call list_agents to see your sub-agents.", true)
        }

        switch name {
        case "create_agent":
            guard let provider = (arguments["provider"] as? String).flatMap(ChatProvider.init(rawValue:)) else {
                return ("provider must be one of codex, claude, opencode.", true)
            }
            guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
                return ("task is required.", true)
            }
            guard children.count < Self.maxChildren else {
                return ("You already have \(children.count) sub-agents, the maximum. Reuse one with send_message.", true)
            }
            let directory = (arguments["directory"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? parent.projectPath
            let effort = ["low", "medium", "high", "xhigh", "max"].contains(arguments["effort"] as? String ?? "") ? arguments["effort"] as! String : "high"
            let model = (arguments["model"] as? String)?.trimmingCharacters(in: .whitespaces)
            let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = store.create(
                projectPath: directory, provider: provider, model: model?.isEmpty == false ? model : nil, effort: effort,
                parentID: caller, title: title?.isEmpty == false ? title : nil, select: false
            ) else { return ("Could not create the agent: \(directory) is not an existing folder.", true) }
            store.send(task + "\n\n" + ChatDelegation.subAgentGuidance, to: id)
            let queued = store.statuses[id] == .queued
            return ("Created \(provider.title) agent \(Self.shortID(id))\(queued ? ". It is queued until a slot frees up (Jack runs at most \(store.maxConcurrent) agents at once)" : " and it started working"). Call wait_for_agents to wait for it.", false)

        case "send_message":
            guard let agent = child(arguments["agent_id"]) else { return notFound(arguments["agent_id"]) }
            guard let text = (arguments["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return ("message is required.", true) }
            guard !(store.statuses[agent.id] ?? .idle).isBusy else { return ("Agent \(Self.shortID(agent.id)) is still working. Wait for it first.", true) }
            store.send(text, to: agent.id)
            return ("Sent to \(Self.shortID(agent.id)).", false)

        case "wait_for_agents":
            let requested = (arguments["agent_ids"] as? [Any])?.compactMap(child) ?? []
            let targets = requested.isEmpty ? children.filter { (store.statuses[$0.id] ?? .idle).isBusy } : requested
            guard !targets.isEmpty else { return (children.isEmpty ? "You have no sub-agents yet." : "None of your sub-agents is working.\n\n" + summary(children), false) }
            let waitAny = arguments["mode"] as? String == "any"
            let timeout = min(max((arguments["timeout_seconds"] as? Int) ?? 600, 10), 900)
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            store.beginDelegatedWait(caller)
            defer { store.endDelegatedWait(caller) }
            while Date() < deadline {
                let busy = targets.filter { (store.statuses[$0.id] ?? .idle).isBusy }
                if busy.isEmpty || (waitAny && busy.count < targets.count) { break }
                // The orchestrator was stopped: stop holding the request open.
                guard (store.statuses[caller] ?? .idle).isBusy else { return ("Stopped.", true) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let timedOut = targets.contains { (store.statuses[$0.id] ?? .idle).isBusy } && !waitAny
            return ((timedOut ? "Timed out; some agents are still working.\n\n" : "") + summary(targets), false)

        case "get_agent_result":
            guard let agent = child(arguments["agent_id"]) else { return notFound(arguments["agent_id"]) }
            var text = line(agent)
            if (arguments["include_activity"] as? Bool) != false {
                let activity = store.recentActivity(of: agent.id, limit: 20)
                if !activity.isEmpty { text += "\n\nRecent activity:\n" + activity.map { "- " + $0 }.joined(separator: "\n") }
            }
            if let error = store.lastError(of: agent.id), store.statuses[agent.id] == .failed { text += "\n\nError: " + error }
            text += "\n\nFinal reply:\n" + (store.lastReply(of: agent.id) ?? "(no reply yet)")
            return (text, false)

        case "list_agents":
            return (children.isEmpty ? "You have no sub-agents yet." : summary(children), false)

        case "stop_agent":
            guard let agent = child(arguments["agent_id"]) else { return notFound(arguments["agent_id"]) }
            store.stop(agent.id)
            return ("Stopped \(Self.shortID(agent.id)).", false)

        default:
            return ("Unknown tool \(name).", true)
        }
    }

    private func generateImage(_ arguments: [String: Any], caller: ChatConversation, store: ChatStore) async -> (String, Bool) {
        guard permissions[caller.id]?.images == true, store.imageGenerationAvailable else {
            return ("Image Playground is not available on this Mac: it needs Apple Intelligence turned on in System Settings.", true)
        }
        guard let prompt = (arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return ("prompt is required.", true)
        }
        guard prompt.count <= 1000 else { return ("The prompt is too long: describe the image in under 1000 characters.", true) }
        let style = (arguments["style"] as? String).flatMap(ChatImageRequest.Style.init(rawValue:)) ?? .realistic
        func size(_ key: String) -> Int { min(max((arguments[key] as? Int) ?? (arguments[key] as? Double).map(Int.init) ?? 1024, 256), 4096) }
        var reference: String?
        if let path = (arguments["reference_image"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : caller.projectPath + "/" + expanded
            guard FileManager.default.fileExists(atPath: absolute) else { return ("reference_image \(absolute) does not exist.", true) }
            reference = absolute
        }
        let request = ChatImageRequest(conversationID: caller.id, prompt: prompt, style: style, width: size("width"), height: size("height"),
                                       destination: ChatImageRequest.destination(for: arguments["path"] as? String, prompt: prompt, project: caller.projectPath),
                                       referenceImage: reference)
        let id = store.requestImage(request)
        let deadline = Date().addingTimeInterval(900)
        while store.imageRequest(id)?.isPending == true {
            // The agent was stopped: stop holding the request open.
            guard (store.statuses[caller.id] ?? .idle).isBusy else { store.resolveImage(id, .failed("the agent was stopped")); return ("Stopped.", true) }
            guard Date() < deadline else {
                store.resolveImage(id, .failed("the user did not answer within 15 minutes"))
                return ("The user did not create the image within 15 minutes. Carry on without it and mention it in your reply.", true)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // Cancelled and declined requests leave the list as soon as they end, so read the state they ended in.
        return (store.imageRequest(id) ?? store.endedImage(id) ?? request).resultText
    }

    private func summary(_ agents: [ChatConversation]) -> String {
        agents.map(line).joined(separator: "\n")
    }

    private func line(_ agent: ChatConversation) -> String {
        let status = store?.statuses[agent.id] ?? .idle
        let state: String
        switch status {
        case .running: state = "working"
        case .queued: state = "queued, waiting for a free slot"
        case .waiting: state = "waiting for the user's permission in Jack"
        case .failed: state = "failed"
        case .idle: state = store?.lastReply(of: agent.id) == nil ? "idle" : "finished"
        }
        let model = agent.model.isEmpty ? "" : " (\(agent.model))"
        return "- \(Self.shortID(agent.id)) · \(agent.provider.title)\(model) · \(state) · \"\(agent.title)\" · \(agent.projectPath)"
    }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
}

extension ChatStatus {
    var isBusy: Bool { self == .running || self == .queued || self == .waiting }
}

// MARK: - Minimal HTTP/1.1 over NWConnection

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var body: Data = Data()
    var contentType: String?

    static func status(_ code: Int) -> HTTPResponse { HTTPResponse(status: code) }
    static func json(_ value: Any) -> HTTPResponse {
        HTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), contentType: "application/json")
    }

    var data: Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if status == 405 { head += "Allow: POST, DELETE\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Serves requests one at a time on a keep-alive connection.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: @MainActor (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()
    private static let maxBody = 4 * 1024 * 1024

    init(_ connection: NWConnection, handler: @escaping @MainActor (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if let request = parse() {
                Task { @MainActor in
                    let response = await self.handler(request)
                    self.connection.send(content: response.data, completion: .contentProcessed { _ in self.receive() })
                }
                return
            }
            if buffer.count > Self.maxBody + 65_536 {
                connection.send(content: HTTPResponse.status(413).data, completion: .contentProcessed { _ in self.connection.cancel() })
                return
            }
            if complete || error != nil { connection.cancel(); return }
            receive()
        }
    }

    /// Removes one complete request from the buffer, if there is one.
    private func parse() -> HTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { buffer.removeAll(); return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = min(Int(headers["content-length"] ?? "0") ?? 0, Self.maxBody)
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }
}
