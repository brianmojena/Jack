import Combine
import XCTest
@testable import JackCore

@MainActor private final class CustomizationCommandDriver: ChatDriver {
    var prompt: String?
    var continuation: CheckedContinuation<Void, Never>?

    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        self.prompt = prompt
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() { continuation?.resume(); continuation = nil }
}

final class CustomizationCommandTests: XCTestCase {
    @MainActor func testPromptCommandsExpandArgumentsEscapeBangAndOverridePersonalTemplate() async throws {
        let root = try projectDirectory("prompts")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChatArchive(directory: root)
        try JSONEncoder().encode([JackCommandTemplate(name: "same", prompt: "personal {{args}}")])
            .write(to: root.appendingPathComponent("commands.json"))
        let driver = CustomizationCommandDriver()
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in driver })
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        try store.customization.importPack(data: JSONEncoder().encode(CustomizationPack(
            id: "prompts", name: "Prompts", commands: [
                .init(name: "same", title: "Mod", kind: .prompt, content: "Mod says {{args}}"),
                .init(name: "bang", title: "Literal bang", kind: .prompt, content: "!literal {{args}}"),
                .init(name: "append", title: "Append args", kind: .prompt, content: "Base")
            ])))
        try store.customization.setPackEnabled("prompts", true)

        XCTAssertEqual(store.jackCommands.first { $0.name == "same" }?.description, "Mod")
        store.send("!same hello", to: id)
        let sawExpandedPrompt = await waitUntil { driver.prompt?.contains("Mod says hello") == true }
        XCTAssertTrue(sawExpandedPrompt)
        driver.stop()
        let firstTurnEnded = await waitUntil { !store.isBusy(id) }
        XCTAssertTrue(firstTurnEnded)

        driver.prompt = nil
        store.send("!bang hello", to: id)
        let sawLiteralBang = await waitUntil { driver.prompt?.contains("!literal hello") == true }
        XCTAssertTrue(sawLiteralBang)
        XCTAssertFalse(store.conversations.first { $0.id == id }?.messages.contains { $0.role == "error" } == true)
        driver.stop()
        let secondTurnEnded = await waitUntil { !store.isBusy(id) }
        XCTAssertTrue(secondTurnEnded)

        driver.prompt = nil
        store.send("!append hello", to: id)
        let sawAppendedArguments = await waitUntil { driver.prompt?.contains("Base\nhello") == true }
        XCTAssertTrue(sawAppendedArguments)
        driver.stop()
        let thirdTurnEnded = await waitUntil { !store.isBusy(id) }
        XCTAssertTrue(thirdTurnEnded)
    }

    @MainActor func testTerminalRequestIsLiteralSingleAndRejectsArgumentsAndRemoteProjects() throws {
        let root = try projectDirectory("terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        var driverCreations = 0
        let store = ChatStore(archive: ChatArchive(directory: root), preferences: nil, driverFactory: { _ in
            driverCreations += 1
            return CustomizationCommandDriver()
        })
        defer { store.shutdown() }
        let localID = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        try store.customization.importPack(data: JSONEncoder().encode(CustomizationPack(
            id: "terminal", name: "Terminal", commands: [
                .init(name: "run", title: "Run exact", kind: .terminal, content: "printf '%s' '{{args}}' && echo \"$HOME\"")
            ])))
        try store.customization.setPackEnabled("terminal", true)

        store.send("!run", to: localID)
        let request = try XCTUnwrap(store.customTerminalCommandRequest)
        XCTAssertEqual(request.conversationID, localID)
        XCTAssertEqual(request.title, "Run exact")
        XCTAssertEqual(request.projectPath, root.path)
        XCTAssertEqual(request.content, "printf '%s' '{{args}}' && echo \"$HOME\"")
        XCTAssertEqual(driverCreations, 0)

        store.send("!run ignored", to: localID)
        XCTAssertEqual(store.customTerminalCommandRequest, request)
        XCTAssertTrue(store.errorMessage?.contains("argumentos") == true)
        store.errorMessage = nil
        store.send("!run", to: localID)
        XCTAssertEqual(store.customTerminalCommandRequest, request)
        XCTAssertEqual(driverCreations, 0)
        store.consumeCustomTerminalCommand(id: UUID())
        XCTAssertEqual(store.customTerminalCommandRequest, request)
        store.consumeCustomTerminalCommand(id: request.id)
        XCTAssertNil(store.customTerminalCommandRequest)

        let remoteID = try XCTUnwrap(store.create(projectPath: root.path, provider: .claude,
                                                  remote: ChatRemoteEndpoint(destination: "example.test")))
        store.send("!run", to: remoteID)
        XCTAssertNil(store.customTerminalCommandRequest)
        XCTAssertTrue(store.errorMessage?.contains("local") == true)
        XCTAssertEqual(driverCreations, 0)

        store.send("!run", to: localID)
        XCTAssertNotNil(store.customTerminalCommandRequest)
        store.shutdown()
        XCTAssertNil(store.customTerminalCommandRequest)
    }

    @MainActor func testLightInitiallyDoesNotCreateCustomizationAndNormalResubscribesAfterLight() async throws {
        let lightRoot = FileManager.default.temporaryDirectory.appendingPathComponent("jack-custom-light-\(UUID().uuidString)", isDirectory: true)
        let lightArchive = ChatArchive(directory: lightRoot)
        let lightStore = ChatStore(archive: lightArchive, preferences: nil, lightMode: true)
        defer { lightStore.shutdown() }
        XCTAssertFalse(lightStore.jackCommands.contains { $0.name == "quiet" })
        lightStore.applyCustomization()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lightRoot.appendingPathComponent("Customization").path))

        let root = try projectDirectory("mode-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(archive: ChatArchive(directory: root), preferences: nil)
        defer { store.shutdown() }
        store.applyCustomization()
        let original = CustomizationPack(id: "mode", name: "Mode", commands: [
            .init(name: "quiet", title: "Before", kind: .prompt, content: "before")
        ])
        try store.customization.importPack(data: JSONEncoder().encode(original))
        try store.customization.setPackEnabled("mode", true)
        XCTAssertEqual(store.jackCommands.first { $0.name == "quiet" }?.description, "Before")
        try store.customization.importPack(
            data: JSONEncoder().encode(
                CustomizationPack(id: "idle", name: "Idle", commands: [
                    .init(name: "idle", title: "Idle", kind: .terminal, content: "touch ran")
                ])
            )
        )
        try store.customization.setPackEnabled("idle", true)
        XCTAssertNil(store.customTerminalCommandRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran").path))

        store.setLightMode(true)
        XCTAssertFalse(store.jackCommands.contains { $0.name == "quiet" })
        store.setLightMode(false)
        store.applyCustomization()
        var updates = 0
        let observation = store.objectWillChange.sink { updates += 1 }
        var changed = original
        changed.commands[0].title = "After"
        changed.commands[0].content = "after"
        try store.customization.save(changed)
        let sawRevisionForwarded = await waitUntil { updates > 0 }
        XCTAssertTrue(sawRevisionForwarded)
        XCTAssertEqual(store.jackCommands.first { $0.name == "quiet" }?.description, "After")
        observation.cancel()
    }

    @MainActor func testModCrearLeEncargaAlAgenteUnPackConElEsquemaCompleto() async throws {
        let root = try projectDirectory("mod-crear")
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = CustomizationCommandDriver()
        let store = ChatStore(archive: ChatArchive(directory: root), preferences: nil, driverFactory: { _ in driver })
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        XCTAssertTrue(store.jackCommands.contains { $0.name == "mod" })

        store.send("!mod crear un panel oscuro con acento verde", to: id)
        let sawSchema = await waitUntil { driver.prompt?.contains("schemaVersion") == true }
        XCTAssertTrue(sawSchema)
        let prompt = try XCTUnwrap(driver.prompt)
        XCTAssertTrue(prompt.contains("un panel oscuro con acento verde"))
        XCTAssertTrue(prompt.contains("mods/<id>.json"))
        XCTAssertTrue(prompt.contains("!mod instalar mods/<id>.json"))
        XCTAssertTrue(prompt.contains("enabled.json"))
        XCTAssertTrue(prompt.contains("sidebarWidth 210-400"))
        // Los nombres reservados salen del catálogo, así que nunca se desincronizan.
        XCTAssertTrue(prompt.contains(JackCommandCatalog.builtins.map(\.name).joined(separator: ", ")))
        driver.stop()
    }

    @MainActor func testModInstalarValidaActivaYListaElPack() throws {
        let root = try projectDirectory("mod-instalar")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChatArchive(directory: root)
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in CustomizationCommandDriver() })
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        let mods = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        let pack = CustomizationPack(id: "neon", name: "Neon", theme: .init(accent: "#55E6C1"),
                                     commands: [.init(name: "neon_review", title: "Review", kind: .prompt, content: "Revisa {{args}}")])
        try JSONEncoder().encode(pack).write(to: mods.appendingPathComponent("neon.json"))

        store.send("!mod listar", to: id)
        XCTAssertTrue(store.conversations.first { $0.id == id }?.messages.last?.text.contains("!mod crear") == true)
        store.send("!mod instalar mods/neon.json", to: id)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.customization.enabledIDs, ["neon"])
        XCTAssertEqual(store.customization.packs.first?.name, "Neon")
        let installed = root.appendingPathComponent("Customization", isDirectory: true)
            .appendingPathComponent("Packs", isDirectory: true).appendingPathComponent("neon.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(store.jackCommands.first { $0.name == "neon_review" }?.description, "Review")

        store.send("!mod listar", to: id)
        let notice = try XCTUnwrap(store.conversations.first { $0.id == id }?.messages.last?.text)
        XCTAssertTrue(notice.contains("neon — Neon (activado)"), notice)
    }

    @MainActor func testModInstalarRechazaRutasFueraDelProyecto() throws {
        let root = try projectDirectory("mod-escape")
        let outside = try projectDirectory("mod-outside")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let store = ChatStore(archive: ChatArchive(directory: root), preferences: nil, driverFactory: { _ in CustomizationCommandDriver() })
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        let pack = CustomizationPack(id: "outside", name: "Outside")
        let outsidePack = outside.appendingPathComponent("outside.json")
        try JSONEncoder().encode(pack).write(to: outsidePack)
        let mods = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: mods.appendingPathComponent("evil.json").path, withDestinationPath: outsidePack.path)

        for attempt in ["!mod instalar ../\(outside.lastPathComponent)/outside.json", "!mod instalar \(outsidePack.path)", "!mod instalar mods/evil.json"] {
            store.send(attempt, to: id)
            XCTAssertTrue(store.errorMessage?.contains("dentro del proyecto") == true, attempt)
            store.errorMessage = nil
        }
        XCTAssertTrue(store.customization.packs.isEmpty)
    }

    @MainActor func testModInstalarRechazaUnPackInvalidoSinInstalarNada() throws {
        let root = try projectDirectory("mod-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(archive: ChatArchive(directory: root), preferences: nil, driverFactory: { _ in CustomizationCommandDriver() })
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        let mods = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        try JSONEncoder().encode(CustomizationPack(id: "bad", name: "Bad", layout: .init(sidebarWidth: 50)))
            .write(to: mods.appendingPathComponent("bad.json"))

        store.send("!mod instalar mods/bad.json", to: id)
        XCTAssertTrue(store.errorMessage?.contains("No se pudo instalar el mod") == true)
        XCTAssertTrue(store.customization.packs.isEmpty)
        XCTAssertTrue(store.customization.enabledIDs.isEmpty)
    }

    @MainActor func testModDesapareceDeLaListaYSeRechazaEnLight() throws {
        let root = try projectDirectory("mod-light")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(archive: ChatArchive(directory: root), preferences: nil, lightMode: true)
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: root.path, provider: .codex))
        store.applyCustomization()
        XCTAssertFalse(store.jackCommands.contains { $0.name == "mod" })
        store.send("!mod listar", to: id)
        XCTAssertTrue(store.errorMessage?.contains("Normal") == true)
        store.errorMessage = nil
        store.send("!comandos", to: id)
        let help = try XCTUnwrap(store.conversations.first { $0.id == id }?.messages.last?.text)
        XCTAssertFalse(help.contains("!mod"), help)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Customization").path))
    }

    @MainActor private func projectDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jack-custom-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !predicate(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
}
