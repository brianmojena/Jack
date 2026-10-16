import Foundation

public enum BuildChannel: String, Codable, CaseIterable, Sendable {
    case debug, release

    public var title: String { self == .debug ? "Debug" : "Release" }
}

public enum BuildPlatform: String, Codable, Sendable {
    case ios, android

    public var title: String { self == .ios ? "iOS" : "Android" }
}

/// One published build. Stored as `meta.json` next to the build file in
/// `<root>/<channel>/<bundleId>/<version>-<build>-<timestamp>/`.
public struct BuildRecord: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var bundleId: String
    public var version: String
    public var build: String
    public var platform: BuildPlatform
    public var channel: BuildChannel
    public var file: String
    public var size: Int64
    public var createdAt: Date
    /// Folder of the build relative to the library root; refreshed from disk when loaded.
    public var path: String

    public var id: String { path }

    /// iOS Debug builds install over the air; Android APKs install directly; the rest are downloads.
    public var isInstallable: Bool {
        switch platform {
        case .ios: channel == .debug
        case .android: file.lowercased().hasSuffix(".apk")
        }
    }

    public init(name: String, bundleId: String, version: String, build: String, platform: BuildPlatform,
                channel: BuildChannel, file: String, size: Int64, createdAt: Date, path: String = "") {
        self.name = name
        self.bundleId = bundleId
        self.version = version
        self.build = build
        self.platform = platform
        self.channel = channel
        self.file = file
        self.size = size
        self.createdAt = createdAt
        self.path = path
    }
}

/// Values read from a build file; any of them can be overridden when publishing.
public struct BuildMetadata: Sendable, Equatable {
    public var name: String?
    public var bundleId: String?
    public var version: String?
    public var build: String?

    public init(name: String? = nil, bundleId: String? = nil, version: String? = nil, build: String? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.version = version
        self.build = build
    }

    /// Fields of `self` win over the ones in `other`.
    func merged(over other: BuildMetadata) -> BuildMetadata {
        BuildMetadata(name: name ?? other.name, bundleId: bundleId ?? other.bundleId,
                      version: version ?? other.version, build: build ?? other.build)
    }
}
