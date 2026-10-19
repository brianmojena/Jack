import Darwin
import Foundation

public enum AntigravityIntegrationError: LocalizedError, Equatable {
    case normalModeRequired
    case invalidEndpoint
    case helperMissing
    case configuration(String)
    case nameConflict(String)
    case proxy(String)

    public var errorDescription: String? {
        switch self {
        case .normalModeRequired:
            return "Antigravity solo puede usar el MCP de Jack en el modo Normal."
        case .invalidEndpoint:
            return "El MCP de Jack debe ser una URL HTTP de loopback con token."
        case .helperMissing:
            return "No se encontró el helper jack-progress. Recompila Jack para incluir su subcomando antigravity-mcp."
        case .configuration(let detail):
            return "No se pudo preparar la configuración MCP de Antigravity: \(detail)"
        case .nameConflict(let name):
            return "La configuración MCP de Antigravity ya tiene un servidor «\(name)» que Jack no creó. Renómbralo o elimínalo antes de continuar."
        case .proxy(let detail):
            return "El proxy MCP de Antigravity falló: \(detail)"
        }
    }
}

/// Connects Antigravity's stdio MCP configuration to Jack's loopback AgentBridge.
///
/// Antigravity reads one global `mcp_config.json`. Jack registers a tiny stdio server
/// (`jack-progress antigravity-mcp`) there and passes the ephemeral bridge URL and token
/// through the Antigravity process environment, so neither value is ever written to disk.
public enum AntigravityIntegration {
    /// Stable, recognizable name for the server Jack owns.
    public static let serverName = "jack_app"
    /// Internal subcommand implemented by `jack-progress`.
    public static let helperCommand = "antigravity-mcp"

    /// Validates the delegation and prepares Antigravity's MCP registration.
    /// The returned values must be merged into the `agy` process environment.
    public static func environment(delegation: ChatDelegation) throws -> [String: String] {
        guard delegation.normalMode else { throw AntigravityIntegrationError.normalModeRequired }
        guard !delegation.token.isEmpty else { throw AntigravityIntegrationError.invalidEndpoint }
        try validateEndpoint(delegation.url)

        let helper = try resolveHelper()
        try register(helper: helper)
        return [
            "JACK_MCP_URL": delegation.url.absoluteString,
            "JACK_MCP_TOKEN": delegation.token,
        ]
    }

    // MARK: - Registration

    /// `~/.gemini/config/mcp_config.json`, with a test-only path override.
    static var configurationURL: URL {
        if let override = ProcessInfo.processInfo.environment["JACK_GEMINI_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/mcp_config.json")
    }

