import XCTest
@testable import JackCore

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
        center.deliver = { delivered.append($0.text); return true }
        let conversation = UUID()
        center.schedule("hola", in: conversation, at: Date().addingTimeInterval(-1))
        center.schedule("luego", in: conversation, at: Date().addingTimeInterval(3600))
        center.fireDue()
        center.fireDue()
        XCTAssertEqual(delivered, ["hola"])
        XCTAssertEqual(center.messages(for: conversation).map(\.text), ["luego"])
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
