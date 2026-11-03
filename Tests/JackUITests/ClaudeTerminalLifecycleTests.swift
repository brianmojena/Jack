import XCTest
@testable import Jack
import JackCore

final class ClaudeTerminalLifecycleTests: XCTestCase {
    @MainActor func testClaudeClaimWaitsForConfirmedExitAfterWorkspaceDeallocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let executable = try makeExecutable(at: root.appendingPathComponent("claude"), contents: "#!/bin/sh\nexec /bin/sleep 30\n")
        let defaultsKey = "providerExecutablePath.claude"
        let previousExecutable = UserDefaults.standard.string(forKey: defaultsKey)
        UserDefaults.standard.set(executable.path, forKey: defaultsKey)
        defer {
            if let previousExecutable { UserDefaults.standard.set(previousExecutable, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }

        let entry = TerminalWorkspaceEntry(title: "Claude", projectPath: project.path, kind: .claude)
        let archive = TerminalWorkspaceArchive(url: root.appendingPathComponent("terminals.json"))
        try archive.save(TerminalWorkspaceSnapshot(entries: [entry], selectedID: entry.id))
        let store = ChatStore(archive: ChatArchive(directory: root.appendingPathComponent("chats")), preferences: nil)
        var workspace: NativeTerminalWorkspace? = NativeTerminalWorkspace(archive: archive)
        defer { workspace?.stopAll(); store.shutdown() }
        workspace?.attach(store)

        workspace?.start(entry.id, allowed: true)
        let session = try XCTUnwrap(workspace?.sessions[entry.id])
        XCTAssertGreaterThan(session.view.process.shellPid, 0)
        XCTAssertFalse(store.claimClaudeSessionForTerminal(entry.claudeSessionID))

        workspace?.stopAll()
        workspace = nil
        XCTAssertFalse(store.claimClaudeSessionForTerminal(entry.claudeSessionID), "The old process must keep ownership while termination is pending")
        var reclaimed = false
        for _ in 0..<300 {
            if store.claimClaudeSessionForTerminal(entry.claudeSessionID) { reclaimed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(session.running)
        XCTAssertTrue(reclaimed, "The process exit callback should release ownership")
        store.releaseClaudeSessionFromTerminal(entry.claudeSessionID)
        XCTAssertTrue(store.claimClaudeSessionForTerminal(entry.claudeSessionID), "Ownership should be available after the process exit callback")
        store.releaseClaudeSessionFromTerminal(entry.claudeSessionID)
    }

    @MainActor func testInvalidClaudeInterpreterExitsAndReleasesClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let executable = try makeExecutable(at: root.appendingPathComponent("claude"), contents: "#!/missing/jack-test-interpreter\n")
        let defaultsKey = "providerExecutablePath.claude"
        let previousExecutable = UserDefaults.standard.string(forKey: defaultsKey)
        UserDefaults.standard.set(executable.path, forKey: defaultsKey)
        defer {
            if let previousExecutable { UserDefaults.standard.set(previousExecutable, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }

        let entry = TerminalWorkspaceEntry(title: "Claude", projectPath: project.path, kind: .claude)
        let archive = TerminalWorkspaceArchive(url: root.appendingPathComponent("terminals.json"))
        try archive.save(TerminalWorkspaceSnapshot(entries: [entry], selectedID: entry.id))
        let store = ChatStore(archive: ChatArchive(directory: root.appendingPathComponent("chats")), preferences: nil)
        let workspace = NativeTerminalWorkspace(archive: archive)
        defer { workspace.stopAll(); store.shutdown() }
        workspace.attach(store)

        workspace.start(entry.id, allowed: true)

        let session = try XCTUnwrap(workspace.sessions[entry.id])
        XCTAssertGreaterThan(session.view.process.shellPid, 0, "SwiftTerm forks before execve, so a bad interpreter exits after spawn")
        var reclaimed = false
        for _ in 0..<300 {
            if store.claimClaudeSessionForTerminal(entry.claudeSessionID) { reclaimed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(session.running)
        XCTAssertTrue(reclaimed, "The failed child must release the session claim after its exit callback")
        store.releaseClaudeSessionFromTerminal(entry.claudeSessionID)
    }

    private func makeExecutable(at url: URL, contents: String) throws -> URL {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
