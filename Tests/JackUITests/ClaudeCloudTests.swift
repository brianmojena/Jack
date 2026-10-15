import AppKit
import WebKit
import XCTest
@testable import Jack

final class ClaudeCloudTests: XCTestCase {
    @MainActor func testCloudLoginIsPersistentAndIsolatedWithoutLoadingOnConstruction() {
        _ = NSApplication.shared
        let session = ClaudeCloudSession(loadImmediately: false)
        XCTAssertNil(session.webView.url)
        XCTAssertTrue(session.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(session.webView.configuration.websiteDataStore.identifier, ClaudeCloudSession.dataStoreID)
        XCTAssertTrue(session.webView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(session.webView.uiDelegate === session)
        XCTAssertTrue(session.webView.navigationDelegate === session)
        session.stop()
    }

    @MainActor func testSuspendingCloudReleasesSessionAndDoesNotCreateOneWhenUnused() {
        _ = NSApplication.shared
        let workspace = WorkspaceSessions()
        workspace.suspendClaudeCloud()
        weak var released: ClaudeCloudSession?
        autoreleasepool {
            let session = workspace.claudeCloud()
            released = session
            XCTAssertTrue(workspace.claudeCloud() === session)
            workspace.suspendClaudeCloud()
        }
        XCTAssertNil(released, "Switching to Light must release the cloud view and its delegates")
    }
}
