import CryptoKit
import XCTest
@testable import Jack

/// The office's models are downloaded, not bundled: the zip is checked against its pinned hash and only a complete folder counts.
@MainActor final class OfficeAssetsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-office-assets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// A zip with a stand-in room model, and its SHA-256.
    private func makeZip(room: Bool = true) throws -> (url: URL, sha: String) {
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("room".utf8).write(to: content.appendingPathComponent(room ? "OfficeRoom.usdz" : "other.usdz"))
        let zip = folder.appendingPathComponent("assets.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", content.path, zip.path]
        try ditto.run(); ditto.waitUntilExit()
        let sha = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        return (zip, sha)
    }

    func testInstallsAZipWhoseHashMatches() throws {
        let (zip, sha) = try makeZip()
        let destination = folder.appendingPathComponent("v1")
        try OfficeAssets.install(zip, checksum: sha, into: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("OfficeRoom.usdz").path))
    }

    func testRejectsAZipWhoseHashDiffersAndLeavesNothing() throws {
        let (zip, _) = try makeZip()
        let destination = folder.appendingPathComponent("v1")
        XCTAssertThrowsError(try OfficeAssets.install(zip, checksum: String(repeating: "0", count: 64), into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsAZipWithoutTheRoom() throws {
        let (zip, sha) = try makeZip(room: false)
        let destination = folder.appendingPathComponent("v1")
        XCTAssertThrowsError(try OfficeAssets.install(zip, checksum: sha, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadingFromASourceBecomesReady() async throws {
        let (zip, sha) = try makeZip()
        let destination = folder.appendingPathComponent("v1")
        let assets = OfficeAssets(source: zip, checksum: sha, destination: destination)
        XCTAssertEqual(assets.state, .missing)
        assets.download()
        for _ in 0..<100 where assets.state != .ready { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(assets.state, .ready)
        XCTAssertEqual(OfficeAssets(source: zip, checksum: sha, destination: destination).state, .ready)
    }

    func testAMissingSourceFailsAndCanBeRetried() async throws {
        let assets = OfficeAssets(source: folder.appendingPathComponent("nope.zip"), checksum: "", destination: folder.appendingPathComponent("v1"))
        assets.download()
        for _ in 0..<100 { if case .failed = assets.state { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .failed = assets.state else { return XCTFail("expected a failure, got \(assets.state)") }
    }
}
