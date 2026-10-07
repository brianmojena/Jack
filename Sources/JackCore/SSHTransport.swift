import Foundation

/// Builds the local `ssh` invocation that runs an agent on another machine.
/// The remote command is a single shell-quoted string, so JSON arguments with
/// spaces and quotes (like Claude Code's `--mcp-config`) arrive intact, and
/// stdio stays attached for the stream-json protocol.
public enum SSHTransport {
    /// Non-interactive: key authentication must already work (`ssh-copy-id`),
    /// otherwise the process fails fast instead of hanging on a password prompt.
    public static let baseOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "LogLevel=ERROR",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
    ]

    /// POSIX shell quoting: wraps in single quotes, escaping embedded ones.
    /// `sh -c <quoted>` restores the exact original argument.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Full local argv (after the `ssh` executable) that runs `remoteExecutable`
    /// with `remoteArgs` in `remoteDirectory` on `endpoint`, with `remoteEnv`
    /// exported. When `tunnel` is given, forwards remote `127.0.0.1:remotePort`
    /// to local `127.0.0.1:localPort` so the remote agent reaches Jack's tools.
    public static func arguments(
        endpoint: ChatRemoteEndpoint,
        tunnel: (remotePort: UInt16, localPort: UInt16)? = nil,
        remoteEnv: [String: String] = [:],
        remoteExecutable: String,
        remoteArgs: [String],
        remoteDirectory: String? = nil
    ) -> [String] {
        var args = baseOptions
        if let port = endpoint.sshPort { args += ["-p", String(port)] }
        if let tunnel {
            args += ["-R", "127.0.0.1:\(tunnel.remotePort):127.0.0.1:\(tunnel.localPort)"]
        }
        args.append(endpoint.destination)
        args.append(remoteCommand(remoteEnv: remoteEnv, remoteExecutable: remoteExecutable,
                                  remoteArgs: remoteArgs, remoteDirectory: remoteDirectory))
        return args
    }

    /// The command ssh runs remotely. A bare `claude` goes through a POSIX script that finds
    /// it in every usual install location, because a non-interactive ssh session gets a
    /// minimal PATH that misses `~/.local/bin`, nvm, Homebrew and the like.
    static func remoteCommand(remoteEnv: [String: String], remoteExecutable: String,
                              remoteArgs: [String], remoteDirectory: String?) -> String {
        var command: [String] = []
        if let directory = remoteDirectory {
            command.append("cd \(shellQuote(directory)) &&")
        }
        let exports = remoteEnv.keys.sorted().map { "\($0)=\(shellQuote(remoteEnv[$0] ?? ""))" }
        let quotedArgs = remoteArgs.map(shellQuote)
        guard remoteExecutable == "claude" else {
            command += exports
            command.append("exec \(shellQuote(remoteExecutable))")
            return (command + quotedArgs).joined(separator: " ")
        }
        let script = [
            claudeFinderScript,
            "[ -n \"$JACK_CLAUDE\" ] || { echo 'Jack: no se encontró claude en la máquina remota' >&2; exit 127; }",
            "PATH=\"$(dirname \"$JACK_CLAUDE\"):$PATH\"; export PATH",
            (exports + ["exec \"$JACK_CLAUDE\""] + quotedArgs).joined(separator: " "),
        ].joined(separator: "\n")
        command.append(shellScript(script))
        return command.joined(separator: " ")
    }

    /// Every place Claude Code lands: the native installer, the old local install, npm/yarn/pnpm/bun
    /// globals, version managers (nvm, fnm, volta, asdf, mise), Homebrew, Nix, MacPorts, snap and
    /// system folders. Falls back to asking the login shell, which knows the user's real PATH.
    /// Sets `JACK_CLAUDE` to the first executable found, empty when there is none.
    public static let claudeFinderScript: String = {
        let fixed = [
            "$HOME/.local/bin", "$HOME/.claude/local", "$HOME/.claude/local/node_modules/.bin", "$HOME/.claude/bin",
            "$HOME/.npm-global/bin", "$HOME/.npm/bin", "$HOME/.bun/bin", "$HOME/.volta/bin", "$HOME/.yarn/bin",
            "$HOME/.config/yarn/global/node_modules/.bin", "$HOME/.local/share/pnpm", "$HOME/Library/pnpm",
            "$HOME/.asdf/shims", "$HOME/.local/share/mise/shims", "$HOME/.nix-profile/bin", "$HOME/bin",
            "$HOME/.deno/bin", "$HOME/n/bin", "$HOME/.local/share/fnm/aliases/default/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin", "/opt/local/bin",
            "/usr/bin", "/usr/local/node/bin", "/snap/bin", "/run/current-system/sw/bin",
        ]
        // Globs for versioned installs: the last match (newest by name) wins.
        let globs = [
            "$HOME/.nvm/versions/node/*/bin", "$HOME/.fnm/node-versions/*/installation/bin",
            "$HOME/.local/share/fnm/node-versions/*/installation/bin", "$HOME/Library/Application Support/fnm/node-versions/*/installation/bin",
            "$HOME/.asdf/installs/nodejs/*/bin", "$HOME/.local/share/mise/installs/node/*/bin",
            "$HOME/.local/share/nvm/*/bin", "$HOME/.nodenv/versions/*/bin", "$HOME/.local/state/fnm_multishells/*/bin",
        ]
        let fixedList = fixed.map { "\"\($0)/claude\"" }.joined(separator: " ")
        let globList = globs.map { "\"\($0)\"/claude" }.joined(separator: " ")
        return """
        JACK_CLAUDE=
        for c in \(fixedList); do [ -x "$c" ] && [ -f "$c" ] && JACK_CLAUDE=$c && break; done
        [ -n "$JACK_CLAUDE" ] || { c=$(command -v claude 2>/dev/null); case "$c" in /*) [ -x "$c" ] && JACK_CLAUDE=$c;; esac; }
        if [ -z "$JACK_CLAUDE" ]; then for c in \(globList); do [ -x "$c" ] && [ -f "$c" ] && JACK_CLAUDE=$c; done; fi
        if [ -z "$JACK_CLAUDE" ]; then
        for flags in -lc -lic; do
        c=$("${SHELL:-/bin/sh}" $flags 'command -v claude' </dev/null 2>/dev/null | tail -n 1)
        case "$c" in /*) [ -x "$c" ] && JACK_CLAUDE=$c && break;; esac
        done
        fi
        """
    }()

    /// Interactive login shell on the machine, in the agent's folder: for a terminal tab.
    /// Unlike the agent connection it allocates a tty and may prompt, since a person is typing.
    public static func terminalArguments(endpoint: ChatRemoteEndpoint) -> [String] {
        var args = ["-t",
                    "-o", "ConnectTimeout=10",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ServerAliveInterval=30",
                    "-o", "ServerAliveCountMax=3"]
        if let port = endpoint.sshPort { args += ["-p", String(port)] }
        args.append(endpoint.destination)
        // Falls back to the home folder when the project folder is gone.
        let change = endpoint.isResolved ? "cd \(shellQuote(endpoint.remotePath ?? "")) 2>/dev/null; " : ""
        args.append(shellScript(change + "exec \"${SHELL:-/bin/sh}\" -l"))
        return args
    }

    /// Points a loopback delegation URL at the remote side of the tunnel.
    /// Returns nil when the URL is not a loopback URL Jack can forward.
    public static func tunneledURL(_ url: URL, remotePort: UInt16) -> URL? {
        guard let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
              url.scheme?.lowercased() == "http" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "127.0.0.1"
        components?.port = Int(remotePort)
        return components?.url
    }

    /// The loopback port of a delegation URL, for the local side of the tunnel.
    public static func loopbackPort(_ url: URL) -> UInt16? {
        guard let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
              let port = url.port, port > 0, port <= 65535 else { return nil }
        return UInt16(port)
    }

    /// Remote command of the probe: confirms SSH works and prints where `claude` lives, if anywhere.
    public static var probeCommand: String {
        shellScript("echo JACK-SSH-OK\n" + claudeFinderScript + "\n"
                    + "if [ -n \"$JACK_CLAUDE\" ]; then echo \"$JACK_CLAUDE\"; else echo JACK-NO-CLAUDE; fi")
    }

    /// A quick connectivity check: answers whether SSH works and `claude` exists remotely.
    public static func probeArguments(endpoint: ChatRemoteEndpoint) -> [String] {
        var args = baseOptions
        if let port = endpoint.sshPort { args += ["-p", String(port)] }
        args.append(endpoint.destination)
        args.append(probeCommand)
        return args
    }

    /// Reads a probe's stdout: `(reachable, claudePath)`.
    public static func readProbe(_ output: String) -> (reachable: Bool, claudePath: String?) {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("JACK-SSH-OK") else { return (false, nil) }
        let path = lines.first { !$0.isEmpty && $0 != "JACK-SSH-OK" && $0 != "JACK-NO-CLAUDE" }
        return (true, path)
    }

    /// Runs `remoteCommand` on the machine and returns its stdout. Fails fast when
    /// keys are missing and kills the connection past `timeout` seconds.
    public static func run(destination: String, sshPort: Int?, remoteCommand: String, timeout: TimeInterval = 60) async throws -> String {
        try await Task.detached(priority: .utility) {
            try runSync(destination: destination, sshPort: sshPort, remoteCommand: remoteCommand, timeout: timeout)
        }.value
    }

    static func runSync(destination: String, sshPort: Int?, remoteCommand: String, timeout: TimeInterval) throws -> String {
        let ssh = ExecutableResolver.resolve("ssh") ?? "/usr/bin/ssh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        var args = baseOptions
        if let sshPort { args += ["-p", String(sshPort)] }
        process.arguments = args + [destination, remoteCommand]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw SSHError.failed("No se pudo lanzar ssh: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            throw SSHError.failed("La máquina remota tardó más de \(Int(timeout)) s en responder.")
        }
        guard process.terminationStatus == 0 else {
            let detail = (String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw SSHError.failed("SSH falló\(detail.map { ": \($0)" } ?? ".") Revisa la máquina, el usuario y la clave.")
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Wraps a POSIX script so it runs under `sh` even when the remote login shell is exotic.
    public static func shellScript(_ script: String) -> String {
        "sh -c " + shellQuote(script)
    }
}

public enum SSHError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
