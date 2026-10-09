import Foundation

/// How an agent's CLI was installed, which decides the command that updates it.
public enum AgentInstallMethod: Equatable, Sendable {
    case homebrewCask(String)
    case homebrewFormula(String)
    case npm(package: String)
    /// The CLI updates itself with these arguments, such as `claude update`.
    case selfUpdate([String])
    case unsupported
}

public struct AgentUpdateResult: Equatable, Sendable {
    public let before: String?
    public let after: String?
    public let output: String
    public var changed: Bool { before != after }
}

/// Updates the agent CLIs Jack launches (Codex, Claude Code, OpenCode). Normal mode only: Light never offers it.
public enum AgentUpdater {
    static let npmPackages: [ChatProvider: String] = [
        .codex: "@openai/codex", .claude: "@anthropic-ai/claude-code", .opencode: "opencode-ai",
    ]

    /// Reads the install method from where the executable really lives: Homebrew links `bin/claude` into the Caskroom or Cellar.
    static func method(for provider: ChatProvider, resolvedPath: String) -> AgentInstallMethod {
        let parts = resolvedPath.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "Caskroom"), parts.indices.contains(index + 1) { return .homebrewCask(parts[index + 1]) }
        if let index = parts.firstIndex(of: "Cellar"), parts.indices.contains(index + 1) { return .homebrewFormula(parts[index + 1]) }
        if parts.contains("node_modules"), let package = npmPackages[provider] { return .npm(package: package) }
        switch provider {
        case .claude: return .selfUpdate(["update"])
        case .opencode: return .selfUpdate(["upgrade"])
        case .codex, .stellar: return .unsupported
        }
    }

    /// The program and arguments that update the agent, or nil when Jack does not know how.
    static func command(for method: AgentInstallMethod, executable: String) -> (program: String, arguments: [String])? {
        switch method {
        case .homebrewCask(let name): return ("brew", ["upgrade", "--cask", "--greedy", name])
        case .homebrewFormula(let name): return ("brew", ["upgrade", name])
        case .npm(let package): return ("npm", ["install", "-g", "\(package)@latest"])
        case .selfUpdate(let arguments): return (executable, arguments)
        case .unsupported: return nil
        }
    }

    /// First `1.2.3`-looking token of `--version`: "2.1.284 (Claude Code)", "codex-cli 0.160.0" and "1.18.33" all work.
    static func parseVersion(_ output: String) -> String? {
        output.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(output[$0]) }
    }

    public static func method(for provider: ChatProvider, override: String? = nil) -> AgentInstallMethod? {
        guard let executable = ExecutableResolver.resolve(provider.rawValue, override: override) else { return nil }
        return method(for: provider, resolvedPath: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)
    }

    public static func canUpdate(_ provider: ChatProvider, override: String? = nil) -> Bool {
        guard let method = method(for: provider, override: override) else { return false }
        return method != .unsupported
    }

    public static func installedVersion(of provider: ChatProvider, override: String? = nil) async -> String? {
        guard let executable = ExecutableResolver.resolve(provider.rawValue, override: override) else { return nil }
        let result = await run(executable, ["--version"], timeout: .seconds(15))
        return result.status == 0 ? parseVersion(result.output) : nil
    }

    /// Runs the update and reports the version before and after. Throws the tool's own message when it fails.
    public static func update(_ provider: ChatProvider, override: String? = nil) async throws -> AgentUpdateResult {
        guard let executable = ExecutableResolver.resolve(provider.rawValue, override: override) else {
            throw AgentUpdateError("No se encontró \(provider.title): elige o escanea su ejecutable primero.")
        }
        let method = method(for: provider, resolvedPath: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)
        guard let command = command(for: method, executable: executable) else {
            throw AgentUpdateError("Jack no sabe actualizar \(provider.title) con esta instalación: actualízalo como lo instalaste.")
        }
        guard let program = ExecutableResolver.resolve(command.program) else {
            throw AgentUpdateError("No se encontró «\(command.program)» para actualizar \(provider.title).")
        }
        let before = await installedVersion(of: provider, override: override)
        let result = await run(program, command.arguments, timeout: .seconds(600))
        guard result.status == 0 else { throw AgentUpdateError(result.message(for: provider)) }
        let after = await installedVersion(of: provider, override: override)
        return AgentUpdateResult(before: before, after: after, output: result.output)
    }

    private struct Output {
        let status: Int32
        let output: String
        func message(for provider: ChatProvider) -> String {
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "No se pudo actualizar \(provider.title) (código \(status))." : String(text.suffix(600))
        }
    }

    /// stdout and stderr share one pipe so the failure message keeps the tool's own order.
    private static func run(_ program: String, _ arguments: [String], timeout: Duration) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: program)
                process.arguments = arguments
                var environment = ExecutableResolver.childEnvironment()
                environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                environment["HOMEBREW_NO_ENV_HINTS"] = "1"
                environment["NO_COLOR"] = "1"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: Output(status: -1, output: error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout.components.seconds), execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

struct AgentUpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
