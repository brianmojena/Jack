import Foundation

/// Long-running work an agent reports to Jack: a download, a clone, loading a model, a build…
/// Each task is a JSON file in its conversation's progress folder, written by `jack-progress` or by any
/// script the agent writes. Keys are snake_case and every one is optional except the file name, which is the id.
public struct ProgressTask: Identifiable, Equatable {
    public enum Status: String { case running, paused, done, failed, cancelled, interrupted }

    /// Unique across conversations: `<conversation>/<task id>`.
    public var id: String { conversationID.uuidString + "/" + taskID }
    public var taskID: String
    public var conversationID: UUID
    public var title: String
    /// `download`, `model` or `task`; only changes the icon.
    public var kind: String
    public var status: Status
    public var fraction: Double?
    public var completed: Double?
    public var total: Double?
    /// `bytes` for sizes; anything else, or nothing, is shown as a count, such as `objects` or `files`.
    public var unit: String?
    /// Units per second, as reported or measured by Jack.
    public var speed: Double?
    /// Seconds left, as reported or estimated by Jack.
    public var eta: TimeInterval?
    /// What the task is doing now, such as the phase of a clone.
    public var detail: String?
    /// Extra rows the agent wants to show, in order.
    public var fields: [ProgressField]
    public var file: String?
    public var command: String?
    /// The process to signal; a task written by `jack-progress run` is `controllable`: SIGUSR1 pauses it,
    /// SIGUSR2 resumes it and SIGTERM cancels it. Any other pid only receives SIGTERM.
    public var pid: Int32?
    public var controllable: Bool
    public var message: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?

    public var isActive: Bool { status == .running || status == .paused }
    public var isFinished: Bool { !isActive }
    /// Bytes, so the bar can say "2,1 GB de 4,7 GB".
    public var isBytes: Bool { ProgressFormat.isBytes(unit) }
    /// The fraction to draw: reported, or derived from the amounts.
    public var progress: Double? {
        if let fraction { return min(1, max(0, fraction)) }
        if let completed, let total, total > 0 { return min(1, max(0, completed / total)) }
        return nil
    }

    public init(taskID: String, conversationID: UUID, title: String, kind: String = "task", status: Status = .running,
                startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.taskID = taskID; self.conversationID = conversationID; self.title = title; self.kind = kind; self.status = status
        self.fields = []; self.controllable = false; self.startedAt = startedAt; self.updatedAt = updatedAt
    }

    /// Reads a task file leniently: agents write these by hand, so wrong types are ignored rather than fatal.
    public init(json: [String: Any], taskID: String, conversationID: UUID, modified: Date) {
        func number(_ key: String) -> Double? {
            // JSONSerialization gives booleans as NSNumber too; `true` is not a percentage.
            var value: Double?
            if let boxed = json[key] as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID() { value = boxed.doubleValue }
            else if let text = json[key] as? String { value = ProgressParser.number(text) }
            return value.flatMap { $0.isFinite ? $0 : nil }
        }
        func text(_ key: String) -> String? {
            guard let value = json[key] else { return nil }
            let string = (value as? String) ?? (value as? NSNumber)?.stringValue
            return string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        func date(_ key: String) -> Date? { number(key).map { Date(timeIntervalSince1970: $0) } }

        self.taskID = taskID
        self.conversationID = conversationID
        title = text("title") ?? text("command").map { String($0.prefix(80)) } ?? taskID
        kind = text("kind") ?? "task"
        status = text("status").flatMap(Status.init(rawValue:)) ?? .running
        fraction = number("fraction") ?? number("percent").map { $0 / 100 }
        completed = number("completed")
        total = number("total")
        unit = text("unit")
        speed = number("speed")
        eta = number("eta")
        detail = text("detail")
        if let object = json["fields"] as? [String: Any] {
            fields = object.keys.sorted().map { ProgressField(name: $0, value: "\(object[$0] ?? "")") }
        } else if let rows = json["fields"] as? [[Any]] {
            fields = rows.compactMap { $0.count == 2 ? ProgressField(name: "\($0[0])", value: "\($0[1])") : nil }
        } else { fields = [] }
        file = text("file")
        command = text("command")
        pid = number("pid").flatMap { Int32(exactly: $0.rounded()) }
        controllable = json["controllable"] as? Bool ?? false
        message = text("message")
        updatedAt = date("updated_at") ?? modified
        startedAt = date("started_at") ?? updatedAt
        finishedAt = date("finished_at")
    }
}

public struct ProgressField: Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// Where tasks live and how agents find the helper.
public enum ProgressFiles {
    public static let directoryKey = "JACK_PROGRESS_DIR"
    public static let helperKey = "JACK_PROGRESS"
    public static let helperName = "jack-progress"

    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jack/Progress", isDirectory: true)
    }

