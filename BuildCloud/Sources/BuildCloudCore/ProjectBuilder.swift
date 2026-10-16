import Foundation

public enum BuildTarget: String, Sendable {
    case ios, android
}

public struct BuildRequest: Sendable {
    public var project: URL
    public var channel: BuildChannel
    public var platform: BuildTarget?
    public var scheme: String?
    public var team: String?
    /// Gradle module; when it doesn't exist the builder falls back to `app`, `androidApp` or `composeApp`.
    public var module: String

    public init(project: URL, channel: BuildChannel, platform: BuildTarget? = nil, scheme: String? = nil,
                team: String? = nil, module: String = "app") {
        self.project = project
        self.channel = channel
        self.platform = platform
        self.scheme = scheme
        self.team = team
        self.module = module
    }
}

public enum ProjectBuilderError: LocalizedError {
    case projectNotFound(String)
    case ambiguousPlatform(String)
    case noScheme
    case commandFailed(step: String, errors: [String], log: URL)
    case artifactMissing(String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let path):
            return "No encuentro un .xcworkspace, .xcodeproj ni gradlew en \(path)."
        case .ambiguousPlatform(let path):
            return "\(path) tiene proyecto iOS y Android. Indica --platform ios o --platform android."
        case .noScheme:
            return "El proyecto no tiene ningún scheme compartido."
        case .commandFailed(let step, let errors, let log):
            let detail = errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n")
            return "Falló \(step).\(detail)\nLog completo: \(log.path)"
        case .artifactMissing(let what):
            return "La compilación terminó pero no generó \(what)."
        }
    }
}

/// Compiles an Xcode or Gradle project and publishes the result to a `BuildLibrary`.
/// Tool output goes to a log file under `<library>/.logs`; only progress lines reach `progress`.
public struct ProjectBuilder: Sendable {
    public let library: BuildLibrary
    public let progress: @Sendable (String) -> Void

    public init(library: BuildLibrary, progress: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.library = library
        self.progress = progress
    }

    enum Project: Equatable {
        case xcode(URL)
        case gradle(URL)
    }

    @discardableResult
    public func build(_ request: BuildRequest) throws -> BuildRecord {
        let project = try Self.detect(request.project.standardizedFileURL, platform: request.platform)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let log = try makeLog(for: request.project)
        progress("Log: \(log.path)")

        let artifact: URL
        switch project {
        case .xcode(let url): artifact = try buildXcode(url, request: request, work: work, log: log)
        case .gradle(let dir): artifact = try buildGradle(dir, request: request, log: log)
        }
        progress("▸ Publicando \(artifact.lastPathComponent) en \(request.channel.title)…")
        return try library.publish(artifact, channel: request.channel)
    }

    // MARK: - Detection

