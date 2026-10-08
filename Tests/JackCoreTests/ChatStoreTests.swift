import XCTest
@testable import JackCore

@MainActor private final class ControlledDriver: ChatDriver {
    var callback: (@MainActor (ChatEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var sessionIDToEmit: String?
    var answers: [(String, Bool)] = []
    var lastPrompt: String?
    var stopped = false
    var finishesOnStop = true
    var holdResponses = false
    var responseContinuation: CheckedContinuation<Void, Never>?
    var energySavingChanges: [Bool] = []
    func setEnergySaving(_ enabled: Bool) { energySavingChanges.append(enabled) }
    func complete(_ text: String) {
        callback?(.text(id: "controlled-answer-\(UUID().uuidString)", text: text, replace: true))
        finish()
    }
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        lastPrompt = prompt
        callback = onEvent
        if let sessionIDToEmit { onEvent(.session(sessionIDToEmit)) }
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws {
        answers.append((approvalID, allow))
        if holdResponses { await withCheckedContinuation { responseContinuation = $0 } }
    }
    func answer(approvalID: String, answers: [String: String]) async throws { try await respond(approvalID: approvalID, allow: true) }
    func stop() { stopped = true; if finishesOnStop { finish() } }
    func finish() { continuation?.resume(); continuation = nil }
}

final class ChatStoreTests: XCTestCase {
    @MainActor private func fixture(lightMode: Bool = false, sessionIDToEmit: String? = nil, preferences: UserDefaults? = nil) -> (ChatStore, ChatArchive, URL, () -> [ControlledDriver]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-chat-tests-" + UUID().uuidString)
        let archive = ChatArchive(directory: folder)
        var drivers: [ControlledDriver] = []
        let store = ChatStore(archive: archive, preferences: preferences, driverFactory: { _ in let driver = ControlledDriver(); driver.sessionIDToEmit = sessionIDToEmit; drivers.append(driver); return driver }, lightMode: lightMode)
        store.setConcurrency(2)
        return (store, archive, folder, { drivers })
    }

    @MainActor func testTerminalClaimsRejectBusySessionsAndPreventConcurrentChatWrites() async throws {
        let session = UUID()
        let (store, _, folder, drivers) = fixture(sessionIDToEmit: session.uuidString)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("first turn", to: id)
        await settle()
        XCTAssertFalse(store.claimClaudeSessionForTerminal(session), "A running agent cannot be handed to a terminal")
        drivers().first?.finish()
        await settle()
        XCTAssertTrue(store.claimClaudeSessionForTerminal(session))
        XCTAssertFalse(store.claimClaudeSessionForTerminal(session), "Only one owner may resume the CLI session")
        let count = store.conversations.first { $0.id == id }?.messages.count
        store.send("must stay out of history", to: id)
        XCTAssertEqual(store.conversations.first { $0.id == id }?.messages.count, count)
        XCTAssertTrue(store.errorMessage?.contains("Terminal") == true)
        store.releaseClaudeSessionFromTerminal(session)
        store.errorMessage = nil
        store.send("next turn", to: id)
        await settle()
        XCTAssertEqual(drivers().last?.lastPrompt, "next turn")
        drivers().last?.finish()
        await settle()
        store.setLightMode(true)
        XCTAssertFalse(store.claimClaudeSessionForTerminal(UUID()), "Light cannot create terminal ownership")
    }

    @MainActor func testClaudeDefaultsAndFreshTaskPreserveOldSessionWithoutInference() throws {
        let (initialStore, archive, folder, _) = fixture()
        initialStore.shutdown()
        var source = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .claude, model: "sonnet", effort: "low",
                                      sessionID: "old-session", messages: [ChatMessage(role: "user", text: "old history")])
        source.jackContext = JackContextSettings()
        source.jackContext?.seed = "old summary"
        source.jackContext?.pinned = ["old instruction"]
        archive.save(index: [source], conversation: source); archive.flush()
        var driverCount = 0
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in driverCount += 1; return ControlledDriver() })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let fresh = try XCTUnwrap(store.startFreshTask(from: source.id))
        let result = try XCTUnwrap(store.conversations.first { $0.id == fresh })
        XCTAssertNil(result.sessionID)
        XCTAssertNil(result.jackContext)
        XCTAssertNil(result.parentID)
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.model, "sonnet")
        XCTAssertEqual(result.effort, "low")
        XCTAssertEqual(store.conversations.first { $0.id == source.id }?.sessionID, "old-session")
        XCTAssertEqual(try archive.load(source.id)?.messages.first?.text, "old history")
        XCTAssertEqual(driverCount, 0)
        XCTAssertEqual(store.defaultEffort(for: .claude), "medium")
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        XCTAssertEqual(store.conversations.first { $0.id == id }?.effort, "medium")
        store.setLightMode(true)
        XCTAssertEqual(store.defaultEffort(for: .claude), "high")
        XCTAssertNil(store.startFreshTask(from: source.id))
        let light = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        XCTAssertEqual(store.conversations.first { $0.id == light }?.effort, "high")
    }

    @MainActor func testStellarSlashCompactRunsRealCompactionAndKeepsTranscript() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
        store.send("/compact inválido", to: id)
        XCTAssertTrue(store.errorMessage?.contains("Uso: /compact") == true)
        XCTAssertTrue(drivers().isEmpty)

        store.send("objetivo original: conservar decisión", to: id)
        await settle()
        let firstDriver = try XCTUnwrap(drivers().first)
        XCTAssertEqual(firstDriver.lastPrompt, "objetivo original: conservar decisión")
        firstDriver.complete("Decisión anterior: mantener el formato de archivo.")
        await settle()

        store.send("/compact 1234", to: id)
        await settle()
        let compactDriver = try XCTUnwrap(drivers().last)
        XCTAssertTrue(try XCTUnwrap(compactDriver.lastPrompt).contains("aproximadamente 1234 tokens"))
        XCTAssertTrue(try XCTUnwrap(compactDriver.lastPrompt).contains("objetivo original: conservar decisión"))
        XCTAssertTrue(try XCTUnwrap(compactDriver.lastPrompt).contains("Decisión anterior: mantener el formato de archivo."))
        XCTAssertFalse(compactDriver.lastPrompt?.contains("/compact 1234") == true)
        compactDriver.complete("RESUMEN REAL DE LA SESIÓN")
        await settle()

        let compacted = try XCTUnwrap(store.conversations.first { $0.id == id })
        XCTAssertNil(compacted.sessionID)
        XCTAssertEqual(compacted.jackContext?.seed, "RESUMEN REAL DE LA SESIÓN")
        XCTAssertTrue(compacted.messages.contains { $0.role == "user" && $0.text == "objetivo original: conservar decisión" })
        XCTAssertTrue(compacted.messages.contains { $0.role == "assistant" && $0.text == "Decisión anterior: mantener el formato de archivo." })
        XCTAssertTrue(compacted.messages.contains { $0.role == "jack" && $0.text.contains("Contexto compactado") })

        store.send("/compact", to: id)
        await settle()
        let defaultCompact = try XCTUnwrap(drivers().last)
        XCTAssertTrue(try XCTUnwrap(defaultCompact.lastPrompt).contains("aproximadamente 2000 tokens"))
        XCTAssertTrue(try XCTUnwrap(defaultCompact.lastPrompt).contains("objetivo original: conservar decisión"))
        defaultCompact.complete("SEGUNDO RESUMEN")
        await settle()
        XCTAssertEqual(store.conversations.first { $0.id == id }?.jackContext?.seed, "SEGUNDO RESUMEN")
    }

    @MainActor func testStellarCompactionResetsAnExistingSessionID() async throws {
        let (store, _, folder, drivers) = fixture(sessionIDToEmit: "existing-stellar-session")
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
        store.send("objetivo antes de compactar", to: id)
        await settle()
        XCTAssertEqual(store.conversations.first { $0.id == id }?.sessionID, "existing-stellar-session")
        let first = try XCTUnwrap(drivers().first)
        first.complete("respuesta anterior")
        await settle()

        store.send("/compact 777", to: id)
        await settle()
        let compact = try XCTUnwrap(drivers().last)
        XCTAssertTrue(try XCTUnwrap(compact.lastPrompt).contains("aproximadamente 777 tokens"))
        compact.complete("resumen de sesión existente")
        await settle()
        XCTAssertNil(store.conversations.first { $0.id == id }?.sessionID)
        XCTAssertEqual(store.conversations.first { $0.id == id }?.jackContext?.seed, "resumen de sesión existente")
    }

    @MainActor func testStellarCloudCatalogAndRecentModelsAreRemovedFromLightAndDiscoveryRace() async throws {
        let (store, _, folder, _) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
        let local = StellarModel(id: "ollama/gemma4:e2b", name: "gemma4:e2b", server: StellarServer.builtIn[0], tools: true)
        let cloud = StellarModel(id: "ollama/account/model:latest", name: "account/model:latest", server: StellarServer.builtIn[0], tools: true, isCloud: true)
        store.loadStellarModels = { includeCloud in includeCloud ? [cloud, local] : [local] }
        await store.refreshLocalModels()
        XCTAssertEqual(store.modelChoices(for: .stellar).map(\.id), [cloud.id, local.id])
        store.updateSettings(id: id, model: cloud.id, effort: "high")
        XCTAssertTrue(store.recentModels[.stellar]?.contains(cloud.id) == true)
        store.setLightMode(true)
        XCTAssertEqual(store.localModels, [local])
        XCTAssertFalse(store.modelChoices(for: .stellar).contains { $0.id == cloud.id })
        XCTAssertTrue(store.recentModels[.stellar]?.contains(cloud.id) == true, "Light hides Normal recents without deleting them")
        store.setLightMode(false)
        XCTAssertTrue(store.modelChoices(for: .stellar).contains { $0.id == cloud.id }, "returning to Normal restores the cloud recent")

        let (racingStore, _, raceFolder, _) = fixture()
        defer { racingStore.shutdown(); try? FileManager.default.removeItem(at: raceFolder) }
        var pending: CheckedContinuation<[StellarModel], Never>?
        var requestedCloud = false
        racingStore.loadStellarModels = { includeCloud in
            requestedCloud = includeCloud
            return await withCheckedContinuation { pending = $0 }
        }
        let refresh = Task { await racingStore.refreshLocalModels() }
        await settle()
        XCTAssertTrue(requestedCloud)
        racingStore.setLightMode(true)
        pending?.resume(returning: [cloud, local])
        await refresh.value
        XCTAssertEqual(racingStore.localModels, [], "a Normal discovery finishing after the switch cannot overwrite the Light catalog")
        XCTAssertFalse(racingStore.modelChoices(for: .stellar).contains { $0.id == cloud.id })
    }

    @MainActor func testStellarDiscoveryChecksModeBeforeRehydratingLinkedCloudAndRejectsStaleOverride() async throws {
        let cloud = StellarModel(id: "ollama/account/model:latest", name: "account/model:latest", server: StellarServer.builtIn[0], tools: true, isCloud: true)
        let local = StellarModel(id: "ollama/gemma4:e2b", name: "gemma4:e2b", server: StellarServer.builtIn[0], tools: true)
        let suite = "StellarDiscovery-\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        prefs.set([cloud.id], forKey: "stellar.linkedCloudModelIDs")
        defer { prefs.removePersistentDomain(forName: suite) }

        let (store, _, folder, _) = fixture(preferences: prefs)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var pending: CheckedContinuation<[StellarModel], Never>?
        var inspections = 0
        store.loadStellarModels = { _ in await withCheckedContinuation { pending = $0 } }
        store.inspectLinkedCloudModel = { _ in inspections += 1; return cloud }
        let refresh = Task { await store.refreshLocalModels() }
        await settle()
        store.setLightMode(true)
        store.setLightMode(false)
        store.setLightMode(true)
        pending?.resume(returning: [local])
        await refresh.value
        XCTAssertEqual(inspections, 0, "an obsolete Normal discovery must not issue linked-cloud /api/show calls after a mode transition")
        XCTAssertEqual(store.localModels, [], "stale completion cannot overwrite a newer mode's catalog")

        let (latestStore, _, latestFolder, _) = fixture()
        defer { latestStore.shutdown(); try? FileManager.default.removeItem(at: latestFolder) }
        var older: CheckedContinuation<[StellarModel], Never>?
        var loadCount = 0
        latestStore.loadStellarModels = { _ in
            loadCount += 1
            if loadCount == 1 { return await withCheckedContinuation { older = $0 } }
            return [local]
        }
        let stale = Task { await latestStore.refreshLocalModels() }
        await settle()
        await latestStore.refreshLocalModels()
        older?.resume(returning: [cloud])
        await stale.value
        XCTAssertEqual(latestStore.localModels, [local], "a late older load cannot replace a newer catalog")
    }

    @MainActor func testLinkedCloudPersistsAcrossReloadAndLightHidesWithoutErasingRecent() async throws {
        let suite = "StellarLinked-\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let (store, _, folder, _) = fixture(preferences: prefs)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let conversation = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
        let response: [String: Any] = ["remote_host": "ollama.com", "remote_model": "gemma4:31b", "capabilities": ["completion", "tools"]]
        store.inspectLinkedCloudInfo = { _ in response }
        let linked = try await store.linkOllamaCloudModel("account/gemma4:31b")
        store.updateSettings(id: conversation, model: linked.id, effort: "high")
        XCTAssertEqual(prefs.stringArray(forKey: "stellar.linkedCloudModelIDs"), [linked.id])
        store.setLightMode(true)
        XCTAssertTrue(store.recentModels[.stellar]?.contains(linked.id) == true)
        XCTAssertFalse(store.modelChoices(for: .stellar).contains { $0.id == linked.id })
        store.setLightMode(false)
        XCTAssertTrue(store.modelChoices(for: .stellar).contains { $0.id == linked.id })
        store.shutdown()

        let (reloaded, _, reloadFolder, _) = fixture(preferences: prefs)
        defer { reloaded.shutdown(); try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: reloadFolder) }
        reloaded.loadStellarModels = { _ in [] }
        var rehydrations = 0
        reloaded.inspectLinkedCloudModel = { name in
            rehydrations += 1
            XCTAssertEqual(name, "account/gemma4:31b")
            return linked
        }
        await reloaded.refreshLocalModels()
        XCTAssertEqual(rehydrations, 1)
        XCTAssertTrue(reloaded.modelChoices(for: .stellar).contains { $0.id == linked.id })
    }

    @MainActor func testCloudLinkValidationSurvivesNormalDiscoveryRefresh() async throws {
        let suite = "StellarLinkRace-\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let (store, _, folder, _) = fixture(preferences: prefs)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var pending: CheckedContinuation<[String: Any], Never>?
        store.inspectLinkedCloudInfo = { _ in await withCheckedContinuation { pending = $0 } }
        store.loadStellarModels = { _ in [] }
        let linking = Task { try await store.linkOllamaCloudModel("account/gemma4:cloud") }
        await settle()
        await store.refreshLocalModels()
        pending?.resume(returning: ["remote_host": "ollama.com", "capabilities": ["completion", "tools"]])
        let linked = try await linking.value
        XCTAssertEqual(prefs.stringArray(forKey: "stellar.linkedCloudModelIDs"), [linked.id])
    }

    @MainActor func testCloudLinkValidationIsInvalidatedByLightRoundTrip() async throws {
        let suite = "StellarLinkModeRace-\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let (store, _, folder, _) = fixture(preferences: prefs)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var pending: CheckedContinuation<[String: Any], Never>?
        store.inspectLinkedCloudInfo = { _ in await withCheckedContinuation { pending = $0 } }
        let linking = Task { try await store.linkOllamaCloudModel("account/gemma4:cloud") }
        await settle()
        store.setLightMode(true)
        store.setLightMode(false)
        pending?.resume(returning: ["remote_host": "ollama.com", "capabilities": ["completion", "tools"]])
        do {
            _ = try await linking.value
            XCTFail("a validation started before the mode change must not register after returning to Normal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("solo están disponibles en modo Normal"))
        }
        XCTAssertNil(prefs.stringArray(forKey: "stellar.linkedCloudModelIDs"))
        XCTAssertFalse(store.localModels.contains { $0.isCloud })
    }

    @MainActor func testLightCancelsNormalStellarLocatorForUnknownCloudAlias() async throws {
        let (store, _, folder, _) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var pending: CheckedContinuation<Void, Never>?
        var allowCloudCaptured: Bool?
        var streamStarted = false
        store.locateProject = { _, _, model, _, allowCloud in
            XCTAssertEqual(model, "ollama/account/model:latest")
            allowCloudCaptured = allowCloud
            await withCheckedContinuation { pending = $0 }
            guard !Task.isCancelled else { throw CancellationError() }
            streamStarted = true
            return NSTemporaryDirectory()
        }
        let id = try XCTUnwrap(store.createLocating("revisa el proyecto", provider: .stellar,
                                                    model: "ollama/account/model:latest", projects: []))
        await settle()
        XCTAssertEqual(allowCloudCaptured, true)
        store.setLightMode(true)
        pending?.resume()
        await settle()
        XCTAssertFalse(streamStarted, "the cancelled Normal locator must not continue to an Ollama Cloud stream")
        XCTAssertTrue(store.isUnplaced(id))
        XCTAssertEqual(store.statuses[id], .idle)
    }

    @MainActor func testStellarCompactAliasIsProviderAndLightGatedAndHandlesBusyQueue() async throws {
        do {
            let (store, _, folder, drivers) = fixture()
            defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex))
            store.send("/compact", to: id)
            await settle()
            XCTAssertEqual(drivers().first?.lastPrompt, "/compact")
            drivers().first?.complete("ordinary provider response")
        }
        do {
            let (store, _, folder, drivers) = fixture(lightMode: true)
            defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
            store.send("/compact", to: id)
            await settle()
            XCTAssertEqual(drivers().first?.lastPrompt, "/compact")
            drivers().first?.complete("Light forwarded the text")
        }
        do {
            let (store, _, folder, drivers) = fixture()
            defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
            store.send("objetivo durante el turno", to: id)
            await settle()
            let first = try XCTUnwrap(drivers().first)
            store.send("/compact 555", to: id)
            XCTAssertEqual(drivers().count, 1, "the alias waits until the active run completes")
            first.complete("respuesta inicial")
            await settle()
            XCTAssertEqual(drivers().count, 2)
            let compact = try XCTUnwrap(drivers().last)
            XCTAssertTrue(try XCTUnwrap(compact.lastPrompt).contains("aproximadamente 555 tokens"))
            XCTAssertTrue(try XCTUnwrap(compact.lastPrompt).contains("objetivo durante el turno"))
            compact.complete("RESUMEN DESDE COLA")
            await settle()
            XCTAssertEqual(store.conversations.first { $0.id == id }?.jackContext?.seed, "RESUMEN DESDE COLA")
        }
    }
    @MainActor func testAutomaticAgentMovesToTheFolderItsModelChooses() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let project = NSTemporaryDirectory()
        var requests: [String] = []
        var locatorMayUseCloud: Bool?
        store.locateProject = { request, _, _, _, allowCloud in
            requests.append(request); locatorMayUseCloud = allowCloud
            return request.contains("Jack") ? project : nil
        }
        let id = try XCTUnwrap(store.createLocating("arregla el login", provider: .codex, projects: [project]))
        XCTAssertTrue(store.isUnplaced(id))
        await settle()
        XCTAssertTrue(store.isUnplaced(id), "an unknown project waits for the user")
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.selectedConversation?.messages.last?.role, "jack")
        XCTAssertTrue(drivers().isEmpty)

        store.send("es en Jack", to: id)
        await settle()
        XCTAssertEqual(requests.last, "arregla el login\n\nes en Jack")
        XCTAssertEqual(locatorMayUseCloud, true, "Normal passes its explicit cloud permission to project location")
        XCTAssertEqual(store.selectedConversation?.projectPath, project)
        XCTAssertFalse(store.isUnplaced(id))
        XCTAssertEqual(drivers().count, 1, "the agent starts once placed")
    }
    @MainActor func testAutomaticAgentJoinsExistingProjectWithoutAskingTheModel() async throws {
        let (store, archive, folder, drivers) = fixture()
        let project = folder.appendingPathComponent("Jack")
        let other = folder.appendingPathComponent("old/Jack")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let existing = try XCTUnwrap(store.create(projectPath: project.path, provider: .claude))
        store.locateProject = { _, _, _, _, _ in XCTFail("An open project resolves without a model call"); return nil }

        // The indexed namesake comes first; Jack must still reuse the open project's path.
        let id = try XCTUnwrap(store.createLocating("ve a Jack y arregla el login", provider: .codex, projects: [other.path]))
        await settle()
        XCTAssertNotEqual(id, existing)
        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.selectedConversation?.projectPath, project.path)
        XCTAssertEqual(store.conversations.first { $0.id == existing }?.projectPath, project.path)
        XCTAssertEqual(store.conversations.count, 2, "The existing conversation is preserved")
        XCTAssertFalse(store.isUnplaced(id))
        XCTAssertEqual(drivers().count, 1)
        archive.flush()
        XCTAssertEqual(try archive.load(id)?.projectPath, project.path)
    }

    @MainActor func testProjectNamedWhileSearchingAutomaticallyJoinsItsExistingSpace() async throws {
        let (store, _, folder, drivers) = fixture()
        let project = folder.appendingPathComponent("Jack")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: project.path, provider: .claude)
        var choice: CheckedContinuation<String?, Never>?
        var searches = 0
        store.locateProject = { _, _, _, _, _ in
            searches += 1
            return await withCheckedContinuation { choice = $0 }
        }
        let id = try XCTUnwrap(store.createLocating("arregla el login", provider: .codex, projects: []))
        await settle()
        XCTAssertTrue(store.locating.contains(id))
        store.send("ve a Jack", to: id)
        choice?.resume(returning: nil)
        await settle()
        XCTAssertEqual(searches, 1, "The clarification resolves directly to the open project")
        XCTAssertEqual(store.selectedConversation?.projectPath, project.path)
        XCTAssertEqual(store.selectedConversation?.messages.filter { $0.role == "user" }.map(\.text), ["arregla el login", "ve a Jack"])
        XCTAssertFalse(store.selectedConversation?.messages.contains { $0.role == "jack" } == true)
        XCTAssertEqual(drivers().count, 1, "Both messages start the same agent")
    }

    @MainActor func testAutomaticAgentRejectsFolderThatNoLongerExists() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.locateProject = { _, _, _, _, _ in folder.appendingPathComponent("missing").path }
        let id = try XCTUnwrap(store.createLocating("arregla el login", provider: .codex, projects: []))
        await settle()
        XCTAssertTrue(store.isUnplaced(id))
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertTrue(drivers().isEmpty)
        XCTAssertTrue(store.selectedConversation?.messages.last?.text.contains("ya no está disponible") == true)
    }

    @MainActor func testStoppingWhileChoosingTheFolderCancelsTheSearch() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        store.locateProject = { _, _, _, _, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { flag.cancelled = true; throw error }
            return NSTemporaryDirectory()
        }
        let id = try XCTUnwrap(store.createLocating("arregla el login", provider: .codex, projects: []))
        XCTAssertEqual(store.statuses[id], .running, "choosing the folder shows as work, not as a queue")
        XCTAssertTrue(store.locating.contains(id))
        store.stop(id)
        await settle()
        XCTAssertTrue(flag.cancelled)
        XCTAssertFalse(store.locating.contains(id))
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertTrue(store.isUnplaced(id))
        XCTAssertTrue(drivers().isEmpty, "a stopped agent does not start once the search ends")
    }
    @MainActor func testSlowFolderChoiceGivesUpAndAsksTheUser() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.locateDeadline = .milliseconds(50)
        store.locateProject = { _, _, _, _, _ in try await Task.sleep(for: .seconds(30)); return NSTemporaryDirectory() }
        let id = try XCTUnwrap(store.createLocating("arregla el login", provider: .codex, projects: []))
        for _ in 0..<100 where store.locating.contains(id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.selectedConversation?.messages.last?.role, "jack")
        XCTAssertTrue(drivers().isEmpty)
    }
    @MainActor func testAgentsInPanesKeepTheirTranscriptWithoutBeingSelected() throws {
        let (store, archive, folder, _) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let session = { (id: String) in ClaudeSessionSummary(id: id, title: id, projectPath: NSTemporaryDirectory(), updatedAt: Date()) }
        let side = try XCTUnwrap(store.importClaudeSession(session("lado"), messages: [ChatMessage(role: "user", text: "hola")]))
        let main = try XCTUnwrap(store.importClaudeSession(session("principal"), messages: [ChatMessage(role: "user", text: "otro")]))
        XCTAssertEqual(store.selectedID, main)
        XCTAssertEqual(store.conversations.first { $0.id == side }?.messages.count, 0, "an agent out of view is evicted")
        store.showInPanes([side])
        XCTAssertEqual(store.conversations.first { $0.id == side }?.messages.map(\.text), ["hola"])
        store.select(main)
        XCTAssertEqual(store.conversations.first { $0.id == side }?.messages.count, 1, "a pane keeps it loaded")
        XCTAssertEqual(store.selectedID, main)
        store.showInPanes([])
        XCTAssertEqual(store.conversations.first { $0.id == side }?.messages.count, 0)
        archive.flush()
    }
    func testLocatorReadsTheFolderFromTheAnswer() {
        let project = NSTemporaryDirectory().hasSuffix("/") ? String(NSTemporaryDirectory().dropLast()) : NSTemporaryDirectory()
        XCTAssertEqual(ProjectLocator.path(in: "`\(project)`", projects: [project]), project)
        XCTAssertEqual(ProjectLocator.path(in: "La carpeta es:\n\(project)/", projects: [project]), project)
        XCTAssertNil(ProjectLocator.path(in: "NINGUNA", projects: [project]))
        XCTAssertNil(ProjectLocator.path(in: "/no/existe/aqui", projects: [project]))
    }
    @MainActor func testClaudeEffortFollowsTheSelectedModel() throws {
        let (store, _, folder, _) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude, model: "claude-opus-4-5", effort: "max"))
        XCTAssertEqual(store.selectedConversation?.effort, "high")
        store.updateSettings(id: id, model: "opus", effort: "xhigh")
        XCTAssertEqual(store.selectedConversation?.effort, "xhigh")
        store.updateSettings(id: id, model: "haiku", effort: "xhigh")
        XCTAssertEqual(store.selectedConversation?.effort, "xhigh")
        XCTAssertEqual(store.supportedEfforts(provider: .claude, model: "haiku"), [])
        XCTAssertEqual(store.modelChoices(for: .claude).first { $0.id == "claude-sonnet-4-6" }?.efforts, nil)
        store.updateSettings(id: id, model: "claude-sonnet-4-6", effort: "xhigh")
        XCTAssertEqual(store.selectedConversation?.effort, "high")
        XCTAssertEqual(store.modelChoices(for: .claude).first { $0.id == "claude-sonnet-4-6" }?.efforts, ["low", "medium", "high", "max"])
    }
    @MainActor func testModelSwitchKeepsSessionAndHistoryAndRemembersProviderRecents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "jack-model-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let archive = ChatArchive(directory: folder)
        let driver = ControlledDriver()
        let store = ChatStore(archive: archive, preferences: preferences, driverFactory: { _ in driver })
        defer { store.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .codex)
        let id = try XCTUnwrap(store.selectedID)
        store.send("Keep context"); await settle()
        driver.callback?(.session("existing-session"))
        store.updateSettings(id: id, model: "busy-change", effort: "high")
        XCTAssertNotEqual(store.selectedConversation?.model, "busy-change")
        driver.finish(); await settle()
        store.updateSettings(id: id, model: "  custom-codex  ", effort: "high")
        XCTAssertEqual(store.selectedConversation?.sessionID, "existing-session")
        XCTAssertEqual(store.selectedConversation?.messages.first?.text, "Keep context")
        XCTAssertEqual(store.selectedConversation?.provider, .codex)
        XCTAssertEqual(store.selectedConversation?.model, "custom-codex")
        XCTAssertEqual(store.modelChoices(for: .codex).first?.id, "custom-codex")
        XCTAssertFalse(store.modelChoices(for: .claude).contains { $0.id == "custom-codex" })
        store.updateSettings(id: id, model: " ", effort: "high")
        XCTAssertEqual(store.selectedConversation?.model, ChatProvider.codex.defaultModel)
        archive.flush()
        let restored = ChatStore(archive: archive, preferences: preferences)
        XCTAssertNil(restored.selectedID, "Launching opens the start screen, not the last agent")
        restored.select(id)
        XCTAssertTrue(restored.modelChoices(for: .codex).contains { $0.id == "custom-codex" })
        XCTAssertEqual(restored.selectedConversation?.sessionID, "existing-session")
        restored.shutdown()
    }
    @MainActor func testFinishedTurnInBackgroundIsUnreadWithPreviewUntilSelected() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .codex)
        let background = try XCTUnwrap(store.selectedID)
        store.send("Trabaja"); await settle()
        store.create(projectPath: NSTemporaryDirectory(), provider: .codex)
        let foreground = try XCTUnwrap(store.selectedID)
        drivers()[0].callback?(.text(id: "a", text: "## Listo\n\nCompilé **todo**.", replace: false))
        drivers()[0].finish(); await settle()
        let finished = try XCTUnwrap(store.conversations.first { $0.id == background })
        XCTAssertEqual(finished.preview, "Listo")
        XCTAssertEqual(finished.hasUnread, true)
        archive.flush()
        XCTAssertEqual(try archive.loadIndex().first { $0.id == background }?.hasUnread, true)
        store.select(background)
        XCTAssertNil(store.conversations.first { $0.id == background }?.hasUnread)
        XCTAssertNil(store.conversations.first { $0.id == foreground }?.hasUnread)
        store.setUnread(background, true)
        XCTAssertEqual(store.conversations.first { $0.id == background }?.hasUnread, true)
    }
    @MainActor func testPinningIsLimitedToFiveAndPendingPersists() throws {
        let (store, archive, folder, _) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var ids: [UUID] = []
        for _ in 0..<6 {
            store.create(projectPath: NSTemporaryDirectory(), provider: .codex)
            ids.append(try XCTUnwrap(store.selectedID))
        }
        for id in ids.prefix(5) { XCTAssertTrue(store.setPinned(id, true)) }
        XCTAssertFalse(store.setPinned(ids[5], true), "a sixth pin is refused")
        XCTAssertNil(store.conversations.first { $0.id == ids[5] }?.pinnedAt)
        XCTAssertNotNil(store.errorMessage)
        store.setPinned(ids[0], false)
        XCTAssertTrue(store.setPinned(ids[5], true), "unpinning frees a slot")
        store.setPending(ids[1], true)
        archive.flush()
        let index = try archive.loadIndex()
        XCTAssertEqual(index.first { $0.id == ids[1] }?.isPending, true)
        XCTAssertNotNil(index.first { $0.id == ids[5] }?.pinnedAt)
        store.setPending(ids[1], false)
        XCTAssertNil(store.conversations.first { $0.id == ids[1] }?.isPending)
    }
    @MainActor func testTwoActiveAgentsAndQueuedThirdStartsAfterCompletion() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var ids: [UUID] = []
        for number in 1...3 {
            store.create(projectPath: NSTemporaryDirectory(), provider: .codex)
            ids.append(try XCTUnwrap(store.selectedID)); store.send("task \(number)")
        }
        await settle()
        XCTAssertEqual(store.activeCount, 2)
        XCTAssertEqual(drivers().count, 2)
        XCTAssertEqual(store.statuses[ids[2]], .queued)
        drivers()[0].finish(); await settle()
        XCTAssertEqual(drivers().count, 3)
        XCTAssertEqual(store.statuses[ids[2]], .running)
        XCTAssertEqual(store.activeCount, 2)
        for driver in drivers() { driver.finish() }; await settle()
    }
    @MainActor func testStreamingFlushesOnCompletionAndPersistsSession() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .codex); store.send("Hola")
        await settle()
        let id = try XCTUnwrap(store.selectedID)
        let driver = try XCTUnwrap(drivers().first)
        driver.callback?(.session("native-session"))
        driver.callback?(.text(id: "reply", text: "Ho", replace: false))
        driver.callback?(.text(id: "reply", text: "la", replace: false))
        driver.callback?(.text(id: "reply", text: "Hola!", replace: true))
        driver.finish(); await settle(); archive.flush()
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "Hola!")
        XCTAssertEqual(try archive.load(id)?.sessionID, "native-session")
        XCTAssertEqual(try archive.load(id)?.messages.count, 2)
    }
    @MainActor func testCompletionReleasesSlotBeforeDriverCleanupAndIgnoresOldTurn() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(1)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        store.send("primero"); await settle()
        let first = try XCTUnwrap(drivers().first)
        first.callback?(.text(id: "reply", text: "Listo", replace: true))
        first.callback?(.tool(id: "tool", title: "Read", detail: "", status: "running"))
        first.callback?(.completed)
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.activeCount, 0, "cleanup must not reserve a concurrency slot")
        XCTAssertFalse(store.isBusy(id))
        XCTAssertEqual(store.selectedConversation?.messages.first { $0.id == "tool" }?.status, "interrupted")
        archive.flush()
        XCTAssertEqual(try archive.load(id)?.messages.first { $0.id == "reply" }?.text, "Listo")

        store.send("segundo"); await settle()
        let second = try XCTUnwrap(drivers().last)
        XCTAssertEqual(drivers().count, 2)
        first.callback?(.approvalResolved("old"))
        first.callback?(.approval(ChatApproval(id: "old", title: "Old permission", detail: "")))
        first.callback?(.text(id: "late", text: "Old text", replace: true))
        first.finish(); await settle()
        XCTAssertEqual(store.statuses[id], .running, "old cleanup must not finish the new turn")
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertTrue(store.approvals[id]?.isEmpty != false)
        XCTAssertFalse(store.selectedConversation?.messages.contains { $0.id == "late" } == true)
        second.finish(); await settle()
    }

    @MainActor func testLatePermissionResponsesCannotClearNextTurnsPermission() async throws {
        for answering in [false, true] {
            let (store, _, folder, drivers) = fixture()
            defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
            let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
            store.send("primero"); await settle()
            let first = try XCTUnwrap(drivers().first)
            first.holdResponses = true
            first.callback?(.approval(ChatApproval(id: "permission", title: "Primero", detail: "")))
            if answering { store.answer(conversationID: id, approvalID: "permission", answers: ["q": "yes"]) }
            else { store.respond(conversationID: id, approvalID: "permission", allow: true) }
            await settle()
            let response = try XCTUnwrap(first.responseContinuation)
            first.callback?(.completed); first.finish(); await settle()
            store.send("segundo"); await settle()
            let second = try XCTUnwrap(drivers().last)
            second.callback?(.approval(ChatApproval(id: "permission", title: "Segundo", detail: "")))
            response.resume(); first.responseContinuation = nil
            await settle()
            XCTAssertEqual(store.statuses[id], .waiting)
            XCTAssertEqual(store.approvals[id]?.first?.title, "Segundo")
            second.finish(); await settle()
        }
    }

    @MainActor func testProtocolCompletionFlushesHiddenLightChat() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setLightMode(true)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        store.send("primero"); await settle()
        let driver = try XCTUnwrap(drivers().first)
        store.create(projectPath: NSTemporaryDirectory(), provider: .claude)
        store.setLightWindowVisible(false)
        driver.callback?(.text(id: "reply", text: "Listo", replace: true))
        driver.callback?(.completed)
        archive.flush()
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertEqual(try archive.load(id)?.messages.last?.text, "Listo")
        driver.finish(); await settle()
    }

    @MainActor func testStopReleasesSlotEvenIfDriverDoesNotReturn() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(1)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        store.send("primero"); await settle()
        let first = try XCTUnwrap(drivers().first)
        first.finishesOnStop = false
        first.callback?(.tool(id: "tool", title: "Bash", detail: "sleep 30", status: "running"))
        store.send("pendiente", to: id)
        store.stop(id)
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertEqual(store.recalled[id]?.text, "pendiente")
        XCTAssertEqual(store.selectedConversation?.messages.last?.status, "interrupted")
        store.send("segundo"); await settle()
        XCTAssertEqual(drivers().count, 2)
        first.callback?(.completed)
        first.callback?(.approvalResolved("late"))
        first.finish(); await settle()
        XCTAssertEqual(store.statuses[id], .running)
        XCTAssertEqual(store.activeCount, 1)
        drivers().last?.finish(); await settle()
    }

    @MainActor func testStopBeforeStartupDoesNotLaunchDriver() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        store.send("primero")
        store.stop(id)
        await settle()
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertNil(drivers().first?.callback, "a cancelled task must not launch a provider")
    }

    @MainActor func testPermissionResponseAndStopAreScopedToConversation() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .claude); store.send("Run")
        await settle()
        let id = try XCTUnwrap(store.selectedID), driver = try XCTUnwrap(drivers().first)
        driver.callback?(.approval(ChatApproval(id: "permission", title: "Run command", detail: "echo hello")))
        XCTAssertEqual(store.statuses[id], .waiting)
        store.respond(conversationID: id, approvalID: "permission", allow: false); await settle()
        XCTAssertEqual(driver.answers.first?.0, "permission")
        XCTAssertEqual(driver.answers.first?.1, false)
        XCTAssertTrue(store.approvals[id]?.isEmpty == true)
        store.stop(id); await settle()
        XCTAssertTrue(driver.stopped)
        XCTAssertEqual(store.activeCount, 0)
    }
    @MainActor func testInactiveHistoryUnloadsAndRenameSurvivesReload() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .codex); store.send("First")
        await settle()
        let first = try XCTUnwrap(store.selectedID)
        drivers()[0].callback?(.text(id: "reply", text: "Saved reply", replace: false))
        drivers()[0].finish(); await settle()
        store.create(projectPath: NSTemporaryDirectory(), provider: .claude)
        XCTAssertTrue(store.conversations.first { $0.id == first }?.messages.isEmpty == true)
        store.rename(first, title: "Renamed")
        store.updateSettings(id: first, model: "another-model", effort: "low")
        store.select(first); archive.flush()
        XCTAssertEqual(store.selectedConversation?.title, "Renamed")
        XCTAssertEqual(store.selectedConversation?.model, "another-model")
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "Saved reply")
        let restored = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in ControlledDriver() })
        restored.select(first)
        XCTAssertEqual(restored.selectedConversation?.title, "Renamed")
        XCTAssertEqual(restored.selectedConversation?.messages.last?.text, "Saved reply")
        restored.shutdown()
    }
    @MainActor func testLightKeepsItsExistingLocatorInsteadOfNormalsNewAutomaticRouting() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("LightProject")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.setLightMode(true)
        _ = try XCTUnwrap(store.create(projectPath: project.path, provider: .claude))
        var requests: [String] = []
        store.locateProject = { request, _, _, _, _ in requests.append(request); return nil }
        let id = try XCTUnwrap(store.createLocating("arregla LightProject", provider: .claude, projects: [project.path]))
        await settle()
        XCTAssertEqual(requests, ["arregla LightProject"], "Light still asks its existing locator, even for a known project")
        XCTAssertTrue(store.isUnplaced(id))
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertTrue(drivers().isEmpty, "Normal's new automatic routing must not start an agent in Light")
    }
    @MainActor func testLightParallelismDoesNotOverwriteNormalOrInterruptRunningAgents() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let first = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("uno", to: first)
        let second = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("dos", to: second)
        await settle()
        XCTAssertEqual(store.activeCount, 2)
        store.setLightMode(true)
        XCTAssertEqual(store.maxConcurrent, 2)
        XCTAssertEqual(store.effectiveMaxConcurrent, 1)
        XCTAssertEqual(store.activeCount, 2, "entering Light does not stop existing work")
        let third = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("tres", to: third)
        await settle()
        XCTAssertEqual(store.statuses[third], .queued)
        XCTAssertEqual(drivers().count, 2)
        store.setLightConcurrency(4)
        await settle()
        XCTAssertEqual(store.activeCount, 3)
        XCTAssertEqual(drivers().last?.energySavingChanges, [true])
        store.setLightMode(false)
        XCTAssertEqual(store.maxConcurrent, 2)
        XCTAssertEqual(store.effectiveMaxConcurrent, 2)
        XCTAssertEqual(store.lightMaxConcurrent, 4)
        XCTAssertTrue(drivers().allSatisfy { !$0.stopped })
        XCTAssertTrue(drivers().allSatisfy { $0.energySavingChanges.last == false })
    }
    @MainActor func testLightBuffersHiddenDetailsButKeepsThemWhenReturningToNormal() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setLightMode(true)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("hola", to: id)
        await settle()
        let driver = try XCTUnwrap(drivers().first)
        driver.callback?(.reasoning(id: "thinking", text: "detalle", replace: false))
        driver.callback?(.tool(id: "command", title: "echo hola", detail: "", status: "running"))
        driver.callback?(.toolOutput(id: "command", text: "hola"))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(store.selectedConversation?.messages.map(\.role), ["user"], "hidden details do not schedule view updates")
        store.setLightMode(false)
        XCTAssertEqual(store.selectedConversation?.messages.map(\.role), ["user", "reasoning", "tool"])
        XCTAssertEqual(store.selectedConversation?.messages.last?.detail, "hola")
        driver.callback?(.text(id: "reply", text: "respuesta", replace: false))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "respuesta", "Normal resumes its existing stream cadence")
    }
    @MainActor func testLightInvisibleTextResumesAndPermissionsRemainImmediate() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setLightMode(true)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("hola", to: id)
        await settle()
        let driver = try XCTUnwrap(drivers().first)
        store.setLightWindowVisible(false)
        driver.callback?(.text(id: "reply", text: "🙂 primero", replace: false))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(store.selectedConversation?.messages.count, 1)
        store.setLightWindowVisible(true)
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "🙂 primero")
        store.setLightWindowVisible(false)
        driver.callback?(.text(id: "reply", text: " segundo", replace: false))
        driver.callback?(.approval(ChatApproval(id: "ask", title: "Permiso", detail: "echo hola")))
        XCTAssertEqual(store.statuses[id], .waiting)
        XCTAssertEqual(store.approvals[id]?.first?.id, "ask")
        driver.finish(); await settle()
        archive.flush()
        XCTAssertEqual(try archive.load(id)?.messages.last?.text, "🙂 primero segundo", "finishing a hidden turn persists all text")
    }
    @MainActor func testLightDetailsCanBeOpenedDuringATurn() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setLightMode(true)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("hola", to: id); await settle()
        let driver = try XCTUnwrap(drivers().first)
        driver.callback?(.tool(id: "command", title: "Build", detail: "inicio", status: "running"))
        store.setLightDetailsVisible(true)
        XCTAssertEqual(store.selectedConversation?.messages.last?.detail, "inicio")
        driver.callback?(.toolOutput(id: "command", text: " fin"))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(store.selectedConversation?.messages.last?.detail, "inicio fin")
    }
    @MainActor func testLightHiddenChatsKeepTheirTextUntilSelectedAndBoundToolOutput() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setLightMode(true); store.setLightConcurrency(2)
        let hidden = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("primero", to: hidden); await settle()
        let visible = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("segundo", to: visible); await settle()
        drivers()[0].callback?(.text(id: "hidden", text: "a", replace: false))
        drivers()[0].callback?(.text(id: "hidden", text: "b", replace: false))
        drivers()[1].callback?(.text(id: "visible", text: "respuesta", replace: false))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(store.conversations.first { $0.id == hidden }?.messages.count, 1)
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "respuesta")
        store.select(hidden)
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "ab")
        drivers()[0].callback?(.text(id: "hidden", text: "snapshot", replace: true))
        drivers()[0].callback?(.text(id: "hidden", text: " + delta", replace: false))
        drivers()[0].callback?(.tool(id: "command", title: "log", detail: "", status: "running"))
        for _ in 0..<20 { drivers()[0].callback?(.toolOutput(id: "command", text: String(repeating: "x", count: 8192))) }
        drivers()[0].finish(); await settle(); archive.flush()
        let messages = try XCTUnwrap(archive.load(hidden)?.messages)
        XCTAssertEqual(messages.first { $0.id == "hidden" }?.text, "snapshot + delta")
        XCTAssertEqual(messages.last?.detail.count, 65_536)
    }
    @MainActor func testLightBatchesTextForOneSecondButPermissionsAndCompletionRemainImmediate() async throws {
        let (store, archive, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setLightMode(true)
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude))
        store.send("hola", to: id); await settle()
        let driver = try XCTUnwrap(drivers().first)
        driver.callback?(.text(id: "reply", text: "uno", replace: false))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.selectedConversation?.messages.map(\.role), ["user"], "Light no longer flushes at 250 ms")
        driver.callback?(.text(id: "reply", text: " dos", replace: false))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "uno dos", "the timer batches all deltas after one second")

        driver.callback?(.text(id: "reply", text: " permiso", replace: false))
        driver.callback?(.approval(ChatApproval(id: "ask", title: "Permiso", detail: "echo hola")))
        XCTAssertEqual(store.approvals[id]?.first?.id, "ask")
        XCTAssertEqual(store.statuses[id], .waiting)
        XCTAssertEqual(store.selectedConversation?.messages.last?.text, "uno dos permiso", "permissions flush pending text immediately")

        driver.callback?(.text(id: "reply", text: " final", replace: false))
        driver.finish(); await settle(); archive.flush()
        XCTAssertEqual(store.statuses[id], .idle)
        XCTAssertEqual(try archive.load(id)?.messages.last?.text, "uno dos permiso final", "completion saves the last delta without waiting a second")
    }
    @MainActor private func settle() async { for _ in 0..<8 { await Task.yield() }; try? await Task.sleep(nanoseconds: 10_000_000) }
    @MainActor func testIncreasingParallelismDrainsQueueAndUnlimitedDoesNotCancelActiveRuns() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        for i in 0..<5 { store.create(projectPath: NSTemporaryDirectory(), provider: .codex); store.send("Task \(i)") }
        await settle()
        XCTAssertEqual(store.activeCount, 2)
        store.setConcurrency(4); await settle()
        XCTAssertEqual(store.activeCount, 4)
        store.setConcurrency(1); await settle()
        XCTAssertEqual(store.activeCount, 4)
        XCTAssertFalse(drivers().contains { $0.stopped })
        store.setConcurrency(0); await settle()
        XCTAssertEqual(store.activeCount, 5)
        drivers().forEach { $0.finish() }; await settle()
    }
    @MainActor func testReasoningAndLiveToolOutputAreCoalescedAndStoredSeparately() async throws {
        let (store, _, folder, drivers) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .codex); store.send("Analyze")
        await settle()
        let driver = try XCTUnwrap(drivers().first)
        driver.callback?(.reasoning(id: "r", text: "Inspect ", replace: false))
        driver.callback?(.reasoning(id: "r", text: "files", replace: false))
        driver.callback?(.tool(id: "t", title: "Read", detail: "file.swift\n", status: "running"))
        driver.callback?(.toolOutput(id: "t", text: "line one\n"))
        driver.callback?(.toolOutput(id: "t", text: "line two"))
        driver.callback?(.tool(id: "t", title: "Read", detail: "", status: "completed"))
        driver.finish(); await settle()
        let messages = try XCTUnwrap(store.selectedConversation?.messages)
        XCTAssertEqual(messages.first { $0.id == "r" }?.role, "reasoning")
        XCTAssertEqual(messages.first { $0.id == "r" }?.text, "Inspect files")
        XCTAssertEqual(messages.first { $0.id == "t" }?.detail, "file.swift\nline one\nline two")
        XCTAssertEqual(messages.first { $0.id == "t" }?.status, "completed")
    }
}
