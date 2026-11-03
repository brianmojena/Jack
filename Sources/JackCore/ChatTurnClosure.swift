import Foundation
import CryptoKit

/// Evidence collected for a completed Normal-mode turn. This value performs no I/O:
/// callers provide events and Git snapshots captured by Jack. Light should not create
/// or evaluate these values as part of its existing turn lifecycle.
public struct ChatTurnClosure: Codable, Equatable, Identifiable {
    public var id: String
    public var generationID: String
    public var conversationID: UUID
    public var completedAt: Date
    public var ending: ChatTurnEnding
    /// Message that ended the turn, when Jack has one to anchor the closure beside.
    public var transcriptMessageID: String?
    /// Only structured events supplied by Jack. Agent prose is stored separately below.
    public var capturedEvents: [ChatTurnCapturedEvent]
    /// File differences between two Git snapshots, without claiming who caused them.
    public var observedFileChanges: [ChatTurnFileChange]
    /// Whether both snapshots existed, and when Jack captured them. An unavailable
    /// comparison must not be displayed as an observed clean worktree.
    public var gitComparison: ChatTurnGitComparison
    /// Text from the agent, retained as an attributed claim rather than verified evidence.
    public var agentStatements: [ChatTurnAgentStatement]
    public var reviewedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), generationID: String? = nil, conversationID: UUID, completedAt: Date,
                transcriptMessageID: String? = nil,
                ending: ChatTurnEnding, capturedEvents: [ChatTurnCapturedEvent],
                observedFileChanges: [ChatTurnFileChange], gitComparison: ChatTurnGitComparison,
                agentStatements: [ChatTurnAgentStatement], reviewedAt: Date? = nil) {
        self.id = id
        self.generationID = generationID ?? id
        self.conversationID = conversationID
        self.completedAt = completedAt
        self.ending = ending
        self.transcriptMessageID = transcriptMessageID
        self.capturedEvents = capturedEvents
        self.observedFileChanges = observedFileChanges
        self.gitComparison = gitComparison
        self.agentStatements = agentStatements
        self.reviewedAt = reviewedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, generationID, conversationID, completedAt, ending, transcriptMessageID
        case capturedEvents, observedFileChanges, gitComparison, agentStatements, reviewedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        generationID = try values.decodeIfPresent(String.self, forKey: .generationID) ?? id
        conversationID = try values.decode(UUID.self, forKey: .conversationID)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        ending = try values.decode(ChatTurnEnding.self, forKey: .ending)
        transcriptMessageID = try values.decodeIfPresent(String.self, forKey: .transcriptMessageID)
        capturedEvents = try values.decodeIfPresent([ChatTurnCapturedEvent].self, forKey: .capturedEvents) ?? []
        observedFileChanges = try values.decodeIfPresent([ChatTurnFileChange].self, forKey: .observedFileChanges) ?? []
        gitComparison = try values.decodeIfPresent(ChatTurnGitComparison.self, forKey: .gitComparison)
            ?? ChatTurnGitComparison(status: .unavailable, headBefore: nil, headAfter: nil, beforeObservedAt: nil, afterObservedAt: nil)
        agentStatements = try values.decodeIfPresent([ChatTurnAgentStatement].self, forKey: .agentStatements) ?? []
        reviewedAt = try values.decodeIfPresent(Date.self, forKey: .reviewedAt)
    }

    /// Captured check outcomes only. A command string without an observed exit status
    /// remains unknown and is never promoted to a passed check.
    public var checks: [ChatTurnCheckResult] {
        capturedEvents.compactMap { event in
            guard event.kind == .check else { return nil }
            let result: ChatTurnCheckStatus
            if let exitStatus = event.exitStatus {
                result = exitStatus == 0 ? .passed : .failed
            } else {
                result = .unknown
            }
            return ChatTurnCheckResult(eventID: event.id, title: event.title, command: event.command,
                                       exitStatus: event.exitStatus, observedAt: event.observedAt, status: result)
        }
    }

    /// Items the agent explicitly reported as remaining work. These are statements,
    /// not Jack-verified facts.
    public var declaredPendingItems: [ChatTurnAgentStatement] {
        agentStatements.filter { $0.kind == .pending }
    }
}

