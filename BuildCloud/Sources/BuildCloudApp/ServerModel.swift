import AppKit
import BuildCloudCore
import CoreImage.CIFilterBuiltins
import Foundation

@MainActor
final class ServerModel: ObservableObject {
    private enum Keys {
        static let port = "port", httpsPort = "httpsPort", dataPath = "dataPath"
    }

    /// HTTP server: certificate page, Android and the Tailscale proxy.
    @Published private(set) var state: HTTPServer.State = .stopped
    /// HTTPS server with BuildCloud's own certificate, for iOS installs on the local network.
    @Published private(set) var httpsState: HTTPServer.State = .stopped
    @Published private(set) var builds: [BuildChannel: [BuildRecord]] = [:]
    @Published private(set) var publishing = 0
    @Published var lastError: String?

    @Published var port: Int
    @Published var httpsPort: Int
    @Published var dataPath: String

    private var server: HTTPServer?
    private var httpsServer: HTTPServer?
    private var refreshTimer: Timer?
    let authority = CertificateAuthority()

    init() {
        let defaults = UserDefaults.standard
        port = defaults.object(forKey: Keys.port) as? Int ?? 8686
        httpsPort = defaults.object(forKey: Keys.httpsPort) as? Int ?? 8443
        dataPath = defaults.string(forKey: Keys.dataPath) ?? BuildLibrary.defaultRoot.path
        start()
        // Builds published from the CLI or scripts appear without reopening the window.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var library: BuildLibrary {
        BuildLibrary(root: URL(fileURLWithPath: (dataPath as NSString).expandingTildeInPath))
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isHTTPSRunning: Bool {
        if case .running = httpsState { return true }
        return false
    }

    var statusText: String {
        switch (state, httpsState) {
        case (.failed(let message), _): "Error HTTP: \(message)"
        case (_, .failed(let message)): "Error HTTPS: \(message)"
        case (.running, .running): "En marcha · HTTPS \(httpsPort) · HTTP \(port)"
        case (.running, _): "En marcha · HTTP \(port) · preparando HTTPS…"
        case (.stopped, _): "Detenido"
        default: "Iniciando…"
        }
    }

    private var lanHost: String { ServerNames.preferredLANHost() }

    /// URL to open on the iPhones: the local HTTPS server.
    var shareURL: String { "https://\(lanHost):\(httpsPort)" }

    /// Page with the profile to trust BuildCloud's certificate; plain HTTP so it opens before trusting it.
    var certificateURL: String { "http://\(lanHost):\(port)/certificado" }

    // MARK: - Server

    func start() {
        let defaults = UserDefaults.standard
        defaults.set(port, forKey: Keys.port)
        defaults.set(httpsPort, forKey: Keys.httpsPort)
        defaults.set(dataPath, forKey: Keys.dataPath)

        stopServers()
        let library = library
        do {
            try library.prepare()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let site = BuildCloudSite(library: library, tls: LocalTLS(authority: authority, httpsPort: UInt16(clamping: httpsPort)),
                                  transfers: TransferTracker(storage: library.installedDevicesFile))
        let log = ServerLog(url: library.serverLogFile)
        let server = HTTPServer { site.handle($0) }
        server.onFileTransfer = { site.transfers.record($0) }
        server.onLog = { log.write("http \($0)") }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
        self.server = server
        server.start(port: UInt16(clamping: port))

        // Creating the CA and the server certificate runs openssl; keep it off the main thread.
        httpsState = .starting
        let authority = authority, httpsPort = UInt16(clamping: httpsPort)
        Task.detached {
            do {
                let identity = try authority.identity(for: ServerNames.current())
                await MainActor.run {
                    guard self.server === server else { return }  // restarted meanwhile
                    let https = HTTPServer { site.handle($0) }
                    https.onFileTransfer = { site.transfers.record($0) }
                    https.onLog = { log.write("https \($0)") }
                    https.onStateChange = { [weak self] state in
                        Task { @MainActor in self?.httpsState = state }
                    }
                    self.httpsServer = https
                    https.start(port: httpsPort, identity: identity)
                }
            } catch {
                await MainActor.run { self.httpsState = .failed(error.localizedDescription) }
            }
        }
        refresh()
    }

    func stop() {
        stopServers()
        state = .stopped
        httpsState = .stopped
    }

    private func stopServers() {
        server?.stop()
        httpsServer?.stop()
        server = nil
        httpsServer = nil
    }

    // MARK: - Builds

    func refresh() {
        let library = library
        var all: [BuildChannel: [BuildRecord]] = [:]
        for channel in BuildChannel.allCases { all[channel] = library.builds(in: channel) }
        if all != builds { builds = all }
    }

    func publish(_ files: [URL], to channel: BuildChannel) {
        let library = library
        for file in files {
            publishing += 1
            Task.detached {
                let error: String?
                do {
                    try library.publish(file, channel: channel)
                    error = nil
                } catch let failure {
                    error = "\(file.lastPathComponent): \(failure.localizedDescription)"
                }
                await MainActor.run {
                    self.publishing -= 1
                    if let error { self.lastError = error }
                    self.refresh()
                }
            }
        }
    }

    func remove(_ record: BuildRecord) {
        do {
            try library.remove(record)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func reveal(_ record: BuildRecord) {
        guard let url = library.fileURL(of: record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyLink(_ record: BuildRecord) {
        let link = BuildCloudSite(library: library).actionLink(for: record, origin: shareURL, installBase: shareURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func openWeb() {
        if let url = URL(string: shareURL) { NSWorkspace.shared.open(url) }
    }

    func revealData() {
        NSWorkspace.shared.open(library.root)
    }

    // MARK: - QR

    func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
