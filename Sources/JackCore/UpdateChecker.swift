import Combine
import Foundation

/// "0.3.34" or "v0.3.34", compared number by number so 0.3.10 is newer than 0.3.9.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        // A suffix such as "-beta" does not take part in the comparison.
        let core = body.prefix { $0.isNumber || $0 == "." }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// A published Jack release: what GitHub's "latest release" answers.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    /// The `.zip` attached to the release, if there is one.
    public let downloadURL: URL?
    public let downloadName: String?
    public let downloadSize: Int?

    public init(version: AppVersion, notes: String, pageURL: URL, downloadURL: URL?, downloadName: String?, downloadSize: Int? = nil) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.downloadName = downloadName
        self.downloadSize = downloadSize
    }

    /// Reads the JSON of `GET /repos/{owner}/{repo}/releases/latest`. Drafts and pre-releases are ignored.
    public static func parse(_ data: Data) -> AppRelease? {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int? }
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              let version = AppVersion(payload.tag_name), let page = URL(string: payload.html_url) else { return nil }
        let zip = payload.assets?.first { $0.name.lowercased().hasSuffix(".zip") }
        return AppRelease(version: version, notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          pageURL: page, downloadURL: zip.flatMap { URL(string: $0.browser_download_url) }, downloadName: zip?.name, downloadSize: zip?.size)
    }
}

/// Looks for a newer Jack on GitHub Releases, once at launch and then every few hours. Normal mode only: Light never starts it.
@MainActor public final class UpdateChecker: ObservableObject {
    public enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed(String)
        case downloading
        /// The update is staged and the helper waits for Jack to quit.
        case installing
    }

    public typealias Fetch = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    public static let enabledKey = "updateChecksEnabled"
    static let skippedKey = "updateSkippedVersion"
    static let lastCheckKey = "updateLastCheck"
    public static let interval: TimeInterval = 6 * 3600

    /// The newer release, unless the user skipped it.
    @Published public private(set) var available: AppRelease?
    @Published public private(set) var status: Status = .idle

    public let currentVersion: AppVersion
    private let endpoint: URL
    private let fetch: Fetch
    private let defaults: UserDefaults
    private let now: () -> Date
    private var polling: Task<Void, Never>?

    public init(repository: String = "brianmojena/Jack", currentVersion: String? = nil, defaults: UserDefaults = .standard,
                now: @escaping () -> Date = Date.init, fetch: Fetch? = nil) {
        self.endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        self.currentVersion = AppVersion(currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")) ?? AppVersion("0")!
        self.defaults = defaults
        self.now = now
        self.fetch = fetch ?? Self.liveFetch
    }

    public var enabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Checks now if the last check is older than the interval, then keeps checking while the user leaves the setting on.
    public func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var wait = Self.interval
                if self.enabled {
                    let last = self.defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
                    let due = last.addingTimeInterval(Self.interval).timeIntervalSince(self.now())
                    if due <= 0 { await self.check(manual: false) } else { wait = due }
                }
                try? await Task.sleep(for: .seconds(max(wait, 60)))
            }
        }
    }

    public func stop() {
        polling?.cancel()
        polling = nil
    }

    /// `manual` also reports "up to date" and errors, and offers a release the user had skipped.
    public func check(manual: Bool) async {
        guard status != .checking, status != .downloading, status != .installing else { return }
        let previous = status
        status = .checking
        do {
            let (data, response) = try await fetch(endpoint)
            defaults.set(now(), forKey: Self.lastCheckKey)
            guard response.statusCode == 200 else {
                throw UpdateError(response.statusCode == 404
                                  ? "GitHub no encuentra versiones publicadas (o el repositorio es privado)."
                                  : "GitHub respondió con el error \(response.statusCode).")
            }
            guard let release = AppRelease.parse(data) else { throw UpdateError("No se pudo leer la última versión publicada.") }
            let skipped = defaults.string(forKey: Self.skippedKey).flatMap(AppVersion.init)
            if release.version > currentVersion, manual || skipped != release.version {
                available = release
                status = .idle
            } else {
                if release.version <= currentVersion { available = nil }
                status = manual ? .upToDate : .idle
            }
        } catch {
            // A failed automatic check is silent: no network is not news.
            status = manual ? .failed(error.localizedDescription) : (previous == .upToDate ? .upToDate : .idle)
        }
    }

    /// Hides this release until a newer one is published.
    public func skipAvailable() {
        guard let available else { return }
        defaults.set(available.version.description, forKey: Self.skippedKey)
        self.available = nil
    }

    /// Downloads the release's zip into the Downloads folder and returns where it is.
    public func download() async throws -> URL {
        guard let release = available, let source = release.downloadURL else {
            throw UpdateError("La versión no incluye un archivo .zip para descargar.")
        }
        status = .downloading
        defer { status = .idle }
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("No se pudo descargar la actualización.") }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let destination = folder.appendingPathComponent(release.downloadName ?? "Jack-\(release.version).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Whether Jack can replace itself here, or only download the zip.
    public var canInstallInPlace: Bool { AppInstaller.replaceableLocation() != nil }

    /// Downloads and checks the release, then starts the helper that swaps the app after Jack quits. The caller quits Jack
    /// right after this returns; a failure leaves the installed app untouched.
    public func install() async throws {
        guard let release = available, let source = release.downloadURL else {
            throw UpdateError("La versión no incluye un archivo .zip para descargar.")
        }
        guard let destination = AppInstaller.replaceableLocation() else {
            throw UpdateError("Jack no está en una carpeta de Aplicaciones donde pueda reemplazarse: descarga el zip.")
        }
        guard status != .downloading, status != .installing else { return }
        status = .downloading
        do {
            let (temporary, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("No se pudo descargar la actualización.") }
            if let size = release.downloadSize,
               (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) != size {
                throw UpdateError("La descarga está incompleta: inténtalo de nuevo.")
            }
            status = .installing
            let version = release.version
            let identifier = Bundle.main.bundleIdentifier ?? "dev.jack.desktop"
            let pid = ProcessInfo.processInfo.processIdentifier
            try await Task.detached {
                let staged = try AppInstaller.stage(zip: temporary, expected: version, bundleIdentifier: identifier,
                                                    in: AppInstaller.updatesDirectory.appendingPathComponent(version.description, isDirectory: true))
                try AppInstaller.startReplacement(staged: staged, destination: destination, pid: pid)
            }.value
        } catch {
            status = .idle
            throw error
        }
    }

    private static let liveFetch: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Jack", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError("Respuesta no válida de GitHub.") }
        return (data, http)
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