public enum ChatTurnEnding: String, Codable, Equatable {
    case completed
    case failed
    case interrupted
}

/// Structured metadata captured by Jack while the turn runs. `exitStatus` is populated
/// only when Jack observes the process/tool result carrying that status.
public struct ChatTurnCapturedEvent: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: Kind
    public var title: String
    public var command: String?
    public var exitStatus: Int?
    /// Provider-reported state for a tool activity; it is not an exit status.
    public var status: String?
    public var observedAt: Date

    public init(id: String, kind: Kind, title: String, command: String? = nil,
                exitStatus: Int? = nil, status: String? = nil, observedAt: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.command = command
        self.exitStatus = exitStatus
        self.status = status
        self.observedAt = observedAt
    }

    public enum Kind: String, Codable, Equatable {
        /// An explicitly designated check/build/test event, not inferred from command text.
        case check
        case tool
        case other
    }
}

public enum ChatTurnCheckStatus: String, Codable, Equatable {
    case passed
    case failed
    case unknown
}

public struct ChatTurnCheckResult: Codable, Equatable, Identifiable {
    public var eventID: String
    public var id: String { eventID }
    public var title: String
    public var command: String?
    public var exitStatus: Int?
    public var observedAt: Date
    public var status: ChatTurnCheckStatus
}

/// One raw file status in a Git snapshot taken by Jack. Status text is preserved so the
/// producer may use porcelain codes or another stable Git status representation.
public struct ChatTurnGitFile: Codable, Equatable, Identifiable {
    public var path: String
    public var status: String
    /// Git blob ID for HEAD entries, or a bounded working-file fingerprint. The latter
    /// combines metadata with a SHA-256 of a prefix; it is not a Git blob identity.
    public var fingerprint: String?
    public var id: String { path }

    public init(path: String, status: String, fingerprint: String? = nil) {
        self.path = path
        self.status = status
        self.fingerprint = fingerprint
    }
}

public struct ChatTurnGitSnapshot: Codable, Equatable {
    public var observedAt: Date
    public var head: String?
    public var files: [ChatTurnGitFile]

    public init(observedAt: Date, head: String? = nil, files: [ChatTurnGitFile]) {
        self.observedAt = observedAt
        self.head = head
        self.files = files
    }

    /// Captures Git's current tree plus bounded worktree fingerprints. All subprocesses are
    /// asynchronous. File metadata and streamed reads run on a utility executor, not the
    /// caller's actor. `normalMode` is rechecked before each subprocess and filesystem read;
    /// a mode change aborts the snapshot rather than starting more capture work.
    public static func capture(in projectPath: String,
                               normalMode: @escaping @MainActor @Sendable () -> Bool = { true }) async -> ChatTurnGitSnapshot? {
        guard await normalMode() else { return nil }
        let rootResult = await Git.run(["rev-parse", "--show-toplevel"], in: projectPath,
                                       timeout: .seconds(10), outputLimit: 64 * 1024)
        guard await normalMode(), rootResult.succeeded else { return nil }
        let rootPath = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return nil }

