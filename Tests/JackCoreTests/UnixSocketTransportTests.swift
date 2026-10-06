import Foundation
import XCTest
@testable import JackCore

final class UnixSocketTransportTests: XCTestCase {
    func testLineFramerHandlesFragmentationAndCoalescedFrames() throws {
        var framer = JSONLineFramer(maximumLineBytes: 64)
        XCTAssertEqual(try framer.append(Data(#"{"id":"one"}"#.utf8)), [])
        XCTAssertEqual(try framer.append(Data("\n{\"id\":\"two\"}\n{\"id\"".utf8)), [Data(#"{"id":"one"}"#.utf8), Data(#"{"id":"two"}"#.utf8)])
        XCTAssertEqual(try framer.append(Data(":\"three\"}\r\n".utf8)), [Data(#"{"id":"three"}"#.utf8)])
    }

    func testLineFramerBoundsIncompleteAndCompleteFrames() throws {
        var incomplete = JSONLineFramer(maximumLineBytes: 4)
        XCTAssertThrowsError(try incomplete.append(Data("12345".utf8)))

        var complete = JSONLineFramer(maximumLineBytes: 4)
        XCTAssertThrowsError(try complete.append(Data("12345\n".utf8)))
    }

    func testChildEnvironmentRemovesOnlyHerdrContextAndAddsStandardPaths() {
        let environment = ExecutableResolver.sanitizedChildEnvironment([
            "HERDR_PANE_ID": "p-1",
            "HERDR_WORKSPACE_ID": "w-1",
            "PATH": "/custom/bin:/usr/bin",
            "HOME": "/Users/test",
            "ANTHROPIC_API_KEY": "kept"
        ])
        XCTAssertNil(environment["HERDR_PANE_ID"])
        XCTAssertNil(environment["HERDR_WORKSPACE_ID"])
        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "kept")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin") == true)
        XCTAssertEqual(environment["PATH"]?.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count, 1)
    }

    func testDefaultSocketPathUsesHerdrConfigDirectory() {
        XCTAssertTrue(ExecutableResolver.defaultSocketPath.hasSuffix("/.config/herdr/herdr.sock"))
    }
}
