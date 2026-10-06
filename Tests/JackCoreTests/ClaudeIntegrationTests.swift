import XCTest
@testable import JackCore

/// A driver that keeps its agent open between turns, like Claude Code's.
@MainActor private final class LiveDriver: ChatDriver {
    var callback: (@MainActor (ChatEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var idle: (@MainActor (ChatEvent) -> Void)?
    var unprompted: (@MainActor () -> Void)?
    var runs = 0, follows = 0, interrupts = 0, closed = 0
    var injected: [String] = []
    var queued: [String] = []
    var keptQueued: [Bool] = []
    var modes: [String] = []
    var responses: [(String, String, String?)] = []

    var keepsAlive: Bool { true }
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        runs += 1
        callback = onEvent
        await withCheckedContinuation { continuation = $0 }
    }
    func follow(onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        follows += 1
        callback = onEvent
        await withCheckedContinuation { continuation = $0 }
    }
    func observe(idle: @escaping @MainActor (ChatEvent) -> Void, unprompted: @escaping @MainActor () -> Void) {
        self.idle = idle
        self.unprompted = unprompted
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func respond(approvalID: String, choice: String, message: String?) async throws { responses.append((approvalID, choice, message)) }
    func inject(_ message: ChatQueuedMessage, conversation: ChatConversation) -> Bool { injected.append(message.text); queued.append(message.id); return true }
    func withdraw(messageID: String) async -> Bool {
        guard queued.contains(messageID) else { return false }
        queued.removeAll { $0 == messageID }; return true
    }
    func isQueued(_ messageID: String) -> Bool { queued.contains(messageID) }
    func stop(keepingQueued: Bool) { keptQueued.append(keepingQueued); interrupts += 1; if !keepingQueued { queued.removeAll() } }
    /// The agent reads a queued message between steps.
    func read(_ index: Int = 0) { let id = queued.remove(at: index); callback?(.delivered(id: id, text: injected.last ?? "")) }
    func setMode(_ mode: String) -> Bool { modes.append(mode); return true }
    func stop() { stop(keepingQueued: false) }
    func close() { closed += 1 }
    func finish() { continuation?.resume(); continuation = nil }
}

final class ClaudeIntegrationTests: XCTestCase {
    @MainActor private func fixture() -> (ChatStore, URL, () -> [LiveDriver]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-live-tests-" + UUID().uuidString)
        var drivers: [LiveDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in let driver = LiveDriver(); drivers.append(driver); return driver })
        return (store, folder, { drivers })
    }
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 80_000_000) }

    @MainActor func testKeptAliveDriverIsReusedTakesMessagesMidTurnAndInterruptsInsteadOfCancelling() async throws {
        let (store, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("primero"); await settle()
        let driver = try XCTUnwrap(drivers().first)
        XCTAssertTrue(store.canSend(to: id))
        store.send("y además esto", to: id)
        XCTAssertEqual(driver.injected, ["y además esto"])
        XCTAssertEqual(store.waiting[id]?.map(\.text), ["y además esto"])
        XCTAssertEqual(store.waiting[id]?.first?.sent, true)
        XCTAssertEqual(store.selectedConversation?.messages.map(\.text), ["primero"], "it waits until the agent reads it")
        driver.callback?(.text(id: "a1", text: "trabajando", replace: true))
        driver.read(); await settle()
        XCTAssertNil(store.waiting[id])
        XCTAssertEqual(store.selectedConversation?.messages.map(\.text), ["primero", "trabajando", "y además esto"])

        store.stop(id)
        XCTAssertEqual(driver.interrupts, 1)
        XCTAssertEqual(store.statuses[id], .running, "the turn ends when the agent confirms the interrupt")
        driver.callback?(.completed); driver.finish(); await settle()
        XCTAssertEqual(store.statuses[id], .idle)

        store.send("segundo"); await settle()
        XCTAssertEqual(drivers().count, 1, "the same process serves the next turn")
        XCTAssertEqual(driver.runs, 2)
        driver.finish(); await settle()
    }

    @MainActor func testStoppingReturnsWaitingMessagesAndInterruptingKeepsThemQueued() async throws {
        let (store, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("primero"); await settle()
        let driver = try XCTUnwrap(drivers().first)

        store.send("uno", to: id)
        store.send("dos", attachments: ["/tmp/a.png"], to: id)
        let edited = await store.withdraw(try XCTUnwrap(store.waiting[id]?.first?.id), from: id)
        XCTAssertEqual(edited?.text, "uno")
        XCTAssertEqual(driver.queued.count, 1, "withdrawing takes it back from the agent")
        store.stop(id)
        XCTAssertEqual(driver.keptQueued, [false])
        XCTAssertNil(store.waiting[id])
        XCTAssertEqual(store.recalled[id]?.text, "dos")
        XCTAssertEqual(store.recalled[id]?.attachments, ["/tmp/a.png"])
        driver.callback?(.completed); driver.finish(); await settle()
        store.clearRecalled(id)

        store.send("segundo"); await settle()
        store.send("urgente", to: id, interrupting: true)
        XCTAssertEqual(driver.keptQueued, [false, true], "the agent reads it right after the interruption")
        XCTAssertEqual(store.waiting[id]?.map(\.text), ["urgente"])
        driver.callback?(.completed); driver.finish(); await settle()
        XCTAssertEqual(store.waiting[id]?.map(\.text), ["urgente"], "still held by the agent, which starts a turn for it")
        XCTAssertEqual(driver.runs, 2, "Jack does not send it again")
        driver.unprompted?(); await settle()
        driver.read(); await settle()
        XCTAssertNil(store.waiting[id])
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "urgente")
        driver.callback?(.completed); driver.finish(); await settle()
    }

    @MainActor func testMessagesForAgentsThatCannotReadMidTurnAreSentWhenTheTurnEnds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-wait-tests-" + UUID().uuidString)
        var prompts: [String] = []
        var finish: CheckedContinuation<Void, Never>?
        final class TurnDriver: ChatDriver {
            let started: (String) -> Void
            var continuation: (CheckedContinuation<Void, Never>) -> Void
            init(started: @escaping (String) -> Void, continuation: @escaping (CheckedContinuation<Void, Never>) -> Void) { self.started = started; self.continuation = continuation }
            func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
                started(prompt); await withCheckedContinuation { continuation($0) }
            }
            func respond(approvalID: String, allow: Bool) async throws {}
            func stop() {}
        }
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in
            TurnDriver(started: { prompts.append($0) }, continuation: { finish = $0 })
        })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        store.send("primero"); await settle()
        store.send("a", to: id); store.send("b", to: id)
        XCTAssertEqual(store.waiting[id]?.map(\.sent), [false, false])
        finish?.resume(); finish = nil; await settle()
        XCTAssertEqual(prompts, ["primero", "a\n\nb"], "held messages go out together as the next turn")
        XCTAssertNil(store.waiting[id])
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "a\n\nb")
        finish?.resume(); await settle()
    }

    @MainActor func testAgentStartsTurnByItselfAndIdleEventsUpdateTheTranscript() async throws {
        let (store, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("lanza un subagente"); await settle()
        let driver = try XCTUnwrap(drivers().first)
        driver.callback?(.tool(id: "agent", title: "Agent", detail: "{}", status: "background"))
        driver.callback?(.completed); driver.finish(); await settle()
        XCTAssertEqual(store.selectedConversation?.messages.last?.status, "background", "background work is not settled as interrupted")

        driver.idle?(.tool(id: "agent", title: "Agent", detail: "{}\nlisto", status: "completed"))
        XCTAssertEqual(store.selectedConversation?.messages.last?.status, "completed")

        driver.unprompted?(); await settle()
        XCTAssertEqual(driver.follows, 1)
        XCTAssertEqual(store.statuses[id], .running)
        driver.callback?(.text(id: "report", text: "El subagente terminó", replace: true))
        driver.callback?(.completed); driver.finish(); await settle()
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "El subagente terminó")
    }

    @MainActor func testModeChangesLiveAndTypingRejectsPendingPermissionWithReason() async throws {
        let (store, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("edita algo"); await settle()
        let driver = try XCTUnwrap(drivers().first)
        store.cycleMode(id)
        XCTAssertEqual(driver.modes, ["acceptEdits"])
        XCTAssertEqual(store.selectedConversation?.mode, "acceptEdits")
        driver.callback?(.mode("plan"))
        XCTAssertEqual(store.selectedConversation?.mode, "plan", "the agent's own mode changes reach the picker")

        driver.callback?(.approval(ChatApproval(id: "p1", title: "Ejecutar un comando", detail: "{}")))
        XCTAssertEqual(store.statuses[id], .waiting)
        store.send("no, usa make", to: id); await settle()
        XCTAssertEqual(driver.responses.first?.0, "p1")
        XCTAssertEqual(driver.responses.first?.1, "deny")
        XCTAssertEqual(driver.responses.first?.2, "no, usa make")
        XCTAssertTrue(driver.injected.isEmpty)
        driver.finish(); await settle()
    }

    @MainActor func testRemovingConversationClosesItsProcess() async throws {
        let (store, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("hola"); await settle()
        let driver = try XCTUnwrap(drivers().first)
        driver.finish(); await settle()
        store.remove(id)
        XCTAssertEqual(driver.closed, 1)
    }
}

final class ClaudeProtocolTests: XCTestCase {
    func testQuestionsPlanAndPermissionsBecomeRichApprovals() {
        var decoder = ClaudeProtocol.Decoder()
        let question = decoder.events(["type": "control_request", "request_id": "q", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": [
            "questions": [["question": "¿Qué color?", "header": "Color", "multiSelect": true, "options": [["label": "Rojo", "description": "cálido"], ["label": "Azul", "description": "frío"]]]]]]])
        guard case .approval(let ask) = question.first else { return XCTFail("Expected questions") }
        XCTAssertEqual(ask.questions.first?.id, "¿Qué color?")
        XCTAssertEqual(ask.questions.first?.multiSelect, true)
        XCTAssertEqual(ask.questions.first?.options?.map(\.label), ["Rojo", "Azul"])
        let answered = ClaudeProtocol.questionResponse(decoder.approvals["q"]!, answers: ["¿Qué color?": "Rojo, Azul"])
        XCTAssertEqual((answered["updatedInput"] as? [String: Any])?["answers"] as? [String: String], ["¿Qué color?": "Rojo, Azul"])

        let plan = decoder.events(["type": "control_request", "request_id": "p", "request": ["subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "# Plan\n1. Hacerlo"]]])
        guard case .approval(let review) = plan.first else { return XCTFail("Expected plan") }
        XCTAssertTrue(review.isPlan)
        XCTAssertEqual(review.detail, "# Plan\n1. Hacerlo")
        XCTAssertEqual(review.choices.map(\.id), ["plan.acceptEdits", "plan.manual", "deny"])
        let approved = ClaudeProtocol.permissionResponse(decoder.approvals["p"]!, choice: "plan.acceptEdits", message: nil)
        XCTAssertEqual((approved["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "acceptEdits")
        let keepPlanning = ClaudeProtocol.permissionResponse(decoder.approvals["p"]!, choice: "deny", message: "añade tests")
        XCTAssertEqual(keepPlanning["behavior"] as? String, "deny")
        XCTAssertTrue((keepPlanning["message"] as? String)?.contains("añade tests") == true)

        let suggestions: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test *"]], "behavior": "allow", "destination": "localSettings"]]
        let bash = decoder.events(["type": "control_request", "request_id": "b", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "npm test"], "permission_suggestions": suggestions]])
        guard case .approval(let permission) = bash.first else { return XCTFail("Expected permission") }
        XCTAssertEqual(permission.title, "Ejecutar un comando")
        XCTAssertEqual(permission.tool, "Bash")
        XCTAssertEqual(permission.choices.first?.title, "Permitir siempre Bash(npm test *) en este proyecto")
        let always = ClaudeProtocol.permissionResponse(decoder.approvals["b"]!, choice: "always", message: nil)
        XCTAssertEqual((always["updatedPermissions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((always["updatedInput"] as? [String: Any])?["command"] as? String, "npm test")
    }

    func testModeSubagentsAndBackgroundTasks() {
        var decoder = ClaudeProtocol.Decoder()
        guard case .mode(let mode) = decoder.events(["type": "system", "subtype": "status", "status": NSNull(), "permissionMode": "default"]).first else { return XCTFail("Expected mode") }
        XCTAssertEqual(mode, "manual")

        _ = decoder.events(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "id": "agent-1", "name": "Agent", "input": ["description": "Leer", "prompt": "lee a.txt"]]]]])
        guard case .tool(_, _, _, let started) = decoder.events(["type": "system", "subtype": "task_started", "tool_use_id": "agent-1", "is_backgrounded": true]).first else { return XCTFail("Expected background start") }
        XCTAssertEqual(started, "background")
        XCTAssertTrue(decoder.events(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "agent-1", "content": [["type": "text", "text": "Async agent launched"]]]]]]).isEmpty,
                      "the launch receipt does not complete the row")
        let child = decoder.events(["type": "assistant", "parent_tool_use_id": "agent-1", "message": ["id": "c", "content": [["type": "tool_use", "id": "child-1", "name": "Bash", "input": ["command": "cat a.txt"]]]]])
        guard case .tool(let rowID, _, let progress, let status) = child.first else { return XCTFail("Expected subagent progress on its row") }
        XCTAssertEqual(rowID, "m:0")
        XCTAssertTrue(progress.contains("› Bash cat a.txt"))
        XCTAssertEqual(status, "background")
        XCTAssertTrue(decoder.events(["type": "user", "parent_tool_use_id": "agent-1", "message": ["content": [["type": "tool_result", "tool_use_id": "child-1", "content": "hola"]]]]).isEmpty)
        let done = decoder.events(["type": "system", "subtype": "task_notification", "tool_use_id": "agent-1", "status": "completed", "summary": "Contiene hola"])
        guard case .tool(_, _, let detail, let finished) = done.first else { return XCTFail("Expected completion") }
        XCTAssertEqual(finished, "completed")
        XCTAssertTrue(detail.hasSuffix("Contiene hola"))

        _ = decoder.events(["type": "system", "subtype": "background_tasks_changed", "tasks": [["task_id": "x"]]])
        XCTAssertEqual(decoder.backgroundTaskCount, 1)
        XCTAssertTrue(decoder.events(["type": "assistant", "message": ["id": "n", "content": [["type": "tool_use", "id": "ts", "name": "ToolSearch", "input": ["query": "select:TaskCreate"]]]]]).isEmpty)
        XCTAssertTrue(ClaudeProtocol.startsTurn(["type": "system", "subtype": "status", "status": "requesting"]))
        XCTAssertFalse(ClaudeProtocol.startsTurn(["type": "assistant", "parent_tool_use_id": "agent-1"]))
    }

    func testLaunchSignatureIgnoresWhatChangesLive() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude, model: "opus", effort: "high")
        let before = ChatRunConfiguration.claudeLaunchSignature(conversation)
        conversation.mode = "plan"; conversation.model = "sonnet"
        XCTAssertEqual(ChatRunConfiguration.claudeLaunchSignature(conversation), before)
        conversation.extraDirectories = ["/var"]
        XCTAssertNotEqual(ChatRunConfiguration.claudeLaunchSignature(conversation), before)
    }
}