    public static func directory(for conversation: UUID) -> URL {
        root.appendingPathComponent(conversation.uuidString, isDirectory: true)
    }

    /// `jack-progress`, which ships next to Jack's executable.
    public static let helperURL: URL? = {
        let candidates = [Bundle.main.url(forAuxiliaryExecutable: helperName),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(helperName)]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    public static var isAvailable: Bool { helperURL != nil }

    /// A folder holding only a launcher for the helper, so it can go on agents' PATH without the app's own executable.
    /// The launcher runs the helper by its real path: a symlink would break how it finds JackCore inside the app.
    private static let shimDirectory: URL? = {
        guard let helperURL else { return nil }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jack/bin", isDirectory: true)
        let quoted = "'" + helperURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // `jack-servers` is the helper's `servers` command under a name agents remember.
        let launchers = [helperName: "exec \(quoted) \"$@\"", "jack-servers": "exec \(quoted) servers \"$@\""]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, line) in launchers {
                let launcher = directory.appendingPathComponent(name)
                let script = "#!/bin/sh\n" + line + "\n"
                guard (try? String(contentsOf: launcher, encoding: .utf8)) != script else { continue }
                try? FileManager.default.removeItem(at: launcher)
                try Data(script.utf8).write(to: launcher, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            }
            return directory
        } catch { return nil }
    }()

    /// Variables every agent process gets, so commands it runs can report to this conversation.
    public static func environment(for conversation: UUID) -> [String: String] {
        let directory = directory(for: conversation)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var environment = [directoryKey: directory.path]
        if let helperURL {
            environment[helperKey] = helperURL.path
            if let shimDirectory {
                environment["PATH"] = shimDirectory.path + ":" + (ExecutableResolver.childEnvironment()["PATH"] ?? "/usr/bin:/bin")
            }
        }
        return environment
    }

    /// Tells every agent how to show progress in Jack.
    public static let instructions = """
    Jack shows native progress bars for long-running work, in this chat and in its Downloads panel. Use them instead \
    of writing your own progress-bar scripts.
    - Wrap any command that takes more than a few seconds and prints progress (downloads with curl, wget, aria2c, \
    huggingface-cli, ollama pull, brew or pip; git clone and fetch; rsync; loading a model; long builds) in \
    `jack-progress run --title "<short title in the user's language>" -- <command>`. It keeps the command's output \
    and exit status, and Jack shows the percentage, size, speed and time left. Add `--kind download` or \
    `--kind model` when it fits, `--file <path>` when the command writes one file, so the user can open it and Jack \
    can follow its size, and `--total <bytes>` when you know the final size and the command prints no progress.
    - For work you track yourself, such as a script or a loop, call `jack-progress set --id <id> --title "<title>" \
    --fraction <0-1>` as it advances (optionally `--completed <n> --total <n> --unit <unit>`, `--detail "<text>"`, \
    `--field "Name=Value"` and `--pid <pid>` so the user can cancel it), then `jack-progress done --id <id>`, or \
    `jack-progress done --id <id> --failed "<reason>"`.
    - If a command may outlive your tool's timeout, run it in the background; its bar keeps updating on its own.
    - If `jack-progress` is not on PATH, call it as "$JACK_PROGRESS".
    """

    /// Everything the helper lets agents do: progress bars and finding the servers already running.
    public static var helperInstructions: String { instructions + "\n\n" + ServerScanner.instructions }

