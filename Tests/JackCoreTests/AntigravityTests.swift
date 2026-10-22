import XCTest
@testable import JackCore

private func hasSession(_ events: [ChatEvent], _ expected: String) -> Bool {
    events.contains { if case let .session(id) = $0 { return id == expected }; return false }
}
private func hasText(_ events: [ChatEvent], _ expected: String, replace expectedReplace: Bool) -> Bool {
    events.contains {
        if case let .text(_, text, replace) = $0 { return text == expected && replace == expectedReplace }
        return false
    }
}
private func hasFailure(_ events: [ChatEvent], _ expected: String) -> Bool {
    events.contains { if case let .failure(message) = $0 { return message == expected }; return false }
}
private func hasCompleted(_ events: [ChatEvent]) -> Bool {
    events.contains { if case .completed = $0 { return true }; return false }
}

final class AntigravityTests: XCTestCase {
    func testProviderUsesAgyWithoutChangingItsSettingsKey() {
        XCTAssertEqual(ChatProvider.antigravity.executableName, "agy")
        XCTAssertEqual(ChatProvider.antigravity.rawValue, "antigravity")
        XCTAssertEqual(ChatProvider.codex.executableName, "codex")
        XCTAssertTrue(ChatProvider.antigravity.isNormalOnly)
        XCTAssertFalse(ChatProvider.claude.isNormalOnly)
        XCTAssertEqual(ChatProvider.antigravity.defaultModel, "", "the CLI's configured model applies until one is chosen")
        XCTAssertEqual(ChatRunMode.choices(for: .antigravity).map(\.id), ["plan", "accept-edits", "auto"])
    }

