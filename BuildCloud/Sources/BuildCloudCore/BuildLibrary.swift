import Foundation

public enum BuildLibraryError: LocalizedError {
    case unsupportedFile(String)
    case missingInfoPlist
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext): "Formato no soportado: .\(ext). Usa .ipa, .apk o .aab."
        case .missingInfoPlist: "El .ipa no contiene Payload/*.app/Info.plist."
        case .toolFailed(let message): message
        }
    }
}

/// The folder that holds every published build.
public struct BuildLibrary: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BuildCloud", isDirectory: true)
    }

    public init(root: URL = BuildLibrary.defaultRoot) {
        self.root = root.standardizedFileURL
    }

    /// Which devices installed which apps (written by `TransferTracker`); hidden from the web by its dot folder.
    public var installedDevicesFile: URL { root.appendingPathComponent(".state/installed.json") }

    /// Requests and downloads served by the app, to debug installs.
    public var serverLogFile: URL { root.appendingPathComponent(".logs/server.log") }

    public func prepare() throws {
        for channel in BuildChannel.allCases {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(channel.rawValue),
                                                    withIntermediateDirectories: true)
        }
    }

    /// Builds of a channel, newest first.
    public func builds(in channel: BuildChannel) -> [BuildRecord] {
        let fm = FileManager.default
        let channelDir = root.appendingPathComponent(channel.rawValue)
        var records: [BuildRecord] = []
        for app in (try? fm.contentsOfDirectory(atPath: channelDir.path)) ?? [] where !app.hasPrefix(".") {
            let appDir = channelDir.appendingPathComponent(app)
            for build in (try? fm.contentsOfDirectory(atPath: appDir.path)) ?? [] where !build.hasPrefix(".") {
                let relative = "\(channel.rawValue)/\(app)/\(build)"
                if let record = loadRecord(at: relative) { records.append(record) }
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    public func loadRecord(at relativePath: String) -> BuildRecord? {
        guard let dir = resolve(relativePath),
              let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              var record = try? Self.decoder.decode(BuildRecord.self, from: data) else { return nil }
        record.path = relativePath
        return record
    }

    /// URL inside the library for a relative path, or nil if it would escape the root.
    public func resolve(_ relativePath: String) -> URL? {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    public func fileURL(of record: BuildRecord) -> URL? {
        resolve(record.path)?.appendingPathComponent(record.file)
    }

    /// Copies a build file into the library and writes its `meta.json`.
    @discardableResult
    public func publish(_ file: URL, channel: BuildChannel, overrides: BuildMetadata = BuildMetadata(),
                        now: Date = Date()) throws -> BuildRecord {
        // meta.json stores whole seconds; keep the returned record equal to what is read back.
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let ext = file.pathExtension.lowercased()
        let platform: BuildPlatform
        let read: BuildMetadata
        switch ext {
        case "ipa":
            platform = .ios
            read = try Self.iosMetadata(of: file)
        case "apk", "aab":
            platform = .android
            read = ext == "apk" ? Self.androidMetadata(of: file) : BuildMetadata()
        default:
            throw BuildLibraryError.unsupportedFile(ext)
        }

        let meta = overrides.merged(over: read)
        let name = meta.name ?? file.deletingPathExtension().lastPathComponent
        let bundleId = Self.safeComponent(meta.bundleId ?? name)
        let version = meta.version ?? "0"
        let build = meta.build ?? "0"
        let folder = "\(Self.safeComponent(version))-\(Self.safeComponent(build))-\(Self.stamp.string(from: now))"
        let relative = "\(channel.rawValue)/\(bundleId)/\(folder)"
        guard let dest = resolve(relative) else { throw BuildLibraryError.toolFailed("Ruta no válida: \(relative)") }

        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let fileName = "\(Self.safeComponent(name)).\(ext)"
        try fm.copyItem(at: file, to: dest.appendingPathComponent(fileName))
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.int64Value ?? 0

        let record = BuildRecord(name: name, bundleId: meta.bundleId ?? bundleId, version: version, build: build,
                                 platform: platform, channel: channel, file: fileName, size: size, createdAt: now,
                                 path: relative)
        try Self.encoder.encode(record).write(to: dest.appendingPathComponent("meta.json"), options: .atomic)
        _ = icon(of: record)
        return record
    }

    /// Deletes a build, and its app folder when it was the last build in it.
    public func remove(_ record: BuildRecord) throws {
        guard let dir = resolve(record.path), dir != root else { return }
        let fm = FileManager.default
        try fm.removeItem(at: dir)
        let appDir = dir.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: appDir.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
            try? fm.removeItem(at: appDir)
        }
    }

    // MARK: - Icon

    /// The app icon of a build as a normal PNG, taken from the build file the first time it is asked for and
    /// cached next to it as `icon.png`. Nil when the build has no icon we can read (a marker file remembers it).
    public func icon(of record: BuildRecord) -> URL? {
        guard let dir = resolve(record.path), let file = fileURL(of: record) else { return nil }
        let fm = FileManager.default
        let icon = dir.appendingPathComponent("icon.png")
        let missing = dir.appendingPathComponent(".icon-missing")
        if fm.fileExists(atPath: icon.path) { return icon }
        if fm.fileExists(atPath: missing.path) { return nil }
        do {
            try Self.extractIcon(from: file, platform: record.platform, to: icon)
            return icon
        } catch {
            fm.createFile(atPath: missing.path, contents: nil)
            return nil
        }
    }

    static func extractIcon(from file: URL, platform: BuildPlatform, to destination: URL) throws {
        let listing = try run("/usr/bin/unzip", ["-Z1", file.path])
        let entries = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        let entry: String?
        switch platform {
        case .ios:
            var names: [String] = []
            if let plistPath = entries.first(where: isAppInfoPlist),
               let data = try? run("/usr/bin/unzip", ["-p", file.path, plistPath]),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                names = iconFileNames(in: plist)
            }
            entry = bestIOSIcon(in: entries, names: names)
        case .android:
            entry = bestAndroidIcon(in: entries)
        }
        guard let entry else { throw BuildLibraryError.toolFailed("La build no trae icono") }

        // The .ipa keeps its PNGs in Apple's optimized (CgBI) format, which browsers can't show;
        // `sips` reads it and writes a standard PNG (and converts Android's WebP).
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("buildcloud-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: raw) }
        try run("/usr/bin/unzip", ["-p", file.path, entry]).write(to: raw)
        _ = try run("/usr/bin/sips", ["-s", "format", "png", raw.path, "--out", destination.path])
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw BuildLibraryError.toolFailed("sips no pudo convertir el icono")
        }
    }

    /// Base names in CFBundleIcons (iPhone and iPad), e.g. "AppIcon60x60".
    static func iconFileNames(in plist: [String: Any]) -> [String] {
        ["CFBundleIcons", "CFBundleIcons~ipad"].flatMap { key -> [String] in
            let primary = (plist[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            return primary?["CFBundleIconFiles"] as? [String] ?? []
        }
    }

    /// The biggest icon PNG at the top of the .app, e.g. "Payload/X.app/AppIcon76x76@2x~ipad.png" (152 px).
    static func bestIOSIcon(in entries: [String], names: [String]) -> String? {
        let candidates = entries.filter { entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"),
                  parts[2].lowercased().hasSuffix(".png") else { return false }
            let file = String(parts[2])
            return names.isEmpty ? file.hasPrefix("AppIcon") : names.contains { file.hasPrefix($0) }
        }
        return candidates.max { iconPixels($0) < iconPixels($1) }
    }

    /// "AppIcon60x60@2x.png" → 120; names without a size count as 0.
    static func iconPixels(_ entry: String) -> Int {
        let file = entry.split(separator: "/").last.map(String.init) ?? entry
        guard let size = file.range(of: #"(\d+(\.\d+)?)x\d+"#, options: .regularExpression) else { return 0 }
        let points = Double(file[size].split(separator: "x").first ?? "") ?? 0
        let scale = file.range(of: #"@(\d)x"#, options: .regularExpression)
            .flatMap { Double(file[$0].dropFirst().dropLast()) } ?? 1
        return Int(points * scale)
    }

    /// The launcher icon of the densest mipmap folder (adaptive XML icons are skipped: they're not images).
    static func bestAndroidIcon(in entries: [String]) -> String? {
        let densities = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"]
        func rank(_ entry: String) -> Int? {
            let lower = entry.lowercased()
            guard lower.range(of: #"(^|/)res/mipmap-[^/]+/ic_launcher\.(png|webp)$"#, options: .regularExpression) != nil,
                  let index = densities.firstIndex(where: { lower.contains("mipmap-\($0)") }) else { return nil }
            return index
        }
        return entries.compactMap { entry in rank(entry).map { (entry, $0) } }.min { $0.1 < $1.1 }?.0
    }

    // MARK: - Metadata

    static func iosMetadata(of ipa: URL) throws -> BuildMetadata {
        let listing = try run("/usr/bin/unzip", ["-Z1", ipa.path])
        let entries = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let plistPath = entries.first(where: isAppInfoPlist) else { throw BuildLibraryError.missingInfoPlist }
        let data = try run("/usr/bin/unzip", ["-p", ipa.path, plistPath])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BuildLibraryError.missingInfoPlist
        }
        let string = { (key: String) in (plist[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return BuildMetadata(name: string("CFBundleDisplayName") ?? string("CFBundleName"),
                             bundleId: string("CFBundleIdentifier"),
                             version: string("CFBundleShortVersionString"),
                             build: string("CFBundleVersion"))
    }

    static func isAppInfoPlist(_ entry: String) -> Bool {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
    }

    /// Reads package, version and label with `aapt2` when the Android SDK is installed.
    static func androidMetadata(of apk: URL) -> BuildMetadata {
        guard let aapt2 = findAapt2(), let output = try? run(aapt2.path, ["dump", "badging", apk.path]) else {
            return BuildMetadata()
        }
        return parseBadging(String(decoding: output, as: UTF8.self))
    }

    static func parseBadging(_ text: String) -> BuildMetadata {
        func value(_ key: String, in line: Substring) -> String? {
            guard let start = line.range(of: "\(key)='") else { return nil }
            let rest = line[start.upperBound...]
            return rest.firstIndex(of: "'").map { String(rest[..<$0]) }
        }
        var meta = BuildMetadata()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("package:") {
                meta.bundleId = value("name", in: line)
                meta.version = value("versionName", in: line)
                meta.build = value("versionCode", in: line)
            } else if line.hasPrefix("application-label:"), meta.name == nil {
                let label = line.dropFirst("application-label:".count).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                meta.name = label.isEmpty ? nil : label
            }
        }
        return meta
    }

    static func findAapt2() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path
        let tools = URL(fileURLWithPath: sdk).appendingPathComponent("build-tools")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return versions.reversed().lazy
            .map { tools.appendingPathComponent($0).appendingPathComponent("aapt2") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Helpers

    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildLibraryError.toolFailed("\((tool as NSString).lastPathComponent) terminó con código \(process.terminationStatus)")
        }
        return data
    }

    /// A single path component without separators or leading dots.
    static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.drop { $0 == "." }
        return trimmed.isEmpty ? "app" : String(trimmed)
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
