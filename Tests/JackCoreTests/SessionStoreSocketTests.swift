import Foundation
import Combine
import XCTest
@testable import JackCore

@MainActor
final class SessionStoreSocketTests: XCTestCase {
    func testIdenticalSnapshotsDoNotRepublishSidebarState() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        try await store.refresh()
        try await store.refresh()
        try await store.refresh()
        XCTAssertEqual(server.snapshotCount, 3)
        XCTAssertEqual(publications, 1, "Repeated terminal events must not redraw an unchanged sidebar")

        var changed = UnixSocketFixture.defaultSnapshot
        changed["focused_workspace_id"] = "another-project"
        server.setSnapshot(changed)
        try await store.refresh()
        XCTAssertEqual(publications, 2, "Real state changes must still reach the UI")
    }

    func testBootstrapSubscribesBeforeSnapshotAndScopesAgentStatusPerPane() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)
        defer { store.disconnect() }

        store.connect()
        let bootstrapped = await eventually(timeout: 5) { server.subscriptionRequests.count >= 2 }
        XCTAssertTrue(bootstrapped, "state=\(store.connectionState), error=\(String(describing: store.errorMessage)), requests=\(server.allRequests.count)")
        let subscriptions = server.subscriptionRequests
        let eventsRefreshed = await eventually(timeout: 5) { server.snapshotCount >= 3 }
        XCTAssertTrue(eventsRefreshed)

        let firstParams = try XCTUnwrap(subscriptions[0]["params"] as? [String: Any])
        let firstSubscriptions = try XCTUnwrap(firstParams["subscriptions"] as? [[String: Any]])
        XCTAssertFalse(firstSubscriptions.contains { $0["type"] as? String == "pane.agent_status_changed" })

        let paneParams = try XCTUnwrap(subscriptions[1]["params"] as? [String: Any])
        let paneSubscriptions = try XCTUnwrap(paneParams["subscriptions"] as? [[String: Any]])
        XCTAssertTrue(paneSubscriptions.contains {
            $0["type"] as? String == "pane.agent_status_changed" && $0["pane_id"] as? String == "w1:p1"
        })
        XCTAssertTrue(paneSubscriptions.contains { $0["type"] as? String == "workspace.created" })
        XCTAssertEqual(store.snapshot.panes.map(\.id), ["w1:p1"])

        server.closeSubscription(1)
        let reconnected = await eventually(timeout: 5) { server.subscriptionRequests.count >= 3 }
        XCTAssertTrue(reconnected)
        let afterReconnect = server.subscriptionRequests
        let thirdParams = try XCTUnwrap(afterReconnect[2]["params"] as? [String: Any])
        let thirdSubscriptions = try XCTUnwrap(thirdParams["subscriptions"] as? [[String: Any]])
        XCTAssertTrue(thirdSubscriptions.contains {
            $0["type"] as? String == "pane.agent_status_changed" && $0["pane_id"] as? String == "w1:p1"
        })

        store.disconnect()
        store.connect()
        let newGenerationConnected = await eventually(timeout: 5) { server.subscriptionRequests.count >= 4 }
        XCTAssertTrue(newGenerationConnected)
        let afterNewGeneration = server.subscriptionRequests
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertNotNil(afterNewGeneration[3]["id"] as? String)
        store.disconnect()
    }

    func testCreateAgentTabUsesReturnedPaneIDAndBoundedUniqueAgentName() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)

        let paneID = try await store.createAgentTab(kind: .codex, workspaceID: "w1")
        XCTAssertEqual(paneID, "w1:p-new")
        let requests = server.allRequests
        let create = try XCTUnwrap(requests.first { $0["method"] as? String == "tab.create" })
        XCTAssertEqual((create["params"] as? [String: Any])?["workspace_id"] as? String, "w1")
        let start = try XCTUnwrap(requests.first { $0["method"] as? String == "agent.start" })
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(params["pane_id"] as? String, paneID)
        XCTAssertEqual(params["kind"] as? String, "codex")
        let name = try XCTUnwrap(params["name"] as? String)
        XCTAssertEqual(name, name.lowercased())
        XCTAssertLessThanOrEqual(name.count, 32)
        XCTAssertEqual(params["timeout_ms"] as? Int, 120_000)
    }

    func testTopologyEventsReconfigurePaneScopedStatusSubscriptions() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)
        defer { store.disconnect() }

        store.connect()
        let bootstrapped = await eventually(timeout: 5) { server.subscriptionRequests.count >= 2 }
        XCTAssertTrue(bootstrapped)

        var addedSnapshot = UnixSocketFixture.defaultSnapshot
        addedSnapshot["panes"] = [
            ["pane_id": "w1:p1", "terminal_id": "term_1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": true, "agent_status": "unknown", "revision": 0, "cwd": "/tmp/project"],
            ["pane_id": "w1:p2", "terminal_id": "term_2", "workspace_id": "w1", "tab_id": "w1:t1", "focused": false, "agent_status": "unknown", "revision": 0, "cwd": "/tmp/project"]
        ]
        server.setSnapshot(addedSnapshot)
        try server.emit(["event": "pane.created", "data": ["type": "pane_created"]], onSubscription: 1)
        let addedScope = await eventually(timeout: 5) { server.subscriptionRequests.count >= 3 }
        XCTAssertTrue(addedScope)
        XCTAssertEqual(try paneIDs(in: server.subscriptionRequests[2]), Set(["w1:p1", "w1:p2"]))

        var removedSnapshot = addedSnapshot
        let addedPanes = try XCTUnwrap(addedSnapshot["panes"] as? [[String: Any]])
        removedSnapshot["panes"] = [addedPanes[1]]
        server.setSnapshot(removedSnapshot)
        try server.emit(["event": "pane.closed", "data": ["type": "pane_closed"]], onSubscription: 2)
        let removedScope = await eventually(timeout: 5) { server.subscriptionRequests.count >= 4 }
        XCTAssertTrue(removedScope)
        XCTAssertEqual(try paneIDs(in: server.subscriptionRequests[3]), Set(["w1:p2"]))
    }

    func testImmediateDisconnectThenReconnectDoesNotLeaveAnOldSubscription() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)

        store.connect()
        store.disconnect()
        store.connect()

        let connected = await eventually(timeout: 5) { server.subscriptionRequests.count >= 2 }
        XCTAssertTrue(connected)
        XCTAssertEqual(store.connectionState, .connected)
        store.disconnect()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(server.subscriptionRequests.count, 2)
    }

    func testRefreshWorksBeforeConnectAndPropagatesTransportErrors() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)
        try await store.refresh()
        XCTAssertEqual(store.snapshot.workspaces.map(\.id), ["w1"])

        let missing = SessionStore(socketPath: server.path + ".missing")
        do {
            try await missing.refresh()
            XCTFail("Expected the missing socket to throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testSessionActionsPropagateServerErrorsToCaller() async throws {
        let server = try UnixSocketFixture()
        defer { server.stop() }
        let store = SessionStore(socketPath: server.path)

        do {
            try await store.focusWorkspace("w1")
            XCTFail("Expected the server error to propagate")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Focus rejected")
        }
    }

    private func eventually(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func paneIDs(in request: [String: Any]) throws -> Set<String> {
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let subscriptions = try XCTUnwrap(params["subscriptions"] as? [[String: Any]])
        return Set(subscriptions.compactMap { subscription in
            guard subscription["type"] as? String == "pane.agent_status_changed" else { return nil }
            return subscription["pane_id"] as? String
        })
    }
}
