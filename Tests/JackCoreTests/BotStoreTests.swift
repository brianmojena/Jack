import XCTest
@testable import JackCore

@MainActor final class BotStoreTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testRoutineNextRunMatchesTheAutomationItReplaces() {
        var automation = Automation(name: "A", prompt: "p", projectPath: "/tmp", provider: .claude, frequency: .weekdays,
                                    startAt: date(1, 9), createdAt: date(9, 10))
        automation.lastRunAt = date(9, 9)
        let routine = BotRoutine(agentID: UUID(), name: "A", instruction: "p", frequency: .weekdays, startAt: date(1, 9),
                                 createdAt: date(9, 10), lastRunAt: date(9, 9))
        XCTAssertEqual(routine.nextRun(calendar: calendar), automation.nextRun(calendar: calendar))
        XCTAssertEqual(routine.nextRun(calendar: calendar), date(12, 9))
    }

    func testPausedRoutineNeverRuns() {
        let routine = BotRoutine(agentID: UUID(), name: "A", instruction: "p", startAt: date(1, 9), paused: true, createdAt: date(9, 10))
        XCTAssertNil(routine.nextRun(calendar: calendar))
    }

    func testMigrationKeepsEveryAutomationAndOnlyRunsOnce() throws {
        let dir = directory()
        let store = BotStore(directory: dir)
        let old = Automation(name: "Informe", prompt: "resume", projectPath: "/tmp", provider: .codex, frequency: .daily,
                             startAt: date(1, 9), enabled: false, createdAt: date(9, 10))
        XCTAssertTrue(store.migrate([old]))
        XCTAssertEqual(store.agents.map(\.name), ["Informe"])
        XCTAssertEqual(store.routines.map(\.instruction), ["resume"])
        XCTAssertEqual(store.routines.first?.paused, true)
        XCTAssertEqual(store.routines.first?.createdAt, old.createdAt)
        XCTAssertTrue(store.migrate([old]), "A second run must be a no-op")
        XCTAssertEqual(store.agents.count, 1)
        // It is on disk before migrate returns.
        let reopened = BotStore(directory: dir)
        XCTAssertTrue(reopened.migrated)
        XCTAssertEqual(reopened.routines.count, 1)
    }

    func testDueRoutineRunsOnTheAgentAndRemembersItsConversation() {
        let store = BotStore(directory: directory())
        let agent = BotAgent(name: "Ada", projectPath: "/tmp", provider: .claude)
        store.upsert(agent)
        store.upsert(BotRoutine(agentID: agent.id, name: "R", instruction: "hola", startAt: date(1, 9), createdAt: date(1, 8)))
        let conversation = UUID()
        var sent: [String] = []
        store.run = { _, routine in sent.append(routine.instruction); return .success(conversation) }
        store.fireDue(now: date(1, 10))
        XCTAssertEqual(sent, ["hola"])
        XCTAssertEqual(store.agents.first?.conversationID, conversation)
        store.fireDue(now: date(1, 10))
        XCTAssertEqual(sent.count, 1, "It runs once per occurrence")
    }

    func testFailedRunIsRecordedAndReported() {
        let store = BotStore(directory: directory())
        let agent = BotAgent(name: "Ada", projectPath: "/nope", provider: .claude)
        store.upsert(agent)
        store.upsert(BotRoutine(agentID: agent.id, name: "R", instruction: "x", startAt: date(1, 9), createdAt: date(1, 8)))
        var reported: [String] = []
        store.onError = { reported.append($0) }
        store.run = { _, _ in .failure(.init("sin carpeta")) }
        store.fireDue(now: date(1, 10))
        XCTAssertEqual(store.routines.first?.lastError, "sin carpeta")
        XCTAssertEqual(reported.count, 1)
    }

    func testRemovingAnAgentRemovesItsRoutines() {
        let store = BotStore(directory: directory())
        let agent = BotAgent(name: "Ada", projectPath: "/tmp", provider: .claude)
        store.upsert(agent)
        store.upsert(BotRoutine(agentID: agent.id, name: "R", instruction: "x", startAt: date(1, 9)))
        store.remove(agent: agent.id)
        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertTrue(store.routines.isEmpty)
    }
}

@MainActor private final class RecordingDriver: ChatDriver {
    var prompts: [String] = []
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        prompts.append(prompt)
        onEvent(.session(UUID().uuidString))
        onEvent(.completed)
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() {}
}

@MainActor final class BotChannelTests: XCTestCase {
    private func store() -> (BotStore, BotAgent, BotAgent, BotChannel, [String]) {
        let bots = BotStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let ada = BotAgent(name: "Ada", projectPath: "/tmp", provider: .claude)
        let bruno = BotAgent(name: "Bruno", projectPath: "/tmp", provider: .codex)
        bots.upsert(ada); bots.upsert(bruno)
        let channel = BotChannel(name: "Equipo", memberIDs: [ada.id, bruno.id], ownerID: ada.id)
        bots.upsert(channel)
        return (bots, ada, bruno, channel, [])
    }

    func testUserMessageReachesOnlyTheOwner() {
        let (bots, ada, _, channel, _) = store()
        var heard: [String] = []
        bots.deliver = { agent, _ in heard.append(agent.name); return .success(UUID()) }
        XCTAssertNil(bots.post("haz el informe", inChannel: channel.id))
        XCTAssertEqual(heard, [ada.name])
        XCTAssertEqual(bots.channels.first?.messages.map(\.text), ["haz el informe"])
    }

