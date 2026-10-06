import Foundation

public enum ExecutableResolver {
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
            .path
    }

    public static func resolve(_ command: String, override: String? = nil) -> String? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty, fileManager.isExecutableFile(atPath: override) { return override }

        let environment = childEnvironment()
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
    static let userPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nodeVersions = home + "/.nvm/versions/node"
        let nvm = ((try? FileManager.default.contentsOfDirectory(atPath: nodeVersions)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nodeVersions + "/" + $0 + "/bin" }
        let known = ["/.local/bin", "/.claude/local", "/.opencode/bin", "/.bun/bin", "/.npm-global/bin", "/.volta/bin",
                     "/.cargo/bin", "/.deno/bin", "/bin"].map { home + $0 } + nvm + ["/opt/local/bin"]
        var isDirectory: ObjCBool = false
        return loginShellPath() + known.filter { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue }
    }()

    /// The PATH the user's login shell sets up, read once. Empty if the shell does not answer within three seconds.
    private static func loginShellPath() -> [String] {
        guard let entry = getpwuid(getuid()), let shellPointer = entry.pointee.pw_shell else { return [] }
        let shell = String(cString: shellPointer)
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
        guard exited.wait(timeout: .now() + 3) == .success else { process.terminate(); return [] }
        // Only what is already written: a process the shell left running may keep the pipe open.
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 1_048_576 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
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
