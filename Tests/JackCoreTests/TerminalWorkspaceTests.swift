import XCTest
@testable import JackCore

final class TerminalWorkspaceTests: XCTestCase {
    func testNativeClaudeCreatesThenResumesItsOwnSessionWithoutChatProtocol() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = TerminalWorkspaceEntry(title: "Claude", projectPath: "/tmp/project with 'quotes' $(echo nope)", kind: .claude)
        let id = entry.claudeSessionID.uuidString.lowercased()
        let fresh = entry.claudeArguments(root: root)
        XCTAssertEqual(fresh, ["--effort", "medium", "--prompt-suggestions", "false", "--session-id", id])
        for flag in ["--print", "--input-format", "--output-format", "--mcp-config", "--append-system-prompt"] {
            XCTAssertFalse(fresh.contains(flag))
        }
        let folder = root.appendingPathComponent(ClaudeSessions.folderName(for: entry.projectPath))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent(id + ".jsonl"))
        XCTAssertEqual(entry.claudeArguments(root: root), ["--effort", "medium", "--prompt-suggestions", "false", "--resume", id])
    }

    func testMetadataRoundTripsWithoutTerminalOutputAndKeepsSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TerminalWorkspaceArchive(url: root.appendingPathComponent("nested/terminals.json"))
        XCTAssertEqual(try archive.load(), TerminalWorkspaceSnapshot())
        let first = TerminalWorkspaceEntry(title: "Claude 🙂", projectPath: "/tmp/project", kind: .claude)
        let second = TerminalWorkspaceEntry(title: "Build", projectPath: "/tmp/project", kind: .shell)
        let expected = TerminalWorkspaceSnapshot(entries: [first, second], selectedID: second.id)
        try archive.save(expected)
        XCTAssertEqual(try archive.load(), expected)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: archive.url)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["entries", "selectedID"])
        let rows = object["entries"] as! [[String: Any]]
        XCTAssertEqual(Set(rows[0].keys), ["id", "title", "projectPath", "kind", "claudeSessionID"])
    }

    func testStaleSelectionAndDuplicateEntriesAreRepairedWithoutChangingSessionIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TerminalWorkspaceArchive(url: root.appendingPathComponent("terminals.json"))
        let entry = TerminalWorkspaceEntry(title: "Claude", projectPath: "/tmp", kind: .claude)
        let invalid = TerminalWorkspaceEntry(title: "Invalid", projectPath: "relative", kind: .shell)
        try archive.save(TerminalWorkspaceSnapshot(entries: [entry, entry, invalid], selectedID: UUID()))
        let restored = try archive.load()
        XCTAssertEqual(restored.entries, [entry])
        XCTAssertEqual(restored.selectedID, entry.id)
        XCTAssertEqual(restored.entries.first?.claudeSessionID, entry.claudeSessionID)
    }

    func testCorruptArchiveIsReportedWithoutOverwritingIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("{broken".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try TerminalWorkspaceArchive(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
