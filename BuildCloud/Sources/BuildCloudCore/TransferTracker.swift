import Foundation

/// Remembers how far each device has downloaded each build, so the web page can show install progress
/// (iOS installs happen outside Safari, but the .ipa still comes from this server), and which apps each
/// device already installed, so their button says "Reemplazar".
public final class TransferTracker: @unchecked Sendable {
    public struct Progress: Codable, Equatable, Sendable {
        public var sent: Int64
        public var total: Int64
        public var state: String
        /// Seconds since 1970, so the page can ignore downloads that started before its click.
        public var updatedAt: Double
    }

    private static let maxAge: TimeInterval = 15 * 60
    private let lock = NSLock()
    private var entries: [String: Progress] = [:]
    /// Device IP → app folders ("debug/<bundle id>") it downloaded completely.
    private var installed: [String: Set<String>]
    private let storage: URL?

    /// - Parameter storage: JSON file that keeps the installed apps across restarts.
    public init(storage: URL? = nil) {
        self.storage = storage
        installed = storage.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
    }

    public func record(_ transfer: FileTransfer, now: Date = Date()) {
        guard let build = Self.buildPath(fromFilePath: transfer.path) else { return }
        let progress = Progress(sent: transfer.sent, total: transfer.total, state: transfer.state.rawValue,
                                updatedAt: now.timeIntervalSince1970)
        lock.lock()
        entries[Self.key(transfer.remoteHost, build)] = progress
        entries = entries.filter { now.timeIntervalSince1970 - $0.value.updatedAt < Self.maxAge }
        var snapshot: [String: Set<String>]?
        if transfer.state == .completed, let app = Self.appPath(fromBuildPath: build),
           installed[transfer.remoteHost, default: []].insert(app).inserted {
            snapshot = installed
        }
        lock.unlock()
        if let snapshot { save(snapshot) }
    }

    /// Latest download of `buildPath` by the device at `remoteHost`.
    public func progress(of buildPath: String, for remoteHost: String) -> Progress? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Self.key(remoteHost, buildPath)]
    }

    /// Whether the device at `remoteHost` already downloaded any build of the app that `buildPath` belongs to.
    public func hasInstalled(appOf buildPath: String, on remoteHost: String) -> Bool {
        guard let app = Self.appPath(fromBuildPath: buildPath) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return installed[remoteHost]?.contains(app) == true
    }

    private func save(_ snapshot: [String: Set<String>]) {
        guard let storage else { return }
        try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: storage, options: .atomic)
    }

    static func key(_ host: String, _ build: String) -> String { "\(host)|\(build)" }

    /// "/files/debug/app/1.0-1-x/App.ipa" → "debug/app/1.0-1-x"
    static func buildPath(fromFilePath path: String) -> String? {
        guard path.hasPrefix("/files/") else { return nil }
        let parts = path.dropFirst("/files/".count).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    /// "debug/app/1.0-1-x" → "debug/app"
    static func appPath(fromBuildPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: "/")
    }
}
