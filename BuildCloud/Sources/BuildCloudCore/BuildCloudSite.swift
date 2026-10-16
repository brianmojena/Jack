import Foundation

/// HTTPS on the local network with BuildCloud's own certificate authority.
public struct LocalTLS: Sendable {
    public var authority: CertificateAuthority
    public var httpsPort: UInt16

    public init(authority: CertificateAuthority, httpsPort: UInt16) {
        self.authority = authority
        self.httpsPort = httpsPort
    }
}

/// Routes of the BuildCloud web:
///   /                          the web app (Svelte, from web/), with the Debug and Release builds
///   /certificado               how to trust BuildCloud's certificate on an iPhone
///   /buildcloud.mobileconfig   iOS profile that installs the CA
///   /buildcloud-ca.crt         the CA certificate (Android, Mac)
///   /api/builds                the builds as JSON
///   /api/apps                  the builds grouped by app, with install links and labels for the visitor
///   /icon/<path>.png           the app icon of a build (extracted from the .ipa/.apk the first time)
///   /api/progress/<path>       how far the calling device has downloaded a build
///   /manifest/<path>.plist     OTA manifest for an iOS build (itms-services)
///   /files/<path>/<file>       the build files
public struct BuildCloudSite: Sendable {
    public let library: BuildLibrary
    public let tls: LocalTLS?
    /// Shared by the HTTP and HTTPS servers: the page may be on one and the download on the other.
    public let transfers: TransferTracker

    public init(library: BuildLibrary, tls: LocalTLS? = nil, transfers: TransferTracker = TransferTracker()) {
        self.library = library
        self.tls = tls
        self.transfers = transfers
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path
        switch path {
        case "/": return page()
        case "/certificado": return certificatePage(for: request)
        case "/buildcloud.mobileconfig": return mobileConfig()
        case "/buildcloud-ca.crt": return caCertificate()
        case "/api/builds": return buildsJSON()
        case "/api/apps": return appsJSON(for: request)
        default: break
        }
        if path.hasPrefix("/manifest/"), path.hasSuffix(".plist") {
            let buildPath = String(path.dropFirst("/manifest/".count).dropLast(".plist".count))
            return manifest(for: buildPath, baseURL: installBase(for: request))
        }
        if path.hasPrefix("/icon/"), path.hasSuffix(".png") {
            return icon(of: String(path.dropFirst("/icon/".count).dropLast(".png".count)))
        }
        if path.hasPrefix("/api/progress/") {
            return progress(of: String(path.dropFirst("/api/progress/".count)), for: request.remoteHost)
        }
        if path.hasPrefix("/files/") { return file(String(path.dropFirst("/files/".count))) }
        return .notFound
    }

    // MARK: - Base URLs

    /// The scheme and host the visitor used: a proxy's (Tailscale serve) or this server's own.
    func origin(for request: HTTPRequest) -> String {
        if let forwarded = request.headers["x-forwarded-host"] {
            let scheme = request.headers["x-forwarded-proto"] ?? (forwarded.hasSuffix(".ts.net") ? "https" : "http")
            return "\(scheme)://\(forwarded)"
        }
        let host = request.headers["host"] ?? "localhost"
        if host.split(separator: ":").first?.hasSuffix(".ts.net") == true { return "https://\(host)" }
        return "\(request.isSecure ? "https" : "http")://\(host)"
    }

    /// Base URL for iOS installs, which must be HTTPS: the visitor's origin when it already is,
    /// else the same host on the local HTTPS port.
    func installBase(for request: HTTPRequest) -> String {
        let origin = origin(for: request)
        guard !origin.hasPrefix("https://"), let tls else { return origin }
        return "https://\(Self.hostWithoutPort(request.headers["host"] ?? "localhost")):\(tls.httpsPort)"
    }

    static func hostWithoutPort(_ host: String) -> String {
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") { return String(host[...end]) }
        return host.split(separator: ":").first.map(String.init) ?? host
    }

    // MARK: - Routes

