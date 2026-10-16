import XCTest
@testable import BuildCloudCore

final class BuildCloudCoreTests: XCTestCase {
    private var root: URL!
    private var library: BuildLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-tests-\(UUID().uuidString)")
        library = BuildLibrary(root: root.appendingPathComponent("data"))
        try library.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a minimal .ipa: a zip with Payload/<name>.app/Info.plist.
    private func makeIPA(name: String = "Demo", bundleId: String = "com.example.demo",
                         version: String = "1.2", build: String = "45") throws -> URL {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        let app = staging.appendingPathComponent("Payload/\(name).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleShortVersionString": version,
                                    "CFBundleVersion": build, "CFBundleDisplayName": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = root.appendingPathComponent("\(name).ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-qr", ipa.path, "Payload"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return ipa
    }

    func testPublishReadsIPAInfoPlist() throws {
        let record = try library.publish(try makeIPA(), channel: .debug)
        XCTAssertEqual(record.name, "Demo")
        XCTAssertEqual(record.bundleId, "com.example.demo")
        XCTAssertEqual(record.version, "1.2")
        XCTAssertEqual(record.build, "45")
        XCTAssertEqual(record.platform, .ios)
        XCTAssertTrue(record.isInstallable)
        XCTAssertTrue(record.path.hasPrefix("debug/com.example.demo/1.2-45-"))

        let listed = library.builds(in: .debug)
        XCTAssertEqual(listed, [record])
        XCTAssertTrue(library.builds(in: .release).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(of: record)!.path))
    }

    func testOverridesWinAndReleaseIPAIsDownloadOnly() throws {
        let record = try library.publish(try makeIPA(), channel: .release,
                                         overrides: BuildMetadata(name: "Otra", version: "2.0"))
        XCTAssertEqual(record.name, "Otra")
        XCTAssertEqual(record.version, "2.0")
        XCTAssertEqual(record.build, "45")
        XCTAssertFalse(record.isInstallable)
    }

    func testRejectsUnknownFiles() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try library.publish(file, channel: .debug))
    }

    func testRemoveDeletesEmptyAppFolder() throws {
        let record = try library.publish(try makeIPA(), channel: .debug)
        try library.remove(record)
        XCTAssertTrue(library.builds(in: .debug).isEmpty)
        let appDir = library.root.appendingPathComponent("debug/com.example.demo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDir.path))
    }

    func testResolveRejectsPathsOutsideRoot() {
        XCTAssertNil(library.resolve("../secret"))
        XCTAssertNil(library.resolve("debug/../../secret"))
        XCTAssertNotNil(library.resolve("debug/app"))
    }

    func testSafeComponent() {
        XCTAssertEqual(BuildLibrary.safeComponent("../evil/app"), "_evil_app")
        XCTAssertEqual(BuildLibrary.safeComponent("Mi App"), "Mi_App")
        XCTAssertEqual(BuildLibrary.safeComponent(""), "app")
    }

    func testParseBadging() {
        let meta = BuildLibrary.parseBadging("""
        package: name='com.example.android' versionCode='12' versionName='3.4.5' platformBuildVersionName='14'
        application-label:'Mi App'
        """)
        XCTAssertEqual(meta, BuildMetadata(name: "Mi App", bundleId: "com.example.android", version: "3.4.5", build: "12"))
    }

    func testManifestUsesForwardedHostAndHTTPS() throws {
        let record = try library.publish(try makeIPA(), channel: .debug)
        let site = BuildCloudSite(library: library)
        let request = HTTPRequest(method: "GET", path: "/manifest/\(record.path).plist",
                                  headers: ["host": "127.0.0.1:8686", "x-forwarded-host": "mac.tail1.ts.net"])
        let response = site.handle(request)
        XCTAssertEqual(response.status, 200)
        guard case .data(let data) = response.body else { return XCTFail("expected data") }
        let plist = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(plist.contains("<string>https://mac.tail1.ts.net/files/\(record.path)/Demo.ipa</string>"), plist)
        XCTAssertTrue(plist.contains("<string>com.example.demo</string>"))
        XCTAssertTrue(plist.contains("<key>bundle-version</key><string>45</string>"), plist)

        let link = site.actionLink(for: record, origin: "https://mac.tail1.ts.net", installBase: "https://mac.tail1.ts.net")
        XCTAssertTrue(link.hasPrefix("itms-services://?action=download-manifest&url=https%3A%2F%2Fmac"))
    }

    func testInstallBaseMovesPlainHTTPToLocalHTTPSPort() {
        let tls = LocalTLS(authority: CertificateAuthority(directory: root.appendingPathComponent("tls")), httpsPort: 8443)
        let site = BuildCloudSite(library: library, tls: tls)
        let plain = HTTPRequest(method: "GET", path: "/", headers: ["host": "mac.local:8686"])
        XCTAssertEqual(site.origin(for: plain), "http://mac.local:8686")
        XCTAssertEqual(site.installBase(for: plain), "https://mac.local:8443")

        let secure = HTTPRequest(method: "GET", path: "/", headers: ["host": "192.168.1.5:8443"], isSecure: true)
        XCTAssertEqual(site.installBase(for: secure), "https://192.168.1.5:8443")

        let tailscale = HTTPRequest(method: "GET", path: "/", headers: ["host": "mac.tail1.ts.net"])
        XCTAssertEqual(site.installBase(for: tailscale), "https://mac.tail1.ts.net")

        // Without local TLS there is nothing better than the visitor's own origin.
        XCTAssertEqual(BuildCloudSite(library: library).installBase(for: plain), "http://mac.local:8686")
    }

    func testSiteHidesMetaAndBlocksTraversal() throws {
        let record = try library.publish(try makeIPA(), channel: .debug)
        let site = BuildCloudSite(library: library)
        XCTAssertEqual(site.handle(HTTPRequest(method: "GET", path: "/files/\(record.path)/meta.json")).status, 404)
        XCTAssertEqual(site.handle(HTTPRequest(method: "GET", path: "/files/../../etc/passwd")).status, 404)
        XCTAssertEqual(site.handle(HTTPRequest(method: "GET", path: "/files/\(record.path)/Demo.ipa")).status, 200)
        XCTAssertEqual(site.handle(HTTPRequest(method: "GET", path: "/")).status, 200)
    }

    func testParseRequestHead() {
        let request = HTTPRequest.parse(Data("GET /files/a%20b/x.ipa?x=1 HTTP/1.1\r\nHost: mac.local:8686\r\nX-Forwarded-Proto: https".utf8))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/files/a b/x.ipa")
        XCTAssertEqual(request?.headers["host"], "mac.local:8686")
        XCTAssertEqual(request?.headers["x-forwarded-proto"], "https")
        XCTAssertNil(HTTPRequest.parse(Data("garbage".utf8)))
    }

    func testServerStreamsFilesOverHTTP() throws {
        let record = try library.publish(try makeIPA(), channel: .debug)
        let site = BuildCloudSite(library: library)
        let server = HTTPServer { site.handle($0) }
        let ready = expectation(description: "server ready")
        let port = LockedPort()
        server.onStateChange = { state in
            if case .running(let value) = state { port.value = value; ready.fulfill() }
        }
        server.start(port: 0)
        wait(for: [ready], timeout: 5)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port.value)/files/\(record.path)/Demo.ipa")!
        let done = expectation(description: "download")
        var downloaded: Data?
        var status = 0
        URLSession.shared.dataTask(with: url) { data, response, _ in
            downloaded = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(downloaded, try Data(contentsOf: library.fileURL(of: record)!))
    }
}

