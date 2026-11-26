import Foundation
import Security

// Providers a Jack Bot agent can run on: the command-line agents installed on this Mac, or a custom API.
// Everything here is for Normal mode only. Light never creates a store, scans for CLIs or reads the Keychain for it.

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

// MARK: - Custom API provider

/// An OpenAI-compatible endpoint (OpenAI, OpenRouter, Groq, LM Studio, Ollama's /v1, …). The key is never part of this value.
public struct APIProviderConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// The server root, without `/v1`: Jack adds `/v1/chat/completions`.
    public var baseURL: String
    public var model: String

    public init(id: UUID = UUID(), name: String, baseURL: String, model: String) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.model = model
    }

    /// Prefix of the model ids this provider serves (`api-1a2b3c4d/<model>`).
    public var serverID: String { "api-" + id.uuidString.lowercased().prefix(8) }
    /// The value stored as an agent's model.
    public var modelID: String { serverID + "/" + model }

    public enum Problem: Error, Equatable, LocalizedError {
        case emptyName, emptyModel, invalidURL, insecureURL, credentialsInURL
        public var errorDescription: String? {
            switch self {
            case .emptyName: return "Ponle un nombre al proveedor."
            case .emptyModel: return "Indica el modelo."
            case .invalidURL: return "La dirección no es válida. Usa algo como https://api.openai.com"
            case .insecureURL: return "Usa https. Solo se admite http en este mismo equipo (localhost)."
            case .credentialsInURL: return "No pongas usuario, contraseña ni claves dentro de la dirección: la clave va en su propio campo."
            }
        }
    }

    /// The URL Jack will call, or why it is refused. `http` is accepted only for loopback servers.
    public static func normalizedBaseURL(_ raw: String) -> Result<String, Problem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/v1") { text.removeLast(3) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return .failure(.invalidURL) }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return .failure(.credentialsInURL) }
        if scheme == "http", !Self.isLoopback(host) { return .failure(.insecureURL) }
        return .success(text)
    }

    static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasPrefix("127.") }

    /// A normalized copy, or the first problem found.
    public func validated() -> Result<APIProviderConfig, Problem> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !model.isEmpty else { return .failure(.emptyModel) }
        switch Self.normalizedBaseURL(baseURL) {
        case .failure(let problem): return .failure(problem)
        case .success(let url): return .success(APIProviderConfig(id: id, name: String(name.prefix(60)), baseURL: url, model: model))
        }
    }
}

// MARK: - Secrets

/// Where API keys live. The real one is the macOS Keychain; tests use `MemorySecretStore`.
public protocol BotSecretStore: Sendable {
    func read(account: String) -> String?
    func save(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public struct BotSecretError: LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? { "No se pudo usar el Llavero de macOS (código \(status))." }
}

/// One generic-password item per provider, readable only while the Mac is unlocked and never synced to iCloud.
public struct KeychainSecretStore: BotSecretStore {
    public static let service = "dev.jack.bot.api"
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }
    public func read(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw BotSecretError(status: update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw BotSecretError(status: status) }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BotSecretError(status: status) }
    }
}

/// For tests: keeps keys in memory only.
public final class MemorySecretStore: BotSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    public func save(_ secret: String, account: String) throws { lock.lock(); values[account] = secret; lock.unlock() }
    public func delete(account: String) throws { lock.lock(); values[account] = nil; lock.unlock() }
}

public enum BotSecrets {
    /// Replaces every occurrence of a key in a text, so an error from a provider never shows it back.
    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { $0.count >= 6 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••") }
    }
    /// A key is one token: no spaces, no line breaks, no control characters.
    public static func isPlausibleKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 4_096 && !key.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 32 || $0.value == 127 }
    }
}

// MARK: - Registry used by the Stellar driver

