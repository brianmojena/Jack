import XCTest
@testable import JackCore

@MainActor private final class MentionTestDriver: ChatDriver {
    var callback: (@MainActor (ChatEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var lastPrompt: String?
    var supportsInjection = false
    var approvalResponses: [(String, Bool)] = []
    private var injected: Set<String> = []
    var keepsAlive: Bool { supportsInjection }

    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        lastPrompt = prompt
        callback = onEvent
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws { approvalResponses.append((approvalID, allow)) }
    func stop() { finish() }
    func finish() { continuation?.resume(); continuation = nil }
    func inject(_ message: ChatQueuedMessage, conversation: ChatConversation) -> Bool {
        guard supportsInjection else { return false }
        injected.insert(message.id)
        return true
    }
    func isQueued(_ messageID: String) -> Bool { injected.contains(messageID) }
}

final class AgentMentionsTests: XCTestCase {
    @MainActor func testMentionSyntaxAndSuggestionsUseStableProjectScopedIDs() throws {
        let project = "/tmp/project"
        let root = ChatConversation(id: UUID(), projectPath: project)
        let existing = ChatConversation(id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!, title: "Review", projectPath: project, provider: .claude)
        let elsewhere = ChatConversation(id: UUID(), title: "Other project", projectPath: "/tmp/elsewhere")

        XCTAssertEqual(AgentMentions.query(in: "@cla"), "cla")
        XCTAssertNil(AgentMentions.query(in: "@cla "), "A completed mention with trailing whitespace must close the list")
        XCTAssertNil(AgentMentions.query(in: " @cla"), "Mentions with leading whitespace are not composer routes")
        XCTAssertNil(AgentMentions.query(in: "Please check @cla"), "An @ in the middle remains ordinary text")
        XCTAssertNil(AgentMentions.query(in: "@cla then continue"))
        XCTAssertEqual(AgentMentions.leadingRoute(in: "@claude Review this")?.message, "Review this")
        XCTAssertNil(AgentMentions.leadingRoute(in: " @claude Review this"))
        XCTAssertNil(AgentMentions.leadingRoute(in: "Please ask @claude later"))
        XCTAssertEqual(AgentMentions.completing("@cla", with: "@claude "), "@claude ")
        XCTAssertNil(AgentMentions.query(in: AgentMentions.completing("@cla", with: "@claude ")))
        XCTAssertEqual(AgentMentions.completing("Please @cla", with: "@claude "), "Please @cla", "Invalid completion cannot append a second mention")

        let options = AgentMentions.options(for: "rev", conversations: [root, existing, elsewhere], projectPath: project, excluding: root.id)
        XCTAssertEqual(options.map(\.id), ["agent:12345678-1234-1234-1234-123456789abc"])
        XCTAssertEqual(options.first?.insertion, "@12345678 ")
        XCTAssertFalse(options.contains { $0.title == elsewhere.title })

        let collideA = ChatConversation(id: UUID(uuidString: "abcdef12-0000-0000-0000-000000000001")!, title: "A", projectPath: project)
        let collideB = ChatConversation(id: UUID(uuidString: "abcdef12-1000-0000-0000-000000000001")!, title: "B", projectPath: project)
        let collisionOptions = AgentMentions.options(for: "abcdef12", conversations: [root, collideA, collideB], projectPath: project, excluding: root.id)
        XCTAssertEqual(Set(collisionOptions.map(\.insertion)), ["@abcdef12-0 ", "@abcdef12-1 "])
        XCTAssertTrue(collisionOptions.allSatisfy { option in
            guard let route = AgentMentions.leadingRoute(in: option.insertion + "task") else { return false }
            return AgentMentions.isAgentReference(route.reference)
        })

        let baseCreate = try XCTUnwrap(AgentBridge.tools.first { $0["name"] as? String == "create_agent" })
        let normalCreate = try XCTUnwrap(AgentBridge.normalTools.first { $0["name"] as? String == "create_agent" })
        let baseProperties = (baseCreate["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        let normalProperties = (normalCreate["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertNil(baseProperties?["context"], "Light's original MCP schema stays unchanged")
        XCTAssertNotNil(normalProperties?["context"], "Normal adds explicit selective context")
        let lightInstructions = ChatRunConfiguration.agentInstructions(delegating: true, normalMode: false) ?? ""
        XCTAssertFalse(lightInstructions.contains("Normal-mode delegation rules"), "Light does not get the new delegation behavior")
        let normalInstructions = ChatRunConfiguration.agentInstructions(delegating: true, normalMode: true) ?? ""
        XCTAssertTrue(normalInstructions.contains("Normal-mode delegation rules"))
    }

    @MainActor func testProviderMentionCreatesChildAndBusyReuseReportsJackQueue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mentions-" + UUID().uuidString)
        var drivers: [MentionTestDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in let driver = MentionTestDriver(); drivers.append(driver); return driver })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(2)
        let root = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))

        let result = try XCTUnwrap(store.routeMention("@claude Review the parser", from: root))
        guard case let .created(childID, .started) = result else { return XCTFail("Unexpected routing: \(result)") }
        XCTAssertEqual(store.conversations.first { $0.id == childID }?.parentID, root)
        XCTAssertEqual(store.conversations.first { $0.id == childID }?.provider, .claude)
        for _ in 0..<100 where drivers.first?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(drivers.first?.lastPrompt?.hasPrefix("Review the parser\n\n") == true)
        XCTAssertTrue(drivers.first?.lastPrompt?.hasSuffix(ChatDelegation.subAgentGuidance) == true,
                      "A user-created child receives the shared-folder guidance too")

        let followup = try XCTUnwrap(store.routeMention("@\(childID.uuidString.prefix(8)) Please add the missing edge cases", from: root))
        XCTAssertEqual(followup, .reused(conversationID: childID, delivery: .queuedUntilTurnEnds))
        XCTAssertEqual(store.waiting[childID]?.last?.text, "Please add the missing edge cases")
        XCTAssertFalse(store.waiting[childID]?.last?.sent ?? true, "A single-turn driver cannot accept mid-turn injection")
        drivers.first?.callback?(.completed)
        drivers.first?.finish()
        for _ in 0..<100 where drivers.last?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(drivers.last?.lastPrompt, "Please add the missing edge cases")
        drivers.last?.finish()
    }

