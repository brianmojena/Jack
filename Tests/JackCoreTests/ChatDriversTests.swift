import Foundation
import XCTest
@testable import JackCore

final class ChatDriversTests: XCTestCase {
    func testCodexApprovalIsSurfacedAndRetainedForExplicitResponse() {
        var session: String?
        var approvals: [String: PendingApproval] = [:]
        let events = CodexProtocol.event([
            "id": 51,
            "method": "item/commandExecution/requestApproval",
            "params": ["threadId": "thread-a", "turnId": "turn-a", "itemId": "item-a", "command": "git status", "cwd": "/workspace"]
        ], session: &session, approvals: &approvals)

        guard case .approval(let approval) = events.first else { return XCTFail("Expected approval event") }
        XCTAssertEqual(approval.id, "codex-51")
        XCTAssertTrue(approval.detail.contains("git status"))
        XCTAssertEqual(approvals[approval.id]?.payload["rpcID"] as? Int, 51)
        XCTAssertEqual(approvals[approval.id]?.payload["method"] as? String, "item/commandExecution/requestApproval")
    }

    func testCodexFailedTurnSurfacesFailureInsteadOfCompletion() {
        var session: String?
        var approvals: [String: PendingApproval] = [:]
        let events = CodexProtocol.event([
            "method": "turn/completed",
            "params": ["turn": ["id": "turn-a", "status": "failed", "error": ["message": "tool crashed"]]]
        ], session: &session, approvals: &approvals)

        guard case .failure(let message) = events.first else { return XCTFail("Expected failed turn event") }
        XCTAssertEqual(message, "tool crashed")
    }

