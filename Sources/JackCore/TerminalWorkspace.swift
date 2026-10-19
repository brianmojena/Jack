import Foundation

/// Metadata only. Terminal output, prompts and Claude's transcript stay with the CLI.
public struct TerminalWorkspaceEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case claude, shell, antigravity }
    public var id: UUID
    public var title: String
    public var projectPath: String
    public var kind: Kind
    public var claudeSessionID: UUID
    /// Antigravity handoffs keep both identifiers as optional metadata, so archives written before
    /// the native TUI existed still decode. Launching always rereads the live conversation: the
    /// stored session may be stale and must never be resumed by itself.
    public var antigravityConversationID: UUID? = nil
    public var antigravitySessionID: String? = nil

    public init(id: UUID = UUID(), title: String, projectPath: String, kind: Kind, claudeSessionID: UUID = UUID(),
                antigravityConversationID: UUID? = nil, antigravitySessionID: String? = nil) {
        self.id = id; self.title = title; self.projectPath = projectPath; self.kind = kind; self.claudeSessionID = claudeSessionID
        self.antigravityConversationID = antigravityConversationID
        self.antigravitySessionID = antigravitySessionID
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

    /// Native interactive Antigravity TUI. It resumes an existing conversation in the project folder
    /// with the model, effort and permission mode the chat had. No prompt is sent and no headless
    /// protocol is involved: approvals happen in the terminal.
    public static func antigravityArguments(conversation: ChatConversation) -> [String] {
        guard conversation.provider == .antigravity else { return [] }
        var arguments: [String] = []
        if let session = conversation.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty {
            arguments += ["--conversation", session]
        }
        let model = conversation.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { arguments += ["--model", model] }
        let effort = conversation.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { arguments += ["--effort", effort] }
        if let mode = conversation.mode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty {
            arguments += ["--mode", mode]
        }
        var seen = Set<String>()
        for directory in conversation.additionalDirectories where seen.insert(directory).inserted {
            arguments += ["--add-dir", directory]
        }
        return arguments
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
