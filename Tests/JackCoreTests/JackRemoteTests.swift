import Network
import XCTest
@testable import JackCore

@MainActor private final class RemoteDriver: ChatDriver {
    var callback: (@MainActor (ChatEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var prompt = ""
    var answers: [(String, String)] = []
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        self.prompt = prompt; callback = onEvent
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws { answers.append((approvalID, allow ? "allow" : "deny")) }
    func respond(approvalID: String, choice: String, message: String?) async throws { answers.append((approvalID, choice)) }
    func stop() { finish() }
    func finish() { continuation?.resume(); continuation = nil }
}

/// What Pixel does on the iPhone, reduced to its essentials.
private final class RemoteClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "jack-remote-test-client")
    private let lock = NSLock()
    private var received: [JackRemote.Event] = []
    private var buffer = Data()
    private var ready = false
    private var failed = false

    init(port: UInt16, code: String) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: JackRemote.parameters(pairingCode: code))
    }

    func connect() async -> Bool {
        connection.stateUpdateHandler = { [self] state in
            lock.withLock {
                switch state {
                case .ready: ready = true
                case .failed, .waiting, .cancelled: failed = true
                default: break
                }
            }
        }
        connection.start(queue: queue)
        receive()
        for _ in 0..<150 {
            let (isReady, hasFailed) = lock.withLock { (ready, failed) }
            if isReady { return true }
            if hasFailed { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
                let events = JackRemote.takeLines(from: &buffer).compactMap { try? JSONDecoder().decode(JackRemote.Event.self, from: $0) }
                lock.withLock { received.append(contentsOf: events) }
            }
            if !isComplete, error == nil { receive() }
        }
    }

    func send(_ request: JackRemote.Request) {
        connection.send(content: JackRemote.encodeLine(request), completion: .idempotent)
    }

    /// Takes the first event that matches, waiting up to five seconds.
    func next(_ matches: (JackRemote.Event) -> Bool) async -> JackRemote.Event? {
        for _ in 0..<250 {
            let found: JackRemote.Event? = lock.withLock {
                guard let index = received.firstIndex(where: matches) else { return nil }
                return received.remove(at: index)
            }
            if let found { return found }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func close() { connection.cancel() }
}

final class JackRemoteTests: XCTestCase {
    private let code = "ABCD-EFGH-JKMN-PQRS"

    func testPairingCodesAreLongAndNormalized() {
        let generated = JackRemote.newPairingCode()
        XCTAssertEqual(generated.count, 19)
        XCTAssertTrue(JackRemote.isValid(generated))
        XCTAssertEqual(JackRemote.normalize("abcd-efgh jkmn-pqrs"), "ABCDEFGHJKMNPQRS")
        XCTAssertFalse(JackRemote.isValid("ABCD-EFGH"))
    }

    func testLineFramingKeepsPartialLines() {
        var buffer = Data("{\"a\":1}\n{\"b\"".utf8)
        XCTAssertEqual(JackRemote.takeLines(from: &buffer).count, 1)
        buffer.append(Data(":2}\n".utf8))
        XCTAssertEqual(JackRemote.takeLines(from: &buffer).map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}"])
    }

    @MainActor func testLightModeNeverListens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-remote-tests-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in RemoteDriver() }, lightMode: true)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let server = JackRemoteServer(store: store, port: 0, advertises: false, pairingCode: code)
        server.start()
        XCTAssertEqual(server.status, .off)
        store.applyRemote(enabled: true)
        XCTAssertNil(store.remoteServer, "Light must not even create the server")
    }

    @MainActor func testWrongCodeNeverConnects() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-remote-tests-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in RemoteDriver() })
        let server = JackRemoteServer(store: store, port: 0, advertises: false, pairingCode: code)
        defer { server.stop(); store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        server.start()
        try await until { server.status == .ready }
        let intruder = RemoteClient(port: try XCTUnwrap(server.listeningPort), code: "ZZZZ-ZZZZ-ZZZZ-ZZZZ")
        let connected = await intruder.connect()
        XCTAssertFalse(connected)
        XCTAssertEqual(server.clientCount, 0)
        intruder.close()
    }

    @MainActor func testPixelDrivesAnAgent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-remote-tests-" + UUID().uuidString)
        var drivers: [RemoteDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in let driver = RemoteDriver(); drivers.append(driver); return driver })
        let server = JackRemoteServer(store: store, port: 0, advertises: false, pairingCode: code)
        defer { server.stop(); store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let project = NSTemporaryDirectory()
        let agent = try XCTUnwrap(store.create(projectPath: project, provider: .claude, title: "Revisar"))

        server.start()
        try await until { server.status == .ready }
        let client = RemoteClient(port: try XCTUnwrap(server.listeningPort), code: code)
        let connected = await client.connect()
        XCTAssertTrue(connected)
        defer { client.close() }
        try await until { server.clientCount == 1 }

        client.send(.init(id: "1", type: .hello))
        let hello = await client.next { $0.type == .hello && $0.id == "1" }
        XCTAssertEqual(hello?.version, JackRemote.version)

        client.send(.init(id: "2", type: .list))
        let list = await client.next { $0.type == .agents }
        XCTAssertEqual(list?.agents?.map(\.title), ["Revisar"])
        XCTAssertEqual(list?.agents?.first?.id, agent.uuidString)
        XCTAssertEqual(list?.projects, [project])

        client.send(.init(id: "3", type: .open, agent: agent.uuidString))
        let opened = await client.next { $0.type == .transcript }
        XCTAssertEqual(opened?.messages?.count, 0)

        client.send(.init(id: "4", type: .send, agent: agent.uuidString, text: "Revisa los tests"))
        let sent = await client.next { $0.type == .ok && $0.id == "4" }
        XCTAssertNotNil(sent)
        try await until { drivers.first?.callback != nil }
        XCTAssertEqual(drivers[0].prompt, "Revisa los tests")
        let user = await client.next { $0.type == .transcript || $0.type == .messages }
        XCTAssertEqual(user?.messages?.last?.text, "Revisa los tests")

        drivers[0].callback?(.text(id: "m1", text: "Voy a mirarlo", replace: false))
        let reply = await client.next { $0.type == .messages && $0.messages?.contains { $0.text == "Voy a mirarlo" } == true }
        XCTAssertEqual(reply?.messages?.first { $0.id == "m1" }?.role, "assistant")

        var approval = ChatApproval(id: "a1", title: "Ejecutar", detail: "swift test")
        approval.tool = "Bash"
        drivers[0].callback?(.approval(approval))
        let waiting = await client.next { $0.type == .state && $0.approvals?.count == 1 }
        XCTAssertEqual(waiting?.approvals?.first?.id, "a1")
        XCTAssertEqual(waiting?.summary?.status, "waiting")

        client.send(.init(id: "5", type: .respond, agent: agent.uuidString, approval: "nope", choice: "allow"))
        let stale = await client.next { $0.type == .error && $0.id == "5" }
        XCTAssertNotNil(stale, "A request that is no longer open is refused")

        client.send(.init(id: "6", type: .respond, agent: agent.uuidString, approval: "a1", choice: "allow"))
        let answered = await client.next { $0.type == .ok && $0.id == "6" }
        XCTAssertNotNil(answered)
        try await until { drivers[0].answers.count == 1 }
        XCTAssertEqual(drivers[0].answers.first?.0, "a1")
        XCTAssertEqual(drivers[0].answers.first?.1, "allow")
    }

    @MainActor func testCreateOnlyInKnownFolders() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-remote-tests-" + UUID().uuidString)
        var drivers: [RemoteDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in let driver = RemoteDriver(); drivers.append(driver); return driver })
        let server = JackRemoteServer(store: store, port: 0, advertises: false, pairingCode: code)
        defer { server.stop(); store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let project = NSTemporaryDirectory()
        _ = store.create(projectPath: project, provider: .claude)
        do {
            server.start()
            try await until { server.status == .ready }
            let client = RemoteClient(port: try XCTUnwrap(server.listeningPort), code: code)
            let connected = await client.connect()
            XCTAssertTrue(connected)
            defer { client.close() }
            let selected = store.selectedID

            client.send(.init(id: "1", type: .create, text: "Haz algo", project: "/etc", provider: "claude"))
            let refused = await client.next { $0.type == .error && $0.id == "1" }
            XCTAssertNotNil(refused, "Only folders of existing agents are accepted")
            XCTAssertEqual(store.conversations.count, 1)

            client.send(.init(id: "2", type: .create, text: "Haz algo", project: project, provider: "codex"))
            let created = await client.next { $0.type == .ok && $0.id == "2" }
            let newID = try XCTUnwrap(created?.agent.flatMap(UUID.init(uuidString:)))
            XCTAssertEqual(store.conversations.first { $0.id == newID }?.provider, .codex)
            XCTAssertEqual(store.selectedID, selected, "A remote agent must not steal the Mac's selection")
            try await until { drivers.contains { $0.prompt == "Haz algo" } }
        }
    }

    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
}
