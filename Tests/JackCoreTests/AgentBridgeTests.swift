import XCTest
@testable import JackCore

@MainActor private final class DelegatingDriver: ChatDriver {
    var callback: (@MainActor (ChatEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var delegation: ChatDelegation?
    var prompt = ""
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        try await run(conversation: conversation, prompt: prompt, delegation: nil, onEvent: onEvent)
    }
    func run(conversation: ChatConversation, prompt: String, delegation: ChatDelegation?, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        self.delegation = delegation; self.prompt = prompt; callback = onEvent
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() { finish() }
    func finish() { continuation?.resume(); continuation = nil }
}

final class AgentBridgeTests: XCTestCase {
    @MainActor func testOrchestratorDelegatesWaitsAndReadsResultOverHTTP() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-bridge-tests-" + UUID().uuidString)
        let archive = ChatArchive(directory: folder)
        var drivers: [DelegatingDriver] = []
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in let driver = DelegatingDriver(); drivers.append(driver); return driver })
        defer { store.shutdown(); store.bridge.stop(); try? FileManager.default.removeItem(at: folder) }
        // One slot: the sub-agent can only run because a waiting orchestrator gives up its slot.
        store.setConcurrency(1)

        let project = NSTemporaryDirectory()
        let parent = try XCTUnwrap(store.create(projectPath: project, provider: .claude))
        store.send("Delegate the tests")
        try await until { drivers.first?.delegation != nil }
        let delegation = try XCTUnwrap(drivers[0].delegation)

        let unauthorized = try await post(delegation, token: "wrong", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        XCTAssertEqual(unauthorized.status, 401)

        let initialize = try await post(delegation, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertEqual((initialize.json?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let notification = try await post(delegation, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(notification.status, 202)
        let tools = try await post(delegation, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((tools.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names ?? []), ["create_agent", "send_message", "wait_for_agents", "get_agent_result", "list_agents", "stop_agent", "notebook_open", "notebook_run", "notebook_edit_cell", "notebook_kernel"])

        let created = try await callTool(delegation, "create_agent", ["provider": "codex", "task": "Write the tests", "title": "Tests"])
        XCTAssertTrue(created.contains("queued"), created)
        let child = try XCTUnwrap(store.conversations.first { $0.parentID == parent })
        XCTAssertEqual(child.title, "Tests")
        XCTAssertEqual(child.provider, .codex)
        XCTAssertEqual(store.selectedID, parent, "Delegating must not steal the user's selection")
        XCTAssertEqual(store.statuses[child.id], .queued)

        async let waited = callTool(delegation, "wait_for_agents", ["timeout_seconds": 30])
        try await until { drivers.count == 2 }
        XCTAssertTrue(drivers[1].prompt.hasPrefix("Write the tests"), drivers[1].prompt)
        XCTAssertTrue(drivers[1].prompt.hasSuffix(ChatDelegation.subAgentGuidance), "Every delegated task carries Jack's shared-folder notes")
        let childDelegation = try XCTUnwrap(drivers[1].delegation, "Sub-agents share the notebook in Normal mode")
        XCTAssertFalse(childDelegation.delegates, "Sub-agents never manage other agents")
        XCTAssertTrue(childDelegation.notebooks, "Sub-agents share the notebook in Normal mode")
        drivers[1].callback?(.text(id: "reply", text: "All 12 tests pass.", replace: true))
        drivers[1].callback?(.completed)
        drivers[1].finish()
        let summary = try await waited
        XCTAssertTrue(summary.contains("finished"), summary)

        let result = try await callTool(delegation, "get_agent_result", ["agent_id": String(child.id.uuidString.prefix(8))])
        XCTAssertTrue(result.contains("All 12 tests pass."), result)
        XCTAssertEqual(store.conversations.first { $0.id == child.id }?.hasUnread, true)
        drivers[0].finish()
    }

    // MARK: Helpers

    private struct Reply { var status: Int; var json: [String: Any]? }

    private func post(_ delegation: ChatDelegation, token: String? = nil, _ body: [String: Any]) async throws -> Reply {
        var request = URLRequest(url: delegation.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token ?? delegation.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, json: try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func callTool(_ delegation: ChatDelegation, _ name: String, _ arguments: [String: Any]) async throws -> String {
        let reply = try await post(delegation, ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let content = (reply.json?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
}
