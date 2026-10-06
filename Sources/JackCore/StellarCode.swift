import Foundation

// Stellar Code: Jack's own coding agent. It runs the agent loop in-process against models served on this Mac
// or the local network (Ollama, MLX, LM Studio…) and never sends anything to a cloud model.

// MARK: - Servers and models

public struct StellarServer: Identifiable, Codable, Equatable, Hashable {
    public enum API: String, Codable { case ollama, openai }
    /// Prefix of the model ids it serves, e.g. `ollama/gemma4:e2b`.
    public var id: String
    public var title: String
    public var baseURL: String
    public var api: API
    public init(id: String, title: String, baseURL: String, api: API) { self.id = id; self.title = title; self.baseURL = baseURL; self.api = api }

    public static let builtIn: [StellarServer] = [
        .init(id: "ollama", title: "Ollama", baseURL: "http://127.0.0.1:11434", api: .ollama),
        .init(id: "mlx", title: "MLX", baseURL: "http://127.0.0.1:8080", api: .openai),
        .init(id: "lmstudio", title: "LM Studio", baseURL: "http://127.0.0.1:1234", api: .openai),
    ]
    public static let customServerURLKey = "stellar.customServerURL"
    public static let contextLengthKey = "stellar.contextLength"
    public static let defaultContextLength = 16_384

    /// The built-in servers plus the one configured in Settings, all checked to be local.
    public static var all: [StellarServer] {
        var servers = builtIn
        if let raw = UserDefaults.standard.string(forKey: customServerURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let url = URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw), isLocal(url) {
            servers.append(.init(id: "local", title: url.host ?? "Servidor local", baseURL: url.absoluteString, api: .openai))
        }
        return servers
    }

    /// Loopback, `.local` names and private network addresses only: Stellar Code works exclusively with local models.
    public static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) || host.hasSuffix(".local") || host.hasPrefix("127.") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
}

public struct StellarModel: Identifiable, Equatable {
    /// `server/model`, the value stored as the conversation's model.
    public var id: String
    public var name: String
    public var server: StellarServer
    /// Whether the model can call tools; without them Stellar Code can only talk.
    public var tools: Bool
    public var contextLength: Int?
    public var title: String { "\(name) · \(server.title)" + (tools ? "" : " (sin herramientas)") }
}

public enum StellarModels {
    /// Every model the reachable local servers offer, Ollama first. Cloud models Ollama proxies are left out.
    public static func discover() async -> [StellarModel] {
        await StellarRuntime.ensureOllama(wait: false)
        return await withTaskGroup(of: [StellarModel].self) { group in
            for server in StellarServer.all { group.addTask { (try? await models(on: server)) ?? [] } }
            var all: [StellarModel] = []
            for await list in group { all += list }
            let order = StellarServer.all.map(\.id)
            return all.sorted { (order.firstIndex(of: $0.server.id) ?? 99, $0.name) < (order.firstIndex(of: $1.server.id) ?? 99, $1.name) }
        }
    }

    public static func resolve(_ modelID: String) -> (server: StellarServer, name: String)? {
        guard let slash = modelID.firstIndex(of: "/") else { return nil }
        let prefix = String(modelID[..<slash])
        guard let server = StellarServer.all.first(where: { $0.id == prefix }) else { return nil }
        let name = String(modelID[modelID.index(after: slash)...])
        return name.isEmpty ? nil : (server, name)
    }

