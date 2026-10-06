import Darwin
import Foundation
import JackCore

// jack-progress: shows an agent's long-running work as a native progress bar in Jack.
//
//   jack-progress run [--title T] [--kind download|model|task] [--file PATH] [--total N] [--id ID] -- <command…>
//   jack-progress set --id ID [--title T] [--fraction 0-1 | --percent 0-100] [--completed N] [--total N] [--unit U]
//                     [--speed N] [--eta SECONDS] [--detail TEXT] [--field NAME=VALUE]… [--pid PID] [--file PATH]
//   jack-progress done --id ID [--failed REASON] [--message TEXT]
//
// Tasks are JSON files in $JACK_PROGRESS_DIR, which Jack sets for every agent. Outside Jack, `run` just runs the
// command and `set`/`done` do nothing.

let usage = """
usage: jack-progress run [--title T] [--kind download|model|task] [--file PATH] [--total N] [--id ID] -- <command…>
       jack-progress set --id ID [--title T] [--fraction F | --percent P] [--completed N] [--total N] [--unit U]
                         [--speed N] [--eta SECONDS] [--detail TEXT] [--field NAME=VALUE]… [--pid PID] [--file PATH]
       jack-progress done --id ID [--failed REASON] [--message TEXT]

run   runs the command, keeping its output and exit status, and turns the progress it prints (curl, wget, aria2c,
      git, rsync, pip, huggingface-cli, ollama…) into a bar in Jack. With --file, Jack also follows that file's size.
set   creates or updates a task you track yourself.
done  marks a task finished, or failed with --failed.

jack-progress servers [--all] (or jack-servers) lists the servers already running for this folder.
"""

// MARK: - Arguments

struct Options {
    var values: [String: [String]] = [:]
    var command: [String] = []
    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
}

let valuedOptions: Set<String> = ["id", "title", "kind", "file", "total", "unit", "fraction", "percent", "completed",
                                  "speed", "eta", "detail", "field", "pid", "failed", "message"]

func fail(_ message: String) -> Never {
    fputs("jack-progress: \(message)\n", stderr)
    exit(2)
}

func parseOptions(_ arguments: [String], allowsCommand: Bool) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            guard allowsCommand else { fail("unexpected --") }
            options.command = Array(arguments[(index + 1)...])
            break
        }
        if argument.hasPrefix("--") {
            var name = String(argument.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            guard valuedOptions.contains(name) else { fail("unknown option --\(name)\n\n\(usage)") }
            if value == nil {
                index += 1
                guard index < arguments.count else { fail("--\(name) needs a value") }
                value = arguments[index]
            }
            options.values[name, default: []].append(value ?? "")
        } else if allowsCommand {
            options.command = Array(arguments[index...])
            break
        } else {
            fail("unexpected argument \(argument)\n\n\(usage)")
        }
        index += 1
    }
    return options
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    return (absolute as NSString).standardizingPath
}

/// Sizes accept suffixes such as 4.7G or 300MiB; a suffix makes the task's unit bytes.
func amount(_ raw: String, unit: String?) -> (value: Double, bytes: Bool)? {
    if unit == nil || unit == "bytes" || unit == "B", raw.rangeOfCharacter(from: .letters) != nil, let bytes = ProgressParser.bytes(raw) {
        return (bytes, true)
    }
    return ProgressParser.number(raw).map { ($0, unit == "bytes" || unit == "B") }
}

