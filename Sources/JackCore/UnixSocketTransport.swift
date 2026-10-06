import Foundation
import Darwin

enum HerdrTransportError: LocalizedError {
    case invalidSocketPath
    case socketFailure(String)
    case timeout
    case connectionClosed
    case lineTooLarge
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidSocketPath: "La ruta del socket de Herdr no es válida."
        case let .socketFailure(message): "No se pudo comunicar con Herdr: \(message)"
        case .timeout: "Herdr tardó demasiado en responder."
        case .connectionClosed: "La conexión con Herdr se cerró."
        case .lineTooLarge: "Herdr envió una respuesta demasiado grande."
        case .invalidResponse: "Herdr devolvió una respuesta JSON no válida."
        case let .serverError(message): message
        }
    }
}

struct JSONLineFramer {
    private(set) var buffer = Data()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 8 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            let trimmed = line.last == 0x0D ? Data(line.dropLast()) : line
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        guard buffer.count <= maximumLineBytes else { throw HerdrTransportError.lineTooLarge }
        if let largest = lines.map(\.count).max(), largest > maximumLineBytes {
            throw HerdrTransportError.lineTooLarge
        }
        return lines
    }
}

private final class UnixSocketConnection {
    private(set) var descriptor: Int32
    private let stateLock = NSLock()
    private var closed = false
    private var framer = JSONLineFramer()
    private var pendingLines: [Data] = []

    init(path: String) throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw HerdrTransportError.invalidSocketPath
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("socket") }
        descriptor = fd

        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard result == 0 else {
            let error = Self.posixError("connect")
            close()
            throw error
        }
    }

    deinit { close() }

    func sendLine(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw HerdrTransportError.lineTooLarge }
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < payload.count {
                let written = Darwin.send(descriptor, base.advanced(by: offset), payload.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError("send")
                }
                if written == 0 { throw HerdrTransportError.connectionClosed }
                offset += written
            }
        }
    }

    func readLine(timeout: TimeInterval?) throws -> Data {
        if let first = pendingLines.first {
            pendingLines.removeFirst()
            return first
        }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let remaining = deadline?.timeIntervalSinceNow
            if let remaining, remaining <= 0 { throw HerdrTransportError.timeout }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let waitMilliseconds = remaining.map { Int32(max(1, min($0 * 1000, 1000))) } ?? -1
            let ready = poll(&pollDescriptor, 1, waitMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw Self.posixError("poll")
            }
            if ready == 0 { continue }
            if pollDescriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) == 0 { continue }

            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Self.posixError("recv")
            }
            guard count > 0 else { throw HerdrTransportError.connectionClosed }
            let complete = try framer.append(Data(chunk.prefix(count)))
            if !complete.isEmpty {
                pendingLines.append(contentsOf: complete.dropFirst())
                return complete[0]
            }
        }
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    func interrupt() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    private static func posixError(_ operation: String) -> HerdrTransportError {
        let message = String(cString: strerror(errno))
        return .socketFailure("\(operation): \(message)")
    }
}

final class HerdrAPIClient: @unchecked Sendable {
    let socketPath: String
    private let subscriptionLock = NSLock()
    private var subscriptionConnection: UnixSocketConnection?
    private var subscriptionEpoch: UInt64 = 0
    private let requestTimeout: TimeInterval

    init(socketPath: String, requestTimeout: TimeInterval = 8) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
    }

    func request(method: String, params: [String: Any], timeout: TimeInterval? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [socketPath, requestTimeout] in
            let connection = try UnixSocketConnection(path: socketPath)
            defer { connection.close() }
            let requestID = "jack-\(UUID().uuidString)"
            let object: [String: Any] = ["id": requestID, "method": method, "params": params]
            let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try connection.sendLine(payload)
            let response = try connection.readLine(timeout: timeout ?? requestTimeout)
            guard let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                throw HerdrTransportError.invalidResponse
            }
            if let error = decoded["error"] as? [String: Any] {
                throw HerdrTransportError.serverError(error["message"] as? String ?? "Error de Herdr")
            }
            guard decoded["id"] as? String == requestID else { throw HerdrTransportError.invalidResponse }
            return response
        }.value
    }

    func makeSubscriptionLease() -> UInt64 {
        subscriptionLock.lock()
        defer { subscriptionLock.unlock() }
        subscriptionEpoch &+= 1
        return subscriptionEpoch
    }

    func subscribe(lease: UInt64, paneIDs: [String], onReady: @escaping () -> Void, onEvent: @escaping ([String: Any]) -> Void) throws {
        let connection = try UnixSocketConnection(path: socketPath)
        subscriptionLock.lock()
        guard subscriptionEpoch == lease else {
            subscriptionLock.unlock()
            connection.close()
            throw CancellationError()
        }
        subscriptionConnection = connection
        subscriptionLock.unlock()
        defer {
            connection.close()
            subscriptionLock.lock()
            if subscriptionConnection === connection { subscriptionConnection = nil }
            subscriptionLock.unlock()
        }

        let subscriptionTypes = [
            "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
            "workspace.moved", "workspace.reordered", "workspace.closed", "workspace.focused",
            "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
            "pane.created", "pane.closed", "pane.updated", "pane.focused", "pane.moved", "pane.exited",
            "pane.agent_detected", "layout.updated"
        ]
        let subscriptions: [[String: Any]] = subscriptionTypes.map { ["type": $0] }
            + paneIDs.sorted().map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        let requestID = "jack-sub-\(UUID().uuidString)"
        let request: [String: Any] = [
            "id": requestID,
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions]
        ]
        try connection.sendLine(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))

        var ready = false
        while true {
            let line = try connection.readLine(timeout: ready ? nil : requestTimeout)
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw HerdrTransportError.invalidResponse
            }
            if object["id"] as? String == requestID {
                if object["error"] != nil { throw HerdrTransportError.serverError("No se pudo suscribir a los eventos de Herdr.") }
                ready = true
                onReady()
                continue
            }
            if ready, object["event"] is String { onEvent(object) }
        }
    }

    func cancelSubscription() {
        subscriptionLock.lock()
        subscriptionEpoch &+= 1
        let connection = subscriptionConnection
        subscriptionConnection = nil
        subscriptionLock.unlock()
        connection?.interrupt()
    }
}