    @MainActor func testCollidingAgentIDsRouteWithExtendedCanonicalPrefix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-collision-" + UUID().uuidString)
        let archive = ChatArchive(directory: folder)
        let project = NSTemporaryDirectory()
        let root = ChatConversation(id: UUID(uuidString: "fedcba98-0000-0000-0000-000000000001")!, projectPath: project)
        let first = ChatConversation(id: UUID(uuidString: "abcdef12-0000-0000-0000-000000000001")!, title: "First", projectPath: project)
        let second = ChatConversation(id: UUID(uuidString: "abcdef12-1000-0000-0000-000000000001")!, title: "Second", projectPath: project)
        for conversation in [root, first, second] { archive.save(index: [root, first, second], conversation: conversation) }
        archive.flush()
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in MentionTestDriver() })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }

        let result = try XCTUnwrap(store.routeMention("@abcdef12-0 Inspect", from: root.id))
        guard case let .reused(id, _) = result else { return XCTFail("Expected an existing agent route") }
        XCTAssertEqual(id, first.id)
        XCTAssertEqual(store.conversations.first { $0.id == first.id }?.messages.last?.text, "Inspect")
        XCTAssertNil(store.conversations.first { $0.id == second.id }?.messages.last)
    }

    @MainActor func testMentionCannotCrossProjectOrAgentBoundaryAndIsDisabledInLight() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-scope-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in MentionTestDriver() })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let root = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        let otherProjectPath = folder.appendingPathComponent("other", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: otherProjectPath, withIntermediateDirectories: true)
        let external = try XCTUnwrap(store.create(projectPath: otherProjectPath, provider: .claude, select: false))
        let sourceChild = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex, parentID: root, select: false))

        guard case .rejected = store.routeMention("@\(external.uuidString.prefix(8)) Work", from: root) else {
            return XCTFail("An agent in another project must not be addressable")
        }
        let childCount = store.conversations.filter { $0.parentID == root }.count
        guard case .rejected = store.routeMention("@claude !btw run", from: root) else {
            return XCTFail("Jack commands are not delegated as agent tasks")
        }
        XCTAssertEqual(store.conversations.filter { $0.parentID == root }.count, childCount)
        XCTAssertNil(store.routeMention(" @claude Work", from: root), "A leading space keeps the text out of routing")
        XCTAssertNil(store.routeMention("@opencode Work", from: sourceChild), "Sub-agents cannot use top-level @ routing recursively")

        store.setLightMode(true)
        XCTAssertNil(store.routeMention("@claude Work", from: root), "New mention routing is Normal-only")
        XCTAssertTrue(store.conversations.allSatisfy { $0.provider != .opencode }, "Light must not create a provider mention agent")
        store.setLightMode(false)
        store.shutdown()
        guard case .rejected = store.routeMention("@claude Work", from: root) else {
            return XCTFail("A stopped store must not report a routed task")
        }
    }

    @MainActor func testMCPFollowupQueuesForBusyChildAndCannotAddressUnrelatedConversation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-mcp-" + UUID().uuidString)
        var drivers: [MentionTestDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in let driver = MentionTestDriver(); driver.supportsInjection = true; drivers.append(driver); return driver })
        defer { store.shutdown(); store.bridge.stop(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(2)
        let project = NSTemporaryDirectory()
        let root = try XCTUnwrap(store.create(projectPath: project, provider: .claude))
        let child = try XCTUnwrap(store.create(projectPath: project, provider: .codex, parentID: root, select: false))
        let unrelated = try XCTUnwrap(store.create(projectPath: project, provider: .claude, select: false))
        store.send("first task", to: child)
        for _ in 0..<100 where drivers.first?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        drivers.first?.callback?(.approval(ChatApproval(id: "approve-edit", title: "Allow edit", detail: "Write file")))
        for _ in 0..<100 where store.approvals[child]?.isEmpty != false { try await Task.sleep(nanoseconds: 5_000_000) }
        let delegation = try await store.bridge.delegation(for: root)

        let (queued, queuedIsError) = await store.bridge.call("send_message", arguments: [
            "agent_id": child.uuidString.lowercased(), "message": "Follow up after your current step"
        ], caller: root)
        XCTAssertFalse(queuedIsError, queued)
        XCTAssertTrue(queued.contains("pending permission request remains unchanged"), queued)
        XCTAssertEqual(store.waiting[child]?.last?.text, "Follow up after your current step")
        XCTAssertFalse(store.waiting[child]?.last?.sent ?? true, "MCP follow-ups preserve pending approvals and stay in Jack's queue")
        XCTAssertEqual(store.approvals[child]?.map(\.id), ["approve-edit"])
        XCTAssertTrue(drivers.first?.approvalResponses.isEmpty == true, "An automated follow-up must not deny the user's pending permission")

        let (denied, isError) = await store.bridge.call("send_message", arguments: [
            "agent_id": unrelated.uuidString.lowercased(), "message": "Do something"
        ], caller: root)
        XCTAssertTrue(isError)
        XCTAssertTrue(denied.contains("No sub-agent"), denied)
        XCTAssertTrue(delegation.normalMode)
    }

    @MainActor func testMCPReportsConcurrencyQueueTerminalErrorAndStoppedStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-mcp-errors-" + UUID().uuidString)
        let archive = ChatArchive(directory: folder)
        let project = NSTemporaryDirectory()
        let root = ChatConversation(id: UUID(), projectPath: project, provider: .codex)
        let sessionID = UUID()
        var terminalAgent = ChatConversation(id: UUID(), title: "Terminal agent", projectPath: project, provider: .claude)
        terminalAgent.parentID = root.id
        terminalAgent.sessionID = sessionID.uuidString
        archive.save(index: [root, terminalAgent], conversation: root)
        archive.save(index: [root, terminalAgent], conversation: terminalAgent)
        archive.flush()
        let store = ChatStore(archive: archive, preferences: nil, driverFactory: { _ in MentionTestDriver() })
        defer { store.shutdown(); store.bridge.stop(); try? FileManager.default.removeItem(at: folder) }
        let delegation = try await store.bridge.delegation(for: root.id)
        XCTAssertTrue(store.claimClaudeSessionForTerminal(sessionID))

        let messageCount = store.conversations.first { $0.id == terminalAgent.id }?.messages.count
        let (terminalResult, terminalError) = await store.bridge.call("send_message", arguments: [
            "agent_id": terminalAgent.id.uuidString.lowercased(), "message": "Do this"
        ], caller: root.id)
        XCTAssertTrue(terminalError)
        XCTAssertTrue(terminalResult.contains("Terminal"), terminalResult)
        XCTAssertEqual(store.conversations.first { $0.id == terminalAgent.id }?.messages.count, messageCount)

        store.shutdown()
        let (stoppedResult, stoppedError) = await store.bridge.call("send_message", arguments: [
            "agent_id": terminalAgent.id.uuidString.lowercased(), "message": "Do this"
        ], caller: root.id)
        XCTAssertTrue(stoppedError)
        XCTAssertTrue(stoppedResult.contains("closing"), stoppedResult)
        XCTAssertTrue(delegation.normalMode)
    }

    @MainActor func testMCPSendMessageHandsFollowupToKeptAliveDriverWithoutApproval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-mcp-inject-" + UUID().uuidString)
        var drivers: [MentionTestDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in
                                  let driver = MentionTestDriver(); driver.supportsInjection = true; drivers.append(driver)
                                  return driver
                              })
        defer { drivers.forEach { $0.finish() }; store.shutdown(); store.bridge.stop(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(2)
        let project = NSTemporaryDirectory()
        let root = try XCTUnwrap(store.create(projectPath: project, provider: .claude))
        let child = try XCTUnwrap(store.create(projectPath: project, provider: .codex, parentID: root, select: false))
        store.send("first task", to: child)
        for _ in 0..<100 where drivers.first?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(store.approvals[child]?.isEmpty ?? true)
        _ = try await store.bridge.delegation(for: root)

        let (result, isError) = await store.bridge.call("send_message", arguments: [
            "agent_id": child.uuidString.lowercased(), "message": "Please also check the edge case"
        ], caller: root)
        XCTAssertFalse(isError, result)
        XCTAssertTrue(result.contains("handed to its driver"), result)
        XCTAssertEqual(store.waiting[child]?.last?.text, "Please also check the edge case")
        XCTAssertTrue(store.waiting[child]?.last?.sent == true)
    }

    @MainActor func testMCPDistinguishesAChildWaitingForAConcurrencySlot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-mcp-slot-" + UUID().uuidString)
        var drivers: [MentionTestDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in let driver = MentionTestDriver(); drivers.append(driver); return driver })
        defer { drivers.forEach { $0.finish() }; store.shutdown(); store.bridge.stop(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(1)
        let project = NSTemporaryDirectory()
        let root = try XCTUnwrap(store.create(projectPath: project, provider: .codex))
        let child = try XCTUnwrap(store.create(projectPath: project, provider: .claude, parentID: root, select: false))
        let blocker = try XCTUnwrap(store.create(projectPath: project, provider: .codex, select: false))
        store.send("occupy the only slot", to: blocker)
        for _ in 0..<100 where drivers.first?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        store.send("initial task", to: child)
        XCTAssertEqual(store.statuses[child], .queued)
        let delegation = try await store.bridge.delegation(for: root)

        let (result, isError) = await store.bridge.call("send_message", arguments: [
            "agent_id": child.uuidString.lowercased(), "message": "Follow up"
        ], caller: root)
        XCTAssertFalse(isError, result)
        XCTAssertTrue(result.contains("waiting for a free concurrency slot"), result)
        XCTAssertTrue(result.contains("follow-up will wait until that turn ends"), result)
        XCTAssertEqual(store.waiting[child]?.last?.text, "Follow up")
        XCTAssertTrue(delegation.normalMode)
    }

    @MainActor func testReusableDriverHandoffIsNotReportedAsDelivered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-inject-" + UUID().uuidString)
        var drivers: [MentionTestDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in let driver = MentionTestDriver(); driver.supportsInjection = true; drivers.append(driver); return driver })
        defer { drivers.forEach { $0.finish() }; store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.setConcurrency(2)
        let root = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        guard case let .created(childID, _) = try XCTUnwrap(store.routeMention("@opencode Start", from: root)) else {
            return XCTFail("Expected to create an OpenCode agent")
        }
        for _ in 0..<100 where drivers.first?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }

        let result = try XCTUnwrap(store.routeMention("@\(childID.uuidString.prefix(8)) Add a focused test", from: root))
        XCTAssertEqual(result, .reused(conversationID: childID, delivery: .handedToDriver))
        XCTAssertTrue(store.waiting[childID]?.last?.sent == true)
        XCTAssertTrue(drivers.first?.isQueued(store.waiting[childID]!.last!.id) == true)
        XCTAssertFalse(String(describing: result).localizedCaseInsensitiveContains("delivered"), "A handoff is not a driver read acknowledgement")
    }

    @MainActor func testManualMentionReportsDeclinedApprovalOnlyForKeptAliveDriver() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-mention-approval-" + UUID().uuidString)
        var driver: MentionTestDriver?
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil,
                              driverFactory: { _ in
                                  let created = MentionTestDriver(); created.supportsInjection = true; driver = created
                                  return created
                              })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let root = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        let child = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .claude, parentID: root, select: false))
        store.send("task", to: child)
        for _ in 0..<100 where driver?.lastPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        driver?.callback?(.approval(ChatApproval(id: "manual-approval", title: "Allow edit", detail: "Write file")))
        for _ in 0..<100 where store.approvals[child]?.isEmpty != false { try await Task.sleep(nanoseconds: 5_000_000) }

        let result = try XCTUnwrap(store.routeMention("@\(child.uuidString.prefix(8)) Apply the requested edit", from: root))
        XCTAssertEqual(result, .reused(conversationID: child, delivery: .declinedApproval))
        for _ in 0..<100 where driver?.approvalResponses.isEmpty != false { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(driver?.approvalResponses.first?.0, "manual-approval")
        XCTAssertEqual(driver?.approvalResponses.first?.1, false)
        XCTAssertTrue(store.waiting[child]?.isEmpty ?? true)
        driver?.finish()
    }
}
