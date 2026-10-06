import XCTest
@testable import JackCore

final class ChatProcessTests: XCTestCase {
    func testSmallHandshakeIsDeliveredWhileChildWaitsForInput() async throws {
        let child = try StructuredChild(executable: "/bin/sh", arguments: ["-c", "printf '{\"ready\":true}\\n'; read line; printf '{\"reply\":true}\\n'; read line"], directory: NSTemporaryDirectory())
        let deadline = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { child.terminate() } }
        defer { deadline.cancel(); child.terminate() }
        let reader = StructuredLineReader(child.lines)
        let first = try await reader.next()
        XCTAssertEqual(first.flatMap { String(data: $0, encoding: .utf8) }, "{\"ready\":true}")
        try child.writeJSON(["hello": true])
        let second = try await reader.next()
        XCTAssertEqual(second.flatMap { String(data: $0, encoding: .utf8) }, "{\"reply\":true}")
        child.terminate(); await child.waitForExit()
    }
    func testStderrAbovePipeCapacityDoesNotBlockStructuredOutput() async throws {
        let child = try StructuredChild(executable: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=4096 count=40 1>&2 2>/dev/null; printf '{\"done\":true}\\n'; read line"], directory: NSTemporaryDirectory())
        let deadline = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { child.terminate() } }
        defer { deadline.cancel(); child.terminate() }
        var iterator = child.lines.makeAsyncIterator()
        let line = try await iterator.next()
        XCTAssertEqual(line.flatMap { String(data: $0, encoding: .utf8) }, "{\"done\":true}")
        child.terminate(); await child.waitForExit()
    }
}