/// The API providers the Stellar driver may call, with their keys fetched from the Keychain only at request time.
/// It is empty until Normal mode registers providers and emptied again in Light, so Stellar Code keeps working
/// with local servers only unless a provider was added here on purpose.
public final class BotAPIRegistry: @unchecked Sendable {
    public static let shared = BotAPIRegistry()
    private let lock = NSLock()
    private var configs: [String: APIProviderConfig] = [:]
    private var secrets: BotSecretStore = KeychainSecretStore()

    public func register(_ providers: [APIProviderConfig], secrets: BotSecretStore) {
        lock.lock(); defer { lock.unlock() }
        configs = Dictionary(providers.map { ($0.serverID, $0) }, uniquingKeysWith: { _, last in last })
        self.secrets = secrets
    }
    public func clear() { lock.lock(); configs = [:]; lock.unlock() }

    public var servers: [StellarServer] {
        lock.lock(); defer { lock.unlock() }
        return configs.values.sorted { $0.name < $1.name }.map { StellarServer(id: $0.serverID, title: $0.name, baseURL: $0.baseURL, api: .openai) }
    }
    func config(for server: StellarServer) -> APIProviderConfig? {
        lock.lock(); defer { lock.unlock() }
        guard let config = configs[server.id], config.baseURL == server.baseURL else { return nil }
        return config
    }
    public func isAPI(_ server: StellarServer) -> Bool { config(for: server) != nil }
    func apiKey(for server: StellarServer) -> String? {
        guard let config = config(for: server) else { return nil }
        lock.lock(); let store = secrets; lock.unlock()
        return store.read(account: config.id.uuidString.lowercased())
    }
    /// The text with every registered key removed.
    func redact(_ text: String) -> String {
        lock.lock(); let store = secrets, all = configs.values; lock.unlock()
        return BotSecrets.redact(text, secrets: all.compactMap { store.read(account: $0.id.uuidString.lowercased()) })
    }
}

// MARK: - Store

/// The custom API providers, saved beside the chats. The file holds names, addresses and models; the keys stay in the Keychain.
@MainActor public final class APIProviderStore: ObservableObject {
    @Published public private(set) var providers: [APIProviderConfig] = []
    private let url: URL
    private let secrets: BotSecretStore

    public init(directory: URL, secrets: BotSecretStore = KeychainSecretStore()) {
        url = directory.appendingPathComponent("botproviders.json"); self.secrets = secrets
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([APIProviderConfig].self, from: data) { providers = saved }
    }

    public func provider(id: UUID) -> APIProviderConfig? { providers.first { $0.id == id } }
    public func provider(serverID: String) -> APIProviderConfig? { providers.first { $0.serverID == serverID } }
    public func hasKey(_ id: UUID) -> Bool { secrets.read(account: id.uuidString.lowercased()) != nil }

    /// Saves the provider and, when `apiKey` is not empty, its key. An empty key keeps the one already stored.
    public func upsert(_ config: APIProviderConfig, apiKey: String? = nil) throws {
        let clean: APIProviderConfig
        switch config.validated() { case .success(let value): clean = value; case .failure(let problem): throw problem }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            guard BotSecrets.isPlausibleKey(key) else { throw BotInputError("La clave no es válida: debe ser una sola palabra, sin espacios ni saltos de línea.") }
            try secrets.save(key, account: clean.id.uuidString.lowercased())
        }
        if let index = providers.firstIndex(where: { $0.id == clean.id }) { providers[index] = clean } else { providers.append(clean) }
        try persist()
    }

    /// Removes the provider and its key.
    public func remove(_ id: UUID) throws {
        try secrets.delete(account: id.uuidString.lowercased())
        providers.removeAll { $0.id == id }
        try persist()
    }

    /// Makes the Stellar driver aware of the providers. Called only in Normal mode.
    public func registerForDriver() { BotAPIRegistry.shared.register(providers, secrets: secrets) }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(providers).write(to: url, options: .atomic)
        registerForDriver()
    }
}

public struct BotInputError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
