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
