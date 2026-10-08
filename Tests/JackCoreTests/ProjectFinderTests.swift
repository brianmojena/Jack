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
        XCTAssertEqual(ProjectFinder.resolve("ve a jack y arregla el login", projects: Array(projects.dropLast(2))).match?.path, "/Users/me/Trabajo/Jack")
        XCTAssertEqual(ProjectFinder.resolve("En Financia App revisa los presupuestos", projects: projects).match?.path, "/Users/me/Trabajo/financia-app")
        XCTAssertEqual(ProjectFinder.resolve("abre llego oficina y mira el deploy", projects: projects).match?.path, "/Users/me/Trabajo/LlegoOficina")
        XCTAssertEqual(ProjectFinder.resolve("en el proyecto llegooficina", projects: projects).match?.path, "/Users/me/Trabajo/LlegoOficina")
    }

    func testGenericFolderIsKnownByItsParent() {
        XCTAssertEqual(ProjectFinder.resolve("en atlas frontend cambia el color", projects: projects).match?.path, "/Users/me/Atlas/frontend")
        XCTAssertEqual(ProjectFinder.resolve("arregla el frontend", projects: projects), .none)
    }

    func testSmallTyposStillMatch() {
        XCTAssertEqual(ProjectFinder.resolve("ve al proyecto LlegoOfisina", projects: projects).match?.path, "/Users/me/Trabajo/LlegoOficina")
    }

    func testEqualNamesAskWhichOneRecentFirst() {
        let choices = ProjectFinder.resolve("jack: sube la versión", projects: projects).choices.map(\.path)
        XCTAssertEqual(choices, ["/Users/me/Trabajo/Jack", "/Users/me/Old/Jack"])
    }

    func testCloserNameIsNotAmbiguous() {
        let projects = ["/p/utipapp", "/p/utipapp-1"]
        XCTAssertEqual(ProjectFinder.resolve("en utipapp revisa", projects: projects).match?.path, "/p/utipapp")
        XCTAssertEqual(ProjectFinder.resolve("en utipapp 1 revisa", projects: projects).match?.path, "/p/utipapp-1")
    }

    func testGenericOrMissingNamesDoNotMatch() {
        XCTAssertEqual(ProjectFinder.resolve("haz una web para mi tienda", projects: projects), .none)
        XCTAssertEqual(ProjectFinder.resolve("explícame qué es un monad", projects: projects), .none)
        XCTAssertEqual(ProjectFinder.resolve("", projects: projects), .none)
    }

    func testWrittenPathIsUsed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(ProjectFinder.resolve("trabaja en \(folder.path), por favor", projects: projects).match?.path, folder.path)
    }

    func testLocatorPrefersOpenProjectButKeepsOpenNamesakesAmbiguous() {
        let current = "/Users/me/Trabajo/Jack", old = "/Users/me/Old/Jack"
        XCTAssertEqual(ProjectLocator.knownPath(in: "ve a Jack", projects: [old, current], openProjects: [current]), current)
        XCTAssertNil(ProjectLocator.knownPath(in: "ve a Jack", projects: [old, current], openProjects: [current, old]))
        XCTAssertEqual(ProjectLocator.knownPath(in: "en Financia App revisa", projects: projects, openProjects: [current]), "/Users/me/Trabajo/financia-app")
        XCTAssertNil(ProjectLocator.knownPath(in: "arregla el login", projects: projects, openProjects: [current]))
    }

    func testLocatorReusesOpenProjectWhenTheUserWritesASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-alias-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Jack")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ProjectLocator.knownPath(in: "trabaja en \(alias.path)", projects: [], openProjects: [project.path]), project.path)
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

final class PlainFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pruebas Vacia"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Trabajo/Taller"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Proyectos Personales/Transfer"), withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Trabajo/App Real")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: project.appendingPathComponent("package.json").path, contents: Data())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAnEmptyFolderNamedInTheRequestIsFound() {
        XCTAssertEqual(ProjectLocator.plainFolder(in: "entra a la carpeta pruebas vacia y crea un proyecto", roots: [root.path]),
                       root.appendingPathComponent("Pruebas Vacia").path)
        XCTAssertEqual(ProjectLocator.plainFolder(in: "ve a la carpeta Taller", roots: [root.path]),
                       root.appendingPathComponent("Trabajo/Taller").path)
    }

    func testProjectCueAndRelativePathsFindAnEmptyFolder() {
        XCTAssertEqual(ProjectLocator.plainFolder(in: "Entra al proyecto taller", roots: [root.path]), root.appendingPathComponent("Trabajo/Taller").path)
        XCTAssertEqual(ProjectLocator.plainFolder(in: "la ruta es trabajo/taller", roots: [root.path]), root.appendingPathComponent("Trabajo/Taller").path)
        XCTAssertEqual(ProjectLocator.plainFolder(in: "la ruta es Trabajo/Taller.", roots: [root.path]), root.appendingPathComponent("Trabajo/Taller").path)
        XCTAssertEqual(ProjectLocator.plainFolder(in: "la ruta es pruebas/vacia", roots: [root.path]), nil, "a path must match whole folder names")
        XCTAssertNil(ProjectLocator.plainFolder(in: "mejora el proyecto y revisa taller", roots: [root.path]), "the name must follow the cue")
    }

    func testRelativePathStartingMidName() {
        XCTAssertEqual(ProjectLocator.plainFolder(in: "la ruta es proyectos personales/transfer", roots: [root.path]),
                       root.appendingPathComponent("Proyectos Personales/Transfer").path)
    }

    func testNeedsAFolderCueAndNeverEntersProjects() {
        XCTAssertNil(ProjectLocator.plainFolder(in: "revisa taller", roots: [root.path]), "without saying folder, a word is just a word")
        XCTAssertNil(ProjectLocator.plainFolder(in: "ve a la carpeta src", roots: [root.path]))
    }

    func testMissingFolderIsCreatedOnlyWhenAskedUnderHome() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let name = "jack-test-\(UUID().uuidString)"
        let wanted = home.appendingPathComponent(name).path
        defer { try? FileManager.default.removeItem(atPath: wanted) }
        XCTAssertEqual(ProjectLocator.createdFolder(in: "crea una carpeta ~/\(name) y un proyecto nuevo"), wanted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wanted))
        XCTAssertNil(ProjectLocator.createdFolder(in: "crea /usr/jack-nope-\(UUID().uuidString) nuevo"))
    }
}
