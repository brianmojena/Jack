import XCTest
@testable import Jack
import JackCore

final class CustomizationTerminalTests: XCTestCase {
    @MainActor func testTerminalColorsUpdateAfterSaveWithoutRestartingShell() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-custom-terminal-theme-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let oldLightMode = defaults.object(forKey: "lightModeEnabled")
        defaults.set(false, forKey: "lightModeEnabled")
        let appearance = CustomizationAppearance.shared
        appearance.disable()
        let center = CustomizationCenter(directory: root.appendingPathComponent("Customization"), enabled: true)
        let pack = CustomizationPack(id: "terminal-theme", name: "Terminal", theme: .init(accent: "#204060", text: "#102030"))
        try center.save(pack)
        try center.setPackEnabled(pack.id, true)
        appearance.connect(to: center)

        let workspace = WorkspaceSessions()
        defer {
            workspace.terminateAll()
            appearance.disable()
            if let oldLightMode { defaults.set(oldLightMode, forKey: "lightModeEnabled") }
            else { defaults.removeObject(forKey: "lightModeEnabled") }
        }
        let conversationID = UUID()
        let tab = workspace.open(.terminal, for: conversationID)
        let session = workspace.terminal(tab.id, conversation: conversationID, directory: root.path)
        let pid = session.view.process.shellPid
        XCTAssertGreaterThan(pid, 0)
        let initialCaret = session.view.caretColor

        try center.save(CustomizationPack(id: pack.id, name: pack.name,
                                          theme: .init(accent: "#A04020", text: "#304050")))
        let updatedCaret = try XCTUnwrap(CustomizationAppearance.color("#A04020"))
        for _ in 0..<100 where session.view.caretColor != updatedCaret {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotEqual(initialCaret, updatedCaret)
        XCTAssertEqual(session.view.caretColor, updatedCaret)
        XCTAssertEqual(session.view.process.shellPid, pid)
    }

    @MainActor func testWorkspaceRunsLiteralCommandInNewTerminalAndKeepsExistingSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-custom-terminal-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("command-ran.txt")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let workspace = WorkspaceSessions()
        defer { workspace.terminateAll() }
        let conversationID = UUID()
        let oldTab = workspace.open(.terminal, for: conversationID)
        let oldSession = workspace.terminal(oldTab.id, conversation: conversationID, directory: project.path)
        let shellQuotedPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let request = CustomTerminalCommandRequest(
            conversationID: conversationID, title: "Escribir marcador",
            content: "printf 'hecho' > \(shellQuotedPath)", projectPath: project.path)

        let commandTab = try workspace.runCustomCommand(request)
        let commandSession = try XCTUnwrap(workspace.existingTerminal(commandTab.id))
        XCTAssertNotEqual(commandTab.id, oldTab.id)
        XCTAssertEqual(commandTab.kind, .terminal)
        XCTAssertEqual(commandTab.title, "Escribir marcador")
        XCTAssertEqual(commandSession.projectPath, project.path)
        XCTAssertEqual(workspace.selectedTab(for: conversationID)?.id, commandTab.id)
        XCTAssertTrue(workspace.existingTerminal(oldTab.id) === oldSession)
        XCTAssertFalse(commandSession === oldSession)

        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "hecho")
    }

    @MainActor func testImportingAndEnablingTerminalCommandDoesNotExecuteIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-custom-import-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-run.txt")
        let store = ChatStore(archive: ChatArchive(directory: root.appendingPathComponent("chats")), preferences: nil)
        let workspace = WorkspaceSessions()
        defer { store.shutdown(); workspace.terminateAll() }
        store.applyCustomization()
        let markerPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try store.customization.importPack(data: JSONEncoder().encode(CustomizationPack(
            id: "terminal", name: "Terminal", commands: [
                .init(name: "marker", title: "Crear marcador", kind: .terminal, content: "touch \(markerPath)")
            ])))
        try store.customization.setPackEnabled("terminal", true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(workspace.tabs.isEmpty)
    }

    @MainActor func testTerminalInterfaceCommandCreatesMetadataOnlyShellEntryAndDoesNotResumeCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-custom-native-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("native-command-ran.txt")
        let archive = TerminalWorkspaceArchive(url: root.appendingPathComponent("terminals.json"))
        let store = ChatStore(archive: ChatArchive(directory: root.appendingPathComponent("chats")), preferences: nil)
        let workspace = NativeTerminalWorkspace(archive: archive)
        defer { workspace.stopAll(); store.shutdown() }
        workspace.attach(store)
        let markerPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = CustomizationCommand(name: "marker", title: "Crear marcador", kind: .terminal,
                                          content: "printf 'hecho' > \(markerPath)")

        workspace.runCustomCommand(command, directory: project.path, allowed: true)
        let entry = try XCTUnwrap(workspace.selected)
        XCTAssertEqual(entry.kind, .shell)
        XCTAssertEqual(entry.title, "Crear marcador")
        XCTAssertEqual(entry.projectPath, project.path)
        let session = try XCTUnwrap(workspace.sessions[entry.id])
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "hecho")
        workspace.stopAll()
        try FileManager.default.removeItem(at: marker)

        let reopened = NativeTerminalWorkspace(archive: archive)
        defer { reopened.stopAll() }
        XCTAssertEqual(reopened.selected, entry)
        XCTAssertTrue(reopened.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = session
    }
}
