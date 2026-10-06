import XCTest
@testable import JackCore

final class ChatRunConfigurationTests: XCTestCase {
    func testCodexPlanAndAutoUseNativeSettings() throws {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .codex)
        conversation.mode = "plan"
        let plan = ChatRunConfiguration.codexTurn(conversation, threadID: "thread", prompt: "Plan this")
        let collaboration = try XCTUnwrap(plan["collaborationMode"] as? [String: Any])
        XCTAssertEqual(collaboration["mode"] as? String, "plan")
        XCTAssertEqual((collaboration["settings"] as? [String: Any])?["reasoning_effort"] as? String, "high")
        conversation.mode = "auto"
        let auto = ChatRunConfiguration.codexTurn(conversation, threadID: "thread", prompt: "Implement")
        XCTAssertEqual(auto["approvalPolicy"] as? String, "never")
        XCTAssertEqual((auto["sandboxPolicy"] as? [String: Any])?["type"] as? String, "workspaceWrite")
        conversation.mode = "default"
        XCTAssertEqual(ChatRunConfiguration.codexTurn(conversation, threadID: "thread", prompt: "Continue")["approvalPolicy"] as? String, "on-request")
    }
    func testOpenCodeModeAndEffortAreSentAsAgentAndVariant() throws {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .opencode, model: "google/gemini-test")
        conversation.mode = "plan"; conversation.variant = "high"
        let body = ChatRunConfiguration.openCodePrompt(conversation, prompt: "Plan")
        XCTAssertEqual(body["agent"] as? String, "plan")
        XCTAssertEqual(body["variant"] as? String, "high")
        XCTAssertEqual((body["model"] as? [String: String])?["providerID"], "google")
        conversation.mode = nil; conversation.variant = nil
        let automatic = ChatRunConfiguration.openCodePrompt(conversation, prompt: "Continue")
        XCTAssertNil(automatic["variant"])
        XCTAssertNil(automatic["agent"])
    }
    func testClaudeUsesSelectedPermissionMode() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude)
        conversation.mode = "auto"
        XCTAssertEqual(ChatRunConfiguration.claudeSettings(conversation).prefix(2), ["--permission-mode", "auto"])
        conversation.mode = "plan"
        XCTAssertEqual(ChatRunConfiguration.claudeSettings(conversation).prefix(2), ["--permission-mode", "plan"])
    }
    func testClaudeEffortIsOnlySentToModelsThatSupportIt() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .claude, model: "opus", effort: "xhigh")
        XCTAssertEqual(ChatRunConfiguration.claudeSettings(conversation).suffix(2), ["--effort", "xhigh"])
        conversation.model = "haiku"
        XCTAssertFalse(ChatRunConfiguration.claudeSettings(conversation).contains("--effort"))
        conversation.model = "claude-opus-4-6"
        XCTAssertFalse(ChatRunConfiguration.claudeSettings(conversation).contains("--effort"))
        conversation.effort = "max"
        XCTAssertEqual(ChatRunConfiguration.claudeSettings(conversation).suffix(2), ["--effort", "max"])
    }
    func testClaudeEffortLevelsPerModel() {
        XCTAssertEqual(ChatModelChoice.claudeCatalog.map(\.id), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "sonnet"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-fable-5-1"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-haiku-4-5"), [])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-sonnet-4-5"), [])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-opus-4-5"), ["low", "medium", "high"])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-sonnet-4-6"), ["low", "medium", "high", "max"])
    }
    func testCodexPlanningQuestionsAreSurfacedAndRetainRPCID() throws {
        var session: String?
        var approvals: [String: PendingApproval] = [:]
        let events = CodexProtocol.event(["id": 77, "method": "item/tool/requestUserInput", "params": [
            "questions": [["id": "scope", "header": "Scope", "question": "Which scope?", "options": [["label": "Small", "description": "Focused change"]]]]
        ]], session: &session, approvals: &approvals)
        guard case .approval(let request) = events.first else { return XCTFail("Expected planning question") }
        XCTAssertEqual(request.questions.first?.id, "scope")
        XCTAssertEqual(request.questions.first?.options?.first?.label, "Small")
        XCTAssertEqual(approvals[request.id]?.payload["rpcID"] as? Int, 77)
    }
    @MainActor func testModeAndVariantPersistAndChangingModelResetsVariant() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = ChatArchive(directory: folder)
        let store = ChatStore(archive: archive, preferences: nil)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.create(projectPath: NSTemporaryDirectory(), provider: .opencode, model: "google/a")
        let id = try XCTUnwrap(store.selectedID)
        store.updateMode(id: id, mode: "plan", supported: [.init(id: "plan", title: "Plan")])
        store.updateVariant(id: id, variant: "high", supported: ["low", "high"])
        store.updateVariant(id: id, variant: "invalid", supported: ["low", "high"])
        archive.flush()
        XCTAssertEqual(try archive.load(id)?.mode, "plan")
        XCTAssertEqual(try archive.load(id)?.variant, "high")
        store.updateSettings(id: id, model: "google/b", effort: "high")
        XCTAssertNil(store.selectedConversation?.variant)
        XCTAssertEqual(store.selectedConversation?.mode, "plan")
    }

    func testDelegationConfigPointsEveryProviderAtJacksServer() throws {
        let delegation = ChatDelegation(url: URL(string: "http://127.0.0.1:4321/mcp")!, token: "secret-token")

        let claude = ChatRunConfiguration.claudeDelegation(delegation)
        let claudeConfig = try XCTUnwrap(claude.firstIndex(of: "--mcp-config").map { claude[$0 + 1] })
        let claudeServer = try XCTUnwrap(((JSONSerialization.jsonObject(with: Data(claudeConfig.utf8)) as? [String: Any])?["mcpServers"] as? [String: Any])?["jack"] as? [String: Any])
        XCTAssertEqual(claudeServer["url"] as? String, "http://127.0.0.1:4321/mcp")
        XCTAssertEqual((claudeServer["headers"] as? [String: String])?["Authorization"], "Bearer secret-token")
        XCTAssertEqual(claude.firstIndex(of: "--allowedTools").map { claude[$0 + 1] }, "mcp__jack")

        let codex = ChatRunConfiguration.codexDelegation(delegation)
        XCTAssertTrue(codex.contains("mcp_servers.jack.url=\"http://127.0.0.1:4321/mcp\""))
        XCTAssertTrue(codex.contains("mcp_servers.jack.bearer_token_env_var=\"JACK_MCP_TOKEN\""))
        XCTAssertFalse(codex.joined().contains("secret-token"), "Codex reads the token from the environment")

        let openCode = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ChatRunConfiguration.openCodeDelegation(delegation).utf8)) as? [String: Any])
        let server = try XCTUnwrap((openCode["mcp"] as? [String: Any])?["jack"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "remote")
        XCTAssertEqual(server["url"] as? String, "http://127.0.0.1:4321/mcp")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer secret-token")
    }
    func testExtraDirectoriesReachEveryProvider() throws {
        var conversation = ChatConversation(projectPath: "/work/app", provider: .claude, model: "opus")
        XCTAssertFalse(ChatRunConfiguration.claudeSettings(conversation).contains("--add-dir"))
        XCTAssertNil(ChatRunConfiguration.openCodeConfig(conversation, delegation: nil))
        conversation.extraDirectories = ["/work/lib", "/work/app", "/work/lib", "/work/docs"]
        XCTAssertEqual(conversation.additionalDirectories, ["/work/lib", "/work/docs"])

        let claude = ChatRunConfiguration.claudeSettings(conversation)
        XCTAssertEqual(Array(claude.prefix(4)), ["--add-dir", "/work/lib", "--add-dir", "/work/docs"])
        XCTAssertTrue(claude[4].hasPrefix("--"), "the variadic --add-dir must be closed by another flag")

        let codex = ChatRunConfiguration.codexTurn(conversation, threadID: "thread", prompt: "Hi")
        XCTAssertEqual((codex["sandboxPolicy"] as? [String: Any])?["writableRoots"] as? [String],
                       ["/work/app", "/work/lib", "/work/docs", ProgressFiles.directory(for: conversation.id).path], "the last one lets jack-progress report from the sandbox")

        let config = try XCTUnwrap(ChatRunConfiguration.openCodeConfig(conversation, delegation: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let rules = try XCTUnwrap((object["permission"] as? [String: Any])?["external_directory"] as? [String: String])
        XCTAssertEqual(rules["/work/lib/**"], "allow")
        XCTAssertEqual(rules["/work/docs"], "allow")
        XCTAssertNil(object["mcp"])
    }
    func testAttachmentsReachEveryProvider() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("captura.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]).write(to: image)
        let notes = folder.appendingPathComponent("notas.txt")
        try Data("hola".utf8).write(to: notes)

        var conversation = ChatConversation(projectPath: "/work/app", provider: .claude, model: "opus")
        conversation.messages = [ChatMessage(role: "user", text: "Mira esto", attachments: [image.path, notes.path])]
        XCTAssertEqual(conversation.attachmentDirectories, [folder.path])

        let blocks = try XCTUnwrap(ChatRunConfiguration.claudeContent(conversation, prompt: "Mira esto") as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2, "text plus one image; the text file travels as a path")
        XCTAssertTrue((blocks[0]["text"] as? String)?.contains(notes.path) == true)
        XCTAssertEqual((blocks[1]["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        XCTAssertEqual(Array(ChatRunConfiguration.claudeSettings(conversation).prefix(2)), ["--add-dir", folder.path])

        let codex = try XCTUnwrap(ChatRunConfiguration.codexTurn(conversation, threadID: "t", prompt: "Mira esto")["input"] as? [[String: Any]])
        XCTAssertEqual(codex.last?["type"] as? String, "localImage")
        XCTAssertEqual(codex.last?["path"] as? String, image.path)

        let parts = try XCTUnwrap(ChatRunConfiguration.openCodePrompt(conversation, prompt: "Mira esto")["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["mime"] as? String, "image/png")
        XCTAssertTrue((parts.last?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)

        conversation.messages.append(ChatMessage(role: "assistant", text: "Visto"))
        XCTAssertEqual(ChatRunConfiguration.claudeContent(conversation, prompt: "Sigue") as? String, "Sigue")
    }
}