private final class LockedPort: @unchecked Sendable {
    var value: UInt16 = 0
}

final class ProjectBuilderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ relative: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(relative)
        if relative.hasSuffix(".xcodeproj") || relative.hasSuffix(".xcworkspace") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(),
                                           attributes: executable ? [.posixPermissions: 0o755] : nil)
        }
    }

    func testDetectsKMPProjectNeedingPlatform() throws {
        try make("iosApp/iosApp.xcodeproj")
        try make("gradlew", executable: true)
        XCTAssertThrowsError(try ProjectBuilder.detect(root, platform: nil))
        XCTAssertEqual(try ProjectBuilder.detect(root, platform: .ios), .xcode(root.appendingPathComponent("iosApp/iosApp.xcodeproj")))
        XCTAssertEqual(try ProjectBuilder.detect(root, platform: .android), .gradle(root))
    }

    func testWorkspaceWinsOverProject() throws {
        try make("App.xcodeproj")
        try make("App.xcworkspace")
        XCTAssertEqual(try ProjectBuilder.detect(root, platform: nil), .xcode(root.appendingPathComponent("App.xcworkspace")))
    }

    func testMissingProjectThrows() {
        XCTAssertThrowsError(try ProjectBuilder.detect(root, platform: nil))
    }

    func testAndroidModuleFallsBackToKMPName() throws {
        try make("androidApp/build.gradle.kts")
        XCTAssertEqual(ProjectBuilder.androidModule(in: root, preferred: "app"), "androidApp")
        try make("app/build.gradle")
        XCTAssertEqual(ProjectBuilder.androidModule(in: root, preferred: "app"), "app")
    }
}

