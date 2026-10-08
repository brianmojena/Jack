import Foundation

// Stellar Code runs in-process against models on this Mac or local network. Normal may also use Ollama Cloud
// through the authenticated local Ollama daemon; Light remains local-only.

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
    public var isCloud: Bool
    public init(id: String, name: String, server: StellarServer, tools: Bool, contextLength: Int? = nil, isCloud: Bool = false) {
        self.id = id; self.name = name; self.server = server; self.tools = tools; self.contextLength = contextLength; self.isCloud = isCloud
    }
    public var title: String { "\(name) · \(server.title)\(isCloud ? " · Nube" : "")" + (tools ? "" : " (sin herramientas)") }
}

public enum StellarModels {
    /// Lists models from reachable local servers, Ollama first. Cloud proxies are included only in Normal.
    public static func discover(includeCloud: Bool = false) async -> [StellarModel] {
        await StellarRuntime.ensureOllama(wait: false)
        return await withTaskGroup(of: [StellarModel].self) { group in
            for server in StellarServer.all { group.addTask { (try? await models(on: server, includeCloud: includeCloud)) ?? [] } }
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

    static func models(on server: StellarServer, includeCloud: Bool = false) async throws -> [StellarModel] {
        switch server.api {
        case .ollama:
            let tags = try await StellarHTTP.json(server, path: "/api/tags", timeout: 3)
            var result: [StellarModel] = []
            for entry in tags["models"] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String ?? entry["model"] as? String else { continue }
                let taggedCloud = isCloud(name: name, metadata: entry)
                // Keep Light's historical filter before calling /api/show for remote entries.
                if !shouldInspectOllamaTag(name: name, metadata: entry, includeCloud: includeCloud) { continue }
                let show = try? await StellarHTTP.json(server, path: "/api/show", body: ["model": name], timeout: 5)
                let cloud = taggedCloud || isCloud(name: name, metadata: show ?? [:])
                if cloud && !includeCloud { continue }
                let capabilities = show?["capabilities"] as? [String] ?? []
                if capabilities.contains("embedding") && !capabilities.contains("completion") { continue }
                let info = show?["model_info"] as? [String: Any] ?? [:]
                let context = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
                // Cloud entries need /api/show to verify capabilities. Keep the historical local entry behavior.
                if cloud && show == nil { continue }
                result.append(StellarModel(id: "\(server.id)/\(name)", name: name, server: server, tools: capabilities.contains("tools"), contextLength: context, isCloud: cloud))
            }
            return result
        case .openai:
            let list = try await StellarHTTP.json(server, path: "/v1/models", timeout: 3)
            return (list["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .filter { !$0.lowercased().contains("embed") }
                .map { StellarModel(id: "\(server.id)/\($0)", name: $0, server: server, tools: true, contextLength: nil) }
        }
    }

    static func isCloud(name: String, metadata: [String: Any]) -> Bool {
        let normalized = name.lowercased()
        if normalized.hasSuffix(":cloud") || normalized.hasSuffix("-cloud") { return true }
        if metadata["remote_host"] != nil || metadata["remote_model"] != nil { return true }
        let modelInfo = metadata["model_info"] as? [String: Any] ?? [:]
        let details = metadata["details"] as? [String: Any] ?? [:]
        return modelInfo["remote_host"] != nil || modelInfo["remote_model"] != nil
            || details["remote_host"] != nil || details["remote_model"] != nil
            || metadata["cloud"] as? Bool == true
    }

    static func shouldInspectOllamaTag(name: String, metadata: [String: Any], includeCloud: Bool) -> Bool {
        includeCloud || !isCloud(name: name, metadata: metadata)
    }

    static func requireCloudAllowed(name: String, metadata: [String: Any] = [:], includeCloud: Bool) throws {
        if isCloud(name: name, metadata: metadata), !includeCloud { throw cloudUnavailableError }
    }

    static func ollamaModel(named rawName: String, show: [String: Any], requireCloud: Bool = false) throws -> StellarModel {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateOllamaName(name)
        guard !show.isEmpty else { throw StellarError.message("Ollama no devolvió metadatos para ese modelo. Comprueba el nombre y el estado de Cloud.") }
        let server = StellarServer.builtIn[0]
        let cloud = isCloud(name: name, metadata: show)
        guard !requireCloud || cloud else { throw StellarError.message("Ollama reconoció el modelo, pero no lo identificó como modelo de nube.") }
        let capabilities = show["capabilities"] as? [String] ?? []
        if capabilities.contains("embedding") && !capabilities.contains("completion") {
            throw StellarError.message("Ese modelo de Ollama solo ofrece embeddings y no puede responder en Stellar Code.")
        }
        let info = show["model_info"] as? [String: Any] ?? [:]
        let context = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        return StellarModel(id: "ollama/\(name)", name: name, server: server, tools: capabilities.contains("tools"), contextLength: context, isCloud: cloud)
    }

    static func linkedCloudModel(named rawName: String, show: [String: Any]) throws -> StellarModel {
        try ollamaModel(named: rawName, show: show, requireCloud: true)
    }

    static func validateOllamaName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-/")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("//") else {
            throw StellarError.message("Escribe un nombre de modelo de Ollama válido, por ejemplo namespace/gemma4:cloud.")
        }
    }

    /// Inspect only the selected model. If `/api/show` is unavailable, preserve the old local-tag fallback,
    /// but never enable tools or accept an unverified cloud model from that fallback.
    static func selectedOllamaModel(named name: String, includeCloud: Bool) async throws -> StellarModel {
        let server = StellarServer.builtIn[0]
        try validateOllamaName(name)
        try requireCloudAllowed(name: name, includeCloud: includeCloud)
        if let show = try? await StellarHTTP.json(server, path: "/api/show", body: ["model": name], timeout: 5), !show.isEmpty {
            let model = try ollamaModel(named: name, show: show)
            try requireCloudAllowed(name: name, metadata: show, includeCloud: includeCloud)
            return model
        }
        let tags = try await StellarHTTP.json(server, path: "/api/tags", timeout: 3)
        guard let entry = (tags["models"] as? [[String: Any]] ?? []).first(where: { ($0["name"] as? String ?? $0["model"] as? String) == name }) else {
            throw StellarError.message("Ollama no tiene el modelo \(name). Vincúlalo desde Ollama y vuelve a elegirlo.")
        }
        let cloud = isCloud(name: name, metadata: entry)
        try requireCloudAllowed(name: name, metadata: entry, includeCloud: includeCloud)
        guard !cloud else { throw StellarError.message("Ollama no pudo verificar las capacidades de ese modelo de nube. Comprueba tu sesión y el estado de Cloud.") }
        return StellarModel(id: "ollama/\(name)", name: name, server: server, tools: true, contextLength: nil)
    }

    static func inspectOllamaModel(named name: String, includeCloud: Bool) async throws -> StellarModel {
        let server = StellarServer.builtIn[0]
        try requireCloudAllowed(name: name, includeCloud: includeCloud)
        let show = try await StellarHTTP.json(server, path: "/api/show", body: ["model": name], timeout: 8)
        let model = try ollamaModel(named: name, show: show)
        try requireCloudAllowed(name: model.name, metadata: show, includeCloud: includeCloud)
        return model
    }

    static var cloudUnavailableError: StellarError {
        .message("Los modelos de Ollama Cloud solo están disponibles en modo Normal. En Light, elige un modelo local.")
    }

    public static func preferredLocalID(in models: [StellarModel]) -> String {
        (models.first { !$0.isCloud && $0.tools } ?? models.first { !$0.isCloud })?.id ?? ""
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let detail = payload["error"] as? String ?? ""
        if status == 200, detail.isEmpty { return payload }
        if status == 200, !detail.isEmpty { throw safeModelError(status: 400, detail: detail, serverTitle: server.title) }
        throw safeModelError(status: status, detail: detail, serverTitle: server.title)
    }

    static func safeModelError(status: Int, detail rawDetail: String, serverTitle: String = "Ollama") -> StellarError {
        let detail = rawDetail.lowercased()
        guard serverTitle == "Ollama" else { return .message("\(serverTitle) respondió un error HTTP \(status). Comprueba que el servidor local esté disponible y que el modelo sea válido.") }
        if detail.contains("cloud") && (detail.contains("disabled") || detail.contains("not enabled") || detail.contains("unavailable"))
            || detail.contains("remote models are disabled") {
            return .message("Ollama Cloud está deshabilitado. Habilítalo desde Ollama y confirma que la cuenta inició sesión.")
        }
        if [401, 403].contains(status) || ["sign in", "signin", "unauthor", "authentication", "not signed in"].contains(where: detail.contains) {
            return .message("Ollama no autorizó el modelo de nube. Abre Ollama, inicia sesión con `ollama signin` y confirma que Cloud esté habilitado.")
        }
        if status == 404 || ["not found", "does not exist", "no such model"].contains(where: detail.contains) {
            return .message("Ollama no encontró ese modelo. Comprueba el nombre mostrado por Ollama y vuelve a vincularlo.")
        }
        return .message("\(serverTitle) respondió un error HTTP \(status). Comprueba que Ollama esté disponible y que el modelo sea válido.")
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

enum StellarInstructions {
    static let rootLimit = 12 * 1024
    static let nestedLimit = 4 * 1024

    struct LoadResult {
        let block: String?
        let files: [String: String]
        let complete: Bool

        var protectedPrefix: String? {
            block.map { "Applicable nested AGENTS.md instructions:\n\($0)\n\nFile contents:\n" }
        }
    }

    static func needsDelivery(_ load: LoadResult, previouslyDelivered: [String: String]) -> Bool {
        !load.complete || load.files.contains { previouslyDelivered[$0.key] != $0.value }
    }

    static func root(projectPath: String) -> String? {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent("AGENTS.md")
        guard isInside(file.resolvingSymlinksInPath(), root: root) else { return nil }
        return boundedFile(file, limit: rootLimit)
    }

    static func rootIsUnavailable(projectPath: String) -> Bool {
        let file = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.appendingPathComponent("AGENTS.md")
        return FileManager.default.fileExists(atPath: file.path) && root(projectPath: projectPath) == nil
    }

    /// Reads every applicable nested file or reports exactly where the bounded load stopped.
    /// It only reads canonical paths inside the project root.
    static func loadApplicable(to filePath: String, projectPath: String,
                               read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> LoadResult {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let lexicalTarget = URL(fileURLWithPath: filePath).standardizedFileURL
        let target = lexicalTarget.resolvingSymlinksInPath()
        guard isInside(target, root: root) else {
            let redirectedProjectPath = isInside(lexicalTarget, root: URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL)
            return LoadResult(block: redirectedProjectPath ? "[La ruta resuelve mediante un enlace fuera de la raíz del proyecto. No leas ni modifiques este ámbito.]" : nil,
                              files: [:], complete: !redirectedProjectPath)
        }
        let directory = target.deletingLastPathComponent()
        let relative = String(directory.path.dropFirst(root.path.count)).split(separator: "/").map(String.init)
        var folders = [root]
        var current = root
        for component in relative { current.appendPathComponent(component, isDirectory: true); folders.append(current) }
        var bytesLeft = nestedLimit
        var chunks: [String] = []
        var files: [String: String] = [:]
        var complete = true
        for folder in folders.dropFirst() {
            let url = folder.appendingPathComponent("AGENTS.md")
            guard isInside(url.resolvingSymlinksInPath(), root: root) else {
                if FileManager.default.fileExists(atPath: url.path) {
                    chunks.append("--- \(url.path) ---\n[No se leyeron estas instrucciones: el enlace resuelve fuera de la raíz del proyecto.]")
                    complete = false
                    break
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= nestedLimit, let data = read(url), let text = String(data: data, encoding: .utf8) else {
                chunks.append("--- \(url.path) ---\n[No se cargaron estas instrucciones completas: el archivo excede 4 KiB o no se pudo leer como UTF-8. No operes en este ámbito.]")
                complete = false
                break
            }
            let chunk = "--- \(url.path) ---\n\(text)"
            guard chunk.utf8.count <= bytesLeft else {
                chunks.append("--- \(url.path) ---\n[No se cargaron estas instrucciones: el presupuesto anidado de 4 KiB se agotó antes de este archivo. No operes en este ámbito.]")
                complete = false
                break
            }
            bytesLeft -= chunk.utf8.count
            chunks.append(chunk)
            files[url.path] = text
        }
        return LoadResult(block: chunks.isEmpty ? nil : chunks.joined(separator: "\n\n"), files: files, complete: complete)
    }

    private static func isInside(_ file: URL, root: URL) -> Bool {
        file.path == root.path || file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func boundedFile(_ url: URL, limit: Int) -> String? {
        guard limit > 0, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize, size <= limit, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

// MARK: - Transcript

/// The model's view of the conversation, kept apart from what Jack shows, in a neutral format for both APIs.
struct StellarMessage: Codable, Equatable {
    var role: String
    var content: String
    var toolCalls: [StellarToolCall]? = nil
    var toolCallID: String? = nil
    var toolName: String? = nil
    /// An instruction prefix embedded in a tool result that must survive context reduction.
    var protectedPrefix: String? = nil
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
    static func requestPayload(server: StellarServer, model: String, messages: [StellarMessage], tools: [[String: Any]]?, contextLength: Int) -> (path: String, body: [String: Any]) {
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
        return (path, body)
    }

    static func stream(server: StellarServer, model: String, messages: [StellarMessage], tools: [[String: Any]]?, contextLength: Int) throws -> AsyncThrowingStream<StellarChunk, Error> {
        let payload = requestPayload(server: server, model: model, messages: messages, tools: tools, contextLength: contextLength)
        let request = try StellarHTTP.request(server, path: payload.path, body: payload.body, timeout: 600)
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
                            if let error = object["error"] as? String {
                                throw StellarHTTP.safeModelError(status: 400, detail: error, serverTitle: server.title)
                            }
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

    static var normalDefinitions: [[String: Any]] {
        specs.map { spec in
            var value = ["type": "function", "function": ["name": spec.name, "description": spec.description, "parameters": spec.parameters] as [String: Any]] as [String: Any]
            if spec.name == "list_files" {
                var function = value["function"] as! [String: Any]
                function["description"] = "List files and folders under a directory. Defaults to the immediate directory; set recursive=true to explore descendants (skips build and dependency folders)."
                var parameters = function["parameters"] as! [String: Any]
                var properties = parameters["properties"] as! [String: Any]
                properties["recursive"] = ["type": "boolean", "description": "Explicitly include descendants. Defaults to false."]
                parameters["properties"] = properties
                function["parameters"] = parameters
                value["function"] = function
            }
            return value
        }
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func boundedUTF8(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        return prefixUTF8(value, bytes: bytes) + "\n… (salida acotada por bytes)"
    }
    static func prefixUTF8(_ value: String, bytes: Int) -> String {
        var result = ""
        for character in value {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
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
    static func execute(_ call: StellarToolCall, root: String, normalMode: Bool = false,
                        onInstructions: ((StellarInstructions.LoadResult, String?) -> Void)? = nil,
                        process: @escaping (Process) -> Void) async -> (String, Bool) {
        let input = call.input
        func path(_ key: String = "path") -> String? { (input[key] as? String).map { resolve($0, root: root) } }
        do {
            switch call.name {
            case "list_files":
                let base = path() ?? root
                let result = normalMode
                    ? try listNormal(base, root: root, recursive: input["recursive"] as? Bool ?? false)
                    : try list(base, root: root)
                return (normalMode ? boundedUTF8(result, bytes: 8_000) : result, false)
            case "read_file":
                guard let file = path() else { return ("Falta el parámetro path.", true) }
                let text = try String(contentsOfFile: file, encoding: .utf8)
                let lines = text.components(separatedBy: "\n")
                let start = max(1, (input["offset"] as? Int) ?? 1)
                let limit = max(1, min(normalMode ? 400 : 2000, (input["limit"] as? Int) ?? (normalMode ? 120 : 400)))
                let instructionLoad = normalMode ? StellarInstructions.loadApplicable(to: file, projectPath: root) : nil
                let protectedPrefix = instructionLoad?.protectedPrefix
                let filePrefix = protectedPrefix ?? ""
                var output: String
                var nextOffset: Int
                if normalMode {
                    let markerReserve = 120
                    let pageBudget = max(0, 8_000 - filePrefix.utf8.count - markerReserve)
                    var rows: [String] = []
                    var used = 0
                    nextOffset = start
                    if start <= lines.count {
                        for number in start...lines.count where rows.count < limit {
                            let row = "\(number)\t\(lines[number - 1])"
                            let rowBytes = row.utf8.count + (rows.isEmpty ? 0 : 1)
                            if !rows.isEmpty && used + rowBytes > pageBudget { break }
                            rows.append(row); used += rowBytes; nextOffset = number + 1
                            if used > pageBudget { break } // A single long line is still returned whole.
                        }
                    }
                    output = rows.joined(separator: "\n")
                    if rows.isEmpty { output = "El archivo tiene \(lines.count) líneas."; nextOffset = start }
                    if nextOffset <= lines.count { output += "\n… (continúa con offset \(nextOffset))" }
                    output = filePrefix + output
                    if let instructionLoad { onInstructions?(instructionLoad, protectedPrefix) }
                } else {
                    guard start <= lines.count else { return ("El archivo tiene \(lines.count) líneas.", false) }
                    let end = min(lines.count, start + limit - 1)
                    output = (start...end).map { "\($0)\t\(lines[$0 - 1].prefix(2000))" }.joined(separator: "\n")
                    if end < lines.count { output += "\n… (\(lines.count - end) more lines; use offset \(end + 1))" }
                }
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
                let searchOutput = relative(String(output.prefix(normalMode ? 10_000 : 20_000)), root: root)
                return (normalMode ? boundedUTF8(searchOutput, bytes: 8_000) : searchOutput, status > 1)
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

    private static func listNormal(_ base: String, root: String, recursive: Bool) throws -> String {
        let folder = URL(fileURLWithPath: base, isDirectory: true)
        let values = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var lines: [String] = []
        let maximum = recursive ? 400 : 80
        func append(_ urls: [URL], depth: Int) throws -> Bool {
            for url in urls {
                if lines.count >= maximum { return true }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory && skipped.contains(url.lastPathComponent) { continue }
                lines.append(relative(url.path, root: root) + (isDirectory ? "/" : ""))
                if lines.count >= maximum { return true }
                if recursive, isDirectory, depth < 4,
                   try append(FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, depth: depth + 1) { return true }
            }
            return false
        }
        let clipped = try append(values, depth: 0)
        if lines.isEmpty { return "(vacía)" }
        return lines.joined(separator: "\n") + (clipped ? "\n… (listado acotado; especifica una subcarpeta o usa recursive=true)" : "")
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
    static func system(_ conversation: ChatConversation, tools: Bool, normalMode: Bool = false, instructions: String? = nil) -> String {
        let extra = conversation.additionalDirectories
        if !normalMode {
            return legacySystem(conversation, tools: tools, extra: extra)
        }
        return """
        You are Stellar Code, the coding agent built into Jack, a macOS app for coding agents. Normal mode may use a local model or an Ollama Cloud model through the user's authenticated local Ollama daemon.
        Working directory (project root): \(conversation.projectPath)\(extra.isEmpty ? "" : "\nAlso allowed: " + extra.joined(separator: ", "))
        Date: \(Date().formatted(date: .complete, time: .omitted)). Platform: macOS.
        \(tools ? """
        You can inspect and change the project with tools. Work step by step:
        - First understand the request: distinguish requested analysis/summary from a request to act. When asked to act, use tools and complete the requested work; do not stop at a plan or generic follow-up question.
        - For analysis or review, report findings, their consequences and useful improvements, each grounded in an observed file and line. Keep factual observations separate from inference. For a summary, give the requested scope and avoid broad repo exploration.
        - For summaries, inspect only relevant files. The initial list_files view is the immediate directory; use recursive=true only when needed.
        - Read root AGENTS.md instructions below before acting. If a present instructions file could not be loaded within the stated limit, explain the limit and do not modify files in its scope. When reading a file in a subdirectory, follow any nested AGENTS.md instructions returned before changing files there.
        - Nested AGENTS.md files are not discovered automatically for arbitrary run_command operations. Read the applicable instructions before a command that acts in a subdirectory; shell commands run in the project environment and this instruction loader is not a command sandbox.
        - Explore with list_files, search and read_file before changing anything; never guess file contents. Ground conclusions in observed file paths and line numbers where available.
        - Change files with edit_file (exact, unique old_string) or write_file for new files.
        - Use run_command to build, test or inspect; prefer short, non-interactive commands.
        - Call tools directly instead of describing what you would do. Only report checks actually run and their results. When done, give a concise account of changes and evidence. Ask a question only when a real blocker requires the user's input; do not end with a generic question.
        """ : "You cannot use tools with this model: answer from the conversation and ask the user for any file you need.")
        \(instructions.map { "\nProject AGENTS.md instructions (bounded to 12 KiB):\n---\n\($0)\n---" } ?? "\nNo readable root AGENTS.md was found within the 12 KiB limit.")
        Reply in the user's language, briefly and concretely. Use Markdown for code.
        """
    }

    private static func legacySystem(_ conversation: ChatConversation, tools: Bool, extra: [String]) -> String {
        """
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
    typealias StreamFactory = (StellarServer, String, [StellarMessage], [[String: Any]]?, Int) throws -> AsyncThrowingStream<StellarChunk, Error>
    private var turn: Task<Void, Error>?
    private var mode = "manual"
    private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var commands: [Process] = []
    private var energySaving = false
    private var activeModelIsCloud = false
    private var rootInstructionsUnavailable = false
    static let maxSteps = 40
    var prepareServer: (StellarServer, String) async throws -> Void = { server, model in
        if server.api == .ollama { await StellarRuntime.ensureOllama(wait: true) }
        guard await StellarHTTP.reachable(server) else {
            throw StellarError.message("\(server.title) no responde en \(server.baseURL). Inícialo para usar \(model).")
        }
    }
    var inspectSelectedModel: (String, Bool) async throws -> StellarModel = { name, includeCloud in
        try await StellarModels.selectedOllamaModel(named: name, includeCloud: includeCloud)
    }
    var streamRequest: StreamFactory = StellarClient.stream

    func setEnergySaving(_ enabled: Bool) {
        energySaving = enabled
        if enabled, activeModelIsCloud { stop() }
    }

    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        mode = conversation.mode ?? "manual"
        let task = Task { try await loop(conversation, prompt: prompt, onEvent: onEvent) }
        turn = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func loop(_ conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        deliveredInstructions.removeAll()
        rootInstructionsUnavailable = !energySaving && StellarInstructions.rootIsUnavailable(projectPath: conversation.projectPath)
        guard let (server, model) = StellarModels.resolve(conversation.model) else {
            if energySaving {
                throw StellarError.message(conversation.model.isEmpty ? "Elige un modelo local para Stellar Code." : "«\(conversation.model)» no es un modelo local de Stellar Code.")
            }
            throw StellarError.message(conversation.model.isEmpty ? "Elige un modelo local o vincula uno de Ollama Cloud para Stellar Code." : "«\(conversation.model)» no es un identificador válido de modelo Stellar.")
        }
        if server.api == .ollama { try StellarModels.requireCloudAllowed(name: model, includeCloud: !energySaving) }
        try await prepareServer(server, model)
        var info: StellarModel?
        if server.api == .ollama {
            info = try await inspectSelectedModel(model, !energySaving)
        } else {
            info = (try? await StellarModels.models(on: server, includeCloud: false))?.first { $0.name == model }
        }
        guard server.api != .ollama || info != nil else { throw StellarError.message("Ollama no tiene el modelo \(model). Vincúlalo desde Ollama y vuelve a elegirlo.") }
        try Task.checkCancellation()
        if energySaving, info?.isCloud == true { throw StellarModels.cloudUnavailableError }
        activeModelIsCloud = info?.isCloud == true
        defer { activeModelIsCloud = false }
        let useTools = info?.tools ?? true
        let contextLength = min(info?.contextLength ?? Int.max, (UserDefaults.standard.object(forKey: StellarServer.contextLengthKey) as? Int) ?? StellarServer.defaultContextLength)

        let sessionID = conversation.sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        if conversation.sessionID != sessionID { onEvent(.session(sessionID)) }
        var history = StellarSessions.load(sessionID)
        history.removeAll { $0.role == "system" }
        var system = StellarMessage(role: "system", content: StellarPrompt.system(conversation, tools: useTools, normalMode: !energySaving, instructions: energySaving ? nil : StellarInstructions.root(projectPath: conversation.projectPath)))
        history.append(StellarMessage(role: "user", content: ChatAttachments.promptText(prompt, attachments: conversation.turnAttachments)))
        StellarSessions.save(history, id: sessionID)

        var tokens = conversation.tokenUsage ?? ChatTokenUsage()
        var contextNoticeSent = false
        let roots = [conversation.projectPath] + conversation.additionalDirectories + conversation.attachmentDirectories
        for step in 0..<Self.maxSteps {
            try Task.checkCancellation()
            if server.api == .ollama {
                try StellarModels.requireCloudAllowed(name: model, metadata: ["cloud": activeModelIsCloud], includeCloud: !energySaving)
            }
            let textID = "stellar-\(UUID().uuidString)"
            let reasoningID = textID + ":reasoning"
            var text = "", calls: [StellarToolCall] = []
            let toolDefinitions = useTools ? (energySaving ? StellarTools.definitions : StellarTools.normalDefinitions) : nil
            let bounded = energySaving ? (history, nil) : Self.contextBounded(history, system: system, contextLength: contextLength, toolDefinitions: toolDefinitions ?? [])
            if let notice = bounded.1, !contextNoticeSent {
                contextNoticeSent = true
                let visibleNotice = notice.contains("todavía exced")
                    ? "Aviso de contexto: Jack redujo cuerpos de resultados antiguos de herramientas, pero el historial y las instrucciones todavía exceden la estimación. Conservó objetivos y llamadas; usa /compact explícitamente."
                    : notice.contains("redujo")
                    ? "Aviso de contexto: Jack redujo solo cuerpos de resultados antiguos de herramientas para esta petición. Conservó el historial guardado, los objetivos y las llamadas; usa /compact para resumir explícitamente."
                    : "Aviso de contexto: el historial y las instrucciones superan la estimación de contexto. Jack conservó todo; usa /compact explícitamente o el modelo podría exceder su ventana."
                onEvent(.text(id: "stellar-context-warning-\(UUID().uuidString)", text: visibleNotice, replace: true))
            }
            let requestMessages = [system] + (bounded.1.map { [StellarMessage(role: "system", content: $0)] } ?? []) + bounded.0
            for try await chunk in try streamRequest(server, model, requestMessages, toolDefinitions, contextLength) {
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
                let result = await perform(call, conversation: conversation, roots: roots, onEvent: onEvent)
                history.append(StellarMessage(role: "tool", content: result.text, toolCallID: call.id, toolName: call.name, protectedPrefix: result.protectedPrefix))
                if result.instructionsDelivered, result.instructionsComplete {
                    deliveredInstructions.merge(result.instructionFiles) { _, new in new }
                }
                if result.instructionsChanged {
                    deliveredInstructions.removeAll()
                    rootInstructionsUnavailable = StellarInstructions.rootIsUnavailable(projectPath: conversation.projectPath)
                    system.content = StellarPrompt.system(conversation, tools: useTools, normalMode: !energySaving,
                                                         instructions: energySaving ? nil : StellarInstructions.root(projectPath: conversation.projectPath))
                }
                StellarSessions.save(history, id: sessionID)
            }
            if step == Self.maxSteps - 1 {
                onEvent(.text(id: "stellar-limit-\(UUID().uuidString)", text: "Me detuve tras \(Self.maxSteps) pasos. Escribe «continúa» para seguir.", replace: true))
            }
        }
        onEvent(.completed)
    }

    private struct ToolResult {
        var text: String
        var failed = false
        var protectedPrefix: String?
        var instructionFiles: [String: String] = [:]
        var instructionsComplete = true
        var instructionsDelivered = false
        var instructionsChanged = false
    }

    private var deliveredInstructions: [String: String] = [:]

    private func perform(_ call: StellarToolCall, conversation: ChatConversation, roots: [String], onEvent: @escaping @MainActor (ChatEvent) -> Void) async -> ToolResult {
        let spec = StellarTools.specs.first { $0.name == call.name }
        let toolID = "stellar-tool-\(UUID().uuidString)"
        let title = spec?.title ?? call.name
        let input = boundedJSON(StellarTools.displayInput(call, root: conversation.projectPath))
        onEvent(.tool(id: toolID, title: title, detail: input, status: "running"))
        if !energySaving, rootInstructionsUnavailable, ["write_file", "edit_file"].contains(call.name) {
            let output = "No se modificó el archivo: existe AGENTS.md en la raíz, pero no se pudo cargar completo dentro del límite de 12 KiB o está fuera de la raíz autorizada. Reduce o corrige ese archivo primero."
            onEvent(.tool(id: toolID, title: title, detail: input + "\n" + output, status: "failed"))
            return ToolResult(text: output, failed: true)
        }
        if !energySaving, ["write_file", "edit_file"].contains(call.name), let path = (call.input["path"] as? String).map({ StellarTools.resolve($0, root: conversation.projectPath) }) {
            let load = StellarInstructions.loadApplicable(to: path, projectPath: conversation.projectPath)
            if StellarInstructions.needsDelivery(load, previouslyDelivered: deliveredInstructions) {
                let reason = load.complete
                    ? "No se modificó el archivo. Jack incluye ahora las instrucciones aplicables; repite la operación en la siguiente llamada."
                    : "No se modificó el archivo. La carga de instrucciones aplicables está incompleta; pide que se reduzcan o reparen antes de operar en este ámbito."
                let prefix = (load.protectedPrefix ?? "")
                let output = prefix + reason
                onEvent(.tool(id: toolID, title: title, detail: input + "\n" + output, status: "failed"))
                return ToolResult(text: output, failed: true, protectedPrefix: prefix.isEmpty ? nil : prefix,
                                  instructionFiles: load.files, instructionsComplete: load.complete,
                                  instructionsDelivered: load.complete && output.hasPrefix(prefix))
            }
        }
        if let spec, needsApproval(spec, call: call, root: conversation.projectPath, roots: roots) {
            let approvalID = "stellar-\(UUID().uuidString)"
            var approval = ChatApproval(id: approvalID, title: Self.approvalTitle(spec), detail: input)
            approval.tool = title
            onEvent(.approval(approval))
            let allowed = await withCheckedContinuation { approvals[approvalID] = $0 }
            onEvent(.approvalResolved(approvalID))
            guard allowed else {
                onEvent(.tool(id: toolID, title: title, detail: input + "\nRechazado por el usuario.", status: "failed"))
                return ToolResult(text: "The user rejected this action. Do not retry it; ask what to do instead or try another approach.", failed: true)
            }
        }
        var instructionLoad: StellarInstructions.LoadResult?
        var instructionPrefix: String?
        let (rawOutput, failed) = await StellarTools.execute(call, root: conversation.projectPath, normalMode: !energySaving,
                                                               onInstructions: { load, prefix in instructionLoad = load; instructionPrefix = prefix }) { [weak self] process in
            Task { @MainActor in self?.commands.append(process) }
        }
        let output = energySaving ? String(rawOutput.prefix(24_000)) : (call.name == "read_file" ? rawOutput : StellarTools.boundedUTF8(rawOutput, bytes: 8_000))
        commands.removeAll { !$0.isRunning }
        onEvent(.tool(id: toolID, title: title, detail: input + "\n" + output, status: failed ? "failed" : "completed"))
        let prefix = instructionPrefix.flatMap { output.hasPrefix($0) ? $0 : nil }
        let delivered = !energySaving && call.name == "read_file" && !failed && instructionLoad?.complete == true && prefix != nil
        let changedInstructions = !energySaving && !failed && ["write_file", "edit_file"].contains(call.name)
            && (call.input["path"] as? String).map { URL(fileURLWithPath: StellarTools.resolve($0, root: conversation.projectPath)).lastPathComponent == "AGENTS.md" } == true
        return ToolResult(text: output, failed: failed, protectedPrefix: prefix,
                          instructionFiles: delivered ? (instructionLoad?.files ?? [:]) : [:],
                          instructionsComplete: instructionLoad?.complete ?? true, instructionsDelivered: delivered,
                          instructionsChanged: changedInstructions)
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

    /// Only old tool-result bodies may be shortened. User/assistant content, instruction prefixes and tool identities stay intact.
    /// This is a UTF-8/4 estimate (not tokenizer telemetry), reserving room for schemas and the model's answer.
    static func contextBounded(_ history: [StellarMessage], system: StellarMessage, contextLength: Int,
                               toolDefinitions: [[String: Any]]) -> ([StellarMessage], String?) {
        let responseMargin = min(2_048, max(256, contextLength / 8))
        let inputBudget = max(0, contextLength - responseMargin)
        let definitionsBytes = boundedJSON(toolDefinitions).utf8.count
        func estimate(_ messages: [StellarMessage]) -> Int {
            let contentBytes = system.content.utf8.count + messages.reduce(0) { partial, message in
                partial + message.content.utf8.count + (message.toolCalls ?? []).reduce(0) { $0 + $1.arguments.utf8.count + $1.name.utf8.count }
            }
            return (contentBytes + definitionsBytes) / 4 + messages.count * 8 + 128
        }
        guard estimate(history) > inputBudget else { return (history, nil) }
        var bounded = history
        let lastUser = history.lastIndex { $0.role == "user" } ?? history.endIndex
        let oldResults = history.indices.filter { history[$0].role == "tool" && $0 < lastUser }
        var shortened = Set<Int>()
        for index in oldResults where estimate(bounded) > inputBudget {
            let original = history[index].content
            let protected = history[index].protectedPrefix.flatMap { original.hasPrefix($0) ? $0 : nil } ?? ""
            let originalBody = String(original.dropFirst(protected.count))
            guard !originalBody.isEmpty else { continue }
            var keepBytes = originalBody.utf8.count
            while estimate(bounded) > inputBudget, keepBytes > 0 {
                let excessBytes = max(1, (estimate(bounded) - inputBudget) * 4)
                let nextKeep = max(0, keepBytes - excessBytes - 96)
                guard nextKeep < keepBytes else { break }
                keepBytes = nextKeep
                let keptBody = StellarTools.prefixUTF8(originalBody, bytes: keepBytes)
                let omittedBytes = originalBody.utf8.count - keptBody.utf8.count
                let marker = "\n[Jack redujo un resultado antiguo: conserva \(keptBody.utf8.count) de \(originalBody.utf8.count) bytes UTF-8; omitió \(omittedBytes).]"
                bounded[index].content = protected + keptBody + marker
                shortened.insert(index)
            }
        }
        guard !shortened.isEmpty else {
            return (bounded, "El historial completo, las instrucciones y las herramientas exceden la estimación de contexto; Jack conservó todo. Usa /compact explícitamente para resumir la sesión.")
        }
        if estimate(bounded) > inputBudget {
            return (bounded, "Jack redujo cuerpos de resultados de herramientas antiguos, pero el historial e instrucciones todavía exceden la estimación de contexto. Conservó todos los mensajes y pares de herramientas; usa /compact explícitamente.")
        }
        return (bounded, "Jack redujo \(shortened.count) resultado(s) antiguo(s) de herramientas para esta petición. Conservó los mensajes de usuario/asistente, las instrucciones y todos los IDs y resultados de llamadas; el historial guardado no cambia.")
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
    static func ask(_ question: String, prompt: String, about conversation: ChatConversation, allowCloud: Bool = false,
                    cloudAllowed: AsideCloudPolicy? = nil, cloudModelResolved: AsideCloudResolved? = nil,
                    prepareServer: ((StellarServer) async throws -> Void)? = nil,
                    inspectModel: ((String, Bool) async throws -> StellarModel)? = nil,
                    streamRequest: StellarChatDriver.StreamFactory? = nil,
                    partial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let (server, model) = StellarModels.resolve(conversation.model) else {
            throw StellarError.message(allowCloud ? "Elige un modelo local o vincula uno de Ollama Cloud para Stellar Code." : "Elige un modelo local para Stellar Code.")
        }
        let cloudIsAllowed = { cloudAllowed?() ?? allowCloud }
        if server.api == .ollama {
            try StellarModels.requireCloudAllowed(name: model, includeCloud: cloudIsAllowed())
            if StellarModels.isCloud(name: model, metadata: [:]) { cloudModelResolved?() }
        }
        if server.api == .ollama {
            if let prepareServer { try await prepareServer(server) }
            else { await StellarRuntime.ensureOllama(wait: true) }
        }
        try Task.checkCancellation()
        if server.api == .ollama { try StellarModels.requireCloudAllowed(name: model, includeCloud: cloudIsAllowed()) }
        var selectedModel: StellarModel?
        if server.api == .ollama {
            selectedModel = try await (inspectModel ?? { name, includeCloud in
                try await StellarModels.inspectOllamaModel(named: name, includeCloud: includeCloud)
            })(model, cloudIsAllowed())
            try Task.checkCancellation()
            if selectedModel?.isCloud == true { cloudModelResolved?() }
            try StellarModels.requireCloudAllowed(name: model, metadata: ["cloud": selectedModel?.isCloud == true], includeCloud: cloudIsAllowed())
        }
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
        let system = StellarMessage(role: "system", content: StellarPrompt.system(conversation, tools: false, normalMode: allowCloud))
        var answer = ""
        let contextLength = (UserDefaults.standard.object(forKey: StellarServer.contextLengthKey) as? Int) ?? StellarServer.defaultContextLength
        try Task.checkCancellation()
        if server.api == .ollama {
            try StellarModels.requireCloudAllowed(name: model, metadata: ["cloud": selectedModel?.isCloud == true], includeCloud: cloudIsAllowed())
        }
        let stream = try (streamRequest ?? StellarClient.stream)(server, model, [system] + context + [StellarMessage(role: "user", content: prompt)], nil, contextLength)
        for try await chunk in stream {
            if case .text(let delta) = chunk { answer += delta; partial(answer) }
        }
        return answer
    }
}
