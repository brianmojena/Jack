import Foundation

/// An iOS simulator as `simctl` lists it.
public struct SimulatorDevice: Identifiable, Equatable, Sendable {
    public let udid: String
    public let name: String
    /// "iOS 27.0"
    public let runtime: String
    public let booted: Bool
    public var id: String { udid }

    public init(udid: String, name: String, runtime: String, booted: Bool) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.booted = booted
    }
}

/// Lists, boots and shuts down simulators through `xcrun simctl`.
public enum Simulators {
    /// Available iPhone and iPad simulators, newest runtime first, booted ones at the top.
    public static func parse(_ data: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var devices: [(device: SimulatorDevice, version: [Int])] = []
        for (key, entries) in byRuntime {
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
            let tail = key.split(separator: ".").last.map(String.init) ?? key
            let parts = tail.split(separator: "-").map(String.init)
            guard let platform = parts.first, platform == "iOS" else { continue }
            let version = parts.dropFirst().compactMap { Int($0) }
            let runtime = "\(platform) \(version.map(String.init).joined(separator: "."))"
            for entry in entries where (entry["isAvailable"] as? Bool) != false {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                devices.append((SimulatorDevice(udid: udid, name: name, runtime: runtime, booted: entry["state"] as? String == "Booted"), version))
            }
        }
        return devices.sorted { lhs, rhs in
            if lhs.device.booted != rhs.device.booted { return lhs.device.booted }
            if lhs.version != rhs.version { return lhs.version.lexicographicallyPrecedes(rhs.version) == false }
            return lhs.device.name.localizedStandardCompare(rhs.device.name) == .orderedAscending
        }.map(\.device)
    }

    public static func list() async -> [SimulatorDevice] {
        guard let output = await run(["list", "devices", "available", "-j"]), output.status == 0 else { return [] }
        return parse(output.data)
    }

    /// Boots the device and waits until it has finished starting up.
    public static func boot(_ udid: String) async -> String? {
        if let output = await run(["boot", udid]), output.status != 0 {
            let message = String(decoding: output.error, as: UTF8.self)
            // Booting a booted device is not a failure.
            if !message.contains("current state: Booted") { return message.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        _ = await run(["bootstatus", udid, "-b"])
        return nil
    }

    public static func shutdown(_ udid: String) async { _ = await run(["shutdown", udid]) }

    /// For quitting: returns once the device is off.
    public static func shutdownNow(_ udids: [String]) {
        guard !udids.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "shutdown"] + udids
        try? process.run()
        process.waitUntilExit()
    }

    /// Services of a booted device that testing an app rarely needs: Siri, Apple Intelligence,
    /// Spotlight knowledge, suggestions, photo analysis, News, Mail, Screen Time… Together they use
    /// about 350 MB and some 40 processes. Disabling them lasts across reboots, until enabled again
    /// or the device is erased, and takes effect on the next boot.
    public static let lightModeServices = [
        "com.apple.assistant_cdmd", "com.apple.assistant_service", "com.apple.assistantd",
        "com.apple.siri.acousticsignature", "com.apple.siri.context.service", "com.apple.siriactionsd",
        "com.apple.siriinferenced", "com.apple.siriknowledged", "com.apple.sirittsd",
        "com.apple.intelligencecontextd", "com.apple.intelligenceflowd", "com.apple.intelligenceplatformd",
        "com.apple.intelligencetasksd", "com.apple.generativeexperiencesd", "com.apple.callintelligenced",
        "com.apple.fitnessintelligenced", "com.apple.finhealthd", "com.apple.knowledgeconstructiond",
        "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater", "com.apple.suggestd",
        "com.apple.proactiveeventtrackerd", "com.apple.biomed", "com.apple.biomesyncd",
        "com.apple.photoanalysisd", "com.apple.mediaanalysisd", "com.apple.mediaanalysisd.service",
        "com.apple.newsd", "com.apple.nanonewscd", "com.apple.tipsd", "com.apple.email.maild",
        "com.apple.ScreenTimeAgent", "com.apple.ScreenTimeSettingsAgent", "com.apple.translationd",
        "com.apple.parsecd", "com.apple.parsec-fbf", "com.apple.AutoFillSuggestions", "com.apple.activitysharingd",
    ]

    /// Enables or disables `lightModeServices` on a booted device, a few at a time.
    public static func setLightModeServices(_ udid: String, enabled: Bool) async {
        let verb = enabled ? "enable" : "disable"
        for batch in stride(from: 0, to: lightModeServices.count, by: 8).map({ Array(lightModeServices[$0..<min($0 + 8, lightModeServices.count)]) }) {
            await withTaskGroup(of: Void.self) { group in
                for label in batch { group.addTask { _ = await run(["spawn", udid, "launchctl", verb, "system/\(label)"]) } }
            }
        }
    }

    /// Whether Xcode is building or testing, possibly on a simulator.
    public static func xcodebuildRunning() async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "xcodebuild"]
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    /// Saves a PNG of the device's screen and returns its path.
    public static func screenshot(_ udid: String) async -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JackSimulator", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        let path = folder.appendingPathComponent("Simulador \(formatter.string(from: Date())).png").path
        guard let output = await run(["io", udid, "screenshot", path]), output.status == 0 else { return nil }
        return path
    }

    private struct Output: Sendable { let status: Int32; let data: Data; let error: Data }

    private static func run(_ arguments: [String]) async -> Output? {
        await Task.detached(priority: .userInitiated) { () -> Output? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(status: process.terminationStatus, data: data, error: error)
        }.value
    }
}