/// Settings shared by `run`, `set` and `done`.
func apply(_ options: Options, to state: inout [String: Any]) {
    for key in ["title", "kind", "unit", "detail", "message"] {
        if let value = options.value(key) { state[key] = value }
    }
    if let file = options.value("file") { state["file"] = absolutePath(file) }
    if let value = options.value("fraction").flatMap(ProgressParser.number) { state["fraction"] = min(1, max(0, value)) }
    if let value = options.value("percent").flatMap(ProgressParser.number) { state["fraction"] = min(1, max(0, value / 100)) }
    let unit = options.value("unit") ?? state["unit"] as? String
    for key in ["completed", "total", "speed"] {
        guard let raw = options.value(key) else { continue }
        guard let parsed = amount(raw, unit: unit) else { fail("--\(key) must be a number, such as 120 or 4.7G") }
        state[key] = parsed.value
        if parsed.bytes { state["unit"] = "bytes" }
    }
    if let raw = options.value("eta") {
        guard let seconds = ProgressParser.number(raw) ?? ProgressParser.duration(raw) else { fail("--eta must be seconds, such as 90 or 1m30s") }
        state["eta"] = seconds
    }
    if let raw = options.value("pid") {
        guard let pid = Int32(raw), pid > 1 else { fail("--pid must be a process id") }
        state["pid"] = Int(pid)
    }
    var fields = state["fields"] as? [String: Any] ?? [:]
    for field in options.all("field") {
        guard let equals = field.firstIndex(of: "=") else { fail("--field must look like Name=Value") }
        let name = String(field[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(field[field.index(after: equals)...])
        if value.isEmpty { fields.removeValue(forKey: name) } else { fields[name] = value }
    }
    if !fields.isEmpty { state["fields"] = fields } else { state.removeValue(forKey: "fields") }
}

// MARK: - Task file

/// Owns one task file. Writes are throttled to four a second; `force` writes at once.
final class Reporter: @unchecked Sendable {
    let id: String
    let file: URL?
    private var state: [String: Any]
    private var lastWrite = Date.distantPast
    private var dirty = false
    private let lock = NSLock()

    init(id: String, fresh: Bool) {
        self.id = id
        let directory = ProcessInfo.processInfo.environment[ProgressFiles.directoryKey].flatMap { $0.isEmpty ? nil : $0 }
        file = directory.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(id + ".json") }
        if !fresh, let file, let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { state = json } else { state = [:] }
    }

    var snapshot: [String: Any] { lock.withLock { state } }

    func update(force: Bool = false, _ change: (inout [String: Any]) -> Void) {
        lock.withLock {
            change(&state)
            dirty = true
            writeLocked(force: force)
        }
    }

    func flush() { lock.withLock { writeLocked(force: false) } }

    private func writeLocked(force: Bool) {
        guard let file, dirty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) >= 0.25 else { return }
        state["updated_at"] = now.timeIntervalSince1970
        do { try ProgressFiles.write(state, to: file) } catch { fputs("jack-progress: could not write \(file.path): \(error.localizedDescription)\n", stderr) }
        lastWrite = now
        dirty = false
    }
}

func taskID(_ options: Options) -> String {
    guard let id = options.value("id") ?? options.value("title") else { fail("--id is required") }
    return ProgressFiles.sanitizedID(id)
}

func setTask(_ options: Options) -> Int32 {
    let reporter = Reporter(id: taskID(options), fresh: false)
    guard reporter.file != nil else { return 0 }
    reporter.update(force: true) { state in
        if state["started_at"] == nil { state["started_at"] = Date().timeIntervalSince1970 }
        state["status"] = "running"
        state.removeValue(forKey: "finished_at")
        apply(options, to: &state)
    }
    return 0
}

func finishTask(_ options: Options) -> Int32 {
    let reporter = Reporter(id: taskID(options), fresh: false)
    guard reporter.file != nil else { return 0 }
    reporter.update(force: true) { state in
        let now = Date().timeIntervalSince1970
        if state["started_at"] == nil { state["started_at"] = now }
        apply(options, to: &state)
        state["finished_at"] = now
        state.removeValue(forKey: "eta"); state.removeValue(forKey: "speed")
        if let reason = options.value("failed") {
            state["status"] = "failed"
            state["message"] = reason
        } else {
            state["status"] = "done"
            if state["fraction"] != nil || state["total"] != nil { state["fraction"] = 1 }
            if let total = state["total"] { state["completed"] = total }
        }
    }
    return 0
}

// MARK: - Signals

/// Written from the signal handler, which may only call async-signal-safe functions.
var signalPipeWrite: Int32 = -1

func watchSignals(_ handle: @escaping @Sendable (Int32) -> Void) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return }
    signalPipeWrite = fds[1]
    let handler: @convention(c) (Int32) -> Void = { number in
        var byte = UInt8(truncatingIfNeeded: number)
        _ = write(signalPipeWrite, &byte, 1)
    }
    // Caught, not ignored: the command starts with default handlers because exec resets caught ones.
    for number in [SIGINT, SIGTERM, SIGHUP, SIGUSR1, SIGUSR2] { _ = signal(number, handler) }
    let readEnd = fds[0]
    DispatchQueue.global(qos: .userInitiated).async {
        var byte: UInt8 = 0
        while true {
            let count = read(readEnd, &byte, 1)
            if count == 1 { handle(Int32(byte)) } else if count < 0 && errno == EINTR { continue } else { break }
        }
    }
}

