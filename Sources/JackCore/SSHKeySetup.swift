import Foundation
import Security

/// Result of a connectivity check against a remote machine.
public enum SSHProbeResult: Equatable {
    /// SSH works with the current keys; `claudePath` is nil when `claude` is not installed there.
    case ready(claudePath: String?)
    /// The machine answered but rejected our keys: a one-time password can install one.
    case needsKey
    case failed(String)
}

/// Sets up key authentication by itself: generates a key when the Mac has none and
/// installs it on the remote machine using the password once. The password goes to
/// ssh through a temporary askpass script and an environment variable, never to disk.
public enum SSHKeySetup {
    static let keyNames = ["id_ed25519", "id_ecdsa", "id_rsa"]

    /// Whether ssh's stderr means the server refused our credentials (as opposed to
    /// an unreachable host, a wrong port or a refused connection).
    public static func isAuthFailure(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("permission denied") || text.contains("too many authentication failures")
    }

    /// Remote script that appends the public key to `authorized_keys` once, with safe modes.
    public static func installScript(publicKey: String) -> String {
        let key = SSHTransport.shellQuote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return SSHTransport.shellScript(
            "umask 077; mkdir -p \"$HOME/.ssh\"; touch \"$HOME/.ssh/authorized_keys\"; "
            + "grep -qxF \(key) \"$HOME/.ssh/authorized_keys\" || printf '%s\\n' \(key) >> \"$HOME/.ssh/authorized_keys\"; "
            + "chmod 700 \"$HOME/.ssh\"; chmod 600 \"$HOME/.ssh/authorized_keys\"; echo JACK-KEY-OK")
    }

