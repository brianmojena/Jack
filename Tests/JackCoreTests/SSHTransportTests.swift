import XCTest
@testable import JackCore

final class SSHTransportTests: XCTestCase {
    private var endpoint: ChatRemoteEndpoint {
        ChatRemoteEndpoint(destination: "ruben@192.168.1.193", remotePath: "/Users/ruben/Jack")
    }

    func testEndpointValidation() {
        XCTAssertTrue(endpoint.isValid)
        XCTAssertTrue(endpoint.isResolved)
        XCTAssertFalse(ChatRemoteEndpoint(destination: "", remotePath: "/tmp/x").isValid)
        XCTAssertFalse(ChatRemoteEndpoint(destination: "  ", remotePath: "/tmp/x").isValid)
        // The folder resolves later, automatically: destination alone is usable.
        let auto = ChatRemoteEndpoint(destination: "ruben@host")
        XCTAssertTrue(auto.isValid)
        XCTAssertFalse(auto.isResolved)
        XCTAssertNil(auto.remotePath)
        XCTAssertEqual(endpoint.displayName, "ruben@192.168.1.193")
    }

    /// The quoting scheme must survive a real shell: every value comes back byte-identical.
    func testShellQuotingRoundTripsThroughSh() throws {
        let values = ["simple", "with space", "quote's", "a\"b$c\\`d",
                      "{\"mcpServers\": {\"jack\": {\"url\": \"http://127.0.0.1:51234/mcp\"}}}",
                      "", "line1\nline2", "tab\there"]
        for value in values {
            XCTAssertEqual(try shEcho(SSHTransport.shellQuote(value)), value, "quoting broke: \(value)")
        }
    }

    func testArgumentsWithoutDelegation() {
        let args = SSHTransport.arguments(endpoint: endpoint, remoteExecutable: "claude",
                                          remoteArgs: ["--print", "--model", "sonnet"],
                                          remoteDirectory: endpoint.remotePath)
        XCTAssertTrue(args.contains("ruben@192.168.1.193"))
        XCTAssertFalse(args.contains { $0.hasPrefix("-R") }, "no tunnel without delegation")
        XCTAssertFalse(args.contains("-p"), "default SSH port needs no flag")
        let command = try! XCTUnwrap(args.last)
        XCTAssertTrue(command.hasPrefix("cd '/Users/ruben/Jack' && sh -c '"))
        XCTAssertTrue(command.contains("--print"))
        XCTAssertTrue(command.contains("exec \"$JACK_CLAUDE\""))
        XCTAssertFalse(command.contains("exec '\\''claude"), "never relies on the remote PATH")
        // BatchMode so a missing key fails fast instead of asking for a password.
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }

    func testArgumentsWithTunnelAndCustomPort() {
        var custom = endpoint
        custom.sshPort = 2222
        let args = SSHTransport.arguments(endpoint: custom, tunnel: (remotePort: 18791, localPort: 51234),
                                          remoteEnv: ["MCP_TOOL_TIMEOUT": "960000"],
                                          remoteExecutable: "claude", remoteArgs: ["--print"])
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
        XCTAssertTrue(args.contains("127.0.0.1:18791:127.0.0.1:51234"))
        let command = try! XCTUnwrap(args.last)
        XCTAssertTrue(command.contains("MCP_TOOL_TIMEOUT="))
        XCTAssertTrue(command.contains("960000"))
    }

    func testTunneledURL() throws {
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:51234/mcp"))
        let remote = try XCTUnwrap(SSHTransport.tunneledURL(local, remotePort: 18791))
        XCTAssertEqual(remote.absoluteString, "http://127.0.0.1:18791/mcp")
        XCTAssertEqual(SSHTransport.loopbackPort(local), 51234)
        XCTAssertNil(SSHTransport.tunneledURL(URL(string: "http://10.0.0.5:51234/mcp")!, remotePort: 18791))
        XCTAssertNil(SSHTransport.tunneledURL(URL(string: "https://127.0.0.1:51234/mcp")!, remotePort: 18791))
        XCTAssertNil(SSHTransport.loopbackPort(URL(string: "http://10.0.0.5:51234/mcp")!))
    }

