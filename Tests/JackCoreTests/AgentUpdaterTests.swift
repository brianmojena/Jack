import XCTest
@testable import JackCore

final class AgentUpdaterTests: XCTestCase {
    func testHomebrewInstallsAreRecognisedFromTheirRealPath() {
        XCTAssertEqual(AgentUpdater.method(for: .claude, resolvedPath: "/opt/homebrew/Caskroom/claude-code@latest/2.1.284/claude"),
                       .homebrewCask("claude-code@latest"))
        XCTAssertEqual(AgentUpdater.method(for: .codex, resolvedPath: "/opt/homebrew/Caskroom/codex/0.160.0/bin/codex"), .homebrewCask("codex"))
        XCTAssertEqual(AgentUpdater.method(for: .opencode, resolvedPath: "/opt/homebrew/Cellar/opencode/1.18.33/bin/opencode"),
                       .homebrewFormula("opencode"))
    }

    func testNpmAndNativeInstalls() {
        XCTAssertEqual(AgentUpdater.method(for: .codex, resolvedPath: "/Users/a/.nvm/versions/node/v22.0.0/lib/node_modules/@openai/codex/bin/codex.js"),
                       .npm(package: "@openai/codex"))
        XCTAssertEqual(AgentUpdater.method(for: .claude, resolvedPath: "/Users/a/.local/share/claude/versions/2.1.0"), .selfUpdate(["update"]))
        XCTAssertEqual(AgentUpdater.method(for: .opencode, resolvedPath: "/Users/a/.opencode/bin/opencode"), .selfUpdate(["upgrade"]))
        XCTAssertEqual(AgentUpdater.method(for: .codex, resolvedPath: "/Users/a/bin/codex"), .unsupported)
    }

    func testCommandsPerMethod() {
        XCTAssertEqual(AgentUpdater.command(for: .homebrewCask("codex"), executable: "/x")?.arguments, ["upgrade", "--cask", "--greedy", "codex"])
        XCTAssertEqual(AgentUpdater.command(for: .homebrewFormula("opencode"), executable: "/x")?.arguments, ["upgrade", "opencode"])
        XCTAssertEqual(AgentUpdater.command(for: .npm(package: "@openai/codex"), executable: "/x")?.arguments, ["install", "-g", "@openai/codex@latest"])
        XCTAssertEqual(AgentUpdater.command(for: .selfUpdate(["update"]), executable: "/bin/claude")?.program, "/bin/claude")
        XCTAssertNil(AgentUpdater.command(for: .unsupported, executable: "/x"))
    }

    func testVersionParsing() {
        XCTAssertEqual(AgentUpdater.parseVersion("2.1.284 (Claude Code)"), "2.1.284")
        XCTAssertEqual(AgentUpdater.parseVersion("codex-cli 0.160.0\n"), "0.160.0")
        XCTAssertEqual(AgentUpdater.parseVersion("1.18.33"), "1.18.33")
        XCTAssertNil(AgentUpdater.parseVersion("command not found"))
    }
}
