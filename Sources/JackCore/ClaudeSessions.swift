import Foundation

/// A Claude Code session saved by the CLI, as `claude --resume` lists it.
public struct ClaudeSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let projectPath: String
    public let updatedAt: Date
    /// The model alias, when the Claude app recorded it.
    public var model: String? = nil
    /// What started the session: "cli" in a terminal, "claude-desktop" in the Claude app, "sdk-…" for other programs (Jack among them).
    public var entrypoint: String? = nil
    public init(id: String, title: String, projectPath: String, updatedAt: Date, model: String? = nil, entrypoint: String? = nil) {
        self.id = id; self.title = title; self.projectPath = projectPath; self.updatedAt = updatedAt; self.model = model; self.entrypoint = entrypoint
    }
}

/// What the Claude app keeps about one of its Claude Code sessions; the transcript itself is the CLI's.
struct ClaudeDesktopSession: Equatable {
    var title: String?
    var model: String?
    var hidden: Bool
}

/// Reads the sessions Claude Code keeps in `~/.claude/projects`, so a conversation started in a terminal
/// can continue in Jack and the other way round: both resume the same session id.
public enum ClaudeSessions {
    public static var root: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    /// The CLI names each project's folder after its path with every other character turned into "-".
    public static func folderName(for projectPath: String) -> String {
        String(projectPath.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The Claude app's own list of Claude Code sessions, one JSON file each.
    public static var desktopRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// The most recent sessions, of every project or of one.
    public static func list(projectPath: String? = nil, limit: Int = 60, root: URL = root) -> [ClaudeSessionSummary] {
        files(projectPath: projectPath, root: root).prefix(limit).compactMap { file in
            summary(file.url, date: file.date, projectPath: projectPath)
        }
    }

    /// Sessions worth bringing into Jack: started by the user in a terminal or the Claude app since `since`,
    /// in folders that still exist, newest first. The Claude app's titles and models win, and the sessions it
    /// archived or ran in its scratch folders are left out, as are those in `excluding` and other programs' sessions.
    public static func importCandidates(since: Date, limit: Int, excluding: Set<String> = [], root: URL = root, desktopRoot: URL = desktopRoot) -> [ClaudeSessionSummary] {
        let desktop = desktopSessions(root: desktopRoot)
        var found: [ClaudeSessionSummary] = []
        for file in files(projectPath: nil, root: root) {
            guard found.count < limit, file.date >= since else { break }
            let id = file.url.deletingPathExtension().lastPathComponent
            let app = desktop[id]
            guard !excluding.contains(id), app?.hidden != true,
                  var session = summary(file.url, date: file.date, projectPath: nil),
                  !(session.entrypoint ?? "").hasPrefix("sdk") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: session.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let title = app?.title { session = ClaudeSessionSummary(id: session.id, title: String(title.prefix(120)), projectPath: session.projectPath, updatedAt: session.updatedAt, entrypoint: session.entrypoint) }
            session.model = app?.model
            found.append(session)
        }
        return found
    }

    /// The Claude app's sessions by their CLI session id.
    static func desktopSessions(root: URL) -> [String: ClaudeDesktopSession] {
        var result: [String: ClaudeDesktopSession] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return result }
        for case let url as URL in walker where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value["cliSessionId"] as? String else { continue }
            let cwd = value["cwd"] as? String ?? ""
            let title = (value["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            result[id] = ClaudeDesktopSession(
                title: title,
                model: (value["model"] as? String).flatMap(alias(of:)),
                hidden: value["isArchived"] as? Bool == true || cwd.contains("/Claude/scratch-workspaces/")
            )
        }
        return result
    }

    /// Transcript files, newest first.
    private static func files(projectPath: String?, root: URL) -> [(url: URL, date: Date)] {
        let manager = FileManager.default
        let folders: [URL]
        if let projectPath { folders = [root.appendingPathComponent(folderName(for: projectPath), isDirectory: true)] }
        else { folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] }
        var files: [(url: URL, date: Date)] = []
        for folder in folders {
            let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for url in entries where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard (values?.fileSize ?? 0) > 0 else { continue }
                files.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        return files.sorted { $0.date > $1.date }
    }

    /// "opus" for "claude-opus-5-5", and so on.
    static func alias(of model: String) -> String? {
        ["fable", "opus", "sonnet", "haiku"].first { model.contains($0) }
    }

    /// Title and folder from the ends of the file: the title lines are appended as the session goes,
    /// and the first message records the working directory.
    static func summary(_ url: URL, date: Date, projectPath: String?) -> ClaudeSessionSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 96 * 1024)) ?? Data()
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 192 * 1024 ? size - 192 * 1024 : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        var custom: String?, generated: String?, lastPrompt: String?, firstPrompt: String?, entrypoint: String?, cwd = projectPath
        for line in lines(tail) {
            switch line["type"] as? String {
            case "custom-title": custom = line["customTitle"] as? String ?? custom
            case "ai-title": generated = line["aiTitle"] as? String ?? generated
            case "summary": generated = generated ?? line["summary"] as? String
            case "last-prompt": lastPrompt = line["lastPrompt"] as? String ?? lastPrompt
            default: break
            }
        }
        let title = custom ?? generated
        for line in lines(head) {
            if cwd == nil, let value = line["cwd"] as? String { cwd = value }
            if entrypoint == nil, let value = line["entrypoint"] as? String { entrypoint = value }
            if firstPrompt == nil, line["type"] as? String == "user", line["isMeta"] as? Bool != true,
               let text = (line["message"] as? [String: Any])?["content"] as? String, !text.hasPrefix("<") { firstPrompt = text }
            if cwd != nil, firstPrompt != nil, entrypoint != nil { break }
        }
        guard let cwd, let label = title ?? firstPrompt ?? lastPrompt else { return nil }
        let oneLine = label.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return ClaudeSessionSummary(id: url.deletingPathExtension().lastPathComponent, title: String(oneLine.prefix(120)), projectPath: cwd, updatedAt: date, entrypoint: entrypoint)
    }

    /// The session's conversation as Jack shows it, and the model alias it last used.
    public static func load(_ session: ClaudeSessionSummary, root: URL = root) -> (messages: [ChatMessage], model: String?) {
        let url = root.appendingPathComponent(folderName(for: session.projectPath)).appendingPathComponent(session.id + ".jsonl")
        guard let data = try? Data(contentsOf: url) else { return ([], nil) }
        return messages(from: data)
    }

    /// Prompts, replies, reasoning and tool calls with their results.
    static func messages(from data: Data) -> (messages: [ChatMessage], model: String?) {
        var model: String?
        var messages: [ChatMessage] = []
        var toolIndex: [String: Int] = [:]
        var toolInputs: [String: String] = [:]
        for line in lines(data) {
            guard line["isSidechain"] as? Bool != true, line["isMeta"] as? Bool != true, line["isCompactSummary"] as? Bool != true,
                  let message = line["message"] as? [String: Any] else { continue }
            let uuid = line["uuid"] as? String ?? UUID().uuidString
            switch line["type"] as? String {
            case "user":
                if let text = message["content"] as? String {
                    if let prompt = typedPrompt(text) { messages.append(ChatMessage(id: uuid, role: "user", text: prompt)) }
                    continue
                }
                let blocks = message["content"] as? [[String: Any]] ?? []
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.compactMap(typedPrompt).joined(separator: "\n")
                if !text.isEmpty { messages.append(ChatMessage(id: uuid, role: "user", text: text)) }
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String, let index = toolIndex[id] else { continue }
                    let result = ClaudeProtocol.resultText(block["content"])
                    messages[index].detail = String(((toolInputs[id].map { $0 + "\n" } ?? "") + result).prefix(65_536))
                    messages[index].status = block["is_error"] as? Bool == true ? "failed" : "completed"
                }
            case "assistant":
                if let name = message["model"] as? String, let short = alias(of: name) { model = short }
                for (offset, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                    let id = "\(uuid):\(offset)"
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty { messages.append(ChatMessage(id: id, role: "assistant", text: text)) }
                    case "thinking":
                        if let text = block["thinking"] as? String, !text.isEmpty { messages.append(ChatMessage(id: id, role: "reasoning", text: text)) }
                    case "tool_use":
                        let name = block["name"] as? String ?? "Herramienta"
                        guard !ClaudeProtocol.hiddenTools.contains(name) else { continue }
                        let input = String(boundedJSON(block["input"] ?? [String: Any]()).prefix(65_536))
                        let toolID = block["id"] as? String ?? id
                        toolIndex[toolID] = messages.count
                        toolInputs[toolID] = input
                        messages.append(ChatMessage(id: toolID, role: "tool", text: name, detail: input, status: "completed"))
                    default: break
                    }
                }
            default: break
            }
        }
        return (messages, model)
    }

    /// What the user typed: slash commands are shown as typed and the CLI's own wrappers are left out.
    static func typedPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("<") else { return trimmed }
        guard let name = tag("command-name", in: trimmed) else { return nil }
        let arguments = tag("command-args", in: trimmed) ?? ""
        return ((name.hasPrefix("/") ? name : "/" + name) + (arguments.isEmpty ? "" : " " + arguments))
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
}