    func testArgumentsResumeTheSessionAndOmitEmptyValues() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .antigravity)
        conversation.sessionID = "conversation-1"
        conversation.model = "claude-sonnet-4-6"
        conversation.effort = "high"
        conversation.mode = "plan"
        conversation.extraDirectories = ["/tmp/one", "/tmp/two"]
        let arguments = ChatRunConfiguration.antigravityArguments(conversation)
        XCTAssertEqual(arguments.prefix(4), ["--input-format", "stream-json", "--output-format", "stream-json"])
        for pair in [["--conversation", "conversation-1"], ["--model", "claude-sonnet-4-6"], ["--effort", "high"],
                     ["--mode", "plan"], ["--add-dir", "/tmp/one"], ["--add-dir", "/tmp/two"]] {
            XCTAssertTrue(arguments.contains(pair), "missing \(pair)")
        }
        var fresh = ChatConversation(projectPath: "/tmp", provider: .antigravity, model: "", effort: "")
        fresh.mode = nil
        XCTAssertEqual(ChatRunConfiguration.antigravityArguments(fresh), ["--input-format", "stream-json", "--output-format", "stream-json"])
        fresh.mode = "auto"
        let automatic = ChatRunConfiguration.antigravityArguments(fresh)
        XCTAssertFalse(automatic.contains("--dangerously-skip-permissions"))
    }

    @MainActor func testParserStreamsTextTokensToolsAndCompletion() {
        var sawText = false
        var streamedText = ""
        var context: Int?
        let initEvent: [String: Any] = ["event": "init", "conversation_id": "abc"]
        XCTAssertTrue(hasSession(AntigravityProtocol.events(initEvent, namespace: "run", sawText: &sawText,
                                                            streamedText: &streamedText, lastContext: &context), "abc"))

        let response: [String: Any] = ["event": "step_update", "step_update": [
            "conversation_id": "abc", "step_index": 1, "state": "ACTIVE", "step_type": "agent_response", "text_delta": "Hola"
        ]]
        let streamed = AntigravityProtocol.events(response, namespace: "run", sawText: &sawText,
                                                   streamedText: &streamedText, lastContext: &context)
        XCTAssertTrue(hasSession(streamed, "abc"))
        XCTAssertTrue(hasText(streamed, "Hola", replace: false))
        XCTAssertTrue(sawText)

        let tool: [String: Any] = ["event": "step_update", "step_update": [
            "conversation_id": "abc", "step_index": 2, "state": "DONE", "step_type": "tool", "tool_name": "run_command",
            "tool_info": ["name": "run_command", "parameters": ["CommandLine": "swift test"], "output": "ok"]
        ]]
        let toolEvents = AntigravityProtocol.events(tool, namespace: "run", sawText: &sawText,
                                                     streamedText: &streamedText, lastContext: &context)
        guard case let .tool(id, title, detail, status)? = toolEvents.last else { return XCTFail("missing tool event") }
        XCTAssertEqual(id, "antigravity-run-tool-2")
        XCTAssertEqual(title, "Ejecutar comando")
        XCTAssertTrue(detail.contains("swift test"))
        XCTAssertTrue(detail.contains("ok"))
        XCTAssertEqual(status, "completed")
        let activeTool: [String: Any] = ["event": "step_update", "step_update": [
            "conversation_id": "abc", "step_index": 2, "state": "ACTIVE", "step_type": "tool", "tool_name": "run_command",
            "tool_info": ["name": "run_command", "parameters": ["CommandLine": "swift test"]]
        ]]
        guard case let .tool(_, _, _, running)? = AntigravityProtocol.events(activeTool, namespace: "run", sawText: &sawText,
                                                                             streamedText: &streamedText, lastContext: &context).last else {
            return XCTFail("missing active tool event")
        }
        XCTAssertEqual(running, "running")

        let usage: [String: Any] = ["event": "step_update", "step_update": [
            "conversation_id": "abc", "step_index": 3, "state": "DONE", "step_type": "checkpoint",
            "usage": ["input_tokens": 100, "cache_read_tokens": 50, "output_tokens": 20]
        ]]
        let usageEvents = AntigravityProtocol.events(usage, namespace: "run", sawText: &sawText,
                                                     streamedText: &streamedText, lastContext: &context)
        XCTAssertNil(context)
        XCTAssertFalse(usageEvents.contains { if case .context = $0 { return true }; return false })

        let result: [String: Any] = ["event": "result", "result": [
            "conversation_id": "abc", "status": "SUCCESS", "response": "Hola",
            "usage": ["input_tokens": 200, "cache_read_tokens": 100, "output_tokens": 30, "thinking_tokens": 5]
        ]]
        let final = AntigravityProtocol.events(result, namespace: "run", sawText: &sawText,
                                               streamedText: &streamedText, lastContext: &context)
        XCTAssertTrue(hasCompleted(final))
        let tokens = final.compactMap { event -> ChatTokenUsage? in
            if case .tokens(let usage) = event { return usage }
            return nil
        }.first
        XCTAssertEqual(tokens, ChatTokenUsage(input: 200, output: 30, cached: 100, reasoning: 5))
        XCTAssertFalse(final.contains { if case .text = $0 { return true }; return false }, "the streamed answer is not repeated")
    }

    @MainActor func testParserUsesTheFinalResponseWhenNothingStreamedAndReportsFailures() {
        var sawText = false
        var streamedText = ""
        var context: Int?
        let result: [String: Any] = ["event": "result", "result": ["conversation_id": "abc", "status": "SUCCESS", "response": "Completo"]]
        XCTAssertTrue(hasText(AntigravityProtocol.events(result, namespace: "run", sawText: &sawText,
                                                         streamedText: &streamedText, lastContext: &context), "Completo", replace: true))
        let failed: [String: Any] = ["event": "result", "result": ["status": "ERROR", "error": "model not found"]]
        XCTAssertTrue(hasFailure(AntigravityProtocol.events(failed, namespace: "run", sawText: &sawText,
                                                            streamedText: &streamedText, lastContext: &context), "model not found"))
        let denied: [String: Any] = ["event": "result", "result": ["status": "SUCCESS", "response": "Listo",
            "denied_actions": [["tool_name": "run_command"]]]]
        let deniedEvents = AntigravityProtocol.events(denied, namespace: "run", sawText: &sawText,
                                                      streamedText: &streamedText, lastContext: &context)
        XCTAssertFalse(hasCompleted(deniedEvents))
        XCTAssertTrue(deniedEvents.contains { if case let .failure(text) = $0 { text.contains("denegó") } else { false } })
    }

    func testDelegationSchemaOffersAntigravityOnlyInNormal() throws {
        func providerEnum(_ tools: [[String: Any]]) throws -> [String] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "create_agent" })
            let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            let provider = properties?["provider"] as? [String: Any]
            return try XCTUnwrap(provider?["enum"] as? [String])
        }
        XCTAssertEqual(try providerEnum(AgentBridge.tools), ["codex", "claude", "opencode"])
        XCTAssertEqual(try providerEnum(AgentBridge.normalTools), ["codex", "claude", "opencode", "antigravity"])
    }

    func testModelListParsingKeepsSlugsAndTitles() {
        let models = ChatModelCatalog.parseAntigravityModels("""
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        claude-sonnet-4-6\tClaude Sonnet 4.6

        Not a model line
        """)
        XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash-high", "claude-sonnet-4-6"])
        XCTAssertEqual(models.last?.title, "Claude Sonnet 4.6")
        XCTAssertEqual(models.first?.efforts, ChatModelChoice.antigravityEfforts)
    }

    func testModelCacheRoundTripsTitlesAndEfforts() {
        let models = ChatModelCatalog.parseAntigravityModels("""
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        claude-sonnet-4-6\tClaude Sonnet 4.6
        """)
        let cached = ChatModelCatalog.decodeAntigravityModels(ChatModelCatalog.encodeAntigravityModels(models))
        XCTAssertEqual(cached.map(\.id), models.map(\.id))
        XCTAssertEqual(cached.map(\.title), models.map(\.title))
        XCTAssertEqual(cached.first?.efforts, ChatModelChoice.antigravityEfforts)
    }

    func testDefaultTitleComesFromTheCLISettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-antigravity-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("settings.json")
        try #"{"model":"Gemini 3.8 Flash (Medium)"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ChatModelCatalog.antigravityDefaultTitle(at: url), "Gemini 3.8 Flash (Medium)")
        XCTAssertNil(ChatModelCatalog.antigravityDefaultTitle(at: folder.appendingPathComponent("missing.json")))
    }

    func testUsageDecodingReadsGroupsAndTurnsFractionsIntoConsumption() throws {
        let payload: [String: Any] = ["command": [
            "name": "usage",
            "data": ["groups": [
                ["name": "Gemini Models", "buckets": [[
                    "id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly",
                    "remaining_fraction": 0.9326480031013489, "reset_time": "2026-10-26T12:05:50Z"
                ]]],
                ["name": "Claude and GPT models", "buckets": [[
                    "id": "3p-weekly", "name": "Weekly Limit Remaining", "window": "weekly",
                    "remaining_fraction": 1, "reset_time": "2026-10-26T18:56:55Z"
                ]]]
            ]]
        ]]
        let usage = UsageDecoder.antigravity(payload)
        XCTAssertEqual(usage.provider, .antigravity)
        XCTAssertEqual(usage.windows.map(\.id), ["antigravity:gemini-weekly", "antigravity:3p-weekly"])
        XCTAssertEqual(usage.windows.map(\.title), ["Gemini · 7 d", "Claude y GPT · 7 d"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, (1 - 0.9326480031013489) * 100, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 0, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testUsageDecodingFallsBackToTheTSVResponse() {
        let usage = UsageDecoder.antigravity(["response": "Gemini Models\tWeekly Limit Remaining\t93%\t2026-10-26T12:05:50Z"])
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].title, "Gemini · 7 d")
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 7, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[0].resetsAt)
        XCTAssertTrue(UsageDecoder.antigravity([:]).windows.isEmpty)
    }

    @MainActor func testLightCannotCreateAntigravityWhileNormalLeavesItsModeToTheCli() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-antigravity-light-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let light = ChatStore(archive: ChatArchive(directory: folder), preferences: UserDefaults(suiteName: "antigravity-light-" + UUID().uuidString),
                              driverFactory: { _ in XCTFail("Light must not create an Antigravity driver"); return StellarChatDriver() }, lightMode: true)
        defer { light.shutdown() }
        XCTAssertNil(light.create(projectPath: NSTemporaryDirectory(), provider: .antigravity))
        XCTAssertTrue(light.errorMessage?.contains("modo Normal") == true)

        let normal = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("normal")), preferences: nil,
                               driverFactory: { _ in XCTFail("no driver is started by create"); return StellarChatDriver() })
        defer { normal.shutdown() }
        XCTAssertNil(normal.defaultMode(for: .antigravity), "the CLI's own permission settings apply")
        XCTAssertEqual(normal.defaultMode(for: .codex), "auto")
    }
    @MainActor func testTwoTurnsKeepBothAnswersInTheTranscript() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-antigravity-turns-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in TwoTurnAntigravityDriver() })
        store.antigravityDelegationProvider = { _, _, _, _ in nil }
        store.loadAntigravityModels = { _ in [] }
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .antigravity, select: false))
        store.send("primero", to: id)
        try await waitUntilIdle(store, id)
        store.send("segundo", to: id)
        try await waitUntilIdle(store, id)
        let answers = store.transcript(of: id).filter { $0.role == "assistant" }.map(\.text)
        XCTAssertEqual(answers, ["respuesta primero\n", "respuesta segundo\n"])
    }

    @MainActor func testArgumentsAddAttachmentFoldersAndReconcileTheStreamedTail() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-antigravity-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try "hola".write(to: file, atomically: true, encoding: .utf8)
        var conversation = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .antigravity,
                                            messages: [ChatMessage(role: "user", text: "lee", attachments: [file.path])])
        conversation.mode = nil
        let arguments = ChatRunConfiguration.antigravityArguments(conversation)
        XCTAssertTrue(arguments.contains("--add-dir"))
        XCTAssertTrue(arguments.contains(folder.path))
        let text = ChatAttachments.promptText("mira", attachments: [file.path], inlineImages: false)
        XCTAssertTrue(text.contains("no se incluyen"))
        XCTAssertFalse(text.contains("también van incluidas"))

        var sawText = false
        var streamed = "Hola"
        var context: Int?
        let result: [String: Any] = ["event": "result", "result": ["status": "SUCCESS", "response": "Hola mundo"]]
        let events = AntigravityProtocol.events(result, namespace: "run", sawText: &sawText,
                                                streamedText: &streamed, lastContext: &context)
        XCTAssertTrue(hasText(events, " mundo", replace: false))
        XCTAssertFalse(hasText(events, "Hola mundo", replace: true))

        var replacement = "incompleto"
        let corrected: [String: Any] = ["event": "result", "result": ["status": "SUCCESS", "response": "Completo"]]
        let fixed = AntigravityProtocol.events(corrected, namespace: "run", sawText: &sawText,
                                               streamedText: &replacement, lastContext: &context)
        XCTAssertTrue(hasText(fixed, "Completo", replace: true))
    }

    @MainActor private func waitUntilIdle(_ store: ChatStore, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if store.statuses[id] == .idle, store.activeCount == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("turn did not finish", file: file, line: line)
    }
}

@MainActor private final class TwoTurnAntigravityDriver: ChatDriver {
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, delegation: nil, onEvent: onEvent)
    }
    func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        let namespace = UUID().uuidString.lowercased()
        var sawText = false
        var streamedText = ""
        var context: Int?
        let delta: [String: Any] = ["event": "step_update", "step_update": [
            "step_index": 1, "state": "ACTIVE", "step_type": "agent_response", "text_delta": "respuesta \(prompt)"
        ]]
        for event in AntigravityProtocol.events(delta, namespace: namespace, sawText: &sawText,
                                                streamedText: &streamedText, lastContext: &context) { onEvent(event) }
        let result: [String: Any] = ["event": "result", "result": [
            "status": "SUCCESS", "response": "respuesta \(prompt)\n"
        ]]
        for event in AntigravityProtocol.events(result, namespace: namespace, sawText: &sawText,
                                                streamedText: &streamedText, lastContext: &context) { onEvent(event) }
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() {}
    func close() {}
}
