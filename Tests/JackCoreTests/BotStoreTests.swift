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
