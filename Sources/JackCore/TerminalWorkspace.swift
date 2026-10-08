import Foundation

/// Metadata only. Terminal output, prompts and Claude's transcript stay with the CLI.
public struct TerminalWorkspaceEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case claude, shell }
    public var id: UUID
    public var title: String
    public var projectPath: String
    public var kind: Kind
    public var claudeSessionID: UUID

    public init(id: UUID = UUID(), title: String, projectPath: String, kind: Kind, claudeSessionID: UUID = UUID()) {
        self.id = id; self.title = title; self.projectPath = projectPath; self.kind = kind; self.claudeSessionID = claudeSessionID
    }

    /// Native interactive Claude: no SDK/print protocol, injected instructions or Jack MCP server.
    /// Resume only a transcript actually saved by Claude (an untouched prompt has none).
    public func claudeArguments(root: URL = ClaudeSessions.root) -> [String] {
        let session = claudeSessionID.uuidString.lowercased()
        let transcript = root.appendingPathComponent(ClaudeSessions.folderName(for: projectPath), isDirectory: true)
            .appendingPathComponent(session + ".jsonl")
        let saved = FileManager.default.fileExists(atPath: transcript.path)
        return ["--effort", "medium", "--prompt-suggestions", "false", saved ? "--resume" : "--session-id", session]
    }
}

public struct TerminalWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var entries: [TerminalWorkspaceEntry]
    public var selectedID: UUID?
    public init(entries: [TerminalWorkspaceEntry] = [], selectedID: UUID? = nil) {
        self.entries = entries; self.selectedID = selectedID
    }
}

/// Loaded lazily by the Normal terminal interface; restoring metadata never starts a process.
public struct TerminalWorkspaceArchive: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> TerminalWorkspaceSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return TerminalWorkspaceSnapshot() }
        var snapshot = try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: Data(contentsOf: url))
        var seen = Set<UUID>()
        snapshot.entries = snapshot.entries.filter { seen.insert($0.id).inserted && $0.projectPath.hasPrefix("/") }
        if !snapshot.entries.contains(where: { $0.id == snapshot.selectedID }) { snapshot.selectedID = snapshot.entries.first?.id }
        return snapshot
    }
    public func save(_ snapshot: TerminalWorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
