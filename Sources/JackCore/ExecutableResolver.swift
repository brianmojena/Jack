import Foundation

public enum ExecutableResolver {
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
            .path
    }

    public static func resolve(_ command: String, override: String? = nil) -> String? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty, fileManager.isExecutableFile(atPath: override) { return override }

        let environment = childEnvironment()
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates: [String]
        if command.contains("/") {
            candidates = [command]
        } else {
            candidates = searchPaths.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(command).path }
        }
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    public static func childEnvironment() -> [String: String] {
        sanitizedChildEnvironment(ProcessInfo.processInfo.environment)
    }

    static func sanitizedChildEnvironment(_ source: [String: String]) -> [String: String] {
        var environment = source
        for key in environment.keys.filter({ $0.hasPrefix("HERDR_") }) {
            environment.removeValue(forKey: key)
        }

        let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = orderedUnique(standardPaths + existing).joined(separator: ":")
        return environment
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