    /// Argv for the password-based install: one prompt, password auth only.
    public static func installArguments(endpoint: ChatRemoteEndpoint, publicKey: String) -> [String] {
        var args = ["-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR",
                    "-o", "PreferredAuthentications=password,keyboard-interactive",
                    "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        if let port = endpoint.sshPort { args += ["-p", String(port)] }
        args.append(endpoint.destination)
        args.append(installScript(publicKey: publicKey))
        return args
    }

    private static var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    /// The public key ssh would offer by default, generating an ed25519 one when none exists.
    public static func ensurePublicKey() throws -> String {
        let directory = sshDirectory
        for name in keyNames {
            let pub = directory.appendingPathComponent(name + ".pub")
            if let text = try? String(contentsOf: pub, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let keyPath = directory.appendingPathComponent("id_ed25519").path
        let keygen = ExecutableResolver.resolve("ssh-keygen") ?? "/usr/bin/ssh-keygen"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: keygen)
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "jack@\(Host.current().localizedName ?? "mac")", "-f", keyPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { throw SSHError.failed("No se pudo crear la clave SSH: \(error.localizedDescription)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8) else {
            throw SSHError.failed("No se pudo crear la clave SSH en ~/.ssh.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks the connection without ever prompting.
    public static func probe(endpoint: ChatRemoteEndpoint, timeout: TimeInterval = 30) -> SSHProbeResult {
        let run = runSSH(arguments: SSHTransport.baseOptions + portArguments(endpoint) + [endpoint.destination, SSHTransport.probeCommand],
                         environment: nil, timeout: timeout)
        if run.timedOut { return .failed("Sin respuesta en \(Int(timeout)) s: revisa la IP y que la máquina esté encendida.") }
        let probe = SSHTransport.readProbe(run.stdout)
        if probe.reachable { return .ready(claudePath: probe.claudePath) }
        if isAuthFailure(run.stderr) { return .needsKey }
        let hint = run.stderr.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return .failed("SSH falló\(hint.map { ": \($0)" } ?? ".") Revisa la IP, el puerto y el usuario.")
    }

    /// Installs this Mac's key on the machine using `password` once, then verifies key login works.
    public static func installKey(endpoint: ChatRemoteEndpoint, password: String) throws {
        let publicKey = try ensurePublicKey()
        let askpass = FileManager.default.temporaryDirectory.appendingPathComponent("jack-askpass-\(UUID().uuidString).sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$JACK_SSH_PASSWORD\"\n".write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        defer { try? FileManager.default.removeItem(at: askpass) }
        let environment = ProcessInfo.processInfo.environment.merging([
            "SSH_ASKPASS": askpass.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "JACK_SSH_PASSWORD": password,
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? "jack:0",
        ]) { _, new in new }
        let run = runSSH(arguments: installArguments(endpoint: endpoint, publicKey: publicKey),
                         environment: environment, timeout: 30)
        if run.timedOut { throw SSHError.failed("La máquina tardó demasiado en responder.") }
        guard run.stdout.contains("JACK-KEY-OK") else {
            if isAuthFailure(run.stderr) { throw SSHError.failed("Contraseña incorrecta o acceso por contraseña desactivado en esa máquina.") }
            let hint = run.stderr.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw SSHError.failed("No se pudo instalar la clave\(hint.map { ": \($0)" } ?? ".")")
        }
    }

    /// Remote script that reads the password from stdin (never from argv, where `ps` would show it)
    /// and unlocks the login keychain. Claude Code keeps its credentials there on macOS, and a
    /// keychain locked in an SSH session makes it ask to log in again.
    public static let unlockKeychainScript = SSHTransport.shellScript(
        "IFS= read -r pw; security unlock-keychain -p \"$pw\" \"$HOME/Library/Keychains/login.keychain-db\" >/dev/null 2>&1 && echo JACK-UNLOCKED")

    /// Unlocks the machine's login keychain with the password saved for it, if any.
    /// Best effort: a failure never blocks the agent from starting. Returns whether it unlocked.
    @discardableResult
    public static func unlockKeychain(endpoint: ChatRemoteEndpoint) -> Bool {
        guard let password = RemoteKeychain.password(for: endpoint.destination), !password.isEmpty else { return false }
        let run = runSSH(arguments: SSHTransport.baseOptions + portArguments(endpoint) + [endpoint.destination, unlockKeychainScript],
                         environment: nil, timeout: 15, input: password)
        return run.stdout.contains("JACK-UNLOCKED")
    }

    private static func portArguments(_ endpoint: ChatRemoteEndpoint) -> [String] {
        endpoint.sshPort.map { ["-p", String($0)] } ?? []
    }

    private static func runSSH(arguments: [String], environment: [String: String]?, timeout: TimeInterval, input: String? = nil)
        -> (stdout: String, stderr: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExecutableResolver.resolve("ssh") ?? "/usr/bin/ssh")
        process.arguments = arguments
        if let environment { process.environment = environment }
        // No terminal: ssh cannot ask on its own and falls back to askpass or fails fast.
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return ("", "No se pudo lanzar ssh: \(error.localizedDescription)", false) }
        if let input {
            stdin.fileHandleForWriting.write(Data((input + "\n").utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            return ("", "", true)
        }
        return (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", false)
    }
}

/// Machines already set up, newest first, so the next agent is one tap away.
public struct SavedRemote: Codable, Equatable, Identifiable {
    public var destination: String
    public var sshPort: Int?
    public var remotePath: String?
    public var id: String { "\(destination):\(sshPort ?? 22)" }
    public init(destination: String, sshPort: Int? = nil, remotePath: String? = nil) {
        self.destination = destination; self.sshPort = sshPort; self.remotePath = remotePath
    }
}

public enum SavedRemotes {
    static let key = "savedRemotes"

    public static func load(_ defaults: UserDefaults = .standard) -> [SavedRemote] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedRemote].self, from: data) else { return [] }
        return list
    }

    /// Adds or refreshes a machine and moves it to the front. Capped at 12.
    public static func remember(_ remote: SavedRemote, _ defaults: UserDefaults = .standard) {
        var list = load(defaults).filter { $0.id != remote.id }
        list.insert(remote, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(12))) { defaults.set(data, forKey: key) }
    }

    public static func forget(_ remote: SavedRemote, _ defaults: UserDefaults = .standard) {
        let list = load(defaults).filter { $0.id != remote.id }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}

/// Per-machine login keychain passwords, kept in this Mac's own keychain (never in
/// preferences or on disk in clear text).
public enum RemoteKeychain {
    static let service = "dev.jack.remote-keychain-password"

    private static func query(_ destination: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: destination.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public static func password(for destination: String) -> String? {
        var request = query(destination)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the password for a machine; an empty one removes it.
    public static func setPassword(_ password: String, for destination: String) {
        SecItemDelete(query(destination) as CFDictionary)
        guard !password.isEmpty, !destination.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var item = query(destination)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }
}
