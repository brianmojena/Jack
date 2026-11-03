import XCTest
import Darwin
@testable import JackCore

@MainActor final class CustomizationTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func pack(_ id: String, color: String? = nil, command: String = "") -> CustomizationPack {
        .init(id: id, name: id, theme: color.map { .init(accent: $0) }, layout: .init(sidebarWidth: 250), commands: command.isEmpty ? [] : [.init(name: "helper", title: id, kind: .prompt, content: command)])
    }

    func testRoundTripAndPromptExpansion() throws {
        let center = CustomizationCenter(directory: temporaryDirectory(), enabled: true)
        let original = CustomizationPack(id: "pack_1", name: "Personal", author: "Ada", theme: .init(appearance: .dark, accent: "#12aBcD"), layout: .init(interface: .office2D, sidebarPosition: .right, sidebarWidth: 260, explorerVisible: false), commands: [.init(name: "review_local", title: "Review", kind: .prompt, content: "Do this {{args}}")])
        try center.save(original)
        let data = try center.exportPack(id: original.id)
        XCTAssertEqual(try JSONDecoder().decode(CustomizationPack.self, from: data), original)
        XCTAssertEqual(try CustomizationCenter.decodePack(data), original)
        try center.setPackEnabled(original.id, true)
        XCTAssertEqual(center.commands.first?.expanded(arguments: "carefully"), "Do this carefully")
        XCTAssertEqual(try center.importPack(data: data), original.id)
    }

    func testEnabledPackOrderAndCommandPrecedence() throws {
        let center = CustomizationCenter(directory: temporaryDirectory(), enabled: true)
        try center.save(pack("one", color: "#111111", command: "first {{args}}"))
        try center.save(pack("two", color: "#222222", command: "second {{args}}"))
        try center.setPackEnabled("one", true); try center.setPackEnabled("two", true)
        XCTAssertEqual(center.enabledIDs, ["one", "two"])
        XCTAssertEqual(center.effectiveTheme?.accent, "#222222")
        XCTAssertEqual(center.commands.first?.content, "second {{args}}")
        let terminal = CustomizationCommand(name: "run", title: "Run", kind: .terminal, content: "echo {{args}}")
        XCTAssertEqual(terminal.expanded(arguments: "bad"), "echo {{args}}")
    }

    func testInvalidSchemaHexPathAndCommandsAreRejected() throws {
        let center = CustomizationCenter(directory: temporaryDirectory(), enabled: true)
        XCTAssertThrowsError(try center.save(.init(schemaVersion: 2, id: "schema", name: "Bad")))
        XCTAssertThrowsError(try center.save(pack("hex", color: "red")))
        XCTAssertThrowsError(try center.save(pack("../outside")))
        XCTAssertThrowsError(try center.save(pack("Neon")))
        XCTAssertThrowsError(try center.save(.init(id: "builtin", name: "Bad", commands: [.init(name: "btw", title: "Bad", kind: .terminal, content: "echo x")])))
        XCTAssertThrowsError(try center.save(.init(id: "builtin_caps", name: "Bad", commands: [.init(name: "BTW", title: "Bad", kind: .terminal, content: "echo x")])))
        XCTAssertThrowsError(try center.save(.init(id: "safe", name: "Bad", commands: [.init(name: "BAD/NAME", title: "Bad", kind: .prompt, content: "run")])))
        XCTAssertThrowsError(try center.save(.init(id: "duplicate", name: "Bad", commands: [.init(name: "Helper", title: "One", kind: .prompt, content: "one"), .init(name: "helper", title: "Two", kind: .prompt, content: "two")])))
    }

    func testLastKnownGoodSurvivesInvalidHotReloadAndDeletionRemovesPack() throws {
        let directory = temporaryDirectory(); let center = CustomizationCenter(directory: directory, enabled: true)
        try center.save(pack("live", color: "#123456")); try center.setPackEnabled("live", true)
        let url = directory.appendingPathComponent("Packs/live.json")
        try Data("{\"schemaVersion\":99}".utf8).write(to: url, options: .atomic)
        center.reload()
        XCTAssertEqual(center.packs.first?.name, "live")
        XCTAssertNotNil(center.error)
        try FileManager.default.removeItem(at: url); center.reload()
        XCTAssertTrue(center.packs.isEmpty)
        XCTAssertNil(center.effectiveTheme)
    }

    func testDisabledCenterPerformsNoDirectoryIOUntilEnabled() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let center = CustomizationCenter(directory: directory)
        center.setEnabled(false); center.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        center.setEnabled(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Packs").path))
        center.setEnabled(false)
    }

    func testHotReloadDetectsInPlaceAndAtomicReplacement() async throws {
        let directory = temporaryDirectory(); let center = CustomizationCenter(directory: directory, enabled: true)
        let first = pack("live", color: "#111111")
        try center.save(first); try center.setPackEnabled("live", true)
        try await Task.sleep(for: .milliseconds(450))
        let file = directory.appendingPathComponent("Packs/live.json")
        try JSONEncoder().encode(pack("live", color: "#222222")).write(to: file)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(center.effectiveTheme?.accent, "#222222")
        try JSONEncoder().encode(pack("live", color: "#333333")).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(center.effectiveTheme?.accent, "#333333")
        center.setEnabled(false)
    }

    func testDisablingCancelsReloadAndGuardsDiskMutators() async throws {
        let directory = temporaryDirectory(); let center = CustomizationCenter(directory: directory, enabled: true)
        try center.save(pack("live", color: "#111111")); try center.setPackEnabled("live", true)
        center.setEnabled(false)
        let file = directory.appendingPathComponent("Packs/live.json")
        try JSONEncoder().encode(pack("live", color: "#222222")).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(center.isEnabled)
        XCTAssertNil(center.effectiveTheme)
        XCTAssertNil(center.effectiveLayout)
        XCTAssertTrue(center.commands.isEmpty)
        XCTAssertEqual(center.packs.first?.theme?.accent, "#111111")
        XCTAssertThrowsError(try center.save(pack("nope")))
        XCTAssertThrowsError(try center.importPack(data: JSONEncoder().encode(pack("import"))))
        XCTAssertThrowsError(try center.exportPack(id: "live"))
        XCTAssertThrowsError(try center.setPackEnabled("live", false))
        XCTAssertThrowsError(try center.removePack("live"))
    }

    func testPackDirectorySymlinkBlocksAllPersistence() throws {
        let directory = temporaryDirectory()
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Packs"), withDestinationURL: outside)
        let center = CustomizationCenter(directory: directory, enabled: true)
        XCTAssertThrowsError(try center.save(pack("unsafe")))
        XCTAssertThrowsError(try center.setPackEnabled("unsafe", false))
        XCTAssertThrowsError(try center.removePack("unsafe"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testReloadRejectsFIFOPackWithoutBlocking() throws {
        let directory = temporaryDirectory(); let center = CustomizationCenter(directory: directory, enabled: true)
        let fifo = directory.appendingPathComponent("Packs/fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        center.reload()
        XCTAssertTrue(center.error?.contains("regular") == true)
    }

    func testBorderAndShapeTokensDecodeAndLastActivePackWins() throws {
        let json = ##"{"schemaVersion":1,"id":"shape","name":"Shape","theme":{"border":"#11223380","cornerRadius":12,"borderWidth":2},"commands":[]}"##
        let decoded = try CustomizationCenter.decodePack(Data(json.utf8))
        XCTAssertEqual(decoded.theme?.border, "#11223380")
        XCTAssertEqual(decoded.theme?.cornerRadius, 12)
        XCTAssertEqual(decoded.theme?.borderWidth, 2)

        let center = CustomizationCenter(directory: temporaryDirectory(), enabled: true)
        try center.save(.init(id: "one", name: "one", theme: .init(border: "#111111", cornerRadius: 4, borderWidth: 1)))
        try center.save(.init(id: "two", name: "two", theme: .init(cornerRadius: 20)))
        try center.setPackEnabled("one", true); try center.setPackEnabled("two", true)
        XCTAssertEqual(center.effectiveTheme?.cornerRadius, 20)
        XCTAssertEqual(center.effectiveTheme?.border, "#111111")
        XCTAssertEqual(center.effectiveTheme?.borderWidth, 1)
    }

    func testInvalidBorderAndShapeTokensAreRejected() throws {
        let center = CustomizationCenter(directory: temporaryDirectory(), enabled: true)
        XCTAssertThrowsError(try center.save(.init(id: "bad_border", name: "Bad", theme: .init(border: "red"))))
        XCTAssertThrowsError(try center.save(.init(id: "bad_radius", name: "Bad", theme: .init(cornerRadius: 25))))
        XCTAssertThrowsError(try center.save(.init(id: "neg_radius", name: "Bad", theme: .init(cornerRadius: -1))))
        XCTAssertThrowsError(try center.save(.init(id: "bad_width", name: "Bad", theme: .init(borderWidth: 5))))
        XCTAssertNoThrow(try center.save(.init(id: "edge_ok", name: "Ok", theme: .init(border: "#ABCDEF", cornerRadius: 24, borderWidth: 0))))
    }

    func testLegacyThemeJSONWithoutNewFieldsStillDecodes() throws {
        let json = ##"{"schemaVersion":1,"id":"legacy","name":"Legacy","theme":{"accent":"#123456"},"commands":[]}"##
        let decoded = try CustomizationCenter.decodePack(Data(json.utf8))
        XCTAssertEqual(decoded.theme?.accent, "#123456")
        XCTAssertNil(decoded.theme?.border)
        XCTAssertNil(decoded.theme?.cornerRadius)
        XCTAssertNil(decoded.theme?.borderWidth)
    }

    func testReloadChecksRegularFileSizeBeforeReadingAndRejectsPackSymlinks() throws {
        let directory = temporaryDirectory(); let center = CustomizationCenter(directory: directory, enabled: true)
        let packs = directory.appendingPathComponent("Packs")
        let oversized = packs.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 1_048_577).write(to: oversized)
        center.reload()
        XCTAssertTrue(center.error?.contains("1 MiB") == true)
        try FileManager.default.removeItem(at: oversized)
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: packs.appendingPathComponent("link.json"), withDestinationURL: target)
        center.reload()
        XCTAssertTrue(center.error?.contains("simbólica") == true)
    }
}
