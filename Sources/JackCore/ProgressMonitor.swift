import Combine
import Darwin
import Foundation

/// Follows the tasks agents report in `ProgressFiles.root`, measures speed and time left when the tool
/// does not report them, and pauses, resumes or cancels the processes behind them.
@MainActor public final class ProgressMonitor: ObservableObject {
    @Published public private(set) var tasks: [ProgressTask] = []
    /// Finished tasks the user dismissed from their chat; the Downloads panel still lists them.
    @Published public private(set) var hiddenInChat: Set<String> = []

    private let root: URL
    private var polling: Task<Void, Never>?
    private var tick = 0
    private var files: [String: (modified: Date, task: ProgressTask)] = [:]
    private var samples: [String: [(time: Date, completed: Double?, fraction: Double?)]] = [:]
    /// Finished tasks older than this are deleted when Jack starts.
    public static let retention: TimeInterval = 7 * 24 * 3600
    /// A running task with no update for this long is shown as stalled.
    public static let stallInterval: TimeInterval = 120

    public init(root: URL = ProgressFiles.root, watching: Bool = true) {
        self.root = root
        prune()
        scan()
        guard watching else { return }
        self.polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.poll()
            }
        }
    }

    public func stop() { polling?.cancel(); polling = nil }

    public var active: [ProgressTask] { tasks.filter(\.isActive) }

    public func tasks(for conversation: UUID) -> [ProgressTask] { tasks.filter { $0.conversationID == conversation } }

    /// What the chat shows: everything still working, and what finished in the last ten minutes until dismissed.
    public func chatTasks(for conversation: UUID, now: Date = Date()) -> [ProgressTask] {
        tasks(for: conversation).filter { task in
            task.isActive || (!hiddenInChat.contains(task.id) && now.timeIntervalSince(task.finishedAt ?? task.updatedAt) < 600)
        }
    }

    /// Overall fraction of the active tasks that know theirs.
    public var overallProgress: Double? {
        let known = active.compactMap(\.progress)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    // MARK: Actions

    public func canPause(_ task: ProgressTask) -> Bool { task.controllable && task.pid != nil && task.isActive }
    public func canCancel(_ task: ProgressTask) -> Bool { task.isActive }

    public func pause(_ task: ProgressTask) {
        guard canPause(task), task.status == .running, let pid = task.pid else { return }
        kill(pid, SIGUSR1)
    }

    public func resume(_ task: ProgressTask) {
        guard canPause(task), task.status == .paused, let pid = task.pid else { return }
        kill(pid, SIGUSR2)
    }

    /// `jack-progress run` stops its command and records the cancellation itself; other tasks are marked here.
    public func cancel(_ task: ProgressTask) {
        guard task.isActive else { return }
        if let pid = task.pid, pid > 1 { kill(pid, SIGTERM) }
        if !task.controllable { update(task) { $0["status"] = ProgressTask.Status.cancelled.rawValue } }
    }

    public func hideInChat(_ task: ProgressTask) { hiddenInChat.insert(task.id) }

    /// Forgets a finished task; the downloaded file, if any, stays where it is.
    public func remove(_ task: ProgressTask) {
        guard task.isFinished else { return }
        try? FileManager.default.removeItem(at: url(of: task))
        scan()
    }

    public func removeFinished(in conversation: UUID? = nil) {
        for task in tasks where task.isFinished && (conversation == nil || task.conversationID == conversation) {
            try? FileManager.default.removeItem(at: url(of: task))
        }
        scan()
    }

    // MARK: Reading

    private func poll() {
        tick += 1
        // Idle, the folder is read every two seconds; with work under way, twice a second.
        guard active.isEmpty == false || tick % 4 == 0 else { return }
        scan()
    }

    public func scan(now: Date = Date()) {
        let manager = FileManager.default
        var found: [String: (modified: Date, task: ProgressTask)] = [:]
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            guard let conversation = UUID(uuidString: folder.lastPathComponent),
                  let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in entries where file.pathExtension == "json" {
                let path = file.path
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if let known = files[path], known.modified == modified {
                    found[path] = known
                    continue
                }
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    // Half-written by a script that does not write atomically: keep what we had.
                    if let known = files[path] { found[path] = known }
                    continue
                }
                let task = ProgressTask(json: json, taskID: file.deletingPathExtension().lastPathComponent, conversationID: conversation, modified: modified)
                found[path] = (modified, measure(task, now: now))
            }
        }
        for (path, entry) in found where entry.task.isActive && isGone(entry.task, now: now) {
            var task = entry.task
            task.status = .interrupted; task.finishedAt = now
            update(task) { $0["status"] = ProgressTask.Status.interrupted.rawValue; $0["finished_at"] = now.timeIntervalSince1970 }
            found[path] = (entry.modified, task)
        }
        files = found
        let live = Set(found.values.map { $0.task.id })
        samples = samples.filter { live.contains($0.key) }
        hiddenInChat.formIntersection(live)
        let sorted = found.values.map { $0.task }.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return (a.finishedAt ?? a.startedAt) > (b.finishedAt ?? b.startedAt)
        }
        if sorted != tasks { tasks = sorted }
    }

    /// Fills in speed and time left from the last seconds of updates when the task did not report them.
    private func measure(_ task: ProgressTask, now: Date) -> ProgressTask {
        var task = task
        guard task.status == .running else { samples[task.id] = nil; return task }
        var history = samples[task.id] ?? []
        if history.last?.completed != task.completed || history.last?.fraction != task.progress {
            history.append((task.updatedAt, task.completed, task.progress))
        }
        history.removeAll { task.updatedAt.timeIntervalSince($0.time) > 8 }
        samples[task.id] = history
        guard let first = history.first, let last = history.last, last.time.timeIntervalSince(first.time) >= 1 else { return task }
        let elapsed = last.time.timeIntervalSince(first.time)
        if task.speed == nil, let start = first.completed, let end = last.completed, end >= start {
            task.speed = (end - start) / elapsed
        }
        if task.eta == nil {
            if let total = task.total, let completed = task.completed, let speed = task.speed, speed > 0 {
                task.eta = max(0, total - completed) / speed
            } else if let start = first.fraction, let end = last.fraction, end > start {
                task.eta = (1 - end) / ((end - start) / elapsed)
            }
        }
        return task
    }

    /// The process that reported the task has ended without saying so.
    private func isGone(_ task: ProgressTask, now: Date) -> Bool {
        guard let pid = task.pid, pid > 1 else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private func url(of task: ProgressTask) -> URL {
        root.appendingPathComponent(task.conversationID.uuidString, isDirectory: true).appendingPathComponent(task.taskID + ".json")
    }

    private func update(_ task: ProgressTask, _ change: (inout [String: Any]) -> Void) {
        let file = url(of: task)
        guard let data = try? Data(contentsOf: file), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        change(&json)
        json["updated_at"] = Date().timeIntervalSince1970
        try? ProgressFiles.write(json, to: file)
    }

    private func prune() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.retention)
        for folder in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in entries where file.pathExtension == "json" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                guard modified < cutoff, let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if ProgressTask(json: json, taskID: "", conversationID: UUID(), modified: modified).isFinished { try? manager.removeItem(at: file) }
            }
        }
    }
}