final class CertificateAuthorityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-ca-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let names = ServerNames(dns: ["test-mac.local", "localhost"], ips: ["127.0.0.1"])

    func testIssuesIdentityAndReusesIt() throws {
        let authority = CertificateAuthority(directory: root)
        _ = try authority.identity(for: names)
        let firstCA = try authority.caCertificateDER()
        let firstServer = try Data(contentsOf: authority.serverCert)
        XCTAssertFalse(authority.needsNewServerCertificate(for: names))

        _ = try authority.identity(for: names)
        XCTAssertEqual(try Data(contentsOf: authority.serverCert), firstServer, "same names → same certificate")

        let moved = ServerNames(dns: names.dns, ips: ["127.0.0.1", "10.0.0.9"])
        XCTAssertTrue(authority.needsNewServerCertificate(for: moved))
        _ = try authority.identity(for: moved)
        XCTAssertNotEqual(try Data(contentsOf: authority.serverCert), firstServer, "new IP → new server certificate")
        XCTAssertEqual(try authority.caCertificateDER(), firstCA, "the CA never changes, iPhones keep trusting it")

        let expiry = try XCTUnwrap(try authority.serverCertificateExpiry())
        XCTAssertLessThan(expiry.timeIntervalSinceNow, 398 * 24 * 3600)
        XCTAssertGreaterThan(expiry.timeIntervalSinceNow, 390 * 24 * 3600)
    }

    func testMobileConfigInstallsTheCA() throws {
        let authority = CertificateAuthority(directory: root)
        _ = try authority.identity(for: names)
        let data = try authority.mobileConfig()
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payload["PayloadContent"] as? Data, try authority.caCertificateDER())
        XCTAssertEqual(try authority.mobileConfig(), data, "identifiers are stable across downloads")
    }

    func testHTTPSServerIsTrustedThroughTheCA() throws {
        let authority = CertificateAuthority(directory: root)
        let identity = try authority.identity(for: names)
        let library = BuildLibrary(root: root.appendingPathComponent("data"))
        try library.prepare()
        let site = BuildCloudSite(library: library, tls: LocalTLS(authority: authority, httpsPort: 0))
        let server = HTTPServer { site.handle($0) }
        let ready = expectation(description: "https ready")
        let port = PortBox()
        server.onStateChange = { state in
            if case .running(let value) = state { port.value = value; ready.fulfill() }
        }
        server.start(port: 0, identity: identity)
        wait(for: [ready], timeout: 5)
        defer { server.stop() }

        let ca = try XCTUnwrap(SecCertificateCreateWithData(nil, try authority.caCertificateDER() as CFData))
        let delegate = AnchorDelegate(anchor: ca)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let done = expectation(description: "request")
        var status = 0
        session.dataTask(with: URL(string: "https://localhost:\(port.value)/certificado")!) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(delegate.trusted, "the server chain must validate against BuildCloud's CA only")
    }
}

private final class PortBox: @unchecked Sendable {
    var value: UInt16 = 0
}

/// Trusts only the given CA, like an iPhone that installed BuildCloud's profile.
private final class AnchorDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchor: SecCertificate
    var trusted = false

    init(anchor: SecCertificate) { self.anchor = anchor }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        trusted = SecTrustEvaluateWithError(trust, nil)
        completionHandler(trusted ? .useCredential : .cancelAuthenticationChallenge, trusted ? URLCredential(trust: trust) : nil)
    }
}

final class TransferTrackerTests: XCTestCase {
    private func transfer(_ state: FileTransfer.State, sent: Int64, host: String = "192.168.1.20") -> FileTransfer {
        FileTransfer(remoteHost: host, path: "/files/debug/com.example.demo/1.0-1-x/Demo.ipa",
                     sent: sent, total: 100, state: state)
    }

