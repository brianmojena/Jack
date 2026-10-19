import XCTest
@testable import Jack

final class AntigravityTerminalLifecycleTests: XCTestCase {
    @MainActor func testTerminationAcknowledgementComesFromTheChildExit() async throws {
        let session = TerminalSession(directory: NSTemporaryDirectory(),
                                      directLaunch: TerminalProcessLaunch(executable: "/bin/sleep", arguments: ["30"])) { _ in }
        let exited = expectation(description: "SwiftTerm confirms child exit")
        session.onProcessExit = { exited.fulfill() }
        session.terminateAfterAcknowledgement()
        XCTAssertFalse(session.hasExited, "Sending SIGTERM is not an exit acknowledgement")
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertTrue(session.hasExited)
        XCTAssertNil(session.onProcessExit)
    }
}
