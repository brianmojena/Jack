import Darwin
import Foundation

/// A process serving something on a local port, such as `npm run dev`, found by asking the kernel.
public struct ServerProcess: Identifiable, Equatable, Sendable {
    public var pid: Int32
    public var id: Int32 { pid }
    public var ports: [Int]
    /// What to show: the wrapper's command when there is one (`npm run dev`), otherwise the server's own.
    public var command: String
    /// The server's full command line.
    public var commandLine: String
    public var directory: String
    /// The project of Jack's it belongs to, if any.
    public var project: String?
    /// The Jack agent that started it, read from the environment Jack gives its agents.
    public var conversationID: UUID?
    /// The coding agent in another session (a terminal, an editor) that started it, if any.
    public var foreignAgent: String?
    public var startedAt: Date
    /// Seconds of CPU used by the server and the processes it started.
    public var cpuTime: Double
    /// Resident memory of the server and the processes it started.
    public var memory: UInt64
    public var processCount: Int
    /// Processes that only launched the server (`npm run`, `pnpm dev`…); stopping it stops them too.
    public var wrapperPIDs: [Int32]
    /// Percentage of one core, measured between two scans.
    public var cpuPercent: Double?

    public var url: URL? { ports.first.flatMap { URL(string: "http://localhost:\($0)") } }
}

/// Lists local servers with libproc: the listening sockets of the user's processes, their folder and their usage.
public enum ServerScanner {
    /// Agent CLIs listen on ports of their own (OpenCode's server, editor bridges); they are not projects' servers.
    static let agentExecutables: Set<String> = ["claude", "codex", "opencode"]
    /// Launchers that only start the real server.
    static let wrappers: Set<String> = ["npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "turbo", "concurrently", "nodemon"]

    /// `project` returns the project a folder belongs to, or nil to leave the process out unless an agent of Jack's
    /// started it. `excluding` is Jack's own pid: its direct children are the agents themselves.
    public static func scan(project: (String) -> String?, excluding owner: pid_t? = nil) -> [ServerProcess] {
        let uid = getuid()
        var infos: [pid_t: proc_bsdinfo] = [:]
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                  info.pbi_uid == uid else { continue }
            infos[pid] = info
        }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, info) in infos { children[pid_t(info.pbi_ppid), default: []].append(pid) }

        var servers: [pid_t: ServerProcess] = [:]
        for (pid, info) in infos {
            guard pid != owner, pid_t(info.pbi_ppid) != owner || owner == nil else { continue }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { continue }
            let path = executablePath(pid)
            let name = (path as NSString).lastPathComponent
            guard !agentExecutables.contains(name) else { continue }
            let directory = workingDirectory(pid) ?? ""
            let (arguments, environment) = argumentsAndEnvironment(pid)
            let conversation = environment[ProgressFiles.directoryKey].flatMap { UUID(uuidString: ($0 as NSString).lastPathComponent) }
            let owningProject = directory.isEmpty ? nil : project(directory)
            guard owningProject != nil || conversation != nil else { continue }

            // Launchers right above the server (`npm run dev` starts `sh -c vite`, which starts vite), and the
            // coding agent further up, if one started it.
            var wrappers: [pid_t] = [], shells: [pid_t] = []
            var foreign: String?
            var contiguous = true
            var displayed = commandText(arguments, fallback: name)
            var ancestor = pid_t(info.pbi_ppid)
            while ancestor > 1, ancestor != owner, let parent = infos[ancestor] {
                let parentName = (executablePath(ancestor) as NSString).lastPathComponent
                if agentExecutables.contains(parentName) { foreign = parentName; break }
                if contiguous {
                    if Self.wrappers.contains(parentName) || isNodeRunner(ancestor) {
                        wrappers += shells + [ancestor]; shells = []
                        displayed = commandText(argumentsAndEnvironment(ancestor).0, fallback: parentName)
                    } else if ["sh", "bash", "dash", "zsh"].contains(parentName), shells.count < 2 {
                        // Only stopped along with a launcher above it: a shell on its own may be the user's terminal.
                        shells.append(ancestor)
                    } else {
                        contiguous = false
                    }
                }
                ancestor = pid_t(parent.pbi_ppid)
            }
            var tree: [pid_t] = [pid]
            var index = 0
            while index < tree.count { tree += children[tree[index]] ?? []; index += 1 }
            var cpu = 0.0, memory: UInt64 = 0
            for member in tree {
                var task = proc_taskinfo()
                guard proc_pidinfo(member, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
                cpu += Double(task.pti_total_user + task.pti_total_system) / 1e9
                memory += task.pti_resident_size
            }
            servers[pid] = ServerProcess(
                pid: pid, ports: ports, command: displayed, commandLine: arguments.isEmpty ? path : arguments.joined(separator: " "),
                directory: directory, project: owningProject, conversationID: conversation,
                foreignAgent: foreign.map(agentTitle), startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
                cpuTime: cpu, memory: memory, processCount: tree.count, wrapperPIDs: wrappers.map { Int32($0) })
        }
        // A server whose own child also listens (Next.js, workers) is one server with several ports.
        for (pid, server) in servers {
            var ancestor = infos[pid].map { pid_t($0.pbi_ppid) } ?? 0
            while ancestor > 1 {
                if let parent = servers[ancestor] {
                    servers[ancestor]?.ports = Array(Set(parent.ports + server.ports)).sorted()
                    servers[pid] = nil
                    break
                }
                ancestor = infos[ancestor].map { pid_t($0.pbi_ppid) } ?? 0
            }
        }
        return servers.values.sorted { ($0.project ?? $0.directory, $0.ports.first ?? 0) < ($1.project ?? $1.directory, $1.ports.first ?? 0) }
    }