    func testTracksProgressPerDevice() {
        let tracker = TransferTracker()
        tracker.record(transfer(.sending, sent: 40))
        XCTAssertEqual(tracker.progress(of: "debug/com.example.demo/1.0-1-x", for: "192.168.1.20")?.sent, 40)
        XCTAssertNil(tracker.progress(of: "debug/com.example.demo/1.0-1-x", for: "192.168.1.99"))
        XCTAssertFalse(tracker.hasInstalled(appOf: "debug/com.example.demo/1.0-1-x", on: "192.168.1.20"))
    }

    func testCompletedDownloadMarksAppInstalledAndPersists() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("installed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        TransferTracker(storage: file).record(transfer(.completed, sent: 100))

        let reloaded = TransferTracker(storage: file)
        XCTAssertTrue(reloaded.hasInstalled(appOf: "debug/com.example.demo/2.0-5-y", on: "192.168.1.20"),
                      "any newer build of the same app replaces it")
        XCTAssertFalse(reloaded.hasInstalled(appOf: "debug/com.other/1.0-1-x", on: "192.168.1.20"))
        XCTAssertFalse(reloaded.hasInstalled(appOf: "debug/com.example.demo/1.0-1-x", on: "192.168.1.21"))
    }

    func testFailedDownloadDoesNotCountAsInstalled() {
        let tracker = TransferTracker()
        tracker.record(transfer(.failed, sent: 30))
        XCTAssertEqual(tracker.progress(of: "debug/com.example.demo/1.0-1-x", for: "192.168.1.20")?.state, "failed")
        XCTAssertFalse(tracker.hasInstalled(appOf: "debug/com.example.demo/1.0-1-x", on: "192.168.1.20"))
    }
}

final class SiteProgressTests: XCTestCase {
    func testAppsSayReemplazarAndReportProgressAfterADownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BuildLibrary(root: root)
        try library.prepare()
        let dir = root.appendingPathComponent("debug/com.example.demo/1.0-1-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: dir.appendingPathComponent("Demo.ipa"))
        let record = BuildRecord(name: "Demo", bundleId: "com.example.demo", version: "1.0", build: "1", platform: .ios,
                                 channel: .debug, file: "Demo.ipa", size: 3_000_000, createdAt: Date(), path: "debug/com.example.demo/1.0-1-x")
        try BuildLibrary.encoder.encode(record).write(to: dir.appendingPathComponent("meta.json"))

        let site = BuildCloudSite(library: library)
        let build = { () -> BuildCloudSite.SiteState.Build? in
            site.state(for: HTTPRequest(method: "GET", path: "/api/apps", headers: ["host": "mac.local:8443"],
                                        isSecure: true, remoteHost: "127.0.0.1")).channels["debug"]?.first?.builds.first
        }
        XCTAssertEqual(build()?.label, "Instalar")
        XCTAssertEqual(build()?.progressPath, "debug/com.example.demo/1.0-1-x")

        let server = HTTPServer { site.handle($0) }
        server.onFileTransfer = { site.transfers.record($0) }
        let ready = expectation(description: "ready")
        let port = PortHolder()
        server.onStateChange = { if case .running(let p) = $0 { port.value = p; ready.fulfill() } }
        server.start(port: 0)
        wait(for: [ready], timeout: 5)
        defer { server.stop() }

        let done = expectation(description: "download")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port.value)/files/\(record.path)/Demo.ipa")!) { _, _, _ in
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)

        let response = site.handle(HTTPRequest(method: "GET", path: "/api/progress/\(record.path)", remoteHost: "127.0.0.1"))
        guard case .data(let json) = response.body else { return XCTFail("expected progress") }
        let progress = try JSONDecoder().decode(TransferTracker.Progress.self, from: json)
        XCTAssertEqual(progress.state, "completed")
        XCTAssertEqual(progress.sent, 3_000_000)
        XCTAssertEqual(build()?.label, "Reemplazar")
    }
}