// MARK: - run

final class Runner: @unchecked Sendable {
    let command: [String]
    let options: Options
    let reporter: Reporter
    let watchedFile: String?
    private let lock = NSLock()
    private var childPID: pid_t = 0
    private var cancelled = false
    private var finished = false
    private var pending: [UInt8] = []
    private var lastLine = ""
    private var parsedAmounts = false
    private var summaryBucket = -1
    private var summaryTime = Date.distantPast

    init(command: [String], options: Options) {
        self.command = command
        self.options = options
        let title = options.value("title") ?? command.joined(separator: " ")
        let id = options.value("id").map(ProgressFiles.sanitizedID) ?? ProgressFiles.sanitizedID(String(title.prefix(40)) + "-\(getpid())")
        reporter = Reporter(id: id, fresh: true)
        watchedFile = options.value("file").map(absolutePath)
    }

    func run() -> Int32 {
        // Outside Jack there is nothing to report: run the command as it is.
        guard reporter.file != nil else {
            guard let pid = spawn(output: nil, ownGroup: false) else { return 127 }
            return wait(pid)
        }
        guard let channel = openTerminal() ?? openPipe() else { fail("could not open a terminal for the command") }
        let (readEnd, writeEnd) = channel
        start()
        watchSignals { [self] number in received(number) }
        guard let pid = spawn(output: writeEnd, ownGroup: true) else {
            close(writeEnd); close(readEnd)
            reporter.update(force: true) { state in
                state["status"] = "failed"; state["message"] = "No se pudo ejecutar \(command[0])"
                state["finished_at"] = Date().timeIntervalSince1970
            }
            return 127
        }
        // Only the command holds the terminal now, so reading ends when it (and anything it started) exits.
        close(writeEnd)
        lock.withLock { childPID = pid }

        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count > 0 { consume(buffer[0..<count]) } else if count < 0 && errno == EINTR { continue } else { break }
            }
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            while !lock.withLock({ finished }) {
                usleep(500_000)
                followFile()
                reporter.flush()
            }
        }

        let code = wait(pid)
        // A process the command left running may keep the terminal open; don't wait for it.
        _ = drained.wait(timeout: .now() + 1.5)
        finish(code)
        return code
    }

    private func start() {
        reporter.update(force: true) { state in
            state = ["title": options.value("title") ?? command.joined(separator: " "),
                     "kind": guessKind(), "status": "running", "command": shellCommand(),
                     "pid": Int(getpid()), "controllable": true, "started_at": Date().timeIntervalSince1970]
            if watchedFile != nil { state["unit"] = "bytes" }
            apply(options, to: &state)
        }
    }

    private func finish(_ code: Int32) {
        let summary: String = lock.withLock {
            if !pending.isEmpty { handle(String(decoding: pending, as: UTF8.self), isLine: true); pending.removeAll() }
            finished = true
            let wasCancelled = cancelled
            reporter.update(force: true) { state in
                state["finished_at"] = Date().timeIntervalSince1970
                state.removeValue(forKey: "eta"); state.removeValue(forKey: "speed")
                if let watchedFile, !parsedAmounts, let size = fileSize(watchedFile) { state["completed"] = size }
                if wasCancelled {
                    state["status"] = "cancelled"
                } else if code == 0 {
                    state["status"] = "done"
                    if state["fraction"] != nil || state["total"] != nil { state["fraction"] = 1 }
                    if let total = state["total"] { state["completed"] = total }
                } else {
                    state["status"] = "failed"
                    state["message"] = "Terminó con código \(code)" + (lastLine.isEmpty ? "" : ": " + String(lastLine.prefix(300)))
                }
            }
            let task = ProgressTask(json: reporter.snapshot, taskID: reporter.id, conversationID: UUID(), modified: Date())
            let elapsed = ProgressFormat.duration(Date().timeIntervalSince(task.startedAt))
            let outcome = wasCancelled ? "cancelled" : code == 0 ? "done" : "failed (exit \(code))"
            return ([outcome, "in \(elapsed)", ProgressFormat.summary(task)].filter { !$0.isEmpty }).joined(separator: " · ")
        }
        emit("[jack-progress] " + summary)
    }

    // MARK: Process

    private func openTerminal() -> (Int32, Int32)? {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0 else { return nil }
        guard grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) else { close(primary); return nil }
        let secondary = open(name, O_RDWR | O_NOCTTY)
        guard secondary >= 0 else { close(primary); return nil }
        var settings = termios()
        if tcgetattr(secondary, &settings) == 0 {
            // Keep "\n" as it is and don't echo anything typed.
            settings.c_oflag &= ~tcflag_t(OPOST)
            settings.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(secondary, TCSANOW, &settings)
        }
        return (primary, secondary)
    }

    private func openPipe() -> (Int32, Int32)? {
        var fds: [Int32] = [0, 0]
        return pipe(&fds) == 0 ? (fds[0], fds[1]) : nil
    }

    /// Starts the command in its own process group, so pausing and cancelling reach everything it starts.
    private func spawn(output: Int32?, ownGroup: Bool) -> pid_t? {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Inheriting a closed descriptor would make the spawn fail.
        func inherit(_ descriptor: Int32) {
            if fcntl(descriptor, F_GETFD) != -1 { posix_spawn_file_actions_addinherit_np(&actions, descriptor) }
        }
        inherit(0)
        if let output {
            posix_spawn_file_actions_adddup2(&actions, output, 1)
            posix_spawn_file_actions_adddup2(&actions, output, 2)
        } else {
            inherit(1)
            inherit(2)
        }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only stdin, stdout and stderr reach the command.
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        if ownGroup { flags |= Int32(POSIX_SPAWN_SETPGROUP); posix_spawnattr_setpgroup(&attributes, 0) }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var environment = ProcessInfo.processInfo.environment
        if output != nil {
            if environment["COLUMNS"] == nil { environment["COLUMNS"] = "120" }
            if environment["TERM"] == nil || environment["TERM"] == "dumb" { environment["TERM"] = "xterm-256color" }
            environment["JACK_PROGRESS_TASK"] = reporter.id
        }
        let arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        let variables: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { arguments.forEach { free($0) }; variables.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, command[0], &actions, &attributes, arguments, variables)
        guard result == 0 else {
            fputs("jack-progress: \(command[0]): \(String(cString: strerror(result)))\n", stderr)
            return nil
        }
        return pid
    }

    /// The command's exit status, or 128 + the signal that ended it, like a shell.
    private func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return 1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private func received(_ number: Int32) {
        lock.withLock {
            guard childPID > 0, !finished else { return }
            let group = -childPID
            switch number {
            case SIGUSR1:
                kill(group, SIGSTOP)
                reporter.update(force: true) { state in
                    state["status"] = "paused"; state.removeValue(forKey: "eta"); state.removeValue(forKey: "speed")
                }
            case SIGUSR2:
                kill(group, SIGCONT)
                reporter.update(force: true) { $0["status"] = "running" }
            default:
                cancelled = true
                kill(group, number)
                kill(group, SIGCONT)
                // Commands that ignore the request are stopped for good after five seconds.
                let pid = childPID
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if kill(pid, 0) == 0 { kill(-pid, SIGKILL) } }
            }
        }
    }

    // MARK: Output

    /// Splits the output on "\n" (lines, shown to the agent) and "\r" (redrawn progress, only parsed).
    private func consume(_ bytes: ArraySlice<UInt8>) {
        lock.withLock {
            // Output that arrives after the command ended must not reopen the task.
            guard !finished else { return }
            pending.append(contentsOf: bytes)
            var start = 0, index = 0
            while index < pending.count {
                let byte = pending[index]
                guard byte == 0x0A || byte == 0x0D else { index += 1; continue }
                // A "\r" at the end may be half of "\r\n": wait for the next bytes.
                if byte == 0x0D, index + 1 == pending.count { break }
                let isLine = byte == 0x0A || pending[index + 1] == 0x0A
                handle(String(decoding: pending[start..<index], as: UTF8.self), isLine: isLine)
                index += byte == 0x0D && isLine ? 2 : 1
                start = index
            }
            pending.removeFirst(start)
            if pending.count > 64 * 1024 {
                handle(String(decoding: pending, as: UTF8.self), isLine: true)
                pending.removeAll()
            }
        }
    }

    /// Called with `lock` held.
    private func handle(_ raw: String, isLine: Bool) {
        let text = ProgressParser.stripANSI(raw)
        if let reading = ProgressParser.parse(text) {
            if reading.completed != nil { parsedAmounts = true }
            reporter.update { state in
                state["status"] = "running"
                if let fraction = reading.fraction { state["fraction"] = fraction } else if reading.total != nil { state.removeValue(forKey: "fraction") }
                if let completed = reading.completed { state["completed"] = completed }
                if let total = reading.total { state["total"] = total }
                if let unit = reading.unit { state["unit"] = unit }
                state["speed"] = reading.speed
                state["eta"] = reading.eta
                if let phase = reading.phase { state["detail"] = phase }
            }
            summarize()
            return
        }
        guard isLine else { return }
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty { lastLine = visible }
        emit(String(text.prefix(4000)))
    }

    /// Tells the agent how it is going every 10 %, or every 30 seconds, instead of every redraw.
    private func summarize() {
        let task = ProgressTask(json: reporter.snapshot, taskID: reporter.id, conversationID: UUID(), modified: Date())
        let bucket = task.progress.map { Int($0 * 10) } ?? -1
        let now = Date()
        guard bucket > summaryBucket || now.timeIntervalSince(summaryTime) >= 30 else { return }
        summaryBucket = max(summaryBucket, bucket)
        summaryTime = now
        let percent = task.progress.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? ""
        emit("[jack-progress] " + [percent, task.detail ?? "", ProgressFormat.summary(task)].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func followFile() {
        guard let watchedFile, !lock.withLock({ parsedAmounts }), let size = fileSize(watchedFile) else { return }
        reporter.update { state in
            guard state["status"] as? String == "running" else { return }
            state["completed"] = size
            state["unit"] = "bytes"
        }
    }

    private func fileSize(_ path: String) -> Double? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.doubleValue
    }

    private func guessKind() -> String {
        let tool = (command[0] as NSString).lastPathComponent
        let arguments = Set(command.dropFirst())
        if ["curl", "wget", "aria2c", "axel", "huggingface-cli", "hf", "yt-dlp", "scp", "rsync"].contains(tool) { return "download" }
        if tool == "git", !arguments.isDisjoint(with: ["clone", "fetch", "pull", "lfs"]) { return "download" }
        if ["ollama", "brew", "pip", "pip3", "npm", "pnpm", "docker"].contains(tool), !arguments.isDisjoint(with: ["pull", "install", "fetch"]) { return "download" }
        if tool == "ollama", arguments.contains("run") { return "model" }
        return "task"
    }

    private func shellCommand() -> String {
        command.map { argument in
            argument.isEmpty || argument.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"\\$`!*?&|;<>(){}[]#~")) != nil
                ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" : argument
        }.joined(separator: " ")
    }
}

