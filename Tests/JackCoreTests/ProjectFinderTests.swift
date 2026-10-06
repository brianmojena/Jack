import Foundation
import XCTest
@testable import JackCore

final class ProjectFinderTests: XCTestCase {
    private let projects = [
        "/Users/me/Trabajo/Jack",
        "/Users/me/Trabajo/financia-app",
        "/Users/me/Trabajo/LlegoOficina",
        "/Users/me/Personal/web",
        "/Users/me/Old/Jack",
        "/Users/me/Atlas/frontend",
    ]

    func testNamesTheProjectInTheRequest() {
        XCTAssertEqual(ProjectFinder.resolve("ve a jack y arregla el login", projects: projects)?.path, "/Users/me/Trabajo/Jack")
        XCTAssertEqual(ProjectFinder.resolve("En Financia App revisa los presupuestos", projects: projects)?.path, "/Users/me/Trabajo/financia-app")
        XCTAssertEqual(ProjectFinder.resolve("abre llego oficina y mira el deploy", projects: projects)?.path, "/Users/me/Trabajo/LlegoOficina")
        XCTAssertEqual(ProjectFinder.resolve("en el proyecto llegooficina", projects: projects)?.path, "/Users/me/Trabajo/LlegoOficina")
    }

    func testGenericFolderIsKnownByItsParent() {
        XCTAssertEqual(ProjectFinder.resolve("en atlas frontend cambia el color", projects: projects)?.path, "/Users/me/Atlas/frontend")
        XCTAssertNil(ProjectFinder.resolve("arregla el frontend", projects: projects))
    }

    func testSmallTyposStillMatch() {
        XCTAssertEqual(ProjectFinder.resolve("ve al proyecto LlegoOfisina", projects: projects)?.path, "/Users/me/Trabajo/LlegoOficina")
    }

    func testRecentProjectWinsOnEqualNames() {
        XCTAssertEqual(ProjectFinder.resolve("jack: sube la versión", projects: projects)?.path, "/Users/me/Trabajo/Jack")
    }

    func testGenericOrMissingNamesDoNotMatch() {
        XCTAssertNil(ProjectFinder.resolve("haz una web para mi tienda", projects: projects))
        XCTAssertNil(ProjectFinder.resolve("explícame qué es un monad", projects: projects))
        XCTAssertNil(ProjectFinder.resolve("", projects: projects))
    }

    func testWrittenPathIsUsed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(ProjectFinder.resolve("trabaja en \(folder.path), por favor", projects: projects)?.path, folder.path)
    }

    func testScanStopsAtProjectRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-scan-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Clients/alpha/.git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Clients/alpha/packages/inner"), withIntermediateDirectories: true)
        manager.createFile(atPath: root.appendingPathComponent("Clients/alpha/packages/inner/package.json").path, contents: Data())
        try manager.createDirectory(at: root.appendingPathComponent("beta/node_modules/x"), withIntermediateDirectories: true)
        manager.createFile(atPath: root.appendingPathComponent("beta/Package.swift").path, contents: Data())
        try manager.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let found = Set(ProjectFinder.scan(roots: [root.path]).map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(found, ["alpha", "beta"])
    }
}
