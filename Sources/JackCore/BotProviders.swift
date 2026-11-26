import Foundation

// Providers a Jack Bot agent can run on. Today: the command-line agents Jack already integrates and that are installed
// on this Mac. Everything here is for Normal mode only; Light never scans for CLIs for Jack Bot.
//
// `BotProviderCatalog` is the seam for more kinds of provider (a custom API with its key in the Keychain is planned
// for a later version): a new kind is a new catalog and a new `BotProviderChoice` case, with no change to the orchestrator.

// MARK: - Installed command-line agents

public struct CLIProviderStatus: Identifiable, Equatable, Sendable {
    public var provider: ChatProvider
    /// Absolute path of the executable, or nil when it was not found.
    public var path: String?
    public var version: String?
    public var id: String { provider.rawValue }
    public var installed: Bool { path != nil }
    public init(provider: ChatProvider, path: String?, version: String? = nil) { self.provider = provider; self.path = path; self.version = version }
}

public enum CLIDetector {
    /// Providers that run as an installed program. Stellar Code is built in and has no executable.
    public static var providers: [ChatProvider] { ChatProvider.allCases.filter { !$0.isBuiltIn } }

    /// The resolver and the version probe are injected so a test never touches the real installation.
    public static func detect(resolver: (ChatProvider) -> String?, probe: (String) -> String?) -> [CLIProviderStatus] {
        providers.map { provider in
            guard let path = resolver(provider) else { return CLIProviderStatus(provider: provider, path: nil) }
            return CLIProviderStatus(provider: provider, path: path, version: probe(path))
        }
    }

    /// Rescans the login shell's PATH and the usual install folders, honouring the path chosen in Settings.
    /// Runs `--version` once per installed program, so call it when the user opens the picker, never in the background.
    public static func scan(preferences: UserDefaults? = .standard) -> [CLIProviderStatus] {
        detect(resolver: { provider in
            let override = preferences?.string(forKey: "providerExecutablePath.\(provider.rawValue)")
            return ExecutableResolver.scan(provider.executableName, override: override)
        }, probe: { probeVersion(executable: $0) })
    }

    /// First line of `<executable> --version`, or nil if it fails or takes more than `timeout` seconds.
    public static func probeVersion(executable: String, timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.environment = ExecutableResolver.childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return cleanVersion(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile().prefix(2_000), as: UTF8.self))
    }

    /// One short, printable line.
    public static func cleanVersion(_ raw: String) -> String? {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let printable = String(line.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 && $0.value != 127 })
        return printable.isEmpty ? nil : String(printable.prefix(80))
    }
}

// MARK: - Provider abstraction

/// What a bot runs on. One case today; a later version adds more without touching the orchestrator.
public enum BotProviderChoice: Equatable, Sendable {
    case cli(ChatProvider)
}

/// One row of the provider picker.
public struct BotProviderOption: Identifiable, Equatable, Sendable {
    public var choice: BotProviderChoice
    public var title: String
    /// Version, «NO ENCONTRADO», «BUSCANDO…»…
    public var detail: String
    public var available: Bool
    public var id: String { switch choice { case .cli(let provider): return "cli-" + provider.rawValue } }
}

/// A source of providers. The orchestrator asks every catalog in turn.
@MainActor public protocol BotProviderCatalog {
    func options() -> [BotProviderOption]
    /// A reference as a bot writes it (`claude`, `codex`…). Nil when this catalog does not own the reference.
    func resolve(_ reference: String) -> Result<(choice: BotProviderChoice, label: String), BotOrchestrationError>?
    /// The choice an existing agent is on, if this catalog owns it.
    func choice(of agent: BotAgent) -> BotProviderChoice?
    /// Points the agent at the choice. Returns false if this catalog does not own it.
    func apply(_ choice: BotProviderChoice, to agent: inout BotAgent) -> Bool
}

/// The command-line agents Jack integrates, as found by `CLIDetector`.
@MainActor public struct CLIProviderCatalog: BotProviderCatalog {
    public var statuses: () -> [CLIProviderStatus]
    public var scanning: () -> Bool
    public init(statuses: @escaping () -> [CLIProviderStatus], scanning: @escaping () -> Bool = { false }) {
        self.statuses = statuses; self.scanning = scanning
    }
    public func options() -> [BotProviderOption] {
        let found = statuses()
        return CLIDetector.providers.map { provider in
            let status = found.first { $0.provider == provider }
            let detail = scanning() && status == nil ? "BUSCANDO…" : status?.installed == true ? (status?.version ?? "INSTALADO").uppercased() : "NO ENCONTRADO"
            return BotProviderOption(choice: .cli(provider), title: provider.title, detail: detail, available: status?.installed == true)
        }
    }
    public func resolve(_ reference: String) -> Result<(choice: BotProviderChoice, label: String), BotOrchestrationError>? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let provider = CLIDetector.providers.first(where: { $0.rawValue == text }) else { return nil }
        guard statuses().contains(where: { $0.provider == provider && $0.installed }) else {
            return .failure(.init("\(provider.title) is not installed on this Mac."))
        }
        return .success((.cli(provider), provider.title))
    }
    public func choice(of agent: BotAgent) -> BotProviderChoice? {
        CLIDetector.providers.contains(agent.provider) ? .cli(agent.provider) : nil
    }
    public func apply(_ choice: BotProviderChoice, to agent: inout BotAgent) -> Bool {
        guard case .cli(let provider) = choice else { return false }
        agent.provider = provider; agent.model = ""
        return true
    }
}

