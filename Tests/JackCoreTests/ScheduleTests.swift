import XCTest
@testable import JackCore

@MainActor private final class ScheduleDeliveryDriver: ChatDriver {
    let sessionID: UUID
    var prompts: [String] = []
    var onPrompt: (@MainActor (String) -> Void)?
    init(sessionID: UUID) { self.sessionID = sessionID }
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        prompts.append(prompt)
        onEvent(.session(sessionID.uuidString))
        onEvent(.completed)
        onPrompt?(prompt)
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() {}
}

@MainActor final class ScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func automation(_ frequency: AutomationFrequency, start: Date, created: Date) -> Automation {
        Automation(name: "A", prompt: "p", projectPath: "/tmp", provider: .claude, frequency: frequency, startAt: start, createdAt: created)
    }

    func testDailyRunsAtTheTimeOfDayAfterCreation() {
        let item = automation(.daily, start: date(1, 9), created: date(9, 10))
        XCTAssertEqual(item.nextRun(calendar: calendar), date(10, 9))
    }

    func testWeekdaysSkipTheWeekend() {
        // 2026-10-09 is a Friday.
        var item = automation(.weekdays, start: date(1, 9), created: date(9, 10))
        item.lastRunAt = date(9, 9)
        XCTAssertEqual(item.nextRun(calendar: calendar), date(12, 9))
    }

    func testOnceRunsOnlyOnce() {
        var item = automation(.once, start: date(10, 8), created: date(9, 10))
        XCTAssertEqual(item.nextRun(calendar: calendar), date(10, 8))
        item.lastRunAt = date(10, 8)
        XCTAssertNil(item.nextRun(calendar: calendar))
    }

    func testDisabledNeverRuns() {
        var item = automation(.daily, start: date(1, 9), created: date(9, 10))
        item.enabled = false
        XCTAssertNil(item.nextRun(calendar: calendar))
    }

    func testDueMessageIsDeliveredOnceAndRemoved() {
        let center = ScheduleCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var delivered: [String] = []
        center.deliver = { delivered.append($0.text); return .accepted }
        let conversation = UUID()
        center.schedule("hola", in: conversation, at: Date().addingTimeInterval(-1))
        center.schedule("luego", in: conversation, at: Date().addingTimeInterval(3600))
        center.fireDue()
        center.fireDue()
        XCTAssertEqual(delivered, ["hola"])
        XCTAssertEqual(center.messages(for: conversation).map(\.text), ["luego"])
    }

    func testRejectedScheduledMessageStaysPendingAndRetriesAfterBackoffUntilAccepted() {
        let center = ScheduleCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let conversation = UUID()
        let due = date(10, 8)
        var attempts = 0
        var accepted = false
        center.deliver = { _ in
            attempts += 1
            return accepted ? .accepted : .retry
        }
        center.schedule("hola", in: conversation, at: due)

        center.fireDue(now: due)
        center.fireDue(now: due.addingTimeInterval(20))
        XCTAssertEqual(attempts, 1, "A rejected delivery must not retry on every 20-second tick")
        XCTAssertEqual(center.messages(for: conversation).count, 1)

        accepted = true
        center.fireDue(now: due.addingTimeInterval(60))
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(center.messages(for: conversation).isEmpty)
    }

    func testDeletedConversationDiscardsScheduledMessageWithoutRetry() {
        let center = ScheduleCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let conversation = UUID()
        let due = date(10, 8)
        var attempts = 0
        center.deliver = { _ in attempts += 1; return .discard }
        center.schedule("hola", in: conversation, at: due)

        center.fireDue(now: due)
        center.fireDue(now: due.addingTimeInterval(20))

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(center.messages(for: conversation).isEmpty)
    }

    func testClaudeTerminalClaimKeepsScheduledMessageUntilSendIsAccepted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-schedule-delivery-" + UUID().uuidString)
        let sessionID = UUID()
        let initialPromptStarted = expectation(description: "initial prompt reaches the simulated driver")
        let scheduledPromptStarted = expectation(description: "scheduled prompt reaches the simulated driver")
        var fulfilledInitialPrompt = false
        var fulfilledScheduledPrompt = false
        var drivers: [ScheduleDeliveryDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in
            let driver = ScheduleDeliveryDriver(sessionID: sessionID)
            driver.onPrompt = { prompt in
                if prompt == "initial", !fulfilledInitialPrompt {
                    fulfilledInitialPrompt = true
                    initialPromptStarted.fulfill()
                } else if prompt == "scheduled", !fulfilledScheduledPrompt {
                    fulfilledScheduledPrompt = true
                    scheduledPromptStarted.fulfill()
                }
            }
            drivers.append(driver)
            return driver
        })
        store.gitSnapshotCaptureOverride = { _ in nil }
        store.setConcurrency(1)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }

        let conversationID = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        // This expected-Void closure also guards source compatibility after send gained its acceptance result.
        let sendFromVoidClosure: (String) -> Void = { store.send($0, to: conversationID) }
        sendFromVoidClosure("initial")
        await fulfillment(of: [initialPromptStarted], timeout: 2)
        XCTAssertEqual(store.conversations.first { $0.id == conversationID }?.sessionID, sessionID.uuidString)
        XCTAssertTrue(store.claimClaudeSessionForTerminal(sessionID))

        let due = Date()
        let schedules = store.schedules
        schedules.schedule("scheduled", in: conversationID, at: due)
        schedules.fireDue(now: due)

        XCTAssertEqual(schedules.messages(for: conversationID).map(\.text), ["scheduled"])
        XCTAssertFalse(store.conversations.first { $0.id == conversationID }?.messages.contains { $0.text == "scheduled" } == true)
        XCTAssertEqual(drivers.flatMap(\.prompts).filter { $0 == "scheduled" }.count, 0)

        store.releaseClaudeSessionFromTerminal(sessionID)
        schedules.fireDue(now: due.addingTimeInterval(60))
        await fulfillment(of: [scheduledPromptStarted], timeout: 2)
        schedules.fireDue(now: due.addingTimeInterval(61))

        XCTAssertTrue(schedules.messages(for: conversationID).isEmpty)
        XCTAssertEqual(store.conversations.first { $0.id == conversationID }?.messages.filter { $0.role == "user" && $0.text == "scheduled" }.count, 1)
        XCTAssertEqual(drivers.flatMap(\.prompts).filter { $0 == "scheduled" }.count, 1)
    }

    func testDueAutomationLaunchesAndRecordsTheRun() {
        let center = ScheduleCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let launched = UUID()
        var count = 0
        center.launch = { _ in count += 1; return .success(launched) }
        center.upsert(automation(.once, start: Date().addingTimeInterval(-60), created: Date().addingTimeInterval(-120)))
        center.fireDue()
        center.fireDue()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(center.automations.first?.lastConversationID, launched)
    }
}