        guard await normalMode() else { return nil }
        let statusResult = await Git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
                                         in: rootPath, timeout: .seconds(15), outputLimit: 16 * 1024 * 1024)
        guard await normalMode(), statusResult.succeeded, !isTruncated(statusResult.output) else { return nil }
        let status = Git.parseStatus(statusResult.output)
        guard status.isRepository else { return nil }

        guard await normalMode() else { return nil }
        let headResult = await Git.run(["rev-parse", "--verify", "HEAD"], in: rootPath,
                                       timeout: .seconds(10), outputLimit: 64 * 1024)
        guard await normalMode(), headResult.succeeded else { return nil }
        let head = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }

        guard await normalMode() else { return nil }
        let tree = await Git.run(["ls-tree", "-r", "-z", head], in: rootPath,
                                 timeout: .seconds(30), outputLimit: 32 * 1024 * 1024)
        guard await normalMode(), tree.succeeded, !isTruncated(tree.output) else { return nil }

        var files: [ChatTurnGitFile] = []
        for entry in tree.output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let metadata = entry[..<tab].split(separator: " ")
            guard metadata.count >= 3 else { continue }
            files.append(ChatTurnGitFile(path: String(entry[entry.index(after: tab)...]), status: "HEAD",
                                         fingerprint: "\(metadata[0]):\(metadata[2])"))
        }

        for file in status.files {
            guard await normalMode() else { return nil }
            let rawStatus = [file.staged.map(String.init), file.unstaged.map(String.init)]
                .compactMap { $0 }.joined()
            let normalizedStatus = file.untracked ? "??" : rawStatus
            // Status ran with the repository root as its working directory, so porcelain
            // paths are root-relative even when the conversation began in a subdirectory.
            let url = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(file.path)
            guard let fingerprint = await workingFingerprint(at: url, normalMode: normalMode) else { return nil }
            files.removeAll { $0.path == file.path }
            files.append(ChatTurnGitFile(path: file.path, status: normalizedStatus, fingerprint: fingerprint))
        }
        return ChatTurnGitSnapshot(observedAt: Date(), head: head, files: files)
    }

    private static let workingHashLimit = 1024 * 1024
    private static let readChunkSize = 64 * 1024

    private static func isTruncated(_ output: String) -> Bool {
        output.hasSuffix("\n[Salida truncada]")
    }

    /// Fingerprint metadata plus at most the first MiB of file content. Streaming keeps peak
    /// memory bounded even for large untracked downloads. This is a comparison hint, not proof
    /// that the complete working file matches a Git object.
    private static func workingFingerprint(at url: URL,
                                           normalMode: @escaping @MainActor @Sendable () -> Bool) async -> String? {
        guard await normalMode() else { return nil }
        return await Task.detached(priority: .utility) {
            guard await normalMode() else { return nil }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                // A deleted path is a meaningful working-tree state. Other metadata failures
                // are retained as unknown metadata while the Git status remains observable.
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                    return "missing"
                }
                return "metadata-unavailable"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.stringValue ?? "?"
            let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "?"
            let metadata = "size=\(size)|mtime=\(modified)|\(type)|mode=\(permissions)"

            guard await normalMode() else { return nil }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "\(metadata)|prefix-unavailable" }
            defer { try? handle.close() }
            var hasher = SHA256()
            var remaining = workingHashLimit
            while remaining > 0 {
                guard await normalMode() else { return nil }
                let count = min(readChunkSize, remaining)
                guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                remaining -= chunk.count
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return "\(metadata)|prefix-sha256=\(digest)|prefix-bytes=\(workingHashLimit - remaining)"
        }.value
    }
}

public struct ChatTurnGitComparison: Codable, Equatable {
    public var status: Status
    public var headBefore: String?
    public var headAfter: String?
    public var beforeObservedAt: Date?
    public var afterObservedAt: Date?

    public enum Status: String, Codable, Equatable {
        case compared
        case unavailable
    }
}

/// Difference observed by comparing the before/after Git snapshots. This records temporal
/// association only: concurrent edits may be included, so causation is deliberately unset.
public struct ChatTurnFileChange: Codable, Equatable, Identifiable {
    public var path: String
    public var beforeStatus: String?
    public var afterStatus: String?
    /// Bounded patch Jack read from Git near turn completion; it can include concurrent changes.
    public var diff: String?
    public var id: String { path }
    public var attribution: Attribution { .notEstablished }

    public enum Attribution: String, Codable, Equatable {
        case notEstablished
    }
}

public struct ChatTurnAgentStatement: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: Kind
    public var text: String
    public var source: Source { .agent }

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    public enum Kind: String, Codable, Equatable {
        case summary
        case pending
    }

    public enum Source: String, Codable, Equatable {
        case agent
    }
}