    static func models(on server: StellarServer) async throws -> [StellarModel] {
        switch server.api {
        case .ollama:
            let tags = try await StellarHTTP.json(server, path: "/api/tags", timeout: 3)
            let entries = (tags["models"] as? [[String: Any]] ?? []).filter { entry in
                let name = entry["name"] as? String ?? ""
                return entry["remote_host"] == nil && entry["remote_model"] == nil && !name.hasSuffix(":cloud") && !name.hasSuffix("-cloud")
            }
            var result: [StellarModel] = []
            for entry in entries {
                guard let name = entry["name"] as? String ?? entry["model"] as? String else { continue }
                let show = try? await StellarHTTP.json(server, path: "/api/show", body: ["model": name], timeout: 5)
                let capabilities = show?["capabilities"] as? [String] ?? []
                if capabilities.contains("embedding") && !capabilities.contains("completion") { continue }
                let info = show?["model_info"] as? [String: Any] ?? [:]
                let context = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
                result.append(StellarModel(id: "\(server.id)/\(name)", name: name, server: server, tools: capabilities.contains("tools"), contextLength: context))
            }
            return result
        case .openai:
            let list = try await StellarHTTP.json(server, path: "/v1/models", timeout: 3)
            return (list["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .filter { !$0.lowercased().contains("embed") }
                .map { StellarModel(id: "\(server.id)/\($0)", name: $0, server: server, tools: true, contextLength: nil) }
        }
    }
}

/// Starts Ollama when it is installed but not running, and stops it with Jack if Jack started it.
@MainActor public enum StellarRuntime {
    private static var ollama: Process?

    public static func ensureOllama(wait: Bool) async {
        guard let server = StellarServer.builtIn.first(where: { $0.api == .ollama }) else { return }
        if await StellarHTTP.reachable(server) { return }
        if ollama?.isRunning != true {
            guard let executable = ExecutableResolver.resolve("ollama", override: nil) else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["serve"]
            process.environment = ExecutableResolver.childEnvironment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            ollama = process
        }
        guard wait else { return }
        for _ in 0..<40 {
            if await StellarHTTP.reachable(server) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    public static func shutdown() {
        if ollama?.isRunning == true { ollama?.terminate() }
        ollama = nil
    }
}

enum StellarHTTP {
    static func request(_ server: StellarServer, path: String, body: [String: Any]? = nil, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: server.baseURL + path), StellarServer.isLocal(url) else {
            throw StellarError.message("Stellar Code solo se conecta a servidores locales.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    static func json(_ server: StellarServer, path: String, body: [String: Any]? = nil, timeout: TimeInterval) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request(server, path: path, body: body, timeout: timeout))
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StellarError.message("\(server.title) respondió con un error.")
        }
        return object
    }

    static func reachable(_ server: StellarServer) async -> Bool {
        guard let request = try? request(server, path: server.api == .ollama ? "/api/version" : "/v1/models", timeout: 1.5) else { return false }
        return ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
    }
}

enum StellarError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// MARK: - Transcript

/// The model's view of the conversation, kept apart from what Jack shows, in a neutral format for both APIs.
struct StellarMessage: Codable, Equatable {
    var role: String
    var content: String
    var toolCalls: [StellarToolCall]? = nil
    var toolCallID: String? = nil
    var toolName: String? = nil
}

struct StellarToolCall: Codable, Equatable {
    var id: String
    var name: String
    /// JSON object, as text.
    var arguments: String
    var input: [String: Any] { (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:] }
}

enum StellarSessions {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jack/Stellar", isDirectory: true)
    }
    static func load(_ id: String) -> [StellarMessage] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")) else { return [] }
        return (try? JSONDecoder().decode([StellarMessage].self, from: data)) ?? []
    }
    static func save(_ messages: [StellarMessage], id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
    }
}

// MARK: - Model client

enum StellarChunk {
    case text(String)
    case reasoning(String)
    case toolCalls([StellarToolCall])
    case usage(prompt: Int, output: Int)
}

enum StellarClient {
    static func stream(server: StellarServer, model: String, messages: [StellarMessage], tools: [[String: Any]]?, contextLength: Int) throws -> AsyncThrowingStream<StellarChunk, Error> {
        let body: [String: Any]
        let path: String
        switch server.api {
        case .ollama:
            path = "/api/chat"
            var value: [String: Any] = ["model": model, "stream": true, "messages": messages.map(ollamaMessage), "options": ["num_ctx": contextLength]]
            if let tools { value["tools"] = tools }
            body = value
        case .openai:
            path = "/v1/chat/completions"
            var value: [String: Any] = ["model": model, "stream": true, "messages": messages.map(openAIMessage), "stream_options": ["include_usage": true]]
            if let tools { value["tools"] = tools }
            body = value
        }
        let request = try StellarHTTP.request(server, path: path, body: body, timeout: 600)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
                        throw StellarError.message(errorText(text) ?? "\(server.title) respondió \(http.statusCode).")
                    }
                    var calls: [Int: (id: String, name: String, arguments: String)] = [:]
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch server.api {
                        case .ollama:
                            guard let object = parse(line) else { continue }
                            if let error = object["error"] as? String { throw StellarError.message(error) }
                            let message = object["message"] as? [String: Any] ?? [:]
                            if let thinking = message["thinking"] as? String, !thinking.isEmpty { continuation.yield(.reasoning(thinking)) }
                            if let content = message["content"] as? String, !content.isEmpty { continuation.yield(.text(content)) }
                            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                                continuation.yield(.toolCalls(toolCalls.compactMap { call in
                                    guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
                                    let arguments = function["arguments"].map { boundedJSON($0) } ?? "{}"
                                    return StellarToolCall(id: call["id"] as? String ?? "call_" + UUID().uuidString.prefix(8), name: name, arguments: arguments)
                                }))
                            }
                            if object["done"] as? Bool == true {
                                continuation.yield(.usage(prompt: object["prompt_eval_count"] as? Int ?? 0, output: object["eval_count"] as? Int ?? 0))
                            }
                        case .openai:
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let object = parse(payload) else { continue }
                            if let error = object["error"] { throw StellarError.message(errorText(boundedJSON(error)) ?? "El servidor local devolvió un error.") }
                            if let usage = object["usage"] as? [String: Any] {
                                continuation.yield(.usage(prompt: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0))
                            }
                            guard let delta = (object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
                            if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty { continuation.yield(.reasoning(reasoning)) }
                            if let content = delta["content"] as? String, !content.isEmpty { continuation.yield(.text(content)) }
                            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                let index = call["index"] as? Int ?? 0
                                var current = calls[index] ?? ("", "", "")
                                if let id = call["id"] as? String, !id.isEmpty { current.id = id }
                                let function = call["function"] as? [String: Any] ?? [:]
                                if let name = function["name"] as? String { current.name += name }
                                if let arguments = function["arguments"] as? String { current.arguments += arguments }
                                calls[index] = current
                            }
                        }
                    }
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls.sorted { $0.key < $1.key }.map { _, call in
                            StellarToolCall(id: call.id.isEmpty ? "call_" + UUID().uuidString.prefix(8) : call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments)
                        }))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parse(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }
    private static func errorText(_ text: String) -> String? {
        guard let object = parse(text) else { return text.isEmpty ? nil : String(text.prefix(500)) }
        if let message = object["error"] as? String { return message }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["message"] as? String
    }

    static func ollamaMessage(_ message: StellarMessage) -> [String: Any] {
        var value: [String: Any] = ["role": message.role, "content": message.content]
        if let calls = message.toolCalls, !calls.isEmpty {
            value["tool_calls"] = calls.map { ["function": ["name": $0.name, "arguments": $0.input]] }
        }
        if let name = message.toolName { value["tool_name"] = name }
        return value
    }

    static func openAIMessage(_ message: StellarMessage) -> [String: Any] {
        var value: [String: Any] = ["role": message.role, "content": message.content]
        if let calls = message.toolCalls, !calls.isEmpty {
            value["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        }
        if let id = message.toolCallID { value["tool_call_id"] = id }
        return value
    }
}

// MARK: - Tools

enum StellarTools {
    enum Access { case read, edit, command }

    struct Spec {
        let name: String
        /// How Jack's transcript labels it, matching the other agents' tools.
        let title: String
        let access: Access
        let description: String
        let parameters: [String: Any]
    }

    static let specs: [Spec] = [
        Spec(name: "list_files", title: "List", access: .read,
             description: "List files and folders under a directory of the project (recursive, skips build and dependency folders).",
             parameters: object(["path": string("Directory, relative to the project root. Defaults to the root.")], required: [])),
        Spec(name: "read_file", title: "Read", access: .read,
             description: "Read a text file. Returns numbered lines. Use offset and limit for long files.",
             parameters: object(["path": string("File path, relative to the project root."),
                                 "offset": ["type": "integer", "description": "First line to read, starting at 1."],
                                 "limit": ["type": "integer", "description": "Maximum number of lines (default 400)."]], required: ["path"])),
        Spec(name: "search", title: "Grep", access: .read,
             description: "Search file contents with a regular expression. Returns matching lines as path:line:text.",
             parameters: object(["pattern": string("Regular expression to search for."), "path": string("Directory or file to search in, relative to the project root.")], required: ["pattern"])),
        Spec(name: "write_file", title: "Write", access: .edit,
             description: "Create a file or replace its whole content.",
             parameters: object(["path": string("File path, relative to the project root."), "content": string("The complete new content.")], required: ["path", "content"])),
        Spec(name: "edit_file", title: "Edit", access: .edit,
             description: "Replace one exact, unique occurrence of old_string with new_string in a file. Read the file first.",
             parameters: object(["path": string("File path, relative to the project root."), "old_string": string("Exact text to replace, unique in the file."),
                                 "new_string": string("Replacement text.")], required: ["path", "old_string", "new_string"])),
        Spec(name: "run_command", title: "Bash", access: .command,
             description: "Run a shell command (zsh) in the project root and return its output. Times out after 2 minutes.",
             parameters: object(["command": string("The command to run.")], required: ["command"])),
    ]

    static var definitions: [[String: Any]] {
        specs.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    /// The input as Jack's tool rows read it: `file_path` for files, as the other agents name it.
    static func displayInput(_ call: StellarToolCall, root: String) -> [String: Any] {
        var input = call.input
        if let path = input["path"] as? String, call.name != "search", call.name != "list_files" {
            input.removeValue(forKey: "path"); input["file_path"] = resolve(path, root: root)
        }
        return input
    }

    static func resolve(_ path: String, root: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (root as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    static func inside(_ path: String, roots: [String]) -> Bool {
        roots.contains { root in
            let base = (root as NSString).standardizingPath
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv", "venv", "__pycache__", "dist", ".next", "Pods"]

    /// Runs a tool; returns its output and whether it failed. `process` receives a running command so it can be stopped.
    static func execute(_ call: StellarToolCall, root: String, process: @escaping (Process) -> Void) async -> (String, Bool) {
        let input = call.input
        func path(_ key: String = "path") -> String? { (input[key] as? String).map { resolve($0, root: root) } }
        do {
            switch call.name {
            case "list_files":
                let base = path() ?? root
                return (try list(base, root: root), false)
            case "read_file":
                guard let file = path() else { return ("Falta el parámetro path.", true) }
                let text = try String(contentsOfFile: file, encoding: .utf8)
                let lines = text.components(separatedBy: "\n")
                let start = max(1, (input["offset"] as? Int) ?? 1)
                let limit = max(1, min(2000, (input["limit"] as? Int) ?? 400))
                guard start <= lines.count else { return ("El archivo tiene \(lines.count) líneas.", false) }
                let end = min(lines.count, start + limit - 1)
                var output = (start...end).map { "\($0)\t\(lines[$0 - 1].prefix(2000))" }.joined(separator: "\n")
                if end < lines.count { output += "\n… (\(lines.count - end) more lines; use offset \(end + 1))" }
                return (output, false)
            case "search":
                guard let pattern = input["pattern"] as? String, !pattern.isEmpty else { return ("Falta el parámetro pattern.", true) }
                let target = path() ?? root
                let rg = ExecutableResolver.resolve("rg", override: nil)
                let arguments = rg != nil
                    ? ["--line-number", "--no-heading", "--color", "never", "--max-count", "50", "-e", pattern, target]
                    : ["-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build", "--exclude-dir=build", "-E", pattern, target]
                let (output, status) = try await run(rg ?? "/usr/bin/grep", arguments, root: root, timeout: 30, process: process)
                if status == 1 && output.isEmpty { return ("Sin coincidencias.", false) }
                return (relative(String(output.prefix(20_000)), root: root), status > 1)
            case "write_file":
                guard let file = path(), let content = input["content"] as? String else { return ("Faltan path o content.", true) }
                try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let existed = FileManager.default.fileExists(atPath: file)
                try content.write(toFile: file, atomically: true, encoding: .utf8)
                return ("\(existed ? "Reemplazado" : "Creado"): \(file) (\(content.components(separatedBy: "\n").count) líneas)", false)
            case "edit_file":
                guard let file = path(), let old = input["old_string"] as? String, let new = input["new_string"] as? String, !old.isEmpty else {
                    return ("Faltan path, old_string o new_string.", true)
                }
                let text = try String(contentsOfFile: file, encoding: .utf8)
                let count = text.components(separatedBy: old).count - 1
                guard count == 1 else { return (count == 0 ? "old_string no aparece en el archivo. Léelo de nuevo y copia el texto exacto." : "old_string aparece \(count) veces; incluye más contexto para que sea única.", true) }
                try text.replacingOccurrences(of: old, with: new).write(toFile: file, atomically: true, encoding: .utf8)
                return ("Editado: \(file)", false)
            case "run_command":
                guard let command = input["command"] as? String, !command.isEmpty else { return ("Falta el parámetro command.", true) }
                let (output, status) = try await run("/bin/zsh", ["-lc", command], root: root, timeout: 120, process: process)
                let trimmed = output.count > 30_000 ? String(output.prefix(15_000)) + "\n… (salida recortada) …\n" + String(output.suffix(15_000)) : output
                return (trimmed + (status == 0 ? "" : "\n[exit \(status)]"), status != 0)
            default:
                return ("Herramienta desconocida: \(call.name). Usa: \(specs.map(\.name).joined(separator: ", ")).", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private static func list(_ base: String, root: String) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw StellarError.message("No existe la carpeta \(base).")
        }
        var lines: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory && skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            lines.append(relative(url.path, root: root) + (isDirectory ? "/" : ""))
            if lines.count >= 400 { lines.append("… (más de 400 entradas; lista una subcarpeta)"); break }
        }
        return lines.isEmpty ? "(vacía)" : lines.joined(separator: "\n")
    }

    /// Paths relative to the project, also when they come back through a symlink such as /var → /private/var.
    private static func relative(_ text: String, root: String) -> String {
        // Foundation's own resolver drops /private instead of adding it.
        let real = realpath(root, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? root
        return [real, root].sorted { $0.count > $1.count }.reduce(text) { text, base in text.replacingOccurrences(of: base.hasSuffix("/") ? base : base + "/", with: "") }
    }

    private static func run(_ executable: String, _ arguments: [String], root: String, timeout: Double, process register: @escaping (Process) -> Void) async throws -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.environment = ExecutableResolver.childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        register(process)
        let reader = Task.detached { () -> Data in
            var data = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if data.count < 2_000_000 { data.append(chunk) }
            }
            return data
        }
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled, process.isRunning { process.terminate() } }
        let data = await reader.value
        timer.cancel()
        await Task.detached { process.waitUntilExit() }.value
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

// MARK: - Agent

enum StellarPrompt {
    static func system(_ conversation: ChatConversation, tools: Bool) -> String {
        let extra = conversation.additionalDirectories
        return """
        You are Stellar Code, the coding agent built into Jack, a macOS app for coding agents. You run on a local model on the user's Mac.
        Working directory (project root): \(conversation.projectPath)\(extra.isEmpty ? "" : "\nAlso allowed: " + extra.joined(separator: ", "))
        Date: \(Date().formatted(date: .complete, time: .omitted)). Platform: macOS.
        \(tools ? """
        You can inspect and change the project with tools. Work step by step:
        - Explore with list_files, search and read_file before changing anything; never guess file contents.
        - Change files with edit_file (exact, unique old_string) or write_file for new files.
        - Use run_command to build, test or inspect; prefer short, non-interactive commands.
        - Call tools directly instead of describing what you would do. When the task is done, stop calling tools and reply.
        """ : "You cannot use tools with this model: answer from the conversation and ask the user for any file you need.")
        Reply in the user's language, briefly and concretely. Use Markdown for code.
        """
    }
}

@MainActor
final class StellarChatDriver: ChatDriver {
    private var turn: Task<Void, Error>?
    private var mode = "manual"
    private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var commands: [Process] = []
    static let maxSteps = 40

    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        mode = conversation.mode ?? "manual"
        let task = Task { try await loop(conversation, prompt: prompt, onEvent: onEvent) }
        turn = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func loop(_ conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        guard let (server, model) = StellarModels.resolve(conversation.model) else {
            throw StellarError.message(conversation.model.isEmpty ? "Elige un modelo local para Stellar Code." : "«\(conversation.model)» no es un modelo local de Stellar Code.")
        }
        if server.api == .ollama { await StellarRuntime.ensureOllama(wait: true) }
        guard await StellarHTTP.reachable(server) else {
            throw StellarError.message("\(server.title) no responde en \(server.baseURL). Inícialo para usar \(model).")
        }
        let info = (try? await StellarModels.models(on: server))?.first { $0.name == model }
        guard server.api != .ollama || info != nil else { throw StellarError.message("Ollama no tiene el modelo \(model). Descárgalo con «ollama pull \(model)».") }
        let useTools = info?.tools ?? true
        let contextLength = min(info?.contextLength ?? Int.max, (UserDefaults.standard.object(forKey: StellarServer.contextLengthKey) as? Int) ?? StellarServer.defaultContextLength)

        let sessionID = conversation.sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        if conversation.sessionID != sessionID { onEvent(.session(sessionID)) }
        var history = StellarSessions.load(sessionID)
        history.removeAll { $0.role == "system" }
        let system = StellarMessage(role: "system", content: StellarPrompt.system(conversation, tools: useTools))
        history.append(StellarMessage(role: "user", content: ChatAttachments.promptText(prompt, attachments: conversation.turnAttachments)))
        StellarSessions.save(history, id: sessionID)

        var tokens = conversation.tokenUsage ?? ChatTokenUsage()
        let roots = [conversation.projectPath] + conversation.additionalDirectories + conversation.attachmentDirectories
        for step in 0..<Self.maxSteps {
            try Task.checkCancellation()
            let textID = "stellar-\(UUID().uuidString)"
            let reasoningID = textID + ":reasoning"
            var text = "", calls: [StellarToolCall] = []
            for try await chunk in try StellarClient.stream(server: server, model: model, messages: [system] + history, tools: useTools ? StellarTools.definitions : nil, contextLength: contextLength) {
                switch chunk {
                case .text(let delta): text += delta; onEvent(.text(id: textID, text: delta, replace: false))
                case .reasoning(let delta): onEvent(.reasoning(id: reasoningID, text: delta, replace: false))
                case .toolCalls(let list): calls += list
                case let .usage(prompt, output):
                    tokens.input += prompt; tokens.output += output
                    onEvent(.tokens(tokens))
                    onEvent(.context(used: prompt + output, window: contextLength))
                }
            }
            try Task.checkCancellation()
            history.append(StellarMessage(role: "assistant", content: text, toolCalls: calls.isEmpty ? nil : calls))
            StellarSessions.save(history, id: sessionID)
            if calls.isEmpty { break }
            for call in calls {
                try Task.checkCancellation()
                let output = await perform(call, conversation: conversation, roots: roots, onEvent: onEvent)
                history.append(StellarMessage(role: "tool", content: output, toolCallID: call.id, toolName: call.name))
                StellarSessions.save(history, id: sessionID)
            }
            if step == Self.maxSteps - 1 {
                onEvent(.text(id: "stellar-limit-\(UUID().uuidString)", text: "Me detuve tras \(Self.maxSteps) pasos. Escribe «continúa» para seguir.", replace: true))
            }
        }
        onEvent(.completed)
    }

    private func perform(_ call: StellarToolCall, conversation: ChatConversation, roots: [String], onEvent: @escaping @MainActor (ChatEvent) -> Void) async -> String {
        let spec = StellarTools.specs.first { $0.name == call.name }
        let toolID = "stellar-tool-\(UUID().uuidString)"
        let title = spec?.title ?? call.name
        let input = boundedJSON(StellarTools.displayInput(call, root: conversation.projectPath))
        onEvent(.tool(id: toolID, title: title, detail: input, status: "running"))
        if let spec, needsApproval(spec, call: call, root: conversation.projectPath, roots: roots) {
            let approvalID = "stellar-\(UUID().uuidString)"
            var approval = ChatApproval(id: approvalID, title: Self.approvalTitle(spec), detail: input)
            approval.tool = title
            onEvent(.approval(approval))
            let allowed = await withCheckedContinuation { approvals[approvalID] = $0 }
            onEvent(.approvalResolved(approvalID))
            guard allowed else {
                onEvent(.tool(id: toolID, title: title, detail: input + "\nRechazado por el usuario.", status: "failed"))
                return "The user rejected this action. Do not retry it; ask what to do instead or try another approach."
            }
        }
        let (output, failed) = await StellarTools.execute(call, root: conversation.projectPath) { [weak self] process in
            Task { @MainActor in self?.commands.append(process) }
        }
        commands.removeAll { !$0.isRunning }
        onEvent(.tool(id: toolID, title: title, detail: input + "\n" + output, status: failed ? "failed" : "completed"))
        return String(output.prefix(24_000))
    }

    private func needsApproval(_ spec: StellarTools.Spec, call: StellarToolCall, root: String, roots: [String]) -> Bool {
        let target = (call.input["path"] as? String).map { StellarTools.resolve($0, root: root) }
        let outside = target.map { !StellarTools.inside($0, roots: roots) } ?? false
        switch spec.access {
        case .read: return outside && mode != "auto"
        case .edit: return outside || !(mode == "acceptEdits" || mode == "auto")
        case .command: return mode != "auto"
        }
    }

    static func approvalTitle(_ spec: StellarTools.Spec) -> String {
        switch spec.access {
        case .read: return "Stellar Code quiere leer fuera del proyecto"
        case .edit: return "Stellar Code quiere modificar un archivo"
        case .command: return "Stellar Code quiere ejecutar un comando"
        }
    }

    func respond(approvalID: String, allow: Bool) async throws {
        guard let continuation = approvals.removeValue(forKey: approvalID) else { throw StellarError.message("Ese permiso ya no está pendiente.") }
        continuation.resume(returning: allow)
    }

    func stop() {
        turn?.cancel(); turn = nil
        for continuation in approvals.values { continuation.resume(returning: false) }
        approvals.removeAll()
        for process in commands where process.isRunning { process.terminate() }
        commands.removeAll()
    }

    func setMode(_ mode: String) -> Bool { self.mode = mode; return true }
}

// MARK: - Side questions

enum StellarAside {
    /// Answers from the saved transcript, without tools, and keeps nothing.
    @MainActor
    static func ask(_ question: String, prompt: String, about conversation: ChatConversation, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let (server, model) = StellarModels.resolve(conversation.model) else { throw StellarError.message("Elige un modelo local para Stellar Code.") }
        if server.api == .ollama { await StellarRuntime.ensureOllama(wait: true) }
        let history = conversation.sessionID.map(StellarSessions.load) ?? []
        // Tool messages need the calls that produced them; plain text keeps any model happy.
        let context = history.compactMap { message -> StellarMessage? in
            switch message.role {
            case "user": return StellarMessage(role: "user", content: message.content)
            case "assistant": return message.content.isEmpty ? nil : StellarMessage(role: "assistant", content: message.content)
            case "tool": return StellarMessage(role: "user", content: "[Resultado de \(message.toolName ?? "herramienta")]\n" + String(message.content.prefix(4000)))
            default: return nil
            }
        }
        let system = StellarMessage(role: "system", content: StellarPrompt.system(conversation, tools: false))
        var answer = ""
        let contextLength = (UserDefaults.standard.object(forKey: StellarServer.contextLengthKey) as? Int) ?? StellarServer.defaultContextLength
        for try await chunk in try StellarClient.stream(server: server, model: model, messages: [system] + context + [StellarMessage(role: "user", content: prompt)], tools: nil, contextLength: contextLength) {
            if case .text(let delta) = chunk { answer += delta; partial(answer) }
        }
        return answer
    }
}