func emit(_ line: String) {
    fputs(line + "\n", stdout)
    fflush(stdout)
}

// MARK: - servers

/// Prints the servers already running for this folder, so an agent reuses them instead of starting another.
func listServers(all: Bool) -> Int32 {
    let here = FileManager.default.currentDirectoryPath
    let home = NSHomeDirectory()
    let servers = ServerScanner.scan(project: { directory in
        if all || directory == here || directory.hasPrefix(here + "/") { return directory }
        // A server started from a parent folder, such as a monorepo's root, serves this one too.
        if directory != "/", directory != home, here.hasPrefix(directory + "/") { return directory }
        return nil
    }).filter { $0.project != nil }
    guard !servers.isEmpty else {
        print(all ? "No local servers are running." : "No servers are running for \(here). Start one if you need it.")
        return 0
    }
    print(all ? "Local servers:" : "Already running for this folder (reuse them instead of starting another):")
    for server in servers {
        let address = server.ports.map { "http://localhost:\($0)" }.joined(separator: ", ")
        let started = ProgressFormat.duration(Date().timeIntervalSince(server.startedAt))
        let by = server.conversationID != nil ? ", started by an agent in Jack" : server.foreignAgent.map { ", started by \($0) in another session" } ?? ""
        print("- \(address)  \(server.command)  (pid \(server.pid), in \(server.directory), running for \(started)\(by))")
    }
    return 0
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run":
    let options = parseOptions(Array(arguments.dropFirst()), allowsCommand: true)
    guard !options.command.isEmpty else { fail("run needs a command: jack-progress run --title \"…\" -- <command>") }
    exit(Runner(command: options.command, options: options).run())
case "set":
    exit(setTask(parseOptions(Array(arguments.dropFirst()), allowsCommand: false)))
case "done":
    exit(finishTask(parseOptions(Array(arguments.dropFirst()), allowsCommand: false)))
case "servers":
    exit(listServers(all: arguments.contains("--all")))
case "-h", "--help", "help":
    print(usage)
default:
    fail(arguments.first.map { "unknown command \($0)\n\n\(usage)" } ?? usage)
}
