import Foundation
import Network
import Security

public struct HTTPRequest: Sendable {
    public var method: String
    /// Percent-decoded path without the query string.
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    /// True when the request arrived over TLS on this server.
    public var isSecure: Bool
    /// IP address of the client, e.g. "192.168.1.20".
    public var remoteHost: String

    public init(method: String, path: String, headers: [String: String] = [:], isSecure: Bool = false,
                remoteHost: String = "") {
        self.method = method
        self.path = path
        self.headers = headers
        self.isSecure = isSecure
        self.remoteHost = remoteHost
    }

    /// Parses the request line and headers of an HTTP/1.x request head.
    public static func parse(_ head: Data) -> HTTPRequest? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])
        let rawPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(parts[0]), path: rawPath.removingPercentEncoding ?? rawPath, headers: headers)
    }
}

public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// `size` is the whole file; `range` the bytes to send when answering a Range request.
        case file(URL, size: Int64, range: ClosedRange<Int64>? = nil)
    }

    /// What a `Range` header asks of a file of a given size.
    enum ByteRange: Equatable {
        /// No range, several ranges or a header we don't understand: send the whole file.
        case full
        case partial(ClosedRange<Int64>)
        case unsatisfiable
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ text: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", type)], body: .data(Data(text.utf8)))
    }

    public static let notFound = HTTPResponse.text(404, "Not found")

    var contentLength: Int64 {
        switch body {
        case .data(let data): Int64(data.count)
        case .file(_, let size, let range): range.map { $0.upperBound - $0.lowerBound + 1 } ?? size
        }
    }

    /// Answers a `Range` header on a file with 206 Partial Content. iOS installs need it: after downloading the
    /// .ipa, appstored asks again for its last bytes, and getting the whole file back makes it retry forever.
    func applyingRange(_ header: String?) -> HTTPResponse {
        guard status == 200, case .file(let url, let size, nil) = body else { return self }
        var response = self
        response.headers.append(("Accept-Ranges", "bytes"))
        guard let header else { return response }
        switch Self.byteRange(header, size: size) {
        case .full:
            return response
        case .partial(let range):
            response.status = 206
            response.headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"))
            response.body = .file(url, size: size, range: range)
            return response
        case .unsatisfiable:
            return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(size)")], body: .data(Data()))
        }
    }

    /// Parses a single `bytes=start-end`, `bytes=start-` or `bytes=-suffix` range.
    static func byteRange(_ header: String, size: Int64) -> ByteRange {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes="), !spec.contains(",") else { return .full }
        let parts = spec.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .full }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix >= 0 else { return .full }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        }
        guard let start = Int64(parts[0]), start >= 0 else { return .full }
        var end = size - 1
        if !parts[1].isEmpty {
            guard let last = Int64(parts[1]), last >= start else { return .full }
            end = min(last, size - 1)
        }
        return start < size ? .partial(start...end) : .unsatisfiable
    }

    func head() -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(contentLength)\r\nConnection: close\r\nServer: BuildCloud\r\n\r\n"
        return Data(text.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        default: "Error"
        }
    }
}

/// Minimal HTTP/1.1 server on Network.framework: GET and HEAD only, one request per connection.
/// Files are streamed in chunks so large .ipa files never sit in memory.
/// Progress of a file being sent to a client.
public struct FileTransfer: Sendable {
    public enum State: String, Sendable { case sending, completed, failed }

    public var remoteHost: String
    /// Request path, e.g. /files/debug/app/1.0-1-…/App.ipa
    public var path: String
    public var sent: Int64
    public var total: Int64
    public var state: State
}