    func file(_ relative: String) -> HTTPResponse {
        guard let url = library.resolve(relative), url.lastPathComponent != "meta.json",
              !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return .notFound }
        var headers = [("Content-Type", Self.contentType(for: url.pathExtension))]
        if ["apk", "aab", "ipa"].contains(url.pathExtension.lowercased()) {
            headers.append(("Content-Disposition", "attachment; filename=\"\(url.lastPathComponent)\""))
        }
        return HTTPResponse(status: 200, headers: headers, body: .file(url, size: size))
    }

    /// `bundle-version` must be the CFBundleVersion (build): iOS compares it with the installed app and,
    /// if they differ, thinks the install didn't happen and downloads the .ipa again in a loop.
    func manifest(for buildPath: String, baseURL: String) -> HTTPResponse {
        guard let record = library.loadRecord(at: buildPath), record.platform == .ios else { return .notFound }
        let url = "\(baseURL)/files/\(Self.urlPath(record.path))/\(Self.urlPath(record.file))"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>items</key>
          <array>
            <dict>
              <key>assets</key>
              <array>
                <dict>
                  <key>kind</key><string>software-package</string>
                  <key>url</key><string>\(Self.escape(url))</string>
                </dict>
              </array>
              <key>metadata</key>
              <dict>
                <key>bundle-identifier</key><string>\(Self.escape(record.bundleId))</string>
                <key>bundle-version</key><string>\(Self.escape(record.build))</string>
                <key>kind</key><string>software</string>
                <key>title</key><string>\(Self.escape(record.name))</string>
              </dict>
            </dict>
          </array>
        </dict>
        </plist>

        """
        return .text(200, plist, type: "application/xml")
    }

    func icon(of buildPath: String) -> HTTPResponse {
        guard !buildPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              let record = library.loadRecord(at: buildPath), let url = library.icon(of: record),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        else { return .notFound }
        // A build never changes, so its icon can be cached for good.
        return HTTPResponse(status: 200, headers: [("Content-Type", "image/png"), ("Cache-Control", "max-age=31536000, immutable")],
                            body: .file(url, size: size))
    }

    func buildsJSON() -> HTTPResponse {
        var all: [String: [BuildRecord]] = [:]
        for channel in BuildChannel.allCases { all[channel.rawValue] = library.builds(in: channel) }
        let data = (try? BuildLibrary.encoder.encode(all)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .data(data))
    }

    func progress(of buildPath: String, for remoteHost: String) -> HTTPResponse {
        guard let progress = transfers.progress(of: buildPath, for: remoteHost),
              let data = try? JSONEncoder().encode(progress) else { return .notFound }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")],
                            body: .data(data))
    }

    func mobileConfig() -> HTTPResponse {
        guard let data = try? tls?.authority.mobileConfig() else { return .notFound }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-apple-aspen-config"),
                                                   ("Content-Disposition", "attachment; filename=\"BuildCloud.mobileconfig\"")],
                            body: .data(data))
    }

    func caCertificate() -> HTTPResponse {
        guard let data = try? tls?.authority.caCertificateDER() else { return .notFound }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-x509-ca-cert"),
                                                   ("Content-Disposition", "attachment; filename=\"BuildCloud-CA.crt\"")],
                            body: .data(data))
    }

    /// Link for the install/download button of a build. iOS Debug builds go through an HTTPS manifest.
    public func actionLink(for record: BuildRecord, origin: String, installBase: String) -> String {
        guard record.platform == .ios, record.channel == .debug else {
            return "\(origin)/files/\(Self.urlPath(record.path))/\(Self.urlPath(record.file))"
        }
        let manifest = "\(installBase)/manifest/\(Self.urlPath(record.path)).plist"
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? manifest
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    // MARK: - Pages

    /// The page is a static Svelte app (`web/`, embedded in `WebApp.html`) that reads `/api/apps`.
    func page() -> HTTPResponse {
        var response = HTTPResponse.text(200, WebApp.html, type: "text/html; charset=utf-8")
        response.headers.append(("Cache-Control", "no-store"))
        return response
    }

    /// What the web app shows: one entry per app (newest first) with all its builds, newest first.
    /// Links and labels depend on the visitor (its origin, and whether its device already has the app).
    public struct SiteState: Encodable, Sendable {
        public struct App: Encodable, Sendable {
            /// "<platform>:<bundle id>": the same bundle id can exist for iOS and Android.
            public var key: String
            public var name: String
            public var bundleId: String
            public var platform: BuildPlatform
            public var builds: [Build]
        }

        public struct Build: Encodable, Sendable {
            public var id: String
            public var name: String
            public var version: String
            public var build: String
            public var file: String
            public var size: String
            public var createdAt: Date
            public var installable: Bool
            public var link: String
            /// "Instalar", "Reemplazar" or "Descargar".
            public var label: String
            /// Where the app icon is; the page falls back to the initial when it doesn't load.
            public var icon: String
            /// For iOS Debug builds: path to poll in /api/progress while the iPhone downloads.
            public var progressPath: String?
        }

        public var certificate: Bool
        /// Set when the visitor uses plain HTTP and iOS installs need the HTTPS address.
        public var secureBase: String?
        public var channels: [String: [App]]
    }

    public func state(for request: HTTPRequest) -> SiteState {
        let origin = origin(for: request), installBase = installBase(for: request)
        var channels: [String: [SiteState.App]] = [:]
        for channel in BuildChannel.allCases {
            var apps: [SiteState.App] = []
            var index: [String: Int] = [:]
            for record in library.builds(in: channel) {
                let key = "\(record.platform.rawValue):\(record.bundleId)"
                let build = siteBuild(record, origin: origin, installBase: installBase, device: request.remoteHost)
                if let position = index[key] {
                    apps[position].builds.append(build)
                } else {
                    index[key] = apps.count
                    apps.append(SiteState.App(key: key, name: record.name, bundleId: record.bundleId,
                                              platform: record.platform, builds: [build]))
                }
            }
            channels[channel.rawValue] = apps
        }
        let secureBase = origin.hasPrefix("https://") || tls == nil ? nil : installBase
        return SiteState(certificate: tls != nil, secureBase: secureBase, channels: channels)
    }

    func siteBuild(_ record: BuildRecord, origin: String, installBase: String, device: String) -> SiteState.Build {
        // iOS replaces an app with the same bundle id, keeping its data; say so when this device already has it.
        let label = !record.isInstallable ? "Descargar"
            : transfers.hasInstalled(appOf: record.path, on: device) ? "Reemplazar" : "Instalar"
        // iOS installs leave Safari, so the page follows the download on the server instead.
        let tracksProgress = record.platform == .ios && record.channel == .debug
        return SiteState.Build(id: record.path, name: record.name, version: record.version, build: record.build,
                               file: record.file, size: Self.size(record.size), createdAt: record.createdAt,
                               installable: record.isInstallable,
                               link: actionLink(for: record, origin: origin, installBase: installBase),
                               label: label, icon: "/icon/\(Self.urlPath(record.path)).png", progressPath: tracksProgress ? Self.urlPath(record.path) : nil)
    }

    func appsJSON(for request: HTTPRequest) -> HTTPResponse {
        let data = (try? BuildLibrary.encoder.encode(state(for: request))) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")],
                            body: .data(data))
    }

    func certificatePage(for request: HTTPRequest) -> HTTPResponse {
        guard let tls else { return .notFound }
        let installBase = installBase(for: request)
        let fingerprint = (try? tls.authority.caFingerprint()) ?? ""
        return html(title: "Certificado · BuildCloud", body: """
        <header><h1>Certificado</h1><a class="link" href="/">Builds</a></header>
        <p>iOS solo instala apps desde HTTPS. BuildCloud usa su propio certificado en la red local:
        cada iPhone tiene que confiar en él <strong>una sola vez</strong>.</p>
        <h2>iPhone</h2>
        <ol>
          <li>Abre esta página en <strong>Safari</strong> y pulsa
            <a class="button" href="/buildcloud.mobileconfig">Descargar perfil</a> → Permitir.</li>
          <li>Ajustes → <strong>Perfil descargado</strong> → Instalar (te pide el código del iPhone).</li>
          <li>Ajustes → General → Información → <strong>Ajustes de confianza de certificados</strong> →
            activa <em>BuildCloud CA</em>.</li>
          <li>Abre <a href="\(Self.escape(installBase))/">\(Self.escape(installBase))</a> y pulsa Instalar en la app.</li>
        </ol>
        <h2>Android y Mac</h2>
        <p>Para abrir la versión HTTPS sin avisos, instala <a href="/buildcloud-ca.crt">BuildCloud-CA.crt</a>.
        Las APK también se instalan desde la versión sin cifrar.</p>
        <p class="fingerprint">SHA-256: \(Self.escape(fingerprint))</p>
        """)
    }

    func html(title: String, body: String) -> HTTPResponse {
        let html = """
        <!doctype html>
        <html lang="es">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(title))</title>
        <style>
          :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
          body { margin: 0 auto; max-width: 640px; padding: 24px 16px 48px; line-height: 1.4; }
          header { display: flex; align-items: baseline; justify-content: space-between; }
          h1 { font-size: 30px; margin: 0; }
          h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .05em; opacity: .55; margin: 28px 4px 8px; }
          a { color: #0a84ff; }
          .link { font-size: 15px; text-decoration: none; }
          .notice { background: rgba(255,159,10,.15); border-radius: 12px; padding: 10px 14px; font-size: 14px; }
          .fingerprint { font-size: 11px; opacity: .5; word-break: break-all; }
          ol li { margin: 10px 0; }
          .button { background: #0a84ff; color: white; text-decoration: none; font-weight: 600; font-size: 14px;
                    padding: 7px 16px; border-radius: 999px; flex: none; display: inline-block; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
        var response = HTTPResponse.text(200, html, type: "text/html; charset=utf-8")
        response.headers.append(("Cache-Control", "no-store"))
        return response
    }

    // MARK: - Helpers

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "apk": "application/vnd.android.package-archive"
        case "plist": "application/xml"
        case "png": "image/png"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    static func urlPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()
}
