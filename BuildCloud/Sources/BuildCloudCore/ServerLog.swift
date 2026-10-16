import Foundation

/// Appends timestamped lines to a text file, e.g. `~/BuildCloud/.logs/server.log`.
public final class ServerLog: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "buildcloud.log")
    private let formatter = ISO8601DateFormatter()

    public init(url: URL) {
        self.url = url
    }

    public func write(_ line: String) {
        let now = Date()
        queue.async { [self] in
            let data = Data("\(formatter.string(from: now)) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