    func testProbeParsing() {
        XCTAssertEqual(SSHTransport.readProbe("JACK-SSH-OK\n/usr/local/bin/claude\n").reachable, true)
        XCTAssertEqual(SSHTransport.readProbe("JACK-SSH-OK\n/usr/local/bin/claude\n").claudePath, "/usr/local/bin/claude")
        XCTAssertNil(SSHTransport.readProbe("JACK-SSH-OK\nJACK-NO-CLAUDE\n").claudePath)
        XCTAssertFalse(SSHTransport.readProbe("Permission denied\n").reachable)
        let args = SSHTransport.probeArguments(endpoint: endpoint)
        XCTAssertEqual(args.last, SSHTransport.probeCommand)
    }

    func testClaudeFinderCoversEveryInstallLocation() {
        let script = SSHTransport.claudeFinderScript
        for place in [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".nvm/versions/node/*/bin",
                      ".fnm/node-versions", ".asdf/shims", "/opt/homebrew/bin", "/usr/local/bin", "/snap/bin", ".nix-profile/bin"] {
            XCTAssertTrue(script.contains(place), "missing \(place)")
        }
        XCTAssertTrue(script.contains("command -v claude"))
        XCTAssertTrue(script.contains("-lic"), "falls back to the login shell PATH")
    }

