import XCTest
@testable import JackCore

final class ExecutableResolverTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func executable(_ path: URL, script: String = "#!/bin/sh\nexit 0\n") throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func testFindsClaudeFromFinderAcrossInstallersAndVersionManagers() throws {
        for directory in [".local/bin", ".claude/local/node_modules/.bin", ".claude/bin",
                          ".nvm/versions/node/v22.0.0/bin", ".fnm/node-versions/v22.0.0/installation/bin",
                          "Library/Application Support/fnm/node-versions/v22.0.0/installation/bin",
                          ".asdf/installs/nodejs/22.0.0/bin", ".local/share/mise/installs/node/22.0.0/bin",
                          "Library/pnpm", ".yarn/bin"] {
            let home = try temporaryHome()
            let cli = home.appendingPathComponent(directory).appendingPathComponent("claude")
            try executable(cli)
            let paths = ExecutableResolver.installedUserPaths(home: home)
            XCTAssertEqual(ExecutableResolver.resolve("claude", environment: ["PATH": paths.joined(separator: ":")]), cli.path, directory)
        }
    }

    func testInstallationAfterFirstLookupIsDiscoveredAndNewestNodeWins() throws {
        let home = try temporaryHome()
        XCTAssertTrue(ExecutableResolver.installedUserPaths(home: home).allSatisfy { !$0.hasPrefix(home.path) })
        let old = home.appendingPathComponent(".nvm/versions/node/v9.0.0/bin/claude")
        let new = home.appendingPathComponent(".nvm/versions/node/v22.0.0/bin/claude")
        try executable(old)
        try executable(new)
        let paths = ExecutableResolver.installedUserPaths(home: home)
        XCTAssertEqual(ExecutableResolver.resolve("claude", environment: ["PATH": paths.joined(separator: ":")]), new.path)
    }

    func testCustomManagerDirectoryAndInvalidOverrideFallback() throws {
        let home = try temporaryHome()
        let prefix = home.appendingPathComponent("custom npm")
        let cli = prefix.appendingPathComponent("bin/claude")
        try executable(cli)
        let paths = ExecutableResolver.installedUserPaths(home: home, environment: ["NPM_CONFIG_PREFIX": prefix.path])
        XCTAssertEqual(ExecutableResolver.resolve("claude", override: home.appendingPathComponent("missing").path,
                                                  environment: ["PATH": paths.joined(separator: ":")]), cli.path)
    }

    func testNoisyShellStartupDoesNotBlockPATHDiscovery() throws {
        let home = try temporaryHome()
        let shell = home.appendingPathComponent("noisy-shell")
        try executable(shell, script: "#!/bin/sh\nprintf '%100000s' ''\nprintf '__JACK_PATH__/custom/bin:/usr/bin__JACK_PATH__'\n")
        XCTAssertEqual(ExecutableResolver.loginShellPath(shell: shell.path), ["/custom/bin", "/usr/bin"])
    }
}
