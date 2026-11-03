import Foundation

// El cliente de Ollama (y de servidores compatibles con OpenAI) de Stellar Code y de los personajes de la oficina. No
// depende de nada de la Mac: el iPhone lo usa igual, con `StellarTransport.remote` para que sus peticiones las haga la Mac.

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
        #if os(macOS)
        await StellarRuntime.ensureOllama(wait: false)
        #endif
        return await withTaskGroup(of: [StellarModel].self) { group in
            for server in StellarServer.all { group.addTask { (try? await models(on: server, includeCloud: includeCloud)) ?? [] } }
            var all: [StellarModel] = []
            for await list in group { all += list }
            let order = StellarServer.all.map(\.id)
            return all.sorted { (order.firstIndex(of: $0.server.id) ?? 99, $0.name) < (order.firstIndex(of: $1.server.id) ?? 99, $1.name) }
        }
    }

    /// Normal also accepts Ollama's tagged names, as entered in the custom-model field.
    /// Keep untagged names and unknown server prefixes ambiguous rather than guessing.
    static func canonicalID(_ rawID: String, allowOllamaName: Bool) -> String {
        guard allowOllamaName else { return rawID }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.contains("/"), id.contains(":"), (try? validateOllamaName(id)) != nil else { return id }
        return "ollama/\(id)"
    }

    public static func resolve(_ modelID: String, allowOllamaName: Bool = false) -> (server: StellarServer, name: String)? {
        let modelID = canonicalID(modelID, allowOllamaName: allowOllamaName)
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

/// Cómo salen las peticiones HTTP a Ollama. En la Mac, directas al servidor local; en el iPhone, `remote` las manda a la Mac
/// (por Jack Remote), que las hace contra su Ollama y devuelve las líneas de la respuesta tal cual.
public enum StellarTransport {
    public struct Response: Sendable {
        public var status: Int
        public var lines: AsyncThrowingStream<String, Error>
        public init(status: Int, lines: AsyncThrowingStream<String, Error>) { self.status = status; self.lines = lines }
    }

    /// Ruta (`/api/chat`, `/api/show`…), cuerpo JSON y tiempo máximo → estado HTTP y líneas de la respuesta.
    nonisolated(unsafe) public static var remote: (@Sendable (_ path: String, _ body: Data?, _ timeout: TimeInterval) async throws -> Response)?

    /// La petición, por donde toque.
    static func lines(for request: URLRequest, path: String) async throws -> Response {
        if let remote { return try await remote(path, request.httpBody, request.timeoutInterval) }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return Response(status: status, lines: lines)
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
        let response = try await StellarTransport.lines(for: request(server, path: path, body: body, timeout: timeout), path: path)
        var text = ""
        for try await line in response.lines { text += line + "\n" }
        let status = response.status
        let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
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
        let path = server.api == .ollama ? "/api/version" : "/v1/models"
        guard let request = try? request(server, path: path, timeout: 1.5) else { return false }
        return (try? await StellarTransport.lines(for: request, path: path))?.status == 200
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
    /// An instruction prefix embedded in a tool result that must survive context reduction.
    var protectedPrefix: String? = nil
    /// Pictures attached to the message, as base64 PNG/JPEG (for models with vision).
    var images: [String]? = nil
}

struct StellarToolCall: Codable, Equatable {
    var id: String
    var name: String
    /// JSON object, as text.
    var arguments: String
    var input: [String: Any] { (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:] }
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
        try stream(server: server, model: model, messages: messages, tools: tools, contextLength: contextLength, timeout: 600)
    }

    static func stream(server: StellarServer, model: String, messages: [StellarMessage], tools: [[String: Any]]?, contextLength: Int, timeout: TimeInterval) throws -> AsyncThrowingStream<StellarChunk, Error> {
        let payload = requestPayload(server: server, model: model, messages: messages, tools: tools, contextLength: contextLength)
        let request = try StellarHTTP.request(server, path: payload.path, body: payload.body, timeout: timeout)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await StellarTransport.lines(for: request, path: payload.path)
                    if response.status != 200 {
                        var text = ""
                        for try await line in response.lines { text += line; if text.count > 4000 { break } }
                        throw StellarError.message(errorText(text) ?? "\(server.title) respondió \(response.status).")
                    }
                    var calls: [Int: (id: String, name: String, arguments: String)] = [:]
                    for try await line in response.lines {
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
        if let images = message.images, !images.isEmpty { value["images"] = images }
        return value
    }

    static func openAIMessage(_ message: StellarMessage) -> [String: Any] {
        var value: [String: Any] = ["role": message.role, "content": message.content]
        if let images = message.images, !images.isEmpty {
            value["content"] = [["type": "text", "text": message.content]]
                + images.map { ["type": "image_url", "image_url": ["url": "data:image/png;base64," + $0]] }
        }
        if let calls = message.toolCalls, !calls.isEmpty {
            value["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        }
        if let id = message.toolCallID { value["tool_call_id"] = id }
        return value
    }
}

func boundedJSON(_ value: Any, limit: Int = 64 * 1024) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return String(describing: value).prefix(limit).description }
    if data.count <= limit { return String(data: data, encoding: .utf8) ?? "" }
    return String(data: data.prefix(limit), encoding: .utf8).map { $0 + "\n… output truncated at 64 KB" } ?? "[output truncated at 64 KB]"
}
