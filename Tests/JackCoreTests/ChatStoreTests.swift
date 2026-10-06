import XCTest
@testable import JackCore

@MainActor private final class ControlledDriver: ChatDriver {
    var callback: (@MainActor (ChatEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var answers: [(String, Bool)] = []
    var stopped = false
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        callback = onEvent
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws { answers.append((approvalID, allow)) }
    func stop() { stopped = true; finish() }
    func finish() { continuation?.resume(); continuation = nil }
}

final class ChatStoreTests: XCTestCase {
    @MainActor private func fixture() -> (ChatStore, ChatArchive, URL, () -> [ControlledDriver]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-chat-tests-" + UUID().uuidString)
        let archive = ChatArchive(directory: folder)
        var drivers: [ControlledDriver] = []
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in let driver = ControlledDriver(); drivers.append(driver); return driver })
        store.setConcurrency(2)
        return (store, archive, folder, { drivers })
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
