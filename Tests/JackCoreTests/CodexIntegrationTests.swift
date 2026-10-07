import XCTest
@testable import JackCore

final class CodexIntegrationTests: XCTestCase {
    func testPermissionProfilesRequireNormalModeAndGrantOnlyRequestedAccess() throws {
        var session: String? = "thread"
        var pending: [String: PendingApproval] = [:]
        let permissions: [String: Any] = ["network": ["enabled": true], "fileSystem": [
            "read": ["/tmp/reference"], "entries": [["access": "write", "path": ["type": "path", "path": "/tmp/output"]]]]]
        let request: [String: Any] = ["id": "permissions-1", "method": "item/permissions/requestApproval", "params": [
            "threadId": "thread", "turnId": "turn", "cwd": "/tmp/project", "reason": "Descargar y guardar", "permissions": permissions]]
        XCTAssertTrue(CodexProtocol.event(request, session: &session, approvals: &pending).isEmpty)
        XCTAssertTrue(pending.isEmpty, "Light keeps the existing protocol surface")
        let events = CodexProtocol.event(request, session: &session, approvals: &pending, permissionProfiles: true)
        guard case .approval(let approval) = events.first else { return XCTFail("Missing permission") }
        XCTAssertTrue(approval.detail.contains("Red: permitir conexiones"))
        XCTAssertTrue(approval.detail.contains("Lectura: /tmp/reference"))
        XCTAssertTrue(approval.detail.contains("Escritura: /tmp/output"))
        XCTAssertEqual(approval.choices.map(\.id), ["session"])
        let stored = try XCTUnwrap(pending[approval.id])
        for choice in ["allow", "session"] {
            let result = try CodexProtocol.approvalResult(stored, choice: choice)
            XCTAssertEqual(result["scope"] as? String, choice == "session" ? "session" : "turn")
            XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(result["permissions"] as? [String: Any])), NSDictionary(dictionary: permissions))
        }
        let denied = try CodexProtocol.approvalResult(stored, choice: "deny")
        XCTAssertTrue((denied["permissions"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(denied["scope"] as? String, "turn")
        XCTAssertThrowsError(try CodexProtocol.approvalResult(stored, choice: "unexpected"))
    }

    func testResolvedRequestsAreScopedToTheirThreadAndIncludeQuestions() throws {
        var session: String? = "thread"
        var pending: [String: PendingApproval] = [:]
        let request: [String: Any] = ["id": 51, "method": "item/commandExecution/requestApproval", "params": ["threadId": "thread", "command": "ls"]]
        _ = CodexProtocol.event(request, session: &session, approvals: &pending)
        var resolved: [String: Any] = ["method": "serverRequest/resolved", "params": ["requestId": 51, "threadId": "other"]]
        XCTAssertTrue(CodexProtocol.event(resolved, session: &session, approvals: &pending).isEmpty)
        XCTAssertNotNil(pending["codex-51"])
        resolved["params"] = ["requestId": 51, "threadId": "thread"]
        guard case .approvalResolved(let id) = CodexProtocol.event(resolved, session: &session, approvals: &pending).first else { return XCTFail("Missing resolution") }
        XCTAssertEqual(id, "codex-51")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(CodexProtocol.event(resolved, session: &session, approvals: &pending).isEmpty, "Duplicate notification is harmless")
        _ = CodexProtocol.event(["id": "question", "method": "item/tool/requestUserInput", "params": ["threadId": "thread", "questions": []]], session: &session, approvals: &pending)
        resolved["params"] = ["requestId": "question", "threadId": "thread"]
        guard case .approvalResolved(let questionID) = CodexProtocol.event(resolved, session: &session, approvals: &pending).first else { return XCTFail("Missing question resolution") }
        XCTAssertEqual(questionID, "codex-input-question")
    }

    // A local stdio fixture exercises the real driver without inference, credentials or a listener.
    private func fixture(_ scenario: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-codex-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("codex")
        let source = #"""
        #!/usr/bin/python3
        import json, sys, time, threading, os
        from pathlib import Path
        folder = Path(__file__).parent
        scenario = "SCENARIO"
        deadline = threading.Timer(5, lambda: os._exit(1))
        deadline.daemon = True
        deadline.start()
        def send(value):
            print(json.dumps(value), flush=True)
        def emit(method, params):
            send({"method": method, "params": params})
        def completed(status="completed"):
            emit("turn/completed", {"threadId": "thread", "turn": {"id": "turn", "status": status}})
        for line in sys.stdin:
            value = json.loads(line)
            with (folder / "wire.jsonl").open("a") as log:
                log.write(json.dumps(value) + "\n")
            method = value.get("method")
            if method == "initialize":
                send({"id": value["id"], "result": {}})
            elif method in ["thread/start", "thread/resume"]:
                send({"id": value["id"], "result": {"thread": {"id": "thread"}}})
            elif method == "turn/start":
                if scenario == "delayed":
                    emit("item/agentMessage/delta", {"threadId": "thread", "itemId": "ready", "delta": "submitted"})
                    time.sleep(0.15)
                send({"id": value["id"], "result": {"turn": {"id": "turn", "status": "inProgress"}}})
                emit("turn/started", {"threadId": "thread", "turn": {"id": "turn", "status": "inProgress"}})
                if scenario in ["permissions", "resolved", "light-permissions", "switch-light"]:
                    send({"id": "permission", "method": "item/permissions/requestApproval", "params": {"threadId": "thread", "turnId": "turn", "cwd": str(folder), "permissions": {"network": {"enabled": True}}}})
                    if scenario == "resolved":
                        emit("serverRequest/resolved", {"threadId": "thread", "requestId": "permission"})
                        emit("item/agentMessage/delta", {"threadId": "thread", "itemId": "ready", "delta": "ready"})
                else:
                    emit("item/agentMessage/delta", {"threadId": "thread", "itemId": "ready", "delta": "ready"})
            elif method == "turn/interrupt":
                send({"id": value["id"], "result": {}})
                emit("item/commandExecution/outputDelta", {"threadId": "thread", "itemId": "late", "delta": "late"})
                if scenario != "no-ack":
                    time.sleep(0.05)
                    completed("interrupted")
            elif value.get("id") == "permission":
                emit("serverRequest/resolved", {"threadId": "thread", "requestId": "permission"})
                completed()
        """#.replacingOccurrences(of: "SCENARIO", with: scenario)
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return folder
    }

    private func wire(_ folder: URL) -> [[String: Any]] {
        let value = (try? String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8)) ?? ""
        return value.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    @MainActor func testStopUsesInterruptAndAcknowledgesInterruptedTurnWithoutFailure() async throws {
        for scenario in ["interrupt", "delayed", "no-ack"] {
            let folder = try fixture(scenario)
            let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path, interruptDeadline: .milliseconds(400))
            defer { driver.close(); try? FileManager.default.removeItem(at: folder) }
            var ready = false, completed = false, failure: String?
            let task = Task {
                try await driver.run(conversation: ChatConversation(projectPath: folder.path), prompt: "test") { event in
                    if case .text = event, !ready { ready = true; driver.stop() }
                    if case .completed = event { completed = true }
                    if case .failure(let message) = event { failure = message }
                }
            }
            for _ in 0..<200 where !completed { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(ready, scenario)
            XCTAssertTrue(completed, scenario)
            XCTAssertNil(failure, scenario)
            _ = try? await task.value
            let requests = wire(folder).filter { $0["method"] as? String == "turn/interrupt" }
            XCTAssertEqual(requests.count, 1, "Even before turn/start returns, interruption is sent once")
            let params = requests.first?["params"] as? [String: Any]
            XCTAssertEqual(params?["threadId"] as? String, "thread")
            XCTAssertEqual(params?["turnId"] as? String, "turn")
            XCTAssertFalse(driver.awaitsStopAcknowledgement)
        }
    }

    @MainActor func testPermissionsUseWireResponseAndLightRejectsNewRequestType() async throws {
        for scenario in ["permissions", "light-permissions", "switch-light"] {
            let folder = try fixture(scenario)
            let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
            driver.setEnergySaving(scenario == "light-permissions")
            defer { driver.close(); try? FileManager.default.removeItem(at: folder) }
            var permission: ChatApproval?
            let task = Task {
                try await driver.run(conversation: ChatConversation(projectPath: folder.path), prompt: "test") { event in
                    if case .approval(let value) = event {
                        permission = value
                        if scenario == "switch-light" { driver.setEnergySaving(true) }
                        else { Task { try await driver.respond(approvalID: value.id, choice: "allow", message: nil) } }
                    }
                }
            }
            try await task.value
            let response = try XCTUnwrap(wire(folder).first { $0["id"] as? String == "permission" })
            XCTAssertEqual(wire(folder).filter { $0["id"] as? String == "permission" }.count, 1)
            if scenario == "light-permissions" {
                XCTAssertNil(permission)
                XCTAssertNotNil(response["error"], "Light retains the unsupported-request behavior")
            } else {
                XCTAssertNotNil(permission)
                let result = try XCTUnwrap(response["result"] as? [String: Any])
                XCTAssertEqual(result["scope"] as? String, "turn")
                let profile = try XCTUnwrap(result["permissions"] as? [String: Any])
                if scenario == "switch-light" { XCTAssertTrue(profile.isEmpty) }
                else { XCTAssertEqual((profile["network"] as? [String: Any])?["enabled"] as? Bool, true) }
            }
        }
    }

    @MainActor func testStoreWaitsForInterruptAndDiscardsLateActivity() async throws {
        let folder = try fixture("interrupt")
        let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("archive")), preferences: nil, driverFactory: { _ in driver })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex))
        store.send("test", to: id)
        for _ in 0..<200 where !store.transcript(of: id).contains(where: { $0.text == "ready" }) { try await Task.sleep(for: .milliseconds(10)) }
        store.stop(id)
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertTrue(store.isBusy(id), "The slot stays reserved until Codex acknowledges the interruption")
        for _ in 0..<200 where store.isBusy(id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy(id))
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertFalse(store.transcript(of: id).contains { $0.id == "late" || $0.role == "error" })
        XCTAssertEqual(wire(folder).filter { $0["method"] as? String == "turn/interrupt" }.count, 1)
    }

    @MainActor func testServerClearedPermissionRestoresRunningStateWithoutUserResponse() async throws {
        let folder = try fixture("resolved")
        let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("archive")), preferences: nil, driverFactory: { _ in driver })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex))
        store.send("test", to: id)
        for _ in 0..<200 where !store.transcript(of: id).contains(where: { $0.text == "ready" }) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.approvals[id]?.isEmpty == true)
        XCTAssertEqual(store.statuses[id], .running)
        XCTAssertTrue(store.isBusy(id))
        store.stop(id)
        for _ in 0..<200 where store.isBusy(id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testLightStopsProcessWithoutNativeInterrupt() async throws {
        let folder = try fixture("interrupt")
        let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
        driver.setEnergySaving(true)
        defer { driver.close(); try? FileManager.default.removeItem(at: folder) }
        var ready = false
        do {
            try await driver.run(conversation: ChatConversation(projectPath: folder.path), prompt: "test") { event in
                if case .text = event { ready = true; driver.stop() }
            }
        } catch {}
        XCTAssertTrue(ready)
        XCTAssertFalse(driver.awaitsStopAcknowledgement)
        XCTAssertFalse(wire(folder).contains { $0["method"] as? String == "turn/interrupt" })
    }

    @MainActor func testStopClearsPermissionAndLateResponseDoesNotShowError() async throws {
        let folder = try fixture("permissions")
        let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("archive")), preferences: nil, driverFactory: { _ in driver })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex))
        store.send("test", to: id)
        for _ in 0..<200 where store.approvals[id]?.isEmpty != false { try await Task.sleep(for: .milliseconds(10)) }
        let request = try XCTUnwrap(store.approvals[id]?.first)
        store.respond(conversationID: id, approvalID: request.id, allow: true)
        // Stop before the asynchronous response executes.
        store.stop(id)
        XCTAssertTrue(store.approvals[id]?.isEmpty == true)
        for _ in 0..<200 where store.isBusy(id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(wire(folder).contains { $0["id"] as? String == "permission" }, "Stopping cannot grant the pending permission")
    }

    @MainActor func testSendingWaitingMessageInterruptsBeforeStartingNextTurn() async throws {
        let folder = try fixture("interrupt")
        var drivers: [CodexChatDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("archive")), preferences: nil, driverFactory: { _ in
            let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
            drivers.append(driver)
            return driver
        })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex))
        store.send("first", to: id)
        for _ in 0..<200 where !store.transcript(of: id).contains(where: { $0.text == "ready" }) { try await Task.sleep(for: .milliseconds(10)) }
        store.send("follow", to: id, interrupting: true)
        XCTAssertEqual(drivers.count, 1)
        XCTAssertTrue(drivers[0].awaitsStopAcknowledgement)
        for _ in 0..<200 where drivers.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(drivers.count, 2)
        XCTAssertTrue(store.transcript(of: id).contains { $0.role == "user" && $0.text == "follow" })
        XCTAssertFalse(store.transcript(of: id).contains { $0.role == "error" || $0.id == "late" })
        XCTAssertNil(store.waiting[id])
    }

    @MainActor func testSwitchingToLightDuringInterruptionReleasesSlotImmediately() async throws {
        let folder = try fixture("no-ack")
        let driver = CodexChatDriver(executable: folder.appendingPathComponent("codex").path)
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("archive")), preferences: nil, driverFactory: { _ in driver })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex))
        store.send("test", to: id)
        for _ in 0..<200 where !store.transcript(of: id).contains(where: { $0.text == "ready" }) { try await Task.sleep(for: .milliseconds(10)) }
        store.stop(id)
        XCTAssertTrue(driver.awaitsStopAcknowledgement)
        store.setLightMode(true)
        XCTAssertFalse(driver.awaitsStopAcknowledgement)
        XCTAssertFalse(store.isBusy(id))
        XCTAssertEqual(store.statuses[id], .idle)
    }
}
