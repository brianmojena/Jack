import XCTest
@testable import JackCore

private func flagValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

final class QoderTests: XCTestCase {
    func testTurnIsOneProcessWithThePromptAfterDoubleDash() {
        let conversation = ChatConversation(projectPath: "/tmp/project", provider: .qoder)
        let arguments = ChatRunConfiguration.qoderArguments(conversation, prompt: "hola", delegation: nil)
        XCTAssertEqual(arguments.suffix(2), ["--", "hola"])
        XCTAssertEqual(Array(arguments.prefix(3)), ["-p", "--permission-prompt-tool", "stdio"])
        XCTAssertEqual(flagValue(after: "--permission-mode", in: arguments), "default")
        XCTAssertFalse(arguments.contains("--model"), "an empty model leaves the CLI's default")
        XCTAssertFalse(arguments.contains("--resume"))
    }

    func testSessionModelAndEffortAreForwardedOnlyWhenKnown() {
        var conversation = ChatConversation(projectPath: "/tmp/project", provider: .qoder)
        conversation.sessionID = "qoder-session-1"
        conversation.model = "Fast"
        conversation.mode = "bypassPermissions"
        conversation.effort = "max"
        var arguments = ChatRunConfiguration.qoderArguments(conversation, prompt: "hola", delegation: nil)
        XCTAssertEqual(flagValue(after: "--resume", in: arguments), "qoder-session-1")
        XCTAssertEqual(flagValue(after: "--model", in: arguments), "Fast")
        XCTAssertEqual(flagValue(after: "--permission-mode", in: arguments), "bypass_permissions")
        XCTAssertEqual(flagValue(after: "--reasoning-effort", in: arguments), "max")

        conversation.effort = "ultracode"
        arguments = ChatRunConfiguration.qoderArguments(conversation, prompt: "hola", delegation: nil)
        XCTAssertFalse(arguments.contains("--reasoning-effort"))
    }

    func testDelegationAddsTheJackServerAndAllowsItsTools() {
        var conversation = ChatConversation(projectPath: "/tmp/project", provider: .qoder)
        conversation.extraDirectories = ["/tmp/one"]
        let delegation = ChatDelegation(url: URL(string: "http://127.0.0.1:4321/mcp")!, token: "secret")
        let arguments = ChatRunConfiguration.qoderArguments(conversation, prompt: "hola", delegation: delegation)
        XCTAssertEqual(flagValue(after: "--allowed-tools", in: arguments), "mcp__jack")
        XCTAssertFalse(arguments.contains("--allowedTools"))
        XCTAssertTrue(flagValue(after: "--mcp-config", in: arguments)?.contains("Bearer secret") == true)
        XCTAssertEqual(flagValue(after: "--add-dir", in: arguments), "/tmp/one")
        XCTAssertEqual(arguments.suffix(2), ["--", "hola"])
    }

    func testPermissionModesMapBothWays() {
        let pairs = [("manual", "default"), ("plan", "plan"), ("acceptEdits", "accept_edits"),
                     ("auto", "auto"), ("dontAsk", "dont_ask"), ("bypassPermissions", "bypass_permissions")]
        for (jack, cli) in pairs {
            XCTAssertEqual(ChatRunConfiguration.qoderPermissionMode(jack), cli)
            XCTAssertEqual(ChatRunConfiguration.qoderJackMode(cli), jack)
        }
        XCTAssertEqual(ChatRunConfiguration.qoderPermissionMode(nil), "default")
        XCTAssertEqual(ChatRunConfiguration.qoderJackMode("unknown_mode"), "unknown_mode")
    }
}
