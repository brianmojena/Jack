import XCTest
@testable import JackCore

final class ChatCommandTests: XCTestCase {
    func testParseSplitsNameAndArgumentsAndIgnoresPaths() {
        XCTAssertEqual(ChatCommand.parse("/compact")?.name, "compact")
        XCTAssertEqual(ChatCommand.parse("/review  focus on tests ")?.arguments, "focus on tests")
        XCTAssertEqual(ChatCommand.parse("/vercel:deploy prod")?.name, "vercel:deploy")
        XCTAssertNil(ChatCommand.parse("/Users/me/file.swift explain"))
        XCTAssertNil(ChatCommand.parse("/"))
        XCTAssertNil(ChatCommand.parse("compact"))
    }

    func testClaudeReportsCommandsAndContextButIgnoresSyntheticReplies() {
        var decoder = ClaudeProtocol.Decoder()
        let commands = decoder.events(["type": "system", "subtype": "commands_changed", "commands": [
            ["name": "compact", "description": "Compact", "argumentHint": "<instructions>"], ["name": "__internal"],
        ]])
        guard case .commands(let list) = commands.first else { return XCTFail("missing commands") }
        XCTAssertEqual(list, [ChatCommand(name: "compact", description: "Compact", argumentHint: "<instructions>")])

        let usage: [String: Any] = ["input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 200, "output_tokens": 5]
        let live = decoder.events(["type": "assistant", "message": ["id": "m1", "model": "claude-opus-5-5", "usage": usage, "content": []]])
        guard case .context(let used, let window) = live.first else { return XCTFail("missing context") }
        XCTAssertEqual(used, 1215); XCTAssertNil(window)

        let synthetic = decoder.events(["type": "assistant", "message": ["id": "m2", "model": "<synthetic>", "usage": ["input_tokens": 0], "content": [["type": "text", "text": "## Context"]]]])
        XCTAssertFalse(synthetic.contains { if case .context = $0 { return true }; return false })

        let result = decoder.events(["type": "result", "usage": ["iterations": [usage]], "modelUsage": ["claude-opus-5-5": ["contextWindow": 1_000_000]]])
        guard case .context(let finalUsed, let finalWindow) = result.first else { return XCTFail("missing result context") }
        XCTAssertEqual(finalUsed, 1215); XCTAssertEqual(finalWindow, 1_000_000)

        let local = decoder.events(["type": "result", "usage": ["iterations": []], "modelUsage": [:]])
        XCTAssertFalse(local.contains { if case .context = $0 { return true }; return false })
    }

    func testCodexContextUsesLastRequestAndModelWindow() {
        var session: String?
        var approvals: [String: PendingApproval] = [:]
        let events = CodexProtocol.event(["method": "thread/tokenUsage/updated", "params": ["tokenUsage": [
            "total": ["totalTokens": 90_000, "inputTokens": 80_000], "last": ["totalTokens": 30_000], "modelContextWindow": 272_000,
        ]]], session: &session, approvals: &approvals)
        guard case .context(let used, let window) = events.first else { return XCTFail("missing context") }
        XCTAssertEqual(used, 30_000); XCTAssertEqual(window, 272_000)

        let review = CodexProtocol.event(["method": "item/completed", "params": ["item": ["type": "exitedReviewMode", "id": "r1", "review": "Looks good"]]], session: &session, approvals: &approvals)
        guard case .text(_, let text, _) = review.first else { return XCTFail("missing review text") }
        XCTAssertEqual(text, "Looks good")
    }

    func testCodexCommandsListBuiltinsAndEnabledSkills() {
        let response: [String: Any] = ["id": 2, "result": ["data": [["cwd": "/tmp", "skills": [
            ["name": "pdf", "description": "Long", "shortDescription": "PDF files", "path": "/s/pdf", "enabled": true],
            ["name": "off", "description": "Disabled", "path": "/s/off", "enabled": false],
        ]]]]]
        XCTAssertEqual(CodexCommands.commands(from: response).map(\.name), ["compact", "review", "pdf"])
        XCTAssertEqual(CodexCommands.commands(from: response).last?.description, "PDF files")
        let turn = ChatRunConfiguration.codexTurn(ChatConversation(projectPath: "/tmp"), threadID: "t", prompt: "/pdf read a.pdf", skill: ["name": "pdf", "path": "/s/pdf"])
        let input = turn["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["text"] as? String, "$pdf read a.pdf")
        XCTAssertEqual(input?.last?["type"] as? String, "skill")
    }

    func testOpenCodeContextUsesModelLimitAndCommandsIncludeCompact() throws {
        let providers = try JSONSerialization.data(withJSONObject: ["all": [["id": "anthropic", "models": ["claude": ["id": "claude", "limit": ["context": 200_000]]]]]])
        let limits = OpenCodeCommands.contextLimits(from: providers)
        XCTAssertEqual(limits["anthropic/claude"], 200_000)
        var approvals: [String: PendingApproval] = [:]
        let events = OpenCodeProtocol.events(["type": "message.updated", "properties": ["info": [
            "id": "m", "role": "assistant", "providerID": "anthropic", "modelID": "claude",
            "tokens": ["input": 100, "output": 20, "reasoning": 5, "cache": ["read": 1000, "write": 50]],
        ]]], sessionID: nil, approvals: &approvals, contextLimits: limits)
        guard case .context(let used, let window) = events.first else { return XCTFail("missing context") }
        XCTAssertEqual(used, 1175); XCTAssertEqual(window, 200_000)

        let commands = try JSONSerialization.data(withJSONObject: [["name": "review", "description": "Review", "hints": ["$ARGUMENTS"]]])
        XCTAssertEqual(OpenCodeCommands.commands(from: commands).map(\.name), ["compact", "review"])
    }

    @MainActor func testStoreMergesContextAndLoadsCommandsOncePerProject() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-command-tests-" + UUID().uuidString)
        var loads = 0
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { ChatDriverFactory.make($0) },
                              commandLoader: { _, _ in loads += 1; return [ChatCommand(name: "compact")] })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        let conversation = try XCTUnwrap(store.selectedConversation)
        store.loadCommands(for: conversation); store.loadCommands(for: conversation)
        XCTAssertTrue(store.isLoadingCommands(for: conversation))
        for _ in 0..<20 where store.commands(for: conversation) == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.commands(for: conversation)?.map(\.name), ["compact"])
        XCTAssertEqual(loads, 1)
        store.updateSettings(id: id, model: "opus", effort: "high")
        XCTAssertNil(store.selectedConversation?.contextUsage)
    }

    /// A loader that never answers, like a CLI whose output stays open, must not leave "Cargando comandos…" forever.
    @MainActor func testCommandLoadingGivesUpAtTheDeadline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-command-tests-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { ChatDriverFactory.make($0) },
                              commandLoader: { _, _ in
                                  try await withCheckedThrowingContinuation { (_: CheckedContinuation<[ChatCommand], Error>) in }
                              })
        store.commandDeadline = .milliseconds(100)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        _ = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        let conversation = try XCTUnwrap(store.selectedConversation)
        store.loadCommands(for: conversation)
        XCTAssertTrue(store.isLoadingCommands(for: conversation))
        for _ in 0..<100 where store.isLoadingCommands(for: conversation) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isLoadingCommands(for: conversation))
        XCTAssertNotNil(store.commandError(for: conversation))
    }
}
