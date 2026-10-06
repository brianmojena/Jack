import Foundation
import XCTest
@testable import JackCore

final class ModelsTests: XCTestCase {
    func testDecodesHerdrProtocol22SnapshotEnvelopeAndReconcilesRelationships() throws {
        let json = #"""
        {
          "id": "probe",
          "result": {
            "type": "session_snapshot",
            "snapshot": {
              "version": "0.9.1",
              "protocol": 22,
              "workspaces": [
                {"workspace_id":"w1","number":1,"label":"Proyecto","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"working","future_field":{"ignored":true}},
                {"workspace_id":"w2","number":2,"label":"Otro","focused":false,"pane_count":0,"tab_count":0,"active_tab_id":"w2:t1","agent_status":"unknown"}
              ],
              "tabs": [
                {"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,"pane_count":2,"agent_status":"working"},
                {"tab_id":"orphan:t1","workspace_id":"missing","number":1,"label":"bad","focused":false,"pane_count":0,"agent_status":"unknown"}
              ],
              "panes": [
                {"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"working","revision":7,"cwd":"/tmp/project","foreground_cwd":"/tmp/project","terminal_title":"Codex","terminal_title_stripped":"Codex task","agent":"codex","name":"Build agent","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":24},"unmodeled_optional":"future"},
                {"pane_id":"orphan:p1","terminal_id":"term_b","workspace_id":"missing","tab_id":"orphan:t1","focused":false,"agent_status":"idle","revision":0}
              ],
              "agents": [
                {"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"working","revision":7,"cwd":"/tmp/project","agent":"codex","name":"Build agent"},
                {"pane_id":"orphan:p1","terminal_id":"term_b","workspace_id":"missing","tab_id":"orphan:t1","focused":false,"agent_status":"idle","revision":0}
              ],
              "layouts": [],
              "focused_workspace_id":"w1",
              "focused_tab_id":"w1:t1",
              "focused_pane_id":"w1:p1"
            }
          }
        }
        """#

        let snapshot = try HerdrSnapshot.decodeAPIResponse(Data(json.utf8))
        XCTAssertEqual(snapshot.workspaces, [WorkspaceInfo(id: "w1", label: "Proyecto", cwd: "/tmp/project"), WorkspaceInfo(id: "w2", label: "Otro", cwd: "")])
        XCTAssertEqual(snapshot.tabs.map(\.id), ["w1:t1"])
        XCTAssertEqual(snapshot.panes.map(\.id), ["w1:p1"])
        XCTAssertEqual(snapshot.agents, [AgentInfo(id: "w1:p1", workspaceID: "w1", tabID: "w1:t1", kind: "codex", name: "Build agent", status: .working)])
        XCTAssertEqual(snapshot.focusedWorkspaceID, "w1")
        XCTAssertEqual(snapshot.focusedTabID, "w1:t1")
        XCTAssertEqual(snapshot.focusedPaneID, "w1:p1")
    }

    func testUnknownAgentStatusDecodesAsUnknown() throws {
        let status = try JSONDecoder().decode(AgentStatus.self, from: Data(#""FutureState""#.utf8))
        XCTAssertEqual(status, .unknown)
        XCTAssertEqual(AgentStatus.blocked.displayName, "Bloqueado")
    }

    func testAcceptsBareSnapshotAndRejectsServerError() throws {
        let bare = #"{"workspaces":[],"tabs":[],"panes":[],"agents":[],"protocol":22}"#
        XCTAssertEqual(try HerdrSnapshot.decodeAPIResponse(Data(bare.utf8)), HerdrSnapshot())

        let failure = #"{"id":"probe","error":{"code":"bad_request","message":"Invalid request"}}"#
        XCTAssertThrowsError(try HerdrSnapshot.decodeAPIResponse(Data(failure.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid request")
        }
    }

    func testReconciliationDropsOnlyEntitiesWithBrokenParentsAndClearsStaleFocus() {
        let original = HerdrSnapshot(
            workspaces: [WorkspaceInfo(id: "w1", label: "One", cwd: "")],
            tabs: [TabInfo(id: "t1", workspaceID: "w1", label: "1"), TabInfo(id: "t2", workspaceID: "missing", label: "2")],
            panes: [PaneInfo(id: "p1", workspaceID: "w1", tabID: "t1", label: "A", cwd: "/tmp"), PaneInfo(id: "p2", workspaceID: "w1", tabID: "t2", label: "B", cwd: "/tmp")],
            agents: [AgentInfo(id: "p1", workspaceID: "w1", tabID: "t1", kind: "claude", name: "Claude", status: .blocked), AgentInfo(id: "p2", workspaceID: "w1", tabID: "t2", kind: "codex", name: "Codex", status: .working)],
            focusedWorkspaceID: "missing", focusedTabID: "t2", focusedPaneID: "p2"
        )

        let result = SnapshotReconciler.reconcile(original)
        XCTAssertEqual(result.tabs.map(\.id), ["t1"])
        XCTAssertEqual(result.panes.map(\.id), ["p1"])
        XCTAssertEqual(result.agents.map(\.id), ["p1"])
        XCTAssertNil(result.focusedWorkspaceID)
        XCTAssertNil(result.focusedTabID)
        XCTAssertNil(result.focusedPaneID)
    }
}
