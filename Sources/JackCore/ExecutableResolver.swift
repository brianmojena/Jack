import Foundation

public enum ExecutableResolver {
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
            .path
    }

    public static func resolve(_ command: String, override: String? = nil) -> String? {
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return resolve(command, environment: childEnvironment())
    }

    /// The supplied environment makes Finder-style PATHs testable without changing the user's installation.
    static func resolve(_ command: String, override: String? = nil, environment: [String: String]) -> String? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates: [String]
        if command.contains("/") {
            candidates = [command]
        } else {
            candidates = searchPaths.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(command).path }
        }
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    public static func childEnvironment() -> [String: String] {
        sanitizedChildEnvironment(ProcessInfo.processInfo.environment)
    }

    static func sanitizedChildEnvironment(_ source: [String: String]) -> [String: String] {
        var environment = source
        for key in environment.keys.filter({ $0.hasPrefix("HERDR_") }) {
            environment.removeValue(forKey: key)
        }

        let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = orderedUnique(standardPaths + existing + userPaths).joined(separator: ":")
        return environment
    }

    /// Folders where the user's own tools live. An app opened from Finder or the Dock only gets the system folders,
    /// so CLIs installed in ~/.local/bin (Claude Code's installer), nvm, bun… would not be found without them.
    static var userPaths: [String] {
        cachedLoginShellPaths + installedUserPaths(home: FileManager.default.homeDirectoryForCurrentUser,
                                                   environment: ProcessInfo.processInfo.environment)
    }

    // Only shell startup is cached. Filesystem paths are rediscovered when a CLI is requested,
    // so installing Claude or a new Node version while Jack is open does not require a restart.
    private static let cachedLoginShellPaths = loginShellPath()

    static func installedUserPaths(home: URL, environment: [String: String] = [:]) -> [String] {
        let manager = FileManager.default
        func path(_ suffix: String) -> String { home.appendingPathComponent(suffix).path }
        func versions(_ root: String, bin: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: root)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { URL(fileURLWithPath: root).appendingPathComponent($0).appendingPathComponent(bin).path }
        }
        let fixed = [".local/bin", ".claude/local", ".claude/local/node_modules/.bin", ".claude/bin",
                     ".opencode/bin", ".bun/bin", ".npm-global/bin", ".npm/bin", ".volta/bin",
                     ".yarn/bin", ".config/yarn/global/node_modules/.bin", ".local/share/pnpm", "Library/pnpm",
                     ".asdf/shims", ".local/share/mise/shims", ".nix-profile/bin", ".cargo/bin", ".deno/bin",
                     "n/bin", ".local/share/fnm/aliases/default/bin", "bin"].map(path)
        let dataHome = environment["XDG_DATA_HOME"] ?? path(".local/share")
        let versionRoots: [(String, String)] = [
            ((environment["NVM_DIR"] ?? path(".nvm")) + "/versions/node", "bin"),
            (path(".local/share/nvm"), "bin"),
            (path(".fnm/node-versions"), "installation/bin"),
            ((environment["FNM_DIR"] ?? dataHome + "/fnm") + "/node-versions", "installation/bin"),
            (path("Library/Application Support/fnm/node-versions"), "installation/bin"),
            ((environment["ASDF_DATA_DIR"] ?? path(".asdf")) + "/installs/nodejs", "bin"),
            ((environment["MISE_DATA_DIR"] ?? dataHome + "/mise") + "/installs/node", "bin"),
            (path(".nodenv/versions"), "bin"),
        ]
        let extra = [environment["PNPM_HOME"], environment["NPM_CONFIG_PREFIX"].map { $0 + "/bin" },
                     environment["npm_config_prefix"].map { $0 + "/bin" },
                     environment["VOLTA_HOME"].map { $0 + "/bin" }, environment["BUN_INSTALL"].map { $0 + "/bin" }]
            .compactMap { $0 }.filter { $0.hasPrefix("/") }
        let versioned = versionRoots.flatMap { versions($0.0, bin: $0.1) }
        return orderedUnique(extra + fixed + versioned + ["/opt/local/bin", "/home/linuxbrew/.linuxbrew/bin", "/run/current-system/sw/bin"])
            .filter { value in
                var directory: ObjCBool = false
                return manager.fileExists(atPath: value, isDirectory: &directory) && directory.boolValue
            }
    }

    /// The PATH the user's login shell sets up, read once. Empty if the shell does not answer within three seconds.
    static func loginShellPath(shell suppliedShell: String? = nil) -> [String] {
        let shell: String
        if let suppliedShell { shell = suppliedShell }
        else {
            guard let entry = getpwuid(getuid()), let shellPointer = entry.pointee.pw_shell else { return [] }
            shell = String(cString: shellPointer)
        }
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let marker = "__JACK_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive too, because many people extend PATH in .zshrc or .bashrc.
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return [] }
        // Never wait for exit with an unread pipe: noisy shell startup can fill it and block the shell.
        // Nonblocking reads also avoid waiting for a background process that inherited stdout.
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var finished = false
        repeat {
            while data.count < 1_048_576 {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            if finished { break }
            if ProcessInfo.processInfo.systemUptime >= deadline || data.count >= 1_048_576 {
                process.terminate()
                return []
            }
            finished = exited.wait(timeout: .now() + .milliseconds(20)) == .success
        } while true
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return [] }
        return parts[parts.count - 2].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
