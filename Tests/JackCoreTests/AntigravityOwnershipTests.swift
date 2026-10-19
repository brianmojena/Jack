import XCTest
import Combine
@testable import JackCore

@MainActor private final class AntigravityHoldingDriver: ChatDriver {
    var continuation: CheckedContinuation<Void, Never>?
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func answer(approvalID: String, answers: [String: String]) async throws {}
    func stop() { continuation?.resume(); continuation = nil }
}

final class AntigravityOwnershipTests: XCTestCase {
    @MainActor private func fixture() throws -> (ChatStore, ChatArchive, URL, UUID, UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = ChatArchive(directory: directory)
        var first = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .antigravity)
        first.sessionID = "shared-session"
        var second = first
        second.id = UUID()
        archive.save(index: [first, second]); archive.flush()
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in AntigravityHoldingDriver() })
        store.loadAntigravityModels = { _ in [] }
        store.antigravityDelegationProvider = { _, _, _, _ in nil }
        return (store, archive, directory, first.id, second.id)
    }

    @MainActor func testOwnershipBlocksBothChatsAndAsidesUntilReleased() throws {
        let (store, archive, directory, first, second) = try fixture()
        defer { store.shutdown(); archive.flush(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.claimAntigravitySessionForTerminal(first))
        XCTAssertFalse(store.claimAntigravitySessionForTerminal(second))
        XCTAssertFalse(store.canSend(to: first))
        XCTAssertFalse(store.canSend(to: second))
        let messages = store.conversations.map(\.messages)
        store.send("blocked", to: second)
        store.askAside("blocked", in: first)
        XCTAssertEqual(store.conversations.map(\.messages), messages)
        XCTAssertNil(store.asides.items[first])
        var refreshes = 0
        let observation = store.objectWillChange.sink { refreshes += 1 }
        store.releaseAntigravitySessionFromTerminal(first)
        XCTAssertGreaterThan(refreshes, 0, "The composer must refresh when the terminal gives the session back")
        withExtendedLifetime(observation) {}
        XCTAssertTrue(store.canSend(to: second))
        XCTAssertTrue(store.claimAntigravitySessionForTerminal(second))
    }

    @MainActor func testBusyDuplicateCannotBeClaimed() async throws {
        let (store, archive, directory, first, second) = try fixture()
        defer { store.shutdown(); archive.flush(); try? FileManager.default.removeItem(at: directory) }
        store.send("held turn", to: second)
        XCTAssertTrue(store.isBusy(second))
        XCTAssertFalse(store.claimAntigravitySessionForTerminal(first))
        store.stop(second)
        for _ in 0..<100 { await Task.yield() }
    }

    @MainActor func testEnvironmentRejectsReleaseAndReclaimWhileAwaitingDelegation() async throws {
        let (store, archive, directory, first, _) = try fixture()
        defer { store.shutdown(); archive.flush(); try? FileManager.default.removeItem(at: directory) }
        var pending: CheckedContinuation<ChatDelegation?, Never>?
        var installed = false
        store.antigravityDelegationProvider = { _, _, _, _ in await withCheckedContinuation { pending = $0 } }
        store.antigravityEnvironmentBuilder = { _ in installed = true; return [:] }
        XCTAssertTrue(store.claimAntigravitySessionForTerminal(first))
        let task = Task { try await store.antigravityTerminalEnvironment(first) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let resume = try XCTUnwrap(pending)
        store.releaseAntigravitySessionFromTerminal(first)
        XCTAssertTrue(store.claimAntigravitySessionForTerminal(first))
        resume.resume(returning: ChatDelegation(url: URL(string: "http://127.0.0.1:9/mcp")!, token: "fixture", normalMode: true))
        do { _ = try await task.value; XCTFail("stale preparation succeeded") } catch {}
        XCTAssertFalse(installed)
    }

    @MainActor func testSwitchToLightInvalidatesPreparationAndPreventsMCPTools() async throws {
        let (store, archive, directory, first, _) = try fixture()
        defer { store.bridge.stop(); store.shutdown(); archive.flush(); try? FileManager.default.removeItem(at: directory) }
        let delegation = ChatDelegation(url: URL(string: "http://127.0.0.1:9/mcp")!, token: "fixture", normalMode: true)
        XCTAssertFalse(delegation.token.isEmpty)
        XCTAssertTrue(store.claimAntigravitySessionForTerminal(first))
        var pending: CheckedContinuation<ChatDelegation?, Never>?
        var installed = false
        store.antigravityDelegationProvider = { _, _, _, _ in await withCheckedContinuation { pending = $0 } }
        store.antigravityEnvironmentBuilder = { _ in installed = true; return [:] }
        let task = Task { try await store.antigravityTerminalEnvironment(first) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let resume = try XCTUnwrap(pending)
        store.setLightMode(true)
        resume.resume(returning: delegation)
        do { _ = try await task.value; XCTFail("Light preparation succeeded") } catch {}
        XCTAssertFalse(installed)
        XCTAssertFalse(store.claimAntigravitySessionForTerminal(first))
        let response = await store.bridge.rpc(["id": 1, "method": "tools/list"], caller: first)
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 0)
        let call = await store.bridge.call("list_agents", arguments: [:], caller: first)
        XCTAssertTrue(call.1)
        XCTAssertTrue(call.0.contains("Normal"))
    }

    func testNativeArgumentsAndLegacyMetadata() throws {
        var chat = ChatConversation(projectPath: "/tmp/project with spaces", provider: .antigravity, model: "", effort: "")
        chat.sessionID = "real-session"
        chat.mode = "auto"
        chat.extraDirectories = ["/tmp/extra", "/tmp/extra"]
        let arguments = TerminalWorkspaceEntry.antigravityArguments(conversation: chat)
        XCTAssertEqual(arguments, ["--conversation", "real-session", "--mode", "auto", "--add-dir", "/tmp/extra"])
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        let entry = TerminalWorkspaceEntry(title: "legacy", projectPath: "/tmp", kind: .claude)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertNil(decoded.antigravitySessionID)
        XCTAssertNil(decoded.antigravityConversationID)
        let native = TerminalWorkspaceEntry(title: "agy", projectPath: "/tmp", kind: .antigravity,
                                             antigravityConversationID: chat.id, antigravitySessionID: chat.sessionID)
        XCTAssertEqual(try JSONDecoder().decode(TerminalWorkspaceEntry.self, from: JSONEncoder().encode(native)), native)
    }
}
