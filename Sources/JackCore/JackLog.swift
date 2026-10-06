import Foundation

/// A small log of what Jack could not do on its own, at `~/Library/Logs/Jack/jack.log`, so a failure that only
/// happens in the app can be read afterwards. It keeps the last 200 KB.
public enum JackLog {
    private static let queue = DispatchQueue(label: "jack.log", qos: .utility)
    private static let limit = 200 * 1024

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jack/jack.log")
    }

    public static func write(_ message: String, to file: URL = url) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > limit,
               let data = try? Data(contentsOf: file) {
                try? data.suffix(limit / 2).write(to: file)
            }
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
