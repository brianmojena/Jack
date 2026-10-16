import BuildCloudCore
import Foundation
import Security

let usage = """
uso:
  buildcloud build <carpeta|.xcodeproj|.xcworkspace> <debug|release> [--platform ios|android] [--scheme S] [--team ID] [--module app]
  buildcloud publish <archivo.ipa|.apk|.aab> <debug|release> [--name N] [--version V] [--build B] [--bundle-id ID]
  buildcloud list [debug|release]
  buildcloud serve [--port 8686] [--https-port 8443]

Los datos están en la carpeta de BuildCloud.app (por defecto ~/BuildCloud) o en $BUILDCLOUD_DATA.
"""

/// HTTPS address of BuildCloud.app on the local network, from its settings.
func webURL() -> String {
    let port = UserDefaults(suiteName: "dev.jack.buildcloud")?.object(forKey: "httpsPort") as? Int ?? 8443
    return "https://\(ServerNames.preferredLANHost()):\(port)"
}

/// Opens BuildCloud.app in the background when its server isn't answering, so the new build is reachable.
func ensureAppRunning() {
    let port = UserDefaults(suiteName: "dev.jack.buildcloud")?.object(forKey: "port") as? Int ?? 8686
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/builds")!, timeoutInterval: 2)
    request.httpMethod = "HEAD"
    let done = DispatchSemaphore(value: 0)
    var reachable = false
    URLSession.shared.dataTask(with: request) { _, response, _ in
        reachable = (response as? HTTPURLResponse)?.statusCode == 200
        done.signal()
    }.resume()
    done.wait()
    guard !reachable else { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", "dev.jack.buildcloud"]
    try? open.run()
    open.waitUntilExit()
    print(open.terminationStatus == 0 ? "BuildCloud.app no estaba abierta; la he abierto." : "Aviso: abre BuildCloud.app para servir la web.")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Splits `--key value` pairs from positional arguments.
func parse(_ arguments: ArraySlice<String>) -> (positional: [String], options: [String: String]) {
    var positional: [String] = []
    var options: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        if argument.hasPrefix("--") {
            guard let value = iterator.next() else { fail("Falta el valor de \(argument)\n\n\(usage)") }
            options[String(argument.dropFirst(2))] = value
        } else {
            positional.append(argument)
        }
    }
    return (positional, options)
}

// Same folder as BuildCloud.app unless $BUILDCLOUD_DATA says otherwise.
let dataPath = ProcessInfo.processInfo.environment["BUILDCLOUD_DATA"]
    ?? UserDefaults(suiteName: "dev.jack.buildcloud")?.string(forKey: "dataPath")
let library = BuildLibrary(root: dataPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? BuildLibrary.defaultRoot)
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail(usage) }
let (positional, options) = parse(arguments.dropFirst(2))

switch arguments[1] {
case "build":
    setvbuf(stdout, nil, _IOLBF, 0)
    guard positional.count == 2, let channel = BuildChannel(rawValue: positional[1]) else { fail(usage) }
    let platform = options["platform"].map { BuildTarget(rawValue: $0) ?? { fail("--platform debe ser ios o android") }() }
    let project = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: project.path) else { fail("No existe: \(project.path)") }
    do {
        try library.prepare()
        let request = BuildRequest(project: project, channel: channel, platform: platform, scheme: options["scheme"],
                                   team: options["team"], module: options["module"] ?? "app")
        let started = Date()
        let record = try ProjectBuilder(library: library).build(request)
        print("✓ \(record.name) \(record.version) (\(record.build)) · \(record.platform.title) → \(channel.title) en \(Int(Date().timeIntervalSince(started)))s")
        ensureAppRunning()
        print("Web: \(webURL())")
    } catch {
        fail("✗ \(error.localizedDescription)")
    }

case "publish":
    guard positional.count == 2, let channel = BuildChannel(rawValue: positional[1]) else { fail(usage) }
    let file = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: file.path) else { fail("No existe: \(file.path)") }
    do {
        try library.prepare()
        let overrides = BuildMetadata(name: options["name"], bundleId: options["bundle-id"],
                                      version: options["version"], build: options["build"])
        let record = try library.publish(file, channel: channel, overrides: overrides)
        print("Publicado: \(record.name) \(record.version) (\(record.build)) → \(channel.title)")
        print(library.root.appendingPathComponent(record.path).path)
        ensureAppRunning()
        print("Web: \(webURL())")
    } catch {
        fail(error.localizedDescription)
    }

case "list":
    let channels = positional.first.map { [BuildChannel(rawValue: $0) ?? { fail(usage) }()] } ?? BuildChannel.allCases
    for channel in channels {
        print("\(channel.title):")
        let builds = library.builds(in: channel)
        if builds.isEmpty { print("  (vacío)") }
        for record in builds {
            print("  \(record.name) \(record.version) (\(record.build)) · \(record.platform.title) · \(BuildCloudSite.size(record.size)) · \(record.path)")
        }
    }

case "serve":
    setvbuf(stdout, nil, _IOLBF, 0)  // logs show up immediately under launchd or a pipe
    guard let port = UInt16(options["port"] ?? "8686"), let httpsPort = UInt16(options["https-port"] ?? "8443") else {
        fail("Puerto no válido")
    }
    do { try library.prepare() } catch { fail(error.localizedDescription) }
    let authority = CertificateAuthority()
    let identity: SecIdentity
    do { identity = try authority.identity(for: ServerNames.current()) } catch { fail(error.localizedDescription) }
    let site = BuildCloudSite(library: library, tls: LocalTLS(authority: authority, httpsPort: httpsPort),
                              transfers: TransferTracker(storage: library.installedDevicesFile))
    let server = HTTPServer { site.handle($0) }
    let https = HTTPServer { site.handle($0) }
    server.onFileTransfer = { site.transfers.record($0) }
    https.onFileTransfer = { site.transfers.record($0) }
    https.onStateChange = { state in
        switch state {
        case .running(let port): print("HTTPS en https://\(ServerNames.preferredLANHost()):\(port) · certificado en http://\(ServerNames.preferredLANHost()):\(options["port"] ?? "8686")/certificado")
        case .failed(let message): fail("No se pudo iniciar HTTPS: \(message)")
        default: break
        }
    }
    https.start(port: httpsPort, identity: identity)
    server.onStateChange = { state in
        switch state {
        case .running(let port): print("BuildCloud en http://localhost:\(port) · datos en \(library.root.path)")
        case .failed(let message): fail("No se pudo iniciar el servidor: \(message)")
        default: break
        }
    }
    server.start(port: port)
    dispatchMain()

default:
    fail(usage)
}