    /// Bundle first, then the app's helper folder and local Swift builds.
    static func resolveHelper() throws -> URL {
        var candidates: [URL] = []
        if let bundled = ProgressFiles.helperURL { candidates.append(bundled) }
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent(ProgressFiles.helperName))
            candidates.append(directory.deletingLastPathComponent().appendingPathComponent("MacOS/\(ProgressFiles.helperName)"))
        }
        let roots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        ]
        for root in roots {
            for build in [".build/debug", ".build/arm64-apple-macosx/debug", ".build/x86_64-apple-macosx/debug",
                          ".build/release", ".build/arm64-apple-macosx/release", ".build/x86_64-apple-macosx/release"] {
                candidates.append(root.appendingPathComponent(build).appendingPathComponent(ProgressFiles.helperName))
            }
        }
        if let override = ProcessInfo.processInfo.environment[ProgressFiles.helperKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted, FileManager.default.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        throw AntigravityIntegrationError.helperMissing
    }

    static func validateEndpoint(_ url: URL) throws {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(),
              ["127.0.0.1", "::1", "localhost"].contains(host),
              let port = url.port, (1...65_535).contains(port),
              url.user == nil, url.password == nil else {
            throw AntigravityIntegrationError.invalidEndpoint
        }
    }

    private static func register(helper: URL) throws {
        try register(helper: helper, to: configurationURL)
    }

    /// Internal overload so tests can use a temporary file instead of the user's global config.
    static func register(helper: URL, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AntigravityIntegrationError.configuration(error.localizedDescription)
        }
        let lockURL = directory.appendingPathComponent(".jack-mcp.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AntigravityIntegrationError.configuration("no se pudo abrir el bloqueo \(lockURL.path)")
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw AntigravityIntegrationError.configuration("no se pudo bloquear \(lockURL.path)")
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let existing: Data
        if FileManager.default.fileExists(atPath: url.path) {
            do { existing = try Data(contentsOf: url) }
            catch { throw AntigravityIntegrationError.configuration("no se pudo leer \(url.path): \(error.localizedDescription)") }
        } else {
            existing = Data()
        }
        var root: [String: Any] = [:]
        if !existing.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw AntigravityIntegrationError.configuration("el archivo existente no es un objeto JSON válido")
            }
            root = object
        }
        var servers: [String: Any]
        if let value = root["mcpServers"] {
            guard let object = value as? [String: Any] else {
                throw AntigravityIntegrationError.configuration("mcpServers no es un objeto")
            }
            servers = object
        } else {
            servers = [:]
        }
        if let current = servers[serverName] {
            guard let entry = current as? [String: Any], isOwned(entry) else {
                throw AntigravityIntegrationError.nameConflict(serverName)
            }
        }
        // No URL or token here: the helper reads them from the inherited process environment.
        servers[serverName] = ["command": helper.path, "args": [helperCommand], "disabled": false]
        root["mcpServers"] = servers

        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) + Data([0x0A])
        let temporary = directory.appendingPathComponent(".mcp_config.\(getpid()).\(UUID().uuidString).tmp")
        do {
            try output.write(to: temporary, options: .atomic)
            let permissions: Int
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let current = attributes[.posixPermissions] as? NSNumber {
                permissions = current.intValue
            } else {
                permissions = 0o600
            }
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                throw AntigravityIntegrationError.configuration("no se pudo reemplazar \(url.path)")
            }
        } catch let error as AntigravityIntegrationError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AntigravityIntegrationError.configuration(error.localizedDescription)
        }
    }

    private static func isOwned(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String,
              (command as NSString).lastPathComponent == ProgressFiles.helperName,
              let arguments = entry["args"] as? [String] else { return false }
        return arguments == [helperCommand]
    }

    // MARK: - stdio proxy

    /// Entry point used by `jack-progress antigravity-mcp`.
    public static func runMCPProxy() -> Int32 {
        _ = signal(SIGPIPE, SIG_IGN)
        return runMCPProxy(input: STDIN_FILENO, output: STDOUT_FILENO,
                           environment: ProcessInfo.processInfo.environment)
    }

    /// Blocking line-oriented JSON-RPC proxy. Exposed internally so tests can use pipes.
    static func runMCPProxy(input: Int32, output: Int32, environment: [String: String]) -> Int32 {
        let url = environment["JACK_MCP_URL"].flatMap(URL.init(string:))
        let token = environment["JACK_MCP_TOKEN"]
        if url != nil, token?.isEmpty != false { return 1 }
        if let url { do { try validateEndpoint(url) } catch { return 1 } }

        var sessionID: String?
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(input, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return 1
            }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= 16 * 1024 * 1024 else { return 1 }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let response = handle(line, url: url, token: token, sessionID: &sessionID) else { continue }
                guard writeAll(response + Data([0x0A]), to: output) else { return 1 }
            }
        }
        if !buffer.isEmpty, let response = handle(buffer, url: url, token: token, sessionID: &sessionID) {
            guard writeAll(response + Data([0x0A]), to: output) else { return 1 }
        }
        return 0
    }

    private static func handle(_ line: Data, url: URL?, token: String?, sessionID: inout String?) -> Data? {
        guard let payload = try? JSONSerialization.jsonObject(with: line) else {
            return error(id: NSNull(), code: -32700, message: "Parse error")
        }
        if let batch = payload as? [[String: Any]] {
            let hasRequest = batch.contains { $0["id"] != nil }
            guard hasRequest else {
                if let url, let token { _ = try? post(line, to: url, token: token, sessionID: &sessionID) }
                return nil
            }
            if let url, let token {
                do { return try post(line, to: url, token: token, sessionID: &sessionID) }
                catch { return Self.error(id: NSNull(), code: -32000, message: error.localizedDescription) }
            }
            let responses = batch.compactMap { message -> [String: Any]? in local(message) }
            guard !responses.isEmpty else { return nil }
            return try? JSONSerialization.data(withJSONObject: responses)
        }
        guard let message = payload as? [String: Any] else {
            return error(id: NSNull(), code: -32600, message: "Invalid request")
        }
        let hasID = message["id"] != nil
        if let url, let token {
            do {
                let body = try post(line, to: url, token: token, sessionID: &sessionID)
                return hasID && !body.isEmpty ? body : nil
            } catch {
                return hasID ? Self.error(id: message["id"] ?? NSNull(), code: -32000, message: error.localizedDescription) : nil
            }
        }
        guard hasID else { return nil }
        guard let response = local(message) else { return nil }
        return try? JSONSerialization.data(withJSONObject: response)
    }

    /// Outside Jack the helper is inert: it exposes no tools and needs no configuration.
    private static func local(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        switch method {
        case "initialize":
            let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0]
            return result(id: id, ["protocolVersion": version, "capabilities": [:],
                                   "serverInfo": ["name": "jack", "version": "1.0"]])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": []])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    private static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private static func error(id: Any, code: Int, message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                                                     "error": ["code": code, "message": message]])
    }

    // MARK: - HTTP

    private static func post(_ body: Data, to url: URL, token: String, sessionID: inout String?) throws -> Data {
        let port = url.port ?? 80
        let host = url.host?.lowercased() ?? "127.0.0.1"
        let descriptor = try connect(host: host, port: port)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 960, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        var head = "POST \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nAuthorization: Bearer \(token)\r\n"
        head += "Content-Type: application/json\r\nAccept: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        if let sessionID { head += "Mcp-Session-Id: \(sessionID)\r\n" }
        head += "\r\n"
        guard writeAll(Data(head.utf8) + body, to: descriptor) else {
            throw AntigravityIntegrationError.proxy("no se pudo enviar la petición HTTP")
        }
        return try readResponse(from: descriptor, sessionID: &sessionID)
    }

    private static func connect(host: String, port: Int) throws -> Int32 {
        let descriptor: Int32
        if host == "::1" {
            descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw AntigravityIntegrationError.proxy("no se pudo crear el socket") }
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            address.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0 else { close(descriptor); throw AntigravityIntegrationError.proxy("no se pudo conectar al MCP de Jack") }
            return descriptor
        }
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AntigravityIntegrationError.proxy("no se pudo crear el socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(descriptor); throw AntigravityIntegrationError.proxy("no se pudo conectar al MCP de Jack") }
        return descriptor
    }

    static func readResponse(from descriptor: Int32, sessionID: inout String?) throws -> Data {
        var reader = SocketReader(descriptor: descriptor)
        var status = 0
        var headers: [String: String] = [:]
        while true {
            let line = try reader.line()
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let parsed = Int(parts[1]) else {
                throw AntigravityIntegrationError.proxy("respuesta HTTP no válida")
            }
            status = parsed
            headers = [:]
            while true {
                let header = try reader.line()
                if header.isEmpty { break }
                guard let colon = header.firstIndex(of: ":") else { continue }
                headers[header[..<colon].lowercased()] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if status != 100 { break }
        }
        if let value = headers["mcp-session-id"], !value.isEmpty { sessionID = value }
        guard (200..<300).contains(status) else {
            throw AntigravityIntegrationError.proxy("HTTP \(status)")
        }
        if status == 202 || status == 204 { return Data() }
        if let encoding = headers["transfer-encoding"]?.lowercased(), encoding.contains("chunked") {
            return try reader.chunkedBody()
        }
        if let value = headers["content-length"], let length = Int(value) {
            return try reader.exact(length)
        }
        return try reader.rest()
    }

    // MARK: - Bytes

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

private struct SocketReader {
    let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) { self.descriptor = descriptor }

    mutating func line() throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            try more()
        }
    }

    mutating func exact(_ count: Int) throws -> Data {
        guard count >= 0, count <= 16 * 1024 * 1024 else {
            throw AntigravityIntegrationError.proxy("respuesta HTTP demasiado grande")
        }
        while buffer.count < count { try more() }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    mutating func chunkedBody() throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try line().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw AntigravityIntegrationError.proxy("bloque HTTP no válido")
            }
            if size == 0 {
                while !(try line()).isEmpty {}
                return body
            }
            body.append(try exact(size))
            guard body.count <= 16 * 1024 * 1024 else {
                throw AntigravityIntegrationError.proxy("respuesta HTTP demasiado grande")
            }
            _ = try exact(2)
        }
    }

    mutating func rest() throws -> Data {
        while true {
            do { try more() } catch AntigravityIntegrationError.proxy(let message) where message == "fin de la respuesta" {
                return buffer
            }
        }
    }

    private mutating func more() throws {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        if count == 0 { throw AntigravityIntegrationError.proxy("fin de la respuesta") }
        if count < 0 {
            if errno == EINTR { return try more() }
            throw AntigravityIntegrationError.proxy("no se pudo leer la respuesta HTTP")
        }
        buffer.append(contentsOf: chunk[0..<count])
        if buffer.count > 16 * 1024 * 1024 {
            throw AntigravityIntegrationError.proxy("respuesta HTTP demasiado grande")
        }
    }
}
