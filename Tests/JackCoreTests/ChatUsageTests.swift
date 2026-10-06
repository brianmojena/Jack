import XCTest
@testable import JackCore

final class ChatUsageTests: XCTestCase {
    func testCodexMultipleQuotaBucketsRemainSeparateAndMissingPercentStaysUnknown() {
        let value = UsageDecoder.codex(["rateLimitsByLimitId": [
            "codex": ["primary": ["usedPercent": 23, "windowDurationMins": 300], "secondary": ["usedPercent": 44, "windowDurationMins": 10080]],
            "luna": ["limitName": "Luna", "primary": ["usedPercent": 11, "windowDurationMins": 300]]
        ]])
        XCTAssertEqual(value.windows.count, 3)
        XCTAssertEqual(value.windows.first { $0.id == "codex:primary" }?.remainingPercent, 77)
        XCTAssertEqual(value.windows.first { $0.id == "luna:primary" }?.remainingPercent, 89)
        XCTAssertTrue(UsageDecoder.codex([:]).windows.isEmpty)
        XCTAssertEqual(UsageDecoder.codex(["rateLimitsByLimitId": [:], "rateLimits": ["primary": ["usedPercent": 50]]]).windows.first?.remainingPercent, 50)
        XCTAssertNil(UsageWindow(id: "u", title: "unknown", usedPercent: nil).remainingPercent)
    }
    func testClaudeCachePreservesObservationTimeAndNativeEventUsesFractionUnits() {
        let stamp = Date().addingTimeInterval(-3600)
        let value = UsageDecoder.claudeCache(["cachedUsageUtilization": ["fetchedAtMs": stamp.timeIntervalSince1970 * 1000, "utilization": ["five_hour": ["utilization": 6]]]])
        XCTAssertTrue(value.isCached)
        XCTAssertEqual(value.windows.first?.remainingPercent, 94)
        XCTAssertEqual(value.windows.first?.observedAt.timeIntervalSince1970 ?? 0, stamp.timeIntervalSince1970, accuracy: 0.001)
        let event = UsageDecoder.claudeEvent(["rate_limit_info": ["rateLimitType": "five_hour", "status": "allowed_warning", "utilization": 0.82]])
        XCTAssertEqual(event?.windows.first?.remainingPercent ?? 0, 18, accuracy: 0.001)
    }
    func testClaudeUnifiedWindowsReportEveryQuota() throws {
        let event = try XCTUnwrap(UsageDecoder.claudeEvent(["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed", "resetsAt": 1791234600, "rateLimitType": "five_hour",
            "unifiedWindows": ["five_hour": ["utilization": 0.77, "resetsAt": 1791234600], "seven_day": ["utilization": 0.56, "resetsAt": 1791486000]]]]))
        XCTAssertEqual(event.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(event.windows[0].usedPercent ?? 0, 77, accuracy: 0.001)
        XCTAssertEqual(event.windows[0].title, "5 h")
        XCTAssertNil(UsageDecoder.claudeEvent(["rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour"]]), "an event without a percentage must not hide the last reading")
        XCTAssertEqual(UsageDecoder.claudeEvent(["rate_limit_info": ["status": "rejected", "rateLimitType": "five_hour"]])?.windows.first?.usedPercent, 100)
    }
    func testClaudeCacheIncludesModelScopedWeeklyLimit() {
        let value = UsageDecoder.claudeCache(["cachedUsageUtilization": ["fetchedAtMs": Date().timeIntervalSince1970 * 1000, "utilization": [
            "five_hour": ["utilization": 6], "seven_day": ["utilization": 44],
            "limits": [["kind": "weekly_scoped", "percent": 3, "scope": ["model": ["display_name": "Fable"]]]]]]])
        XCTAssertEqual(value.windows.map(\.title), ["5 h", "7 d", "Fable · 7 d"])
        XCTAssertFalse(value.isCached)
    }
    func testExpiredWindowNeverInventsARefreshedBalance() {
        let value = UsageWindow(id: "expired", title: "5 h", usedPercent: 99, resetsAt: Date().addingTimeInterval(-1))
        XCTAssertNil(value.remainingPercent)
    }
    func testCodexReasoningAndCommandOutputAreForwardedAsDifferentEvents() {
        var session: String?
        var approvals: [String: PendingApproval] = [:]
        let events = CodexProtocol.event(["method": "item/reasoning/summaryTextDelta", "params": ["itemId": "r", "delta": "Inspect dependencies"]], session: &session, approvals: &approvals)
        guard case .reasoning(let id, let text, let replace) = events.first else { return XCTFail("Missing reasoning") }
        XCTAssertEqual(id, "r:summary"); XCTAssertEqual(text, "Inspect dependencies"); XCTAssertFalse(replace)
        let output = CodexProtocol.event(["method": "item/commandExecution/outputDelta", "params": ["itemId": "c", "delta": "Build passed"]], session: &session, approvals: &approvals)
        guard case .toolOutput(let commandID, let detail) = output.first else { return XCTFail("Missing tool output") }
        XCTAssertEqual(commandID, "c"); XCTAssertEqual(detail, "Build passed")
    }
    func testClaudeThinkingAndToolResultsPreserveNativeToolIdentity() {
        var decoder = ClaudeProtocol.Decoder()
        _ = decoder.events(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "m"]]])
        let thought = decoder.events(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Checking files"]]])
        guard case .reasoning(_, let text, _) = thought.first else { return XCTFail("Missing thinking") }
        XCTAssertEqual(text, "Checking files")
        _ = decoder.events(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "id": "native-tool", "name": "Read", "input": ["file_path": "a.swift"]]]]])
        let result = decoder.events(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "native-tool", "content": "File content"]]]])
        guard case .tool(let id, let name, let output, let status) = result.first else { return XCTFail("Missing tool result") }
        XCTAssertEqual(id, "m:tool:0", "Must not reuse the thinking block id"); XCTAssertEqual(name, "Read"); XCTAssertEqual(output, "{\"file_path\":\"a.swift\"}\nFile content"); XCTAssertEqual(status, "completed")
    }
    func testOpenCodeUserEchoIsHiddenAndReasoningDeltasAreVisible() {
        var approvals: [String: PendingApproval] = [:]
        let echo = OpenCodeProtocol.events(["type": "message.part.delta", "properties": ["sessionID": "s", "messageID": "u", "partID": "p", "field": "text", "delta": "User prompt"]], sessionID: "s", approvals: &approvals, messageRoles: ["u": "user"])
        XCTAssertTrue(echo.isEmpty)
        let reasoning = OpenCodeProtocol.events(["type": "message.part.delta", "properties": ["sessionID": "s", "messageID": "a", "partID": "r", "field": "text", "delta": "Checking"]], sessionID: "s", approvals: &approvals, partTypes: ["r": "reasoning"])
        guard case .reasoning(let id, let text, _) = reasoning.first else { return XCTFail("Missing reasoning") }
        XCTAssertEqual(id, "r"); XCTAssertEqual(text, "Checking")
    }
}