final class ClaudeSessionsTests: XCTestCase {
    func testFolderNameMatchesTheCLI() {
        XCTAssertEqual(ClaudeSessions.folderName(for: "/Users/brian/Documents/Trabajo/Proyectos Privados/Jack"), "-Users-brian-Documents-Trabajo-Proyectos-Privados-Jack")
        XCTAssertEqual(ClaudeSessions.folderName(for: "/private/tmp/cc.probe"), "-private-tmp-cc-probe")
    }

    func testTranscriptAndSummaryReadTheSavedSession() throws {
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "cwd": "/tmp/proyecto", "message": ["role": "user", "content": "arregla el login"]],
            ["type": "user", "uuid": "meta", "isMeta": true, "message": ["role": "user", "content": "[Image: original]"]],
            ["type": "assistant", "uuid": "a1", "message": ["model": "claude-opus-5-5", "content": [["type": "thinking", "thinking": "miro"], ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]]],
            ["type": "user", "uuid": "r1", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "a.swift"]]]],
            ["type": "assistant", "uuid": "a2", "message": ["content": [["type": "text", "text": "Listo."]]]],
            ["type": "user", "uuid": "c1", "message": ["role": "user", "content": "<command-name>/compact</command-name>\n<command-args></command-args>"]],
            ["type": "user", "uuid": "s1", "isSidechain": true, "message": ["role": "user", "content": "subagente"]],
            ["type": "ai-title", "aiTitle": "Arreglar el login"],
        ]
        let data = Data(try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
        let (messages, model) = ClaudeSessions.messages(from: data)
        XCTAssertEqual(messages.map(\.role), ["user", "reasoning", "tool", "assistant", "user"])
        XCTAssertEqual(messages[2].status, "completed")
        XCTAssertTrue(messages[2].detail.hasSuffix("a.swift"))
        XCTAssertEqual(messages.last?.text, "/compact")
        XCTAssertEqual(model, "opus")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-sessions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(ClaudeSessions.folderName(for: "/tmp/proyecto"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("abc.jsonl"))
        let sessions = ClaudeSessions.list(root: root)
        XCTAssertEqual(sessions.first?.id, "abc")
        XCTAssertEqual(sessions.first?.title, "Arreglar el login")
        XCTAssertEqual(sessions.first?.projectPath, "/tmp/proyecto")
        XCTAssertEqual(ClaudeSessions.load(try XCTUnwrap(sessions.first), root: root).messages.count, 5)
    }
}