    func testClaudeStreamingTextUsesNativeMessageAndBlockAndSkipsDuplicateSnapshot() {
        var decoder = ClaudeProtocol.Decoder()
        let start = ["type": "stream_event", "event": ["type": "message_start", "message": ["id": "msg-native"]]] as [String: Any]
        _ = decoder.events(start)
        let first = decoder.events(["type": "stream_event", "event": ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": "hello"]]])
        let second = decoder.events(["type": "stream_event", "event": ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": " world"]]])
        let snapshot = decoder.events(["type": "assistant", "message": ["id": "msg-native", "content": [["type": "thinking", "thinking": "reason"], ["type": "redacted_thinking", "data": "redacted"], ["type": "text", "text": "hello world"]]]])

        guard case .text(let id1, let text1, let replace1) = first.first,
              case .text(let id2, let text2, let replace2) = second.first else { return XCTFail("Expected text deltas") }
        XCTAssertEqual(id1, "msg-native:2")
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(text1, "hello")
        XCTAssertEqual(text2, " world")
        XCTAssertFalse(replace1)
        XCTAssertFalse(replace2)
        XCTAssertFalse(snapshot.contains { event in if case .text(let id, _, _) = event { return id == "msg-native:2" }; return false })
    }

    func testClaudePerBlockSnapshotsKeepToolAndReasoningApart() {
        var decoder = ClaudeProtocol.Decoder()
        _ = decoder.events(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "m"]]])
        _ = decoder.events(["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]])
        let started = decoder.events(["type": "stream_event", "event": ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "Bash"]]])
        // The CLI then sends one snapshot per block, each with a single content entry.
        _ = decoder.events(["type": "assistant", "message": ["id": "m", "content": [["type": "thinking", "thinking": ""]]]])
        let snapshot = decoder.events(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "echo hi"]]]]])
        let result = decoder.events(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "hi", "is_error": false]]]])

        guard case .tool(let startedID, _, _, _) = started.first,
              case .tool(let snapshotID, _, _, _) = snapshot.first,
              case .tool(let resultID, _, _, let status) = result.first else { return XCTFail("Expected tool events") }
        XCTAssertEqual(startedID, "m:1")
        XCTAssertEqual(snapshotID, "m:1")
        XCTAssertEqual(resultID, "m:1")
        XCTAssertEqual(status, "completed")
    }

    func testClaudeHostApprovalPreservesOriginalInputForAllow() {
        var decoder = ClaudeProtocol.Decoder()
        let events = decoder.events(["type": "control_request", "request_id": "permission-a", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "swift test"]]])
        guard case .approval(let approval) = events.first else { return XCTFail("Expected approval") }
        XCTAssertEqual(approval.id, "permission-a")
        XCTAssertEqual(decoder.approvals[approval.id]?.payload["input"] as? [String: String], ["command": "swift test"])
    }

    func testOpenCodePermissionIsScopedToCurrentSessionAndCanBeAnswered() {
        var approvals: [String: PendingApproval] = [:]
        let otherProps: [String: Any] = ["id": "permission-other", "sessionID": "session-other", "permission": "bash", "patterns": ["echo hi"], "metadata": [:] as [String: Any], "always": [] as [String]]
        let unrelated = OpenCodeProtocol.events(["payload": ["type": "permission.asked", "properties": otherProps]], sessionID: "session-current", approvals: &approvals)
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertTrue(approvals.isEmpty)

        let currentProps: [String: Any] = ["id": "permission-current", "sessionID": "session-current", "permission": "bash", "patterns": ["git status"], "metadata": ["command": "git status"], "always": ["bash git status"]]
        let current = OpenCodeProtocol.events(["payload": ["type": "permission.asked", "properties": currentProps]], sessionID: "session-current", approvals: &approvals)
        guard case .approval(let approval) = current.first else { return XCTFail("Expected current-session permission") }
        XCTAssertEqual(approval.id, "opencode:permission-current")
        XCTAssertEqual(approvals[approval.id]?.payload["sessionID"] as? String, "session-current")
        XCTAssertEqual(approval.title, "Ejecutar un comando")
        XCTAssertEqual(approval.tool, "bash")
        XCTAssertEqual(approval.choices.map(\.id), ["always"])
    }

    func testOpenCodeQuestionAskedSurfacesApprovalWithQuestions() {
        var approvals: [String: PendingApproval] = [:]
        let otherQuestion: [String: Any] = ["question": "Q?", "header": "H", "options": [["label": "A", "description": "d"]]]
        let unrelated = OpenCodeProtocol.events(["payload": ["type": "question.asked", "properties": ["id": "que-other", "sessionID": "session-other", "questions": [otherQuestion]]]], sessionID: "session-current", approvals: &approvals)
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertTrue(approvals.isEmpty)

        let red: [String: Any] = ["label": "Red", "description": "Red color"]
        let blue: [String: Any] = ["label": "Blue", "description": "Blue color"]
        let colorQuestion: [String: Any] = ["question": "Which color?", "header": "Color", "options": [red, blue], "multiple": false]
        let event = OpenCodeProtocol.events(["payload": ["type": "question.asked", "properties": ["id": "que-1", "sessionID": "session-current", "questions": [colorQuestion]]]], sessionID: "session-current", approvals: &approvals)
        guard case .approval(let approval) = event.first else { return XCTFail("Expected question approval") }
        XCTAssertEqual(approval.id, "opencode:que-1")
        XCTAssertEqual(approval.questions.count, 1)
        XCTAssertEqual(approval.questions[0].question, "Which color?")
        XCTAssertEqual(approval.questions[0].options?.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(approvals[approval.id]?.payload["questionID"] as? String, "que-1")

        let replied = OpenCodeProtocol.events(["payload": ["type": "question.replied", "properties": ["sessionID": "session-current", "requestID": "que-1"]]], sessionID: "session-current", approvals: &approvals)
        guard case .approvalResolved(let resolvedID) = replied.first else { return XCTFail("Expected approval resolution") }
        XCTAssertEqual(resolvedID, "opencode:que-1")
    }

    func testOpenCodeTodoUpdatedEmitsLiveTaskList() {
        var approvals: [String: PendingApproval] = [:]
        let todo1: [String: Any] = ["content": "setup", "status": "in_progress", "priority": "high"]
        let todo2: [String: Any] = ["content": "test", "status": "pending", "priority": "medium"]
        let todoProps: [String: Any] = ["sessionID": "s1", "todos": [todo1, todo2]]
        let events = OpenCodeProtocol.events(["payload": ["type": "todo.updated", "properties": todoProps]], sessionID: "s1", approvals: &approvals)
        guard case .tool(let id, let title, let detail, let status) = events.first else { return XCTFail("Expected todo tool event") }
        XCTAssertEqual(title, "todowrite")
        XCTAssertEqual(status, "running")
        XCTAssertTrue(detail.contains("setup"))
        XCTAssertTrue(id.hasPrefix("todo:"))
    }

    func testOpenCodeToolKeepsRawNameAndMapsErrorToFailed() {
        var approvals: [String: PendingApproval] = [:]
        let completed: [String: Any] = ["id": "prt-1", "sessionID": "s1", "messageID": "m1", "type": "tool", "tool": "todowrite",
            "state": ["status": "completed", "input": ["todos": [] as [Any]], "output": "[]", "title": "2 todos"] as [String: Any]]
        let events = OpenCodeProtocol.events(["payload": ["type": "message.part.updated", "properties": ["sessionID": "s1", "part": completed]]], sessionID: "s1", approvals: &approvals)
        guard case .tool(_, let title, _, let status) = events.first else { return XCTFail("Expected tool event") }
        XCTAssertEqual(title, "todowrite")
        XCTAssertEqual(status, "completed")

        let failed: [String: Any] = ["id": "prt-2", "sessionID": "s1", "messageID": "m1", "type": "tool", "tool": "bash",
            "state": ["status": "error", "input": ["command": "exit 1"], "error": "boom"] as [String: Any]]
        let failedEvents = OpenCodeProtocol.events(["payload": ["type": "message.part.updated", "properties": ["sessionID": "s1", "part": failed]]], sessionID: "s1", approvals: &approvals)
        guard case .tool(_, _, _, let failedStatus) = failedEvents.first else { return XCTFail("Expected failed tool event") }
        XCTAssertEqual(failedStatus, "failed")
    }

    func testOpenCodeStreamsTextDeltasAndSessionCompletion() {
        var approvals: [String: PendingApproval] = [:]
        let delta = OpenCodeProtocol.events(["payload": ["type": "message.part.delta", "properties": ["sessionID": "s1", "partID": "part-1", "messageID": "m1", "field": "text", "delta": "hello"]]], sessionID: "s1", approvals: &approvals)
        guard case .text(let id, let text, let replace) = delta.first else { return XCTFail("Expected text delta") }
        XCTAssertEqual(id, "part-1")
        XCTAssertEqual(text, "hello")
        XCTAssertFalse(replace)

        let done = OpenCodeProtocol.events(["payload": ["type": "session.idle", "properties": ["sessionID": "s1"]]], sessionID: "s1", approvals: &approvals)
        guard case .completed = done.first else { return XCTFail("Expected completion") }
    }

    func testToolDetailsAreBoundedTo64KB() {
        var decoder = ClaudeProtocol.Decoder()
        let events = decoder.events(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "name": "Read", "input": ["content": String(repeating: "x", count: 1_000_000)]]]]])
        guard case .tool(_, _, let detail, _) = events.first else { return XCTFail("Expected tool event") }
        XCTAssertLessThanOrEqual(detail.utf8.count, 65_636)
        XCTAssertTrue(detail.contains("truncated"))
    }
}