final class SiteGroupingTests: XCTestCase {
    func testBuildsOfTheSameAppAreGroupedNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BuildLibrary(root: root)
        try library.prepare()
        func add(_ bundleId: String, _ build: String, _ folder: String, _ seconds: TimeInterval, platform: BuildPlatform = .ios) throws {
            let path = "debug/\(bundleId)/\(folder)"
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let record = BuildRecord(name: bundleId, bundleId: bundleId, version: "1.0", build: build, platform: platform,
                                     channel: .debug, file: "App.ipa", size: 10,
                                     createdAt: Date(timeIntervalSince1970: seconds), path: path)
            try BuildLibrary.encoder.encode(record).write(to: dir.appendingPathComponent("meta.json"))
        }
        try add("com.a", "1", "1.0-1-x", 100)
        try add("com.b", "1", "1.0-1-y", 200)
        try add("com.a", "2", "1.0-2-z", 300)

        let apps = BuildCloudSite(library: library).state(for: HTTPRequest(method: "GET", path: "/api/apps")).channels["debug"] ?? []
        XCTAssertEqual(apps.map(\.key), ["ios:com.a", "ios:com.b"])
        XCTAssertEqual(apps.first?.builds.map(\.build), ["2", "1"])
    }
}

final class IconTests: XCTestCase {
    func testPicksTheBiggestIconOfTheApp() {
        let entries = ["Payload/A.app/Info.plist", "Payload/A.app/AppIcon60x60@2x.png", "Payload/A.app/AppIcon76x76@2x~ipad.png",
                       "Payload/A.app/Frameworks/X.framework/AppIcon99x99@3x.png", "Payload/A.app/logo.png"]
        XCTAssertEqual(BuildLibrary.bestIOSIcon(in: entries, names: ["AppIcon60x60", "AppIcon76x76"]),
                       "Payload/A.app/AppIcon76x76@2x~ipad.png")
        XCTAssertEqual(BuildLibrary.iconPixels("AppIcon83.5x83.5@2x~ipad.png"), 167)
    }

    func testPicksTheDensestAndroidLauncherIcon() {
        let entries = ["res/mipmap-hdpi-v4/ic_launcher.png", "res/mipmap-xxxhdpi-v4/ic_launcher.webp",
                       "res/mipmap-anydpi-v26/ic_launcher.xml", "res/mipmap-xxxhdpi-v4/ic_launcher_round.webp"]
        XCTAssertEqual(BuildLibrary.bestAndroidIcon(in: entries), "res/mipmap-xxxhdpi-v4/ic_launcher.webp")
    }
}

private final class PortHolder: @unchecked Sendable {
    var value: UInt16 = 0
}

final class ByteRangeTests: XCTestCase {
    func testParsesRanges() {
        XCTAssertEqual(HTTPResponse.byteRange("bytes=28442624-", size: 28521747), .partial(28442624...28521746))
        XCTAssertEqual(HTTPResponse.byteRange("bytes=0-99", size: 1000), .partial(0...99))
        XCTAssertEqual(HTTPResponse.byteRange("bytes=900-5000", size: 1000), .partial(900...999))
        XCTAssertEqual(HTTPResponse.byteRange("bytes=-100", size: 1000), .partial(900...999))
        XCTAssertEqual(HTTPResponse.byteRange("bytes=-5000", size: 1000), .partial(0...999))
        XCTAssertEqual(HTTPResponse.byteRange("bytes=1000-", size: 1000), .unsatisfiable)
        XCTAssertEqual(HTTPResponse.byteRange("bytes=0-1,5-9", size: 1000), .full)
        XCTAssertEqual(HTTPResponse.byteRange("bytes=9-5", size: 1000), .full)
        XCTAssertEqual(HTTPResponse.byteRange("items=0-1", size: 1000), .full)
    }

    func testFileResponseAnswersRangeWith206() {
        let url = URL(fileURLWithPath: "/tmp/app.ipa")
        let full = HTTPResponse(status: 200, body: .file(url, size: 1000))

        let partial = full.applyingRange("bytes=990-")
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.contentLength, 10)
        XCTAssertTrue(partial.headers.contains { $0 == ("Content-Range", "bytes 990-999/1000") })

        let whole = full.applyingRange(nil)
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.contentLength, 1000)
        XCTAssertTrue(whole.headers.contains { $0 == ("Accept-Ranges", "bytes") })

        XCTAssertEqual(full.applyingRange("bytes=5000-").status, 416)
        XCTAssertEqual(HTTPResponse.notFound.applyingRange("bytes=0-1").status, 404)
    }
}