    func testStoppedChannelKeepsHistoryButTellsNobody() {
        let (bots, _, bruno, channel, _) = store()
        var heard = 0
        bots.deliver = { _, _ in heard += 1; return .success(UUID()) }
        bots.setState(.stopped, for: channel.id)
        XCTAssertNil(bots.post("hola", inChannel: channel.id))
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(bots.channels.first?.messages.count, 1)
        guard case .failure = bots.post("sigo", from: bruno.id, inChannel: channel.id) else { return XCTFail("A stopped channel must refuse agents") }
    }

    func testArchivedChannelRefusesTheUser() {
        let (bots, _, _, channel, _) = store()
        bots.setState(.archived, for: channel.id)
        XCTAssertNotNil(bots.post("hola", inChannel: channel.id))
        XCTAssertTrue(bots.channels.first?.messages.isEmpty == true)
    }

    func testDelegationReachesOnlyTheNamedMember() throws {
        let (bots, ada, bruno, channel, _) = store()
        var heard: [String] = []
        bots.deliver = { agent, text in heard.append(agent.name + ": " + text); return .success(UUID()) }
        guard case .success = bots.post("revisa esto", from: ada.id, inChannel: channel.id, delegateTo: bruno.id) else { return XCTFail() }
        XCTAssertEqual(heard.count, 1)
        XCTAssertTrue(try XCTUnwrap(heard.first).hasPrefix("Bruno"))
        guard case .failure = bots.post("a mí", from: ada.id, inChannel: channel.id, delegateTo: ada.id) else { return XCTFail("No self-delegation") }
        guard case .failure = bots.post("x", from: UUID(), inChannel: channel.id) else { return XCTFail("Non-members cannot post") }
    }

    func testReassignOnlyToMembersAndRemovingTheOwnerPassesTheTask() {
        let (bots, ada, bruno, channel, _) = store()
        bots.setOwner(UUID(), in: channel.id)
        XCTAssertEqual(bots.channels.first?.ownerID, ada.id)
        bots.setOwner(bruno.id, in: channel.id)
        XCTAssertEqual(bots.channels.first?.ownerID, bruno.id)
        bots.remove(agent: bruno.id)
        XCTAssertEqual(bots.channels.first?.ownerID, ada.id)
        bots.remove(agent: ada.id)
        XCTAssertEqual(bots.channels.first?.state, .archived)
    }

    func testHistoryIsCapped() {
        let (bots, ada, _, channel, _) = store()
        bots.deliver = { _, _ in .success(UUID()) }
        for number in 0..<(BotChannel.maxMessages + 5) { _ = bots.post("m\(number)", from: ada.id, inChannel: channel.id) }
        XCTAssertEqual(bots.channels.first?.messages.count, BotChannel.maxMessages)
        XCTAssertEqual(bots.channels.first?.messages.last?.text, "m\(BotChannel.maxMessages + 4)")
    }

    func testChannelsSurviveARestartAndOldFilesStillLoad() throws {
        let (bots, _, _, _, _) = store()
        // A file written before channels existed has no "channels" key.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"agents":[],"routines":[],"migrated":true}"#.utf8).write(to: dir.appendingPathComponent("jackbot.json"))
        XCTAssertTrue(BotStore(directory: dir).migrated)
        XCTAssertEqual(bots.channels.count, 1)
    }

    func testAgentLookupPrefersNameThenIDPrefix() {
        let (bots, ada, _, _, _) = store()
        XCTAssertEqual(bots.agents(matching: "ada").map(\.id), [ada.id])
        XCTAssertEqual(bots.agents(matching: String(ada.id.uuidString.prefix(8))).map(\.id), [ada.id])
        XCTAssertTrue(bots.agents(matching: "zzz").isEmpty)
    }

    func testBridgeToolsOnlyForBotAgentsAndDeliverIntoTheTeammate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-bot-tools-" + UUID().uuidString)
        var drivers: [RecordingDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in
            let driver = RecordingDriver(); drivers.append(driver); return driver
        })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let ada = BotAgent(name: "Ada", projectPath: NSTemporaryDirectory(), provider: .claude)
        let bruno = BotAgent(name: "Bruno", projectPath: NSTemporaryDirectory(), provider: .claude)
        store.bots.upsert(ada); store.bots.upsert(bruno)
        let adaChat = try XCTUnwrap(store.botConversation(for: ada))
        let plain = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        let bridge = AgentBridge(store: store)

        _ = try await bridge.delegation(for: adaChat)
        _ = try await bridge.delegation(for: plain)
        func toolNames(_ caller: UUID) async -> [String] {
            let listed = await bridge.rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], caller: caller)
            return ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }
        let botTools = await toolNames(adaChat)
        XCTAssertTrue(botTools.contains("bot_send_message") && botTools.contains("channel_post"))
        let plainTools = await toolNames(plain)
        XCTAssertFalse(plainTools.contains("bot_send_message"))
        let refused = await bridge.call("bot_list_agents", arguments: [:], caller: plain)
        XCTAssertTrue(refused.1, "A normal chat must not use Jack Bot tools")
        let sent = await bridge.call("bot_send_message", arguments: ["agent": "bruno", "message": "hola", "expects_reply": true], caller: adaChat)
        XCTAssertFalse(sent.1, sent.0)
        let brunoChat = try XCTUnwrap(store.bots.agents.first { $0.id == bruno.id }?.conversationID)
        XCTAssertEqual(store.conversations.first { $0.id == brunoChat }?.botAgentID, bruno.id)
        let unknown = await bridge.call("bot_send_message", arguments: ["agent": "nadie", "message": "hola"], caller: adaChat)
        XCTAssertTrue(unknown.1)
    }
}
