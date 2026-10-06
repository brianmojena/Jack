import Foundation
import Darwin

final class UnixSocketFixture {
    let path: String
    private let condition = NSCondition()
    private var listener: Int32 = -1
    private var stopped = false
    private var subscriptions: [(descriptor: Int32, request: [String: Any])] = []
    private var requests: [[String: Any]] = []
    private var snapshots = 0
    private let queue = DispatchQueue(label: "JackCoreTests.UnixSocketFixture", attributes: .concurrent)
    private var sessionSnapshot: [String: Any]

    init(snapshot: [String: Any] = UnixSocketFixture.defaultSnapshot) throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jack-core-\(UUID().uuidString).sock")
            .path
        sessionSnapshot = snapshot
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.posixError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count)
        #endif
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count))
            }
        }
        guard bindResult == 0 else { throw Self.posixError("bind") }
        guard Darwin.listen(listener, 16) == 0 else { throw Self.posixError("listen") }

        let listeningFD = listener
        queue.async { [weak self] in self?.acceptConnections(on: listeningFD) }
    }

    deinit { stop() }

    var subscriptionRequests: [[String: Any]] {
        condition.lock(); defer { condition.unlock() }
        return subscriptions.map(\.request)
    }

    var allRequests: [[String: Any]] {
        condition.lock(); defer { condition.unlock() }
        return requests
    }

    func setSnapshot(_ snapshot: [String: Any]) {
        condition.lock(); sessionSnapshot = snapshot; condition.unlock()
    }

    var snapshotCount: Int {
        condition.lock(); defer { condition.unlock() }
        return snapshots
    }

    func waitForSubscriptions(_ count: Int, timeout: TimeInterval = 4) -> [[String: Any]]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while subscriptions.count < count && !stopped {
            guard condition.wait(until: deadline) else { break }
        }
        return subscriptions.count >= count ? subscriptions.map(\.request) : nil
    }

    func waitForSnapshotCount(_ count: Int, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while snapshots < count && !stopped {
            guard condition.wait(until: deadline) else { break }
        }
        return snapshots >= count
    }

    func emit(_ event: [String: Any], onSubscription index: Int) throws {
        condition.lock()
        guard subscriptions.indices.contains(index) else {
            condition.unlock()
            throw NSError(domain: "UnixSocketFixture", code: 1)
        }
        let fd = subscriptions[index].descriptor
        condition.unlock()
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0A)
        try Self.writeAll(data, to: fd)
    }

    func closeSubscription(_ index: Int) {
        condition.lock()
        guard subscriptions.indices.contains(index) else { condition.unlock(); return }
        let fd = subscriptions[index].descriptor
        subscriptions[index].descriptor = -1
        condition.unlock()
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    func stop() {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true
        let listeningFD = listener
        listener = -1
        let clients = subscriptions.map(\.descriptor).filter { $0 >= 0 }
        condition.broadcast()
        condition.unlock()
        if listeningFD >= 0 {
            _ = Darwin.shutdown(listeningFD, SHUT_RDWR)
            _ = Darwin.close(listeningFD)
        }
        for fd in clients {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptConnections(on fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                condition.lock(); let shouldStop = stopped; condition.unlock()
                if shouldStop || errno == EBADF || errno == EINVAL { return }
                if errno == EINTR { continue }
                return
            }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard let requestData = Self.readLine(from: fd),
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let id = request["id"] as? String,
              let method = request["method"] as? String else {
            _ = Darwin.close(fd)
            return
        }
        condition.lock(); requests.append(request); condition.broadcast(); condition.unlock()

        if method == "events.subscribe" {
            condition.lock()
            let index = subscriptions.count
            subscriptions.append((fd, request))
            condition.broadcast()
            condition.unlock()
            Self.send(["id": id, "result": ["type": "ok"]], to: fd)
            if index == 1 {
                try? emit(["event": "pane.agent_status_changed", "data": ["pane_id": "w1:p1", "workspace_id": "w1", "agent_status": "blocked"]], onSubscription: index)
            }
            while Self.readSome(from: fd) != nil {}
            condition.lock()
            if subscriptions.indices.contains(index), subscriptions[index].descriptor == fd {
                subscriptions[index].descriptor = -1
            }
            condition.unlock()
            _ = Darwin.close(fd)
            return
        }

        if method == "session.snapshot" {
            condition.lock(); snapshots += 1; let snapshot = sessionSnapshot; condition.broadcast(); condition.unlock()
            Self.send(["id": id, "result": ["type": "session_snapshot", "snapshot": snapshot]], to: fd)
            _ = Darwin.close(fd)
            return
        }

        if method == "tab.create" {
            Self.send(["id": id, "result": ["type": "tab_created", "tab": ["tab_id": "w1:t2", "workspace_id": "w1", "number": 2, "label": "2", "focused": true, "pane_count": 1, "agent_status": "unknown"], "root_pane": ["pane_id": "w1:p-new", "workspace_id": "w1", "tab_id": "w1:t2", "terminal_id": "term_new", "focused": true, "agent_status": "unknown", "revision": 0]]], to: fd)
        } else if method == "agent.start" {
            Self.send(["id": id, "result": ["type": "agent_started", "agent": [:], "argv": []]], to: fd)
        } else if method == "workspace.focus" {
            Self.send(["id": id, "error": ["code": "fixture_error", "message": "Focus rejected"]], to: fd)
        } else {
            Self.send(["id": id, "result": ["type": "ok"]], to: fd)
        }
        _ = Darwin.close(fd)
    }

    private static func send(_ object: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? writeAll(data, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("send")
                }
                offset += count
            }
        }
    }

    private static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        while let chunk = readSome(from: fd) {
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[..<newline])
                return data
            }
            data.append(chunk)
            if data.count > 8 * 1024 * 1024 { return nil }
        }
        return nil
    }

    private static func readSome(from fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            return Data(bytes.prefix(count))
        }
    }

    private static func posixError(_ action: String) -> NSError {
        NSError(domain: "UnixSocketFixture.\(action)", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }

    static let defaultSnapshot: [String: Any] = [
        "version": "0.9.1", "protocol": 22,
        "workspaces": [["workspace_id": "w1", "number": 1, "label": "Fixture", "focused": true, "pane_count": 1, "tab_count": 1, "active_tab_id": "w1:t1", "agent_status": "unknown"]],
        "tabs": [["tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1", "focused": true, "pane_count": 1, "agent_status": "unknown"]],
        "panes": [["pane_id": "w1:p1", "terminal_id": "term_1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": true, "agent_status": "unknown", "revision": 0, "cwd": "/tmp/project"]],
        "agents": [], "layouts": [], "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1"
    ]
}