/// Pure evaluator used by Normal-mode integration once Jack has collected evidence.
public enum ChatTurnClosureEvaluator {
    public static func evaluate(conversationID: UUID, completedAt: Date, ending: ChatTurnEnding,
                                events: [ChatTurnCapturedEvent],
                                gitBefore: ChatTurnGitSnapshot?, gitAfter: ChatTurnGitSnapshot?,
                                agentSummary: String? = nil, agentPendingItems: [String] = [],
                                transcriptMessageID: String? = nil) -> ChatTurnClosure {
        var statements: [ChatTurnAgentStatement] = []
        if let agentSummary, !agentSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statements.append(ChatTurnAgentStatement(kind: .summary, text: agentSummary))
        }
        let pendingClaims = agentPendingItems.isEmpty ? extractPendingDeclarations(from: agentSummary ?? "") : agentPendingItems
        statements += pendingClaims
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ChatTurnAgentStatement(kind: .pending, text: $0) }

        return ChatTurnClosure(conversationID: conversationID, completedAt: completedAt,
                               transcriptMessageID: transcriptMessageID, ending: ending,
                               capturedEvents: events,
                               observedFileChanges: fileChanges(before: gitBefore, after: gitAfter),
                               gitComparison: ChatTurnGitComparison(status: gitBefore != nil && gitAfter != nil ? .compared : .unavailable,
                                                                   headBefore: gitBefore?.head, headAfter: gitAfter?.head,
                                                                   beforeObservedAt: gitBefore?.observedAt,
                                                                   afterObservedAt: gitAfter?.observedAt),
                               agentStatements: statements)
    }

    private static func fileChanges(before: ChatTurnGitSnapshot?, after: ChatTurnGitSnapshot?) -> [ChatTurnFileChange] {
        guard let before, let after else { return [] }
        let old = Dictionary(before.files.map { ($0.path, "\($0.status)|\($0.fingerprint ?? "")") }, uniquingKeysWith: { _, latest in latest })
        let new = Dictionary(after.files.map { ($0.path, "\($0.status)|\($0.fingerprint ?? "")") }, uniquingKeysWith: { _, latest in latest })
        return Set(old.keys).union(new.keys).sorted().compactMap { path in
            let oldStatus = old[path]
            let newStatus = new[path]
            guard oldStatus != newStatus else { return nil }
            return ChatTurnFileChange(path: path, beforeStatus: oldStatus?.components(separatedBy: "|").first,
                                      afterStatus: newStatus?.components(separatedBy: "|").first)
        }
    }

    /// Extracts only an explicitly labeled pending section. It does not infer unfinished work
    /// from general prose, and every result remains attributed to the agent.
    public static func extractPendingDeclarations(from summary: String) -> [String] {
        let pendingHeadings: Set<String> = ["pendiente", "pendientes", "por hacer", "siguientes pasos", "pending", "pending items", "next steps"]
        var collecting = false
        var result: [String] = []
        for rawLine in summary.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { collecting = false; continue }
            let headingText = line.drop { $0 == "#" || $0 == " " || $0 == "*" }.lowercased()
            let heading = headingText.trimmingCharacters(in: CharacterSet(charactersIn: ":* "))
            if pendingHeadings.contains(heading) || pendingHeadings.contains(String(headingText.prefix { $0 != ":" })) {
                collecting = true
                if let colon = line.firstIndex(of: ":") {
                    let remainder = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty { result.append(remainder) }
                }
                continue
            }
            guard collecting else { continue }
            let item = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
            if item.first?.isNumber == true, let delimiter = item.firstIndex(where: { $0 == "." || $0 == ")" }) {
                result.append(item[item.index(after: delimiter)...].trimmingCharacters(in: .whitespacesAndNewlines))
            } else if rawLine.hasPrefix("-") || rawLine.hasPrefix("•") || rawLine.hasPrefix("*") {
                result.append(item)
            } else {
                collecting = false
            }
        }
        var seen = Set<String>()
        return result.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
