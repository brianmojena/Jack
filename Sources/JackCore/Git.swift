import Foundation

/// A project's state as `git status` sees it.
public struct GitStatus: Equatable, Sendable {
    public var isRepository: Bool
    /// The branch checked out; nil when HEAD is detached.
    public var branch: String?
    /// The short hash of HEAD; nil before the first commit.
    public var head: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var files: [GitFileChange] = []

    public init(isRepository: Bool, branch: String? = nil, head: String? = nil, upstream: String? = nil,
                ahead: Int = 0, behind: Int = 0, files: [GitFileChange] = []) {
        self.isRepository = isRepository
        self.branch = branch
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }

    public static let notRepository = GitStatus(isRepository: false)

    public var staged: [GitFileChange] { files.filter { $0.staged != nil && !$0.conflicted } }
    public var unstaged: [GitFileChange] { files.filter { ($0.unstaged != nil || $0.untracked) && !$0.conflicted } }
    public var conflicted: [GitFileChange] { files.filter(\.conflicted) }
}

/// One changed file. A file can have staged and unstaged changes at once.
public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    /// The path before a rename or copy.
    public let originalPath: String?
    /// Status in the index: M, A, D, R, C or T; nil when nothing is staged.
    public let staged: Character?
    /// Status in the working tree; nil when it matches the index.
    public let unstaged: Character?
    public let untracked: Bool
    public let conflicted: Bool

    public init(path: String, originalPath: String? = nil, staged: Character? = nil, unstaged: Character? = nil,
                untracked: Bool = false, conflicted: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
    }
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let author: String
    public let date: Date
}

/// What a git command printed, and whether it worked.
public struct GitResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public var succeeded: Bool { status == 0 }
    /// The part of the output worth showing the user when it failed.
    public var message: String {
        let text = [error, output].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        return text.isEmpty ? "git terminó con el código \(status)." : text
    }
}

/// Runs git for Jack's Git pane.
public enum Git {
    public static var executable = "/usr/bin/git"