    /// Writes a task file atomically, so Jack never reads half of it.
    public static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// File names agents may use: letters, digits, dots, dashes and underscores.
    public static func sanitizedID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).prefix(60))
        return trimmed.isEmpty ? "task" : trimmed
    }
}

/// What one line of a command's output says about its progress.
public struct ProgressReading: Equatable {
    public var fraction: Double?
    public var completed: Double?
    public var total: Double?
    public var unit: String?
    public var speed: Double?
    public var eta: TimeInterval?
    public var phase: String?
    public init(fraction: Double? = nil, completed: Double? = nil, total: Double? = nil, unit: String? = nil, speed: Double? = nil, eta: TimeInterval? = nil, phase: String? = nil) {
        self.fraction = fraction; self.completed = completed; self.total = total; self.unit = unit; self.speed = speed; self.eta = eta; self.phase = phase
    }
}

/// Reads the progress lines of common tools (curl, aria2c, git, wget, rsync, tqdm, ollama, pip…) and falls back
/// to any line with a percentage or a "done/total" size.
public enum ProgressParser {
    public static func parse(_ line: String) -> ProgressReading? {
        let text = stripANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 600 else { return nil }
        guard var reading = curl(text) ?? aria2(text) ?? git(text) ?? generic(text) else { return nil }
        // Speeds are always read as bytes per second, even when the line gives no sizes.
        if reading.speed != nil, reading.unit == nil { reading.unit = "bytes" }
        return reading
    }

    /// `  45  100M   45 45.2M    0     0  10.1M      0  0:00:09  0:00:04  0:00:05 10.3M`
    static func curl(_ text: String) -> ProgressReading? {
        let columns = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard columns.count == 12, let percent = Double(columns[0]), (0...100).contains(percent),
              Int(columns[2]) != nil, Int(columns[4]) != nil,
              columns[8...10].allSatisfy({ $0.contains(":") }) else { return nil }
        let total = bytes(columns[1])
        var reading = ProgressReading(completed: bytes(columns[3]), unit: "bytes", speed: bytes(columns[11]), eta: duration(columns[10]))
        if let total, total > 0 { reading.total = total; reading.fraction = percent / 100 }
        return reading
    }

    /// `[#2089b0 1.2MiB/10MiB(12%) CN:1 DL:3.1MiB ETA:3s]`
    static func aria2(_ text: String) -> ProgressReading? {
        guard let match = groups(aria2Pattern, text) else { return nil }
        var reading = ProgressReading(completed: match[1].flatMap(bytes), total: match[2].flatMap(bytes), unit: "bytes")
        reading.fraction = match[3].flatMap(Double.init).map { $0 / 100 }
        reading.speed = groups(aria2Speed, text)?[1].flatMap(bytes)
        reading.eta = groups(aria2ETA, text)?[1].flatMap(duration)
        return reading
    }

    /// `Receiving objects:  45% (450/1000), 1.20 MiB | 2.30 MiB/s`
    static func git(_ text: String) -> ProgressReading? {
        guard let match = groups(gitPattern, text), let percent = match[2].flatMap(Double.init) else { return nil }
        var phase = match[1] ?? ""
        if phase.hasPrefix("remote: ") { phase = String(phase.dropFirst(8)) }
        let counts = [match[3], match[4]].compactMap { $0 }.joined(separator: "/")
        var reading = ProgressReading(fraction: percent / 100, phase: [phase, counts].filter { !$0.isEmpty }.joined(separator: " "))
        if let received = match[5].flatMap(bytes) { reading.completed = received; reading.unit = "bytes" }
        reading.speed = match[6].flatMap(bytes)
        return reading
    }