    /// Asks the server and its launchers to stop, then forces whatever is left after three seconds.
    public static func stop(_ server: ServerProcess) {
        let targets = [server.pid] + server.wrapperPIDs
        for pid in targets { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    // MARK: Text

    static func agentTitle(_ executable: String) -> String {
        switch executable {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: executable
        }
    }

    /// `node /…/node_modules/.bin/vite --port 5173` reads as `vite --port 5173`.
    static func commandText(_ arguments: [String], fallback: String) -> String {
        guard var words = arguments.isEmpty ? nil : arguments else { return fallback }
        words[0] = (words[0] as NSString).lastPathComponent
        if ["node", "python", "python3", "ruby", "bun", "deno"].contains(words[0]), words.count > 1, words[1].contains("/") {
            words.removeFirst()
            words[0] = (words[0] as NSString).lastPathComponent
        }
        let text = words.joined(separator: " ")
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    /// `node …/npm-cli.js run dev` and similar: Node running a package manager.
    private static func isNodeRunner(_ pid: pid_t) -> Bool {
        guard (executablePath(pid) as NSString).lastPathComponent == "node" else { return false }
        let arguments = argumentsAndEnvironment(pid).0
        return arguments.dropFirst().first.map { argument in ["npm", "pnpm", "yarn", "npx"].contains { argument.contains("/\($0)") } } ?? false
    }

    // MARK: libproc

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    static func listeningPorts(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard filled > 0 else { return [] }
        var ports = Set<Int>()
        for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size), socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// The command line and environment, from `KERN_PROCARGS2`: argc, the executable path, then NUL-separated
    /// arguments followed by the environment.
    static func argumentsAndEnvironment(_ pid: pid_t) -> ([String], [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = [], environment: [String: String] = [:]
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let text = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            if arguments.count < argc { arguments.append(text); continue }
            guard !text.isEmpty else { break }
            if let equals = text.firstIndex(of: "=") { environment[String(text[..<equals])] = String(text[text.index(after: equals)...]) }
        }
        return (arguments, environment)
    }

    /// The project `directory` belongs to: the deepest of `projects` that contains it.
    public static func project(of directory: String, in projects: some Collection<String>) -> String? {
        projects.filter { directory == $0 || directory.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }

    /// Tells agents to reuse what is already running.
    public static let instructions = """
    Before you start a development server or anything else that listens on a port (npm run dev, vite, next dev, \
    rails s, python -m http.server…), run `jack-servers` to see what is already running for this folder, even from \
    other sessions. If a server already serves this project, use its URL instead of starting another one, and do not \
    stop servers you did not start. If `jack-servers` is not on PATH, run "$JACK_PROGRESS" servers.
    """
}

/// Keeps the list of local servers up to date for the status bar.
@MainActor public final class ServerMonitor: ObservableObject {
    @Published public private(set) var servers: [ServerProcess] = []
    private let projects: () -> Set<String>
    private var polling: Task<Void, Never>?
    private var previous: [Int32: (time: Date, cpu: Double)] = [:]

    public init(projects: @escaping () -> Set<String>, watching: Bool = true) {
        self.projects = projects
        setWatching(watching)
    }

    var isWatching: Bool { polling != nil }
    public func setWatching(_ watching: Bool) {
        guard watching else { stop(); return }
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    public func stop() { polling?.cancel(); polling = nil }

    public func refresh() async {
        let projects = projects()
        let owner = getpid()
        var found = await Task.detached(priority: .utility) {
            ServerScanner.scan(project: { ServerScanner.project(of: $0, in: projects) }, excluding: owner)
        }.value
        let now = Date()
        for index in found.indices {
            let server = found[index]
            if let last = previous[server.pid], now.timeIntervalSince(last.time) > 0.5 {
                found[index].cpuPercent = max(0, (server.cpuTime - last.cpu) / now.timeIntervalSince(last.time) * 100)
            }
        }
        previous = Dictionary(uniqueKeysWithValues: found.map { ($0.pid, (time: now, cpu: $0.cpuTime)) })
        if found != servers { servers = found }
    }

    public func stop(_ server: ServerProcess) {
        ServerScanner.stop(server)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await self?.refresh()
        }
    }
}