public final class HTTPServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped, starting, running(port: UInt16), failed(String)
    }

    public typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "buildcloud.http")
    private var listener: NWListener?
    public var onStateChange: (@Sendable (State) -> Void)?
    /// Called on the server queue while files are sent; set before `start`.
    public var onFileTransfer: (@Sendable (FileTransfer) -> Void)?
    /// One line per request and per finished file transfer; set before `start`.
    public var onLog: (@Sendable (String) -> Void)?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening on `port`; with an `identity` the server speaks HTTPS instead of HTTP.
    public func start(port: UInt16, identity: SecIdentity? = nil) {
        stop()
        onStateChange?(.starting)
        do {
            let parameters: NWParameters
            if let identity, let secIdentity = sec_identity_create(identity) {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                parameters = .tcp
            }
            let isSecure = identity != nil
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
            let listener = try NWListener(using: parameters, on: nwPort)
            let onFileTransfer = onFileTransfer, onLog = onLog
            listener.newConnectionHandler = { [handler, queue] connection in
                HTTPConnection(connection: connection, handler: handler, queue: queue, isSecure: isSecure,
                               onFileTransfer: onFileTransfer, onLog: onLog).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onStateChange?(.running(port: listener.port?.rawValue ?? port))
                case .failed(let error):
                    self?.onStateChange?(.failed(error.localizedDescription))
                    listener.cancel()
                case .cancelled: break
                default: break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        guard let listener else { return }
        listener.stateUpdateHandler = nil
        listener.cancel()
        self.listener = nil
        onStateChange?(.stopped)
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private static let maxHeadSize = 64 * 1024
    private static let chunkSize = 1 << 20

    private let connection: NWConnection
    private let handler: HTTPServer.Handler
    private let queue: DispatchQueue
    private let isSecure: Bool
    private let onFileTransfer: (@Sendable (FileTransfer) -> Void)?
    private let onLog: (@Sendable (String) -> Void)?
    private var buffer = Data()
    private var transfer: FileTransfer?

    init(connection: NWConnection, handler: @escaping HTTPServer.Handler, queue: DispatchQueue, isSecure: Bool,
         onFileTransfer: (@Sendable (FileTransfer) -> Void)?, onLog: (@Sendable (String) -> Void)?) {
        self.connection = connection
        self.handler = handler
        self.queue = queue
        self.isSecure = isSecure
        self.onFileTransfer = onFileTransfer
        self.onLog = onLog
    }

    /// The client's IP without the IPv4-mapped prefix or interface suffix.
    private var remoteHost: String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "" }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text.removeFirst("::ffff:".count) }
        return text
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled: connection.stateUpdateHandler = nil  // breaks the retain cycle
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                var request = HTTPRequest.parse(buffer[..<end.lowerBound])
                request?.isSecure = isSecure
                request?.remoteHost = remoteHost
                respond(to: request)
            } else if error != nil || isComplete || buffer.count > Self.maxHeadSize {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    private func respond(to request: HTTPRequest?) {
        var response: HTTPResponse
        if let request {
            response = ["GET", "HEAD"].contains(request.method) ? handler(request) : .text(405, "Method not allowed")
            response = response.applyingRange(request.headers["range"])
        } else {
            response = .text(400, "Bad request")
        }
        let omitBody = request?.method == "HEAD"
        if let request {
            let extra = ["range", "user-agent"].compactMap { name in request.headers[name].map { "\(name)=\"\($0)\"" } }
            onLog?(([remoteHost, request.method, request.path, "→ \(response.status)"] + extra).joined(separator: " "))
        }
        connection.send(content: response.head(), completion: .contentProcessed { [self] error in
            guard error == nil, !omitBody else { return finish() }
            switch response.body {
            case .data(let data):
                connection.send(content: data, completion: .contentProcessed { [self] _ in finish() })
            case .file(let url, let size, let range):
                let offset = range?.lowerBound ?? 0
                guard let handle = try? FileHandle(forReadingFrom: url),
                      (try? handle.seek(toOffset: UInt64(offset))) != nil else { return finish() }
                // A range counts from where it starts, so the page shows e.g. 99 % → 100 % for the tail of the .ipa.
                if let request {
                    transfer = FileTransfer(remoteHost: request.remoteHost, path: request.path, sent: offset,
                                            total: size, state: .sending)
                    report()
                }
                sendChunks(from: handle, remaining: response.contentLength)
            }
        })
    }

    private func sendChunks(from handle: FileHandle, remaining: Int64) {
        let chunk = remaining > 0 ? (try? handle.read(upToCount: Int(min(Int64(Self.chunkSize), remaining)))) ?? nil : nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            transfer?.state = remaining == 0 ? .completed : .failed
            report()
            logTransfer(error: nil)
            return finish()
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if let error {
                try? handle.close()
                transfer?.state = .failed
                report()
                logTransfer(error: error)
                connection.cancel()
            } else {
                transfer?.sent += Int64(chunk.count)
                report()
                sendChunks(from: handle, remaining: remaining - Int64(chunk.count))
            }
        })
    }

    private func logTransfer(error: NWError?) {
        guard let transfer else { return }
        var line = "\(transfer.remoteHost) \(transfer.state.rawValue) \(transfer.path) \(transfer.sent)/\(transfer.total)"
        if let error { line += " error=\"\(error)\"" }
        onLog?(line)
    }

    private func report() {
        if let transfer { onFileTransfer?(transfer) }
    }

    private func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [self] _ in connection.cancel() })
    }
}
