import XCTest
@testable import JackCore

final class ChatAsideTests: XCTestCase {
    func testArgumentsForkTheSessionWithoutKeepingTheCopy() {
        var claude = ChatConversation(projectPath: "/tmp", provider: .claude, model: "sonnet", sessionID: "abc")
        claude.effort = "high"
        let claudeArgs = ChatAsideService.arguments(claude, prompt: ChatAsideService.prompt("¿qué?"))
        XCTAssertTrue(claudeArgs[0].hasSuffix("¿qué?"), "the prompt goes before the variadic --tools")
        XCTAssertEqual(Array(claudeArgs.suffix(2)), ["--tools", ""])
        XCTAssertTrue(claudeArgs.contains("--no-session-persistence"))
        XCTAssertTrue(claudeArgs.joined(separator: " ").contains("--resume abc --fork-session"))

        let codex = ChatConversation(projectPath: "/tmp", provider: .codex, model: "gpt-6-luna", sessionID: "t1")
        let codexArgs = ChatAsideService.arguments(codex, prompt: ChatAsideService.prompt("x"))
        XCTAssertEqual(Array(codexArgs.suffix(4).prefix(3)), ["fork", "t1", "--ephemeral"])
        XCTAssertTrue(codexArgs.joined(separator: " ").contains("--sandbox read-only"))

        let fresh = ChatConversation(projectPath: "/tmp", provider: .opencode, model: "openai/gpt-6")
        let openCodeArgs = ChatAsideService.arguments(fresh, prompt: ChatAsideService.prompt("x"))
        XCTAssertFalse(openCodeArgs.contains("--fork"))
        XCTAssertTrue(openCodeArgs.joined(separator: " ").contains("--model openai/gpt-6"))
    }

    func testEconomicalClaudeAsideUsesHaikuWithoutResumingAndBoundsVisibleContext() {
        let chat = ChatConversation(projectPath: "/tmp", provider: .claude, model: "opus", sessionID: "expensive",
                                    messages: [ChatMessage(role: "user", text: "old secret")]
                                        + (0..<20).map { _ in ChatMessage(role: "assistant", text: String(repeating: "🙂", count: 5000)) }
                                        + [ChatMessage(role: "tool", text: "tool secret", detail: "large output"),
                                           ChatMessage(role: "reasoning", text: "private thinking"),
                                           ChatMessage(role: "user", text: "recent decision")])
        let prompt = ChatAsideService.economicalPrompt("current question", about: chat)
        XCTAssertLessThan(prompt.count, 12_200)
        XCTAssertTrue(prompt.contains("recent decision"))
        XCTAssertTrue(prompt.hasSuffix("current question"))
        XCTAssertFalse(prompt.contains("old secret"))
        XCTAssertFalse(prompt.contains("tool secret"))
        XCTAssertFalse(prompt.contains("private thinking"))
        let args = ChatAsideService.arguments(chat, prompt: prompt, economicalClaude: true)
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertFalse(args.contains("--fork-session"))
        XCTAssertTrue(args.contains("haiku"))
        XCTAssertFalse(args.contains("opus"))
        XCTAssertTrue(args.contains("--system-prompt"))
        XCTAssertTrue(args.contains("--setting-sources"))
        XCTAssertEqual(Array(args.suffix(2)), ["--tools", ""])
        // Light still forks the original model with the complete session.
        let light = ChatAsideService.arguments(chat, prompt: "q")
        XCTAssertTrue(light.contains("opus"))
        XCTAssertTrue(light.contains("--resume"))
    }

    @MainActor func testEconomicalAsideRefusesToLaunchAfterSwitchingToLight() async {
        let chat = ChatConversation(projectPath: "/tmp", provider: .claude)
        do {
            _ = try await ChatAsideService.ask("q", about: chat, allowCloud: true, cloudAllowed: { false }, partial: { _ in })
            XCTFail("Must not start a CLI when Normal's policy is no longer allowed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Light"))
        }
    }

    func testClaudeStreamIsReplacedByTheCompleteMessage() {
        var parser = ChatAsideService.Parser(provider: .claude)
        let delta: (String) -> [String: Any] = { ["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": $0]]] }
        XCTAssertTrue(parser.consume(delta("Hola ")))
        XCTAssertTrue(parser.consume(delta("mundo")))
        XCTAssertEqual(parser.answer, "Hola mundo")
        _ = parser.consume(["type": "assistant", "message": ["id": "m1", "content": [["type": "thinking", "thinking": "…"], ["type": "text", "text": "Hola mundo."]]]])
        XCTAssertEqual(parser.answer, "Hola mundo.")
        XCTAssertFalse(parser.done)
        _ = parser.consume(["type": "result", "subtype": "success", "is_error": false, "result": "Hola mundo."])
        XCTAssertTrue(parser.done)
        XCTAssertNil(parser.failure)
    }

    func testCodexAndOpenCodeEventsAndFailures() {
        var codex = ChatAsideService.Parser(provider: .codex)
        _ = codex.consume(["type": "item.completed", "item": ["id": "item_0", "type": "error", "message": "config warning"]])
        _ = codex.consume(["type": "item.completed", "item": ["id": "item_2", "type": "agent_message", "text": "mandarina"]])
        _ = codex.consume(["type": "turn.completed"])
        XCTAssertEqual(codex.answer, "mandarina")
        XCTAssertNil(codex.failure, "item errors are warnings")
        XCTAssertTrue(codex.done)

        var openCode = ChatAsideService.Parser(provider: .opencode)
        _ = openCode.consume(["type": "text", "sessionID": "fork", "part": ["id": "p1", "type": "text", "text": "pomelo"]])
        _ = openCode.consume(["type": "step_finish", "sessionID": "fork", "part": ["reason": "stop"]])
        XCTAssertEqual(openCode.answer, "pomelo")
        XCTAssertEqual(openCode.sessions, ["fork"])
        XCTAssertTrue(openCode.done)

        var failing = ChatAsideService.Parser(provider: .opencode)
        _ = failing.consume(["type": "error", "error": ["name": "APIError", "data": ["message": "sin cuota"]]])
        XCTAssertEqual(failing.failure, "sin cuota")
    }

    func testBtwIsAJackCommand() {
        XCTAssertTrue(JackCommandCatalog.builtins.contains { $0.name == "btw" })
        XCTAssertEqual(JackCommandCatalog.parse("!btw ¿por qué?")?.arguments, "¿por qué?")
    }
}
