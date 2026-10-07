import XCTest
@testable import JackCore

final class RemoteProjectsTests: XCTestCase {
    func testParseListReadsJackIndexAndScan() {
        let output = """
        (
            "/Users/ruben/Jack",
            "/Users/ruben/Finanzas"
        )
        /Users/ruben/Proyectos/MiApp
        /Users/ruben/Proyectos/MiApp/
        relative/path
        /Users/ruben/Proyectos/MiApp
        /
        """
        XCTAssertEqual(RemoteProjects.parseList(output), ["/Users/ruben/Jack", "/Users/ruben/Finanzas", "/Users/ruben/Proyectos/MiApp"])
    }

    func testListCommandRunsUnderShAndFindsMarkers() {
        let command = RemoteProjects.listCommand()
        XCTAssertTrue(command.hasPrefix("sh -c "))
        XCTAssertTrue(command.contains("defaults read dev.jack.desktop knownProjects"))
        XCTAssertTrue(command.contains("Package.swift"))
        XCTAssertTrue(command.contains("-maxdepth 4"))
        XCTAssertTrue(command.contains("sort -u"))
    }

    func testPathTokensKeepsAbsolutePaths() {
        XCTAssertEqual(RemoteProjects.pathTokens(in: "arregla /Users/ruben/MiApp, por favor."),
                       ["/Users/ruben/MiApp"])
        XCTAssertEqual(RemoteProjects.pathTokens(in: "mira ~/Proyectos/X y /tmp/y/"), ["/tmp/y"])
        XCTAssertTrue(RemoteProjects.pathTokens(in: "sin rutas aquí").isEmpty)
    }

    func testKnownPathPrefersExplicitThenOpenThenDiscovered() {
        let projects = ["/Users/ruben/Finanzas", "/Users/ruben/MiApp"]
        // An explicit remote path wins, canonicalized against known lists.
        XCTAssertEqual(RemoteProjects.knownPath(in: "trabaja en /Users/ruben/MiApp", projects: projects, openProjects: [], existing: ["/Users/ruben/MiApp"]),
                       "/Users/ruben/MiApp")
        // Name matching prefers open projects, like locally.
        XCTAssertEqual(RemoteProjects.knownPath(in: "arregla el login de miapp", projects: projects, openProjects: ["/Users/ruben/MiApp"]),
                       "/Users/ruben/MiApp")
        XCTAssertEqual(RemoteProjects.knownPath(in: "arregla finanzas", projects: projects, openProjects: []),
                       "/Users/ruben/Finanzas")
        XCTAssertNil(RemoteProjects.knownPath(in: "hola, ¿qué tal?", projects: projects, openProjects: []))
    }

    @MainActor func testUnresolvedEndpointNeverLaunches() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude)
        conversation.remote = ChatRemoteEndpoint(destination: "ruben@192.168.1.193")
        XCTAssertFalse(conversation.remote!.isResolved)
        XCTAssertNil(ChatRunConfiguration.claudeRemoteLaunch(conversation: conversation, delegation: nil, remotePort: 18791))
    }

    @MainActor func testCreateKeepsUnresolvedRemoteForDiscovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-remote-auto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent("chats")), preferences: nil)
        defer { store.shutdown() }
        let remote = ChatRemoteEndpoint(destination: "ruben@192.168.1.193")
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .claude, remote: remote))
        XCTAssertEqual(store.conversations.first { $0.id == id }?.remote, remote)
    }
}
