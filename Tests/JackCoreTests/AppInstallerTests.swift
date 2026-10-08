import XCTest
@testable import JackCore

final class AppInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A Jack.app with just enough inside to pass the checks (no code signature).
    @discardableResult
    private func makeApp(in folder: URL, version: String, identifier: String = "dev.jack.desktop", marker: String) throws -> URL {
        let app = folder.appendingPathComponent("Jack.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Jack"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Jack")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        return app
    }

    private func zip(_ paths: [URL], name: String = "update.zip") throws -> URL {
        let archive = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = paths[0].deletingLastPathComponent()
        process.arguments = ["-qry", archive.path] + paths.map(\.lastPathComponent)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func marker(of app: URL) -> String? {
        (try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8))
    }

    func testOnlyAppsInAnApplicationsFolderCanBeReplaced() throws {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = try makeApp(in: applications, version: "0.3.35", marker: "x")
        XCTAssertEqual(AppInstaller.replaceableLocation(of: installed, applicationFolders: [applications])?.lastPathComponent, "Jack.app")

        let elsewhere = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let built = try makeApp(in: elsewhere, version: "0.3.35", marker: "x")
        XCTAssertNil(AppInstaller.replaceableLocation(of: built, applicationFolders: [applications]))
        XCTAssertNil(AppInstaller.replaceableLocation(of: applications.appendingPathComponent("Jack"), applicationFolders: [applications]))
    }

    func testStagesAReleaseThatMatches() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let app = try makeApp(in: source, version: "0.3.36", marker: "new")
        let archive = try zip([app])
        let staged = try AppInstaller.stage(zip: archive, expected: AppVersion("0.3.36")!, bundleIdentifier: "dev.jack.desktop",
                                            in: root.appendingPathComponent("staging"), checkSignature: false)
        XCTAssertEqual(marker(of: staged), "new")
    }

    func testRefusesWrongVersionWrongAppAndExtraFiles() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let app = try makeApp(in: source, version: "0.3.36", marker: "new")
        let archive = try zip([app])
        XCTAssertThrowsError(try AppInstaller.stage(zip: archive, expected: AppVersion("0.3.37")!, bundleIdentifier: "dev.jack.desktop",
                                                    in: root.appendingPathComponent("s1"), checkSignature: false))
        XCTAssertThrowsError(try AppInstaller.stage(zip: archive, expected: AppVersion("0.3.36")!, bundleIdentifier: "com.other.app",
                                                    in: root.appendingPathComponent("s2"), checkSignature: false))
        try Data("x".utf8).write(to: source.appendingPathComponent("extra.txt"))
        let crowded = try zip([app, source.appendingPathComponent("extra.txt")], name: "crowded.zip")
        XCTAssertThrowsError(try AppInstaller.stage(zip: crowded, expected: AppVersion("0.3.36")!, bundleIdentifier: "dev.jack.desktop",
                                                    in: root.appendingPathComponent("s3"), checkSignature: false))
    }

    func testRealSignatureCheckRejectsAnUnsignedApp() throws {
        let app = try makeApp(in: root.appendingPathComponent("source"), version: "0.3.36", marker: "new")
        XCTAssertThrowsError(try AppInstaller.verify(app: app, expected: AppVersion("0.3.36")!, bundleIdentifier: "dev.jack.desktop", checkSignature: true))
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    func testHelperWaitsForJackToQuitThenSwapsAndKeepsThePreviousVersion() throws {
        let installedFolder = root.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeApp(in: installedFolder, version: "0.3.35", marker: "old")
        let staged = try makeApp(in: root.appendingPathComponent("staging/0.3.36"), version: "0.3.36", marker: "new")
        let previous = root.appendingPathComponent("previous")
        let log = root.appendingPathComponent("update.log")

        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["1.5"]
        try running.run()
        let started = Date()
        try AppInstaller.startReplacement(staged: staged, destination: installed, pid: running.processIdentifier, relaunch: false,
                                          checkSignature: false, previous: previous, log: log)

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(marker(of: installed), "old", "The app must not be touched while Jack is still running")
        XCTAssertTrue(waitUntil { marker(of: installed) == "new" })
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.2)
        XCTAssertEqual(try? String(contentsOf: previous.appendingPathComponent("Contents/marker"), encoding: .utf8), "old")
        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path) })
        XCTAssertTrue((try? String(contentsOf: log, encoding: .utf8))?.contains("Jack actualizado") == true)
    }

    func testHelperPutsTheOldVersionBackWhenTheSwapFails() throws {
        let installed = try makeApp(in: root.appendingPathComponent("Applications"), version: "0.3.35", marker: "old")
        let broken = root.appendingPathComponent("staging/0.3.36/Jack.app", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("update.log")

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try AppInstaller.startReplacement(staged: broken, destination: installed, pid: finished.processIdentifier, relaunch: false,
                                          checkSignature: false, previous: root.appendingPathComponent("previous"), log: log)

        XCTAssertTrue(waitUntil { (try? String(contentsOf: log, encoding: .utf8))?.contains("se restaura") == true })
        XCTAssertTrue(waitUntil { self.marker(of: installed) == "old" })
    }
}