    static func generic(_ text: String) -> ProgressReading? {
        var reading = ProgressReading()
        var percentRange: Range<String.Index>?
        if let match = groupRanges(percentPattern, text), let value = match[1].flatMap({ number(String(text[$0])) }), (0...100).contains(value) {
            reading.fraction = value / 100
            percentRange = match[0]
        }
        if let match = groups(pairPattern, text), let done = match[1].flatMap(bytes), let total = match[2].flatMap(bytes), total > 0, done <= total * 1.01 {
            reading.completed = done; reading.total = total; reading.unit = "bytes"
        } else if let match = groups(sharedUnitPair, text), let unit = match[3],
                  let done = match[1].flatMap({ bytes($0 + unit) }), let total = match[2].flatMap({ bytes($0 + unit) }), total > 0, done <= total * 1.01 {
            // pip: `2.1/4.7 MB`
            reading.completed = done; reading.total = total; reading.unit = "bytes"
        }
        guard reading.fraction != nil || reading.total != nil else { return nil }
        reading.speed = groups(speedPattern, text)?[1].flatMap(bytes)
        reading.eta = (groups(etaPattern, text)?[1] ?? groups(tqdmETA, text)?[1] ?? groups(trailingDuration, text)?[1]
            ?? groups(bareClock, text)?[1]).flatMap(duration)
        // Text before the percentage names what is progressing, such as `pulling 8eeb52dfb3bb` or a file name.
        if let percentRange {
            let before = text[..<percentRange.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: " :|[]()-=>#.").union(.whitespaces))
            if before.count >= 3, before.count <= 70, before.rangeOfCharacter(from: .letters) != nil,
               before.rangeOfCharacter(from: CharacterSet(charactersIn: "█▏▕▌▍▎▉▊▋")) == nil { reading.phase = before }
        }
        return reading
    }

    // MARK: Values

    /// "45.2M", "1.2MiB", "2,1 GB", "512", "10k": bytes. Bare prefixes and `iB` are binary, `kB`/`MB`… decimal.
    public static func bytes(_ text: String) -> Double? {
        guard let match = groups(sizePattern, text.trimmingCharacters(in: .whitespaces)),
              let value = match[1].flatMap(number) else { return nil }
        let prefix = (match[2] ?? "").uppercased()
        let binary = match[3]?.isEmpty == false || match[4]?.isEmpty != false
        let powers = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5]
        guard let power = powers[prefix] else { return nil }
        return value * pow(binary ? 1024 : 1000, Double(power))
    }

    /// "0:00:05", "01:30", "1m2s", "3s", "1h 2m", "2.5s": seconds. Unknown values such as "--:--:--" are nil.
    public static func duration(_ text: String) -> TimeInterval? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.contains("-"), !value.contains("?") else { return nil }
        if value.contains(":") {
            let parts = value.split(separator: ":").map { Double($0) }
            guard parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        let units: [String: Double] = ["d": 86_400, "h": 3_600, "m": 60, "min": 60, "s": 1, "ms": 0.001]
        var total: Double = 0
        var matched = false
        for match in allGroups(durationPart, value) {
            guard let amount = match[1].flatMap(Double.init), let unit = match[2].map({ $0.lowercased() }), let scale = units[unit] else { return nil }
            total += amount * scale; matched = true
        }
        return matched ? total : nil
    }

    /// Accepts "1.5", "1,5" and "1,234,567" (thousands).
    public static func number(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil { value = value.replacingOccurrences(of: ",", with: "") }
        else { value = value.replacingOccurrences(of: ",", with: ".") }
        return Double(value)
    }

    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: Patterns

    private static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
    private static let ansiPattern = regex(#"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#)
    private static let size = #"\d+(?:[.,]\d+)*\s?[KMGTP]?i?B?"#
    private static let sizePattern = regex(#"^(\d+(?:[.,]\d+)*)\s?([KMGTP]?)(i?)(B?)$"#)
    private static let aria2Pattern = regex(#"#[0-9a-f]+\s+(\d+(?:\.\d+)?[KMGTP]?i?B)/(\d+(?:\.\d+)?[KMGTP]?i?B)\((\d{1,3})%\)"#)
    private static let aria2Speed = regex(#"\bDL:(\d+(?:\.\d+)?[KMGTP]?i?B)"#)
    private static let aria2ETA = regex(#"\bETA:(\w+)"#)
    private static let gitPattern = regex(#"^((?:remote: )?[A-Z][A-Za-z ]+):\s+(\d{1,3})% \((\d+)/(\d+)\)(?:,\s*(\d+(?:\.\d+)?\s?[KMGT]?i?B)(?:\s*\|\s*(\d+(?:\.\d+)?\s?[KMGT]?i?B)/s)?)?"#)
    private static let percentPattern = regex(#"(?<![\d.,])(\d{1,3}(?:[.,]\d+)?)\s?%"#)
    private static let pairPattern = regex(#"(\d+(?:[.,]\d+)*\s?[KMGTP]i?B?|\d+(?:[.,]\d+)*\s?B)\s?/\s?(\d+(?:[.,]\d+)*\s?[KMGTP]i?B?|\d+(?:[.,]\d+)*\s?B)\b"#)
    private static let sharedUnitPair = regex(#"(?<![\d.,])(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)\s?([KMGT]i?B)\b"#)
    private static let speedPattern = regex("(" + size + #")/s\b"#)
    private static let etaPattern = regex(#"\b(?:ETA|left|remaining|restante)[:\s]+((?:\d+(?:\.\d+)?\s?(?:d|h|min|m|s)\s?)+|\d+(?::\d+){1,2})"#)
    private static let tqdmETA = regex(#"<(\d+(?::\d+){1,2})[,\]]"#)
    /// ollama's `1m2s` at the end of the line; lowercase only, so a size such as `100M` is not read as minutes.
    private static let trailingDuration = regex(#"\s((?:\d+h)?(?:\d+m)?\d+s|\d+h(?:\d+m)?)\s*$"#, caseInsensitive: false)
    /// rsync's time left: `0:00:05` on its own.
    private static let bareClock = regex(#"(?:^|\s)(\d{1,2}:\d{2}:\d{2})(?:\s|$)"#)
    private static let durationPart = regex(#"(\d+(?:\.\d+)?)\s?(ms|min|d|h|m|s)"#)

    private static func groupRanges(_ regex: NSRegularExpression, _ text: String) -> [Range<String.Index>?]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text) }
    }
    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        groupRanges(regex, text)?.map { $0.map { String(text[$0]) } }
    }
    private static func allGroups(_ regex: NSRegularExpression, _ text: String) -> [[String?]] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }
}

/// Text shared by Jack's views and the helper's summaries.
public enum ProgressFormat {
    public static func isBytes(_ unit: String?) -> Bool { unit == "bytes" || unit == "B" }

    public static func amount(_ value: Double, unit: String?) -> String {
        let value = value.isFinite ? min(max(value, -9e18), 9e18) : 0
        if isBytes(unit) { return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
        let number = value.rounded() == value ? Int64(value).formatted() : value.formatted(.number.precision(.fractionLength(0...1)))
        return unit.map { "\(number) \($0)" } ?? number
    }

    public static func speed(_ value: Double, unit: String?) -> String {
        amount(value, unit: unit) + "/s"
    }

    /// "1 h 5 min", "3 min 12 s", "45 s".
    public static func duration(_ seconds: TimeInterval) -> String {
        // Estimates can be absurd early on; anything past a year reads as a year.
        let value = Int(min(max(0, seconds.isFinite ? seconds : 0), 31_536_000).rounded())
        let hours = value / 3600, minutes = value % 3600 / 60, rest = value % 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return minutes < 10 && rest > 0 ? "\(minutes) min \(rest) s" : "\(minutes) min" }
        return "\(rest) s"
    }

    /// "2,1 GB de 4,7 GB · 45 MB/s · quedan 1 min"
    public static func summary(_ task: ProgressTask) -> String {
        var parts: [String] = []
        if let completed = task.completed {
            parts.append(task.total.map { "\(amount(completed, unit: task.unit)) de \(amount($0, unit: task.unit))" } ?? amount(completed, unit: task.unit))
        } else if let total = task.total {
            parts.append(amount(total, unit: task.unit))
        }
        if task.status == .running {
            if let speed = task.speed, speed > 0 { parts.append(self.speed(speed, unit: task.unit)) }
            if let eta = task.eta, eta.isFinite, eta >= 1 { parts.append("quedan \(duration(eta))") }
        }
        return parts.joined(separator: " · ")
    }
}
