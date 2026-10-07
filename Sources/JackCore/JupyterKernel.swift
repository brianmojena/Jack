import Foundation

public struct JupyterEndpoint: Equatable {
    public enum Authentication: Equatable { case jupyter, colab }
    public let url: URL
    let token: String
    public let authentication: Authentication

    public init(address: String, token: String = "", authentication: Authentication = .jupyter) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil else {
            throw NotebookError.message("Introduce la URL HTTP o HTTPS del servidor Jupyter, con su ruta base.")
        }
        let queryToken = parts.queryItems?.first { $0.name == "token" }?.value ?? ""
        parts.query = nil; parts.fragment = nil
        // Pasting Jupyter's usual /tree or /lab URL should work too.
        if parts.path.hasSuffix("/lab") { parts.path = String(parts.path.dropLast(4)) }
        if parts.path.hasSuffix("/tree") { parts.path = String(parts.path.dropLast(5)) }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw NotebookError.message("URL de Jupyter inválida.") }
        self.url = url
        self.token = token.isEmpty ? queryToken : token
        self.authentication = authentication
    }

    public var displayName: String {
        authentication == .colab ? "Colab" : (url.host == "127.0.0.1" || url.host == "localhost" ? "Jupyter local" : (url.host ?? "Jupyter"))
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authentication == .colab {
            request.setValue(token, forHTTPHeaderField: "X-Colab-Runtime-Proxy-Token")
            request.setValue("vscode", forHTTPHeaderField: "X-Colab-Client-Agent")
        } else if !token.isEmpty {
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}

/// Do not forward notebook credentials through redirects to a different origin.
private final class JupyterTransportDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let target = request.url
        let same = original?.scheme == target?.scheme && original?.host == target?.host && original?.port == target?.port
        completionHandler(same ? request : nil)
    }
}

public struct JupyterKernelSpec: Identifiable, Equatable {
    public let id: String
    public let title: String
}

/// Native Jupyter REST + WebSocket client. The document and agent share this exact kernel.
@MainActor public final class JupyterKernel {
    public let endpoint: JupyterEndpoint
    public private(set) var kernelID: String?
    public var onDisconnected: ((String) -> Void)?
    public var onInput: ((String, Bool) -> Void)?
    private let transport: URLSession
    private let clientID = UUID().uuidString
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var executions: [String: Execution] = [:]
    private var inputHeader: [String: Any]?
    private var closing = false
    private struct Execution {
        var count: Int?
        var failure: String?
        var replied = false
        var idle = false
        let output: (String, [String: Any]) -> Void
        let continuation: CheckedContinuation<Int?, Error>
    }

    public init(endpoint: JupyterEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        transport = URLSession(configuration: config, delegate: JupyterTransportDelegate(), delegateQueue: nil)
    }