    func testClaudeFinderFindsAndRunsClaude() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jack-finder-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\necho fake-claude \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: home) }
        let command = SSHTransport.remoteCommand(remoteEnv: [:], remoteExecutable: "claude",
                                                 remoteArgs: ["--print", "a b"], remoteDirectory: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "fake-claude --print a b\n")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", SSHTransport.probeCommand]
        probe.environment = process.environment
        let probePipe = Pipe()
        probe.standardOutput = probePipe
        try probe.run()
        probe.waitUntilExit()
        let result = SSHTransport.readProbe(String(data: probePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        XCTAssertEqual(result.claudePath, fake.path)
    }

    @MainActor func testRemoteLaunchNeedsValidEndpoint() {
        var local = ChatConversation(projectPath: "/tmp", provider: .claude)
        XCTAssertNil(ChatRunConfiguration.claudeRemoteLaunch(conversation: local, delegation: nil, remotePort: 18791))
        local.remote = ChatRemoteEndpoint(destination: "", remotePath: "/tmp/x")
        XCTAssertNil(ChatRunConfiguration.claudeRemoteLaunch(conversation: local, delegation: nil, remotePort: 18791))
    }

    @MainActor func testRemoteLaunchWithoutDelegation() throws {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude)
        conversation.remote = endpoint
        conversation.extraDirectories = ["/Users/brian/Extra"]
        let launch = try XCTUnwrap(ChatRunConfiguration.claudeRemoteLaunch(conversation: conversation, delegation: nil, remotePort: 18791))
        XCTAssertFalse(launch.sshArguments.contains { $0.hasPrefix("-R") })
        XCTAssertEqual(launch.localDirectory, "/tmp")
        let command = try XCTUnwrap(launch.sshArguments.last)
        XCTAssertTrue(command.contains("cd '/Users/ruben/Jack'"))
        XCTAssertTrue(command.contains("CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="))
        XCTAssertFalse(command.contains("--add-dir"), "local folders do not exist remotely")
        XCTAssertFalse(command.contains("--mcp-config"), "no delegation, no MCP tools")
        XCTAssertNil(launch.delegation)
    }

    @MainActor func testRemoteLaunchRewritesDelegationThroughTunnel() throws {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude)
        conversation.remote = endpoint
        let delegation = ChatDelegation(url: URL(string: "http://127.0.0.1:51234/mcp")!, token: "secret", delegates: true)
        let launch = try XCTUnwrap(ChatRunConfiguration.claudeRemoteLaunch(conversation: conversation, delegation: delegation, remotePort: 18791))
        let rewritten = try XCTUnwrap(launch.delegation)
        XCTAssertEqual(rewritten.url.absoluteString, "http://127.0.0.1:18791/mcp")
        XCTAssertEqual(rewritten.token, "secret")
        XCTAssertTrue(launch.sshArguments.contains("127.0.0.1:18791:127.0.0.1:51234"))
        let command = try XCTUnwrap(launch.sshArguments.last)
        XCTAssertTrue(command.contains("--mcp-config"))
        // JSON escapes slashes, so look for the tunnel port rather than the literal URL.
        XCTAssertTrue(command.contains("18791"), "remote claude must call back through the tunnel")
        XCTAssertTrue(command.contains("MCP_TOOL_TIMEOUT="))
        XCTAssertTrue(command.contains("960000"))
        XCTAssertTrue(ChatRunConfiguration.claudeLaunchSignature(conversation).contains("ssh:ruben@192.168.1.193"),
                      "switching machines restarts the session")
    }

    @MainActor func testRemoteLaunchRejectsNonLoopbackDelegation() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude)
        conversation.remote = endpoint
        let delegation = ChatDelegation(url: URL(string: "http://10.0.0.5:51234/mcp")!, token: "secret", delegates: true)
        XCTAssertNil(ChatRunConfiguration.claudeRemoteLaunch(conversation: conversation, delegation: delegation, remotePort: 18791))
    }

    @MainActor func testRemoteLaunchFallsBackDirectoryAndSkipsSuggestionsForSubagents() throws {
        var conversation = ChatConversation(projectPath: "/no/existe", provider: .claude)
        conversation.remote = endpoint
        conversation.parentID = UUID()
        let launch = try XCTUnwrap(ChatRunConfiguration.claudeRemoteLaunch(conversation: conversation, delegation: nil, remotePort: 18791))
        XCTAssertEqual(launch.localDirectory, NSTemporaryDirectory())
        XCTAssertFalse(try XCTUnwrap(launch.sshArguments.last).contains("CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"))
    }

    @MainActor func testLocalSettingsStillSendAddDir() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude)
        conversation.extraDirectories = ["/Users/brian/Extra"]
        XCTAssertTrue(ChatRunConfiguration.claudeSettings(conversation).contains("--add-dir"))
        conversation.remote = endpoint
        XCTAssertFalse(ChatRunConfiguration.claudeSettings(conversation).contains("--add-dir"))
        XCTAssertEqual(ChatRunConfiguration.claudeLaunchSignature(conversation).prefix(2), ["/tmp", "high"])
    }

    @MainActor func testCreateAttachesRemoteOnlyToClaude() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-remote-create-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("chats")), preferences: nil)
        defer { store.shutdown() }
        let remote = ChatRemoteEndpoint(destination: "ruben@192.168.1.193", remotePath: "/Users/ruben/X")
        let claude = try XCTUnwrap(store.create(projectPath: folder.path, provider: .claude, remote: remote))
        XCTAssertEqual(store.conversations.first { $0.id == claude }?.remote, remote)
        let codex = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex, remote: remote))
        XCTAssertNil(store.conversations.first { $0.id == codex }?.remote, "remote agents only exist for Claude Code")
    }

    // Runs `printf %s <quoted>` through a real shell and returns what came back.
    private func shEcho(_ quoted: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "sh", code: Int(process.terminationStatus)) }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

final class SSHTerminalTests: XCTestCase {
    func testTerminalAllocatesTtyAndChangesFolder() {
        let endpoint = ChatRemoteEndpoint(destination: "ruben@10.0.0.2", remotePath: "/Users/ruben/App")
        let args = SSHTransport.terminalArguments(endpoint: endpoint)
        XCTAssertEqual(args.first, "-t")
        XCTAssertFalse(args.contains("BatchMode=yes"), "a person can answer prompts in the terminal")
        XCTAssertTrue(args.contains("ruben@10.0.0.2"))
        XCTAssertTrue(args.last!.contains("/Users/ruben/App"))
        XCTAssertTrue(args.last!.contains("-l"))
    }

    func testTerminalWithoutFolderOpensHome() {
        let args = SSHTransport.terminalArguments(endpoint: ChatRemoteEndpoint(destination: "a@b"))
        XCTAssertFalse(args.last!.contains("cd "))
    }
}