    /// Runs `git` in `directory`. It never asks for a password on a terminal, and reading the status
    /// takes no lock, so it does not get in the way of an agent running git at the same time.
    public static func run(_ arguments: [String], in directory: String, timeout: Duration = .seconds(120)) async -> GitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                environment["LC_ALL"] = "C"
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: GitResult(status: -1, output: "", error: error.localizedDescription))
                    return
                }
                let seconds = Double(timeout.components.seconds)
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                // Both pipes at once: a full stderr would otherwise block git while we wait on stdout.
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errorData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outputData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: GitResult(status: process.terminationStatus,
                                                         output: String(decoding: outputData, as: UTF8.self),
                                                         error: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }

    // MARK: Reading

    public static func status(in directory: String) async -> GitStatus {
        let result = await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: directory, timeout: .seconds(30))
        return result.succeeded ? parseStatus(result.output) : .notRepository
    }

    /// Reads `git status --porcelain=v2 --branch -z`.
    public static func parseStatus(_ output: String) -> GitStatus {
        var status = GitStatus(isRepository: true)
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        func code(_ character: Character) -> Character? { character == "." ? nil : character }
        while let entry = entries.popFirst() {
            if entry.hasPrefix("# ") {
                let parts = entry.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.head = parts[2] == "(initial)" ? nil : String(parts[2].prefix(7))
                case "branch.head": status.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.upstream = parts[2]
                case "branch.ab":
                    let counts = parts[2].split(separator: " ")
                    status.ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    status.behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
                continue
            }
            guard let kind = entry.first else { continue }
            switch kind {
            case "1", "2", "u":
                // Fields before the path: 8 for changes, 9 for renames, 10 for conflicts.
                let fieldCount = kind == "1" ? 8 : kind == "2" ? 9 : 10
                let parts = entry.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard parts.count == fieldCount + 1 else { continue }
                let xy = Array(parts[1])
                guard xy.count == 2 else { continue }
                let path = String(parts[fieldCount])
                let original = kind == "2" ? entries.popFirst() : nil
                status.files.append(GitFileChange(path: path, originalPath: original, staged: code(xy[0]), unstaged: code(xy[1]),
                                                  conflicted: kind == "u"))
            case "?":
                status.files.append(GitFileChange(path: String(entry.dropFirst(2)), untracked: true))
            default:
                break
            }
        }
        return status
    }

    public static func log(in directory: String, limit: Int = 30) async -> [GitCommit] {
        let result = await run(["log", "-n", "\(limit)", "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%at%x1e"], in: directory, timeout: .seconds(30))
        guard result.succeeded else { return [] }
        return parseLog(result.output)
    }

    public static func parseLog(_ output: String) -> [GitCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let seconds = TimeInterval(fields[4]) else { return nil }
            return GitCommit(hash: fields[0], shortHash: fields[1], subject: fields[2], author: fields[3], date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// Local branches, most recently used first.
    public static func branches(in directory: String) async -> [String] {
        let result = await run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], in: directory, timeout: .seconds(30))
        return result.output.split(separator: "\n").map(String.init)
    }

    /// The changes of one file: staged against HEAD, or in the working tree against the index.
    public static func diff(_ file: GitFileChange, staged: Bool, in directory: String) async -> String {
        if file.untracked {
            // An untracked file is all new: compare it with nothing. `--no-index` exits 1 when files differ.
            let result = await run(["diff", "--no-color", "--no-index", "--", "/dev/null", file.path], in: directory, timeout: .seconds(30))
            return result.output
        }
        let arguments = ["diff", "--no-color"] + (staged ? ["--cached"] : []) + ["--", file.path]
        return await run(arguments, in: directory, timeout: .seconds(30)).output
    }

    // MARK: Changing

    public static func stage(_ paths: [String], in directory: String) async -> GitResult {
        await run(["add", "-A", "--"] + paths, in: directory)
    }

    public static func stageAll(in directory: String) async -> GitResult {
        await run(["add", "-A"], in: directory)
    }

    public static func unstage(_ paths: [String], in directory: String) async -> GitResult {
        let result = await run(["reset", "-q", "HEAD", "--"] + paths, in: directory)
        if result.succeeded { return result }
        // Before the first commit there is no HEAD to reset to.
        return await run(["rm", "-q", "--cached", "-r", "--"] + paths, in: directory)
    }

    /// Throws away the unstaged changes of a file. An untracked file goes to the Trash, so it can be recovered.
    public static func discard(_ file: GitFileChange, in directory: String) async -> GitResult {
        if file.untracked {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: directory).appendingPathComponent(file.path), resultingItemURL: nil)
                return GitResult(status: 0, output: "", error: "")
            } catch {
                return GitResult(status: 1, output: "", error: error.localizedDescription)
            }
        }
        return await run(["checkout", "--", file.path], in: directory)
    }

    public static func commit(_ message: String, in directory: String) async -> GitResult {
        await run(["commit", "-q", "-m", message], in: directory)
    }

    public static func checkout(_ branch: String, in directory: String) async -> GitResult {
        await run(["checkout", "-q", branch], in: directory)
    }

    public static func createBranch(_ name: String, in directory: String) async -> GitResult {
        await run(["checkout", "-q", "-b", name], in: directory)
    }

    /// Pushes, setting the upstream on a branch's first push.
    public static func push(_ status: GitStatus, in directory: String) async -> GitResult {
        if status.upstream == nil, let branch = status.branch {
            return await run(["push", "-u", "origin", branch], in: directory)
        }
        return await run(["push"], in: directory)
    }

    /// Only fast-forwards: merging or rebasing on its own could leave the project mid-conflict.
    public static func pull(in directory: String) async -> GitResult {
        await run(["pull", "--ff-only"], in: directory)
    }

    public static func fetch(in directory: String) async -> GitResult {
        await run(["fetch", "--prune"], in: directory)
    }

    public static func initialize(in directory: String) async -> GitResult {
        await run(["init", "-q"], in: directory)
    }
}