    public func specifications() async throws -> [JupyterKernelSpec] {
        let root = try await request("api/kernelspecs") as? [String: Any] ?? [:]
        let specs = root["kernelspecs"] as? [String: [String: Any]] ?? [:]
        return specs.map { name, data in
            JupyterKernelSpec(id: name, title: (data["spec"] as? [String: Any])?["display_name"] as? String ?? name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func connect(name: String, directory: String = "") async throws {
        guard socket == nil else { throw NotebookError.message("El kernel ya está conectado.") }
        closing = false
        let result = try await request("api/kernels", method: "POST", body: ["name": name, "path": directory]) as? [String: Any]
        guard let id = result?["id"] as? String, !id.isEmpty else { throw NotebookError.message("Jupyter no devolvió el identificador del kernel.") }
        kernelID = id
        do {
            var request = try endpoint.request("api/kernels/\(id)/channels")
            var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            parts.scheme = endpoint.url.scheme == "https" ? "wss" : "ws"
            parts.queryItems = [URLQueryItem(name: "session_id", value: clientID)]
            request.url = parts.url
            let socket = transport.webSocketTask(with: request)
            socket.maximumMessageSize = 16 * 1024 * 1024
            self.socket = socket
            socket.resume()
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard let self else { return }
                        try self.consume(Self.decode(message))
                    }
                } catch {
                    guard let self, !self.closing else { return }
                    // URLSession errors can contain the URL; use a credential-free message.
                    self.failAll("Se perdió la conexión con el kernel. Vuelve a conectarlo.")
                    self.onDisconnected?("Se perdió la conexión con el kernel. Vuelve a conectarlo.")
                }
            }
            // This also detects an HTTP auth error during the WebSocket upgrade.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        socket.sendPing { error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                }
                group.addTask { try await Task.sleep(for: .seconds(30)); throw NotebookError.message("El kernel no respondió al conectar.") }
                try await group.next(); group.cancelAll()
            }
        } catch {
            await disconnect()
            throw NotebookError.message("No se pudo abrir el canal del kernel. Comprueba la URL y el token.")
        }
    }

    public func execute(_ source: String, output: @escaping (String, [String: Any]) -> Void) async throws -> Int? {
        guard let socket, !closing else { throw NotebookError.message("Selecciona y conecta un kernel primero.") }
        let id = UUID().uuidString
        let message = Self.message(id: id, session: clientID, type: "execute_request", channel: "shell", content: [
            "code": source, "silent": false, "store_history": true, "user_expressions": [:],
            "allow_stdin": true, "stop_on_error": true
        ])
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executions[id] = Execution(output: output, continuation: continuation)
                Task {
                    do { try await socket.send(.string(payload)) }
                    catch { self.finish(id, error: NotebookError.message("No se pudo enviar la celda al kernel.")) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                try? await self?.interrupt()
                self?.finish(id, error: CancellationError())
            }
        }
    }

    public func input(_ value: String) async throws {
        guard let socket, let header = inputHeader else { throw NotebookError.message("El kernel no está esperando entrada.") }
        inputHeader = nil
        let message = Self.message(id: UUID().uuidString, session: clientID, type: "input_reply", channel: "stdin", content: ["value": value], parent: header)
        try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
    }

    public func interrupt() async throws {
        guard let id = kernelID else { return }
        _ = try await request("api/kernels/\(id)/interrupt", method: "POST")
    }
    public func restart() async throws {
        guard let id = kernelID else { return }
        failAll("El kernel se ha reiniciado.")
        _ = try await request("api/kernels/\(id)/restart", method: "POST")
    }
    public func disconnect() async {
        closeChannel()
        if let id = kernelID {
            kernelID = nil
            _ = try? await request("api/kernels/\(id)", method: "DELETE")
        }
        transport.invalidateAndCancel()
    }
    /// Synchronous teardown for app shutdown; local server teardown also ends its kernels.
    public func closeChannel() {
        closing = true; reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        failAll("Se desconectó el kernel.")
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let (data, response) = try await transport.data(for: endpoint.request(path, method: method, body: body))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                throw NotebookError.message("Jupyter rechazó la autenticación (\(code)). El token puede haber caducado; vuelve a conectarte.")
            }
            throw NotebookError.message("Jupyter devolvió HTTP \(code). Comprueba la ruta base y el kernel seleccionado.")
        }
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func message(id: String, session: String, type: String, channel: String, content: [String: Any], parent: [String: Any] = [:]) -> [String: Any] {
        ["header": ["msg_id": id, "username": "jack", "session": session, "msg_type": type,
                    "version": "5.3", "date": ISO8601DateFormatter().string(from: Date())],
         "parent_header": parent, "metadata": [:], "content": content, "channel": channel, "buffers": []]
    }

    /// The default Jupyter WebSocket protocol sends JSON, or a binary offset table followed by JSON and buffers.
    static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes):
            func word(_ offset: Int) -> Int {
                bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            }
            guard bytes.count >= 8 else { throw NotebookError.message("Mensaje binario de Jupyter incompleto.") }
            let count = word(0)
            guard count > 0, count < bytes.count / 4 else { throw NotebookError.message("Mensaje binario de Jupyter inválido.") }
            let start = word(4), end = count > 1 ? word(8) : bytes.count
            guard start >= (count + 1) * 4, end >= start, end <= bytes.count else { throw NotebookError.message("Offsets de Jupyter inválidos.") }
            data = bytes.subdata(in: start..<end)
        @unknown default: throw NotebookError.message("Mensaje de Jupyter desconocido.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotebookError.message("Mensaje de Jupyter inválido.") }
        return object
    }

    private func consume(_ message: [String: Any]) throws {
        let type = (message["header"] as? [String: Any])?["msg_type"] as? String ?? ""
        let parent = message["parent_header"] as? [String: Any] ?? [:]
        let id = parent["msg_id"] as? String ?? ""
        let content = message["content"] as? [String: Any] ?? [:]
        guard executions[id] != nil else { return }
        if type == "input_request" {
            inputHeader = message["header"] as? [String: Any]
            onInput?(content["prompt"] as? String ?? "Entrada:", content["password"] as? Bool ?? false)
        } else if type == "colab_request" {
            // Drive / Google ephemeral credentials require a separate user consent flow.
            // Reply explicitly so unsupported requests never leave a cell hung indefinitely.
            let metadata = message["metadata"] as? [String: Any] ?? [:]
            if let requestID = metadata["colab_msg_id"], let socket {
                let reply = Self.message(id: UUID().uuidString, session: clientID, type: "input_reply", channel: "stdin",
                                         content: ["value": ["type": "colab_reply", "colab_msg_id": requestID,
                                                              "error": "Autoriza Drive o Google desde Colab; Jack todavía no admite credenciales efímeras."]])
                try awaitSend(socket, reply)
            }
        } else if type == "execute_reply" {
            executions[id]?.count = content["execution_count"] as? Int
            executions[id]?.replied = true
            if content["status"] as? String == "error" { executions[id]?.failure = content["evalue"] as? String ?? "La celda falló." }
            if executions[id]?.idle == true { finish(id) }
        } else if type == "status", content["execution_state"] as? String == "idle" {
            executions[id]?.idle = true
            if executions[id]?.replied == true { finish(id) }
        } else {
            executions[id]?.output(type, content)
        }
    }
    private func awaitSend(_ socket: URLSessionWebSocketTask, _ message: [String: Any]) throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        Task { try? await socket.send(.string(text)) }
    }
    private func finish(_ id: String, error: Error? = nil) {
        guard let execution = executions.removeValue(forKey: id) else { return }
        if let error { execution.continuation.resume(throwing: error) }
        else if let failure = execution.failure { execution.continuation.resume(throwing: NotebookError.message(failure)) }
        else { execution.continuation.resume(returning: execution.count) }
    }
    private func failAll(_ message: String) {
        for id in Array(executions.keys) { finish(id, error: NotebookError.message(message)) }
        inputHeader = nil
    }
}