    /// Finds the project to build: the path itself, or a workspace/project/gradlew inside it
    /// (also in the usual `ios`, `iosApp` and `android` subfolders).
    static func detect(_ url: URL, platform: BuildTarget?) throws -> Project {
        let ext = url.pathExtension
        if ext == "xcworkspace" || ext == "xcodeproj" { return .xcode(url) }

        let xcode = findXcode(in: url) ?? ["ios", "iosApp", "iOS"].lazy
            .compactMap { findXcode(in: url.appendingPathComponent($0)) }.first
        let gradle = [url, url.appendingPathComponent("android")]
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("gradlew").path) }

        switch (platform, xcode, gradle) {
        case (.ios, let xcode?, _), (nil, let xcode?, nil): return .xcode(xcode)
        case (.android, _, let gradle?), (nil, nil, let gradle?): return .gradle(gradle)
        case (nil, _?, _?): throw ProjectBuilderError.ambiguousPlatform(url.path)
        default: throw ProjectBuilderError.projectNotFound(url.path)
        }
    }

    /// A workspace wins over a project (CocoaPods); the workspace inside a .xcodeproj doesn't count.
    static func findXcode(in dir: URL) -> URL? {
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        if let workspace = items.first(where: { $0.hasSuffix(".xcworkspace") }) { return dir.appendingPathComponent(workspace) }
        return items.first { $0.hasSuffix(".xcodeproj") }.map { dir.appendingPathComponent($0) }
    }

    // MARK: - Xcode

    func buildXcode(_ project: URL, request: BuildRequest, work: URL, log: URL) throws -> URL {
        let kind = project.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let scheme = try request.scheme ?? defaultScheme(project, kind: kind, log: log)
        let release = request.channel == .release
        let configuration = release ? "Release" : "Debug"
        let archive = work.appendingPathComponent("\(scheme).xcarchive")

        progress("▸ Archivando \(scheme) (\(configuration)) desde \(project.lastPathComponent)…")
        var archiveArgs = ["archive", kind, project.path, "-scheme", scheme, "-configuration", configuration,
                           "-destination", "generic/platform=iOS", "-archivePath", archive.path,
                           "-allowProvisioningUpdates"]
        if let team = request.team { archiveArgs.append("DEVELOPMENT_TEAM=\(team)") }
        try run("/usr/bin/xcodebuild", archiveArgs, step: "el archive", log: log)

        let method = release ? "app-store-connect" : "debugging"
        var options: [String: Any] = ["method": method, "signingStyle": "automatic", "destination": "export"]
        if let team = request.team { options["teamID"] = team }
        let optionsURL = work.appendingPathComponent("ExportOptions.plist")
        try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0).write(to: optionsURL)

        progress("▸ Exportando .ipa (\(method))…")
        let export = work.appendingPathComponent("export")
        try run("/usr/bin/xcodebuild", ["-exportArchive", "-archivePath", archive.path, "-exportPath", export.path,
                                        "-exportOptionsPlist", optionsURL.path, "-allowProvisioningUpdates"],
                step: "el export", log: log)
        let ipa = ((try? FileManager.default.contentsOfDirectory(atPath: export.path)) ?? [])
            .first { $0.hasSuffix(".ipa") }
        guard let ipa else { throw ProjectBuilderError.artifactMissing("ningún .ipa") }
        return export.appendingPathComponent(ipa)
    }

    /// The scheme named like the project, or the first one.
    func defaultScheme(_ project: URL, kind: String, log: URL) throws -> String {
        let output = try run("/usr/bin/xcodebuild", ["-list", "-json", kind, project.path],
                             step: "xcodebuild -list", log: log, capture: true)
        let json = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let info = (json?["workspace"] ?? json?["project"]) as? [String: Any]
        let schemes = info?["schemes"] as? [String] ?? []
        let name = project.deletingPathExtension().lastPathComponent
        guard let scheme = schemes.first(where: { $0 == name }) ?? schemes.first else { throw ProjectBuilderError.noScheme }
        return scheme
    }

    // MARK: - Gradle

    func buildGradle(_ dir: URL, request: BuildRequest, log: URL) throws -> URL {
        let debug = request.channel == .debug
        let module = Self.androidModule(in: dir, preferred: request.module)
        let task = ":\(module):\(debug ? "assembleDebug" : "bundleRelease")"
        progress("▸ Gradle \(task)…")
        try run(dir.appendingPathComponent("gradlew").path, [task], step: "Gradle \(task)", log: log, in: dir)

        let outputs = dir.appendingPathComponent(module)
            .appendingPathComponent(debug ? "build/outputs/apk/debug" : "build/outputs/bundle/release")
        let ext = debug ? "apk" : "aab"
        let newest = ((try? FileManager.default.contentsOfDirectory(at: outputs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == ext }
            .max { modified($0) < modified($1) }
        guard let newest else { throw ProjectBuilderError.artifactMissing("ningún .\(ext) en \(outputs.path)") }
        return newest
    }

    /// The requested module if it exists, else the usual names (`app`, KMP's `androidApp` and `composeApp`).
    static func androidModule(in dir: URL, preferred: String) -> String {
        let exists = { (name: String) in
            ["build.gradle", "build.gradle.kts"].contains {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent($0).path)
            }
        }
        return ([preferred, "app", "androidApp", "composeApp"]).first(where: exists) ?? preferred
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Processes

    func makeLog(for project: URL) throws -> URL {
        let logs = library.root.appendingPathComponent(".logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let name = BuildLibrary.safeComponent(project.deletingPathExtension().lastPathComponent)
        let url = logs.appendingPathComponent("\(BuildLibrary.stamp.string(from: Date()))-\(name).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// Runs a tool appending its output to `log`. Throws with the error lines when it fails.
    @discardableResult
    func run(_ tool: String, _ arguments: [String], step: String, log: URL, in directory: URL? = nil,
             capture: Bool = false) throws -> Data {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n$ \(([tool] + arguments).joined(separator: " "))\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let captured = Pipe()
        process.standardOutput = capture ? captured : handle
        process.standardError = handle
        try process.run()
        let data = capture ? captured.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProjectBuilderError.commandFailed(step: step, errors: Self.errorLines(in: log), log: log)
        }
        return data
    }

    /// The distinct `error:` lines of a log (at most 15), for a short failure message.
    static func errorLines(in log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ($0.contains("error:") || $0.hasPrefix("e: ") || $0.contains("FAILURE:")) && seen.insert($0).inserted }
            .suffix(15)
    }
}
