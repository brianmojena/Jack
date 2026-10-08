import XCTest
@testable import JackCore

final class StellarCodeTests: XCTestCase {
    func testOnlyLocalServersAreAllowed() {
        for local in ["http://127.0.0.1:11434", "http://localhost:8080", "http://mac-studio.local:1234", "http://192.168.1.20:8000", "http://10.0.0.5", "http://172.20.1.1"] {
            XCTAssertTrue(StellarServer.isLocal(URL(string: local)!), local)
        }
        for remote in ["https://api.openai.com", "http://8.8.8.8", "http://172.32.0.1", "ftp://127.0.0.1", "https://ollama.com"] {
            XCTAssertFalse(StellarServer.isLocal(URL(string: remote)!), remote)
        }
    }

    func testModelIDsNameTheirServer() {
        XCTAssertEqual(StellarModels.resolve("ollama/gemma4:e2b")?.name, "gemma4:e2b")
        XCTAssertEqual(StellarModels.resolve("mlx/mlx-community/Qwen3-4B-4bit")?.name, "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(StellarModels.resolve("ollama/account/team/model:tag")?.name, "account/team/model:tag", "Ollama namespaces remain valid model names")
        XCTAssertNil(StellarModels.resolve("gpt-6-luna"))
        XCTAssertNil(StellarModels.resolve("ollama/"))
    }

    @MainActor func testOllamaCloudMetadataLinkingAndLightGates() throws {
        let localServer = StellarServer.builtIn[0]
        let local = try StellarModels.ollamaModel(named: "gemma4:e2b", show: ["capabilities": ["completion", "tools"]])
        XCTAssertEqual(local.id, "ollama/gemma4:e2b")
        XCTAssertFalse(local.isCloud)
        XCTAssertTrue(local.tools)

        let metadataCloud = try StellarModels.linkedCloudModel(named: "account/gemma4:31b", show: [
            "remote_host": "ollama.com", "remote_model": "gemma4:31b", "capabilities": ["completion", "tools"],
            "model_info": ["gemma4.context_length": 65_536]
        ])
        XCTAssertEqual(metadataCloud.id, "ollama/account/gemma4:31b", "an explicitly linked /api/show model does not need to appear in /api/tags")
        XCTAssertEqual(metadataCloud.server, localServer)
        XCTAssertTrue(metadataCloud.isCloud)
        XCTAssertTrue(metadataCloud.tools, "tools come from /api/show capabilities")
        XCTAssertEqual(metadataCloud.contextLength, 65_536)
        XCTAssertTrue(metadataCloud.title.contains("Nube"))

        let suffixCloud = try StellarModels.linkedCloudModel(named: "qwen3-coder:480b-cloud", show: ["capabilities": ["completion"]])
        XCTAssertTrue(suffixCloud.isCloud)
        XCTAssertFalse(suffixCloud.tools)
        XCTAssertFalse(StellarModels.isCloud(name: "qwen3:8b", metadata: [:]))
        XCTAssertTrue(StellarModels.isCloud(name: "account/model:latest", metadata: ["details": ["remote_model": "model"]]))
        XCTAssertFalse(StellarModels.shouldInspectOllamaTag(name: "account/model:latest", metadata: ["remote_host": "ollama.com"], includeCloud: false), "Light filters cloud tags before /api/show")
        XCTAssertTrue(StellarModels.shouldInspectOllamaTag(name: "account/model:latest", metadata: ["remote_host": "ollama.com"], includeCloud: true))
        XCTAssertThrowsError(try StellarModels.linkedCloudModel(named: "gemma4:e2b", show: ["capabilities": ["completion"]]))
        XCTAssertThrowsError(try StellarModels.linkedCloudModel(named: "https://example.com/gemma4:cloud", show: ["remote_host": "ollama.com"]))

        XCTAssertThrowsError(try StellarModels.requireCloudAllowed(name: "account/gemma4:31b", metadata: ["remote_model": "gemma4:31b"], includeCloud: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("solo están disponibles en modo Normal"))
        }
        XCTAssertNoThrow(try StellarModels.requireCloudAllowed(name: "gemma4:e2b", includeCloud: false))
        XCTAssertEqual(StellarModels.preferredLocalID(in: [metadataCloud, local]), local.id)
        XCTAssertEqual(StellarModels.preferredLocalID(in: [metadataCloud]), "", "a cloud model is never selected automatically")
        XCTAssertEqual(ChatStore.visibleStellarModels([metadataCloud, local], lightMode: true), [local])
        XCTAssertEqual(ChatStore.visibleStellarModels([metadataCloud, local], lightMode: false), [metadataCloud, local])

        let cloudRequest = StellarClient.requestPayload(server: localServer, model: metadataCloud.name,
                                                        messages: [StellarMessage(role: "user", content: "private project context")],
                                                        tools: StellarTools.normalDefinitions, contextLength: 16_384)
        XCTAssertEqual(cloudRequest.path, "/api/chat", "cloud requests go through the local Ollama daemon")
        XCTAssertEqual(cloudRequest.body["model"] as? String, metadataCloud.name)
        XCTAssertEqual((cloudRequest.body["messages"] as? [[String: Any]])?.first?["content"] as? String, "private project context")
        XCTAssertNotNil(cloudRequest.body["tools"], "capabilities from /api/show determine whether tools are passed")
        let request = try StellarHTTP.request(localServer, path: cloudRequest.path, body: cloudRequest.body, timeout: 10)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Jack never attaches cloud API keys")
    }

    @MainActor func testStellarAsideRejectsCloudBeforeNetworkInLightGate() async throws {
        let conversation = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .stellar, model: "ollama/gemma4:cloud")
        do {
            _ = try await StellarAside.ask("pregunta", prompt: "pregunta", about: conversation, allowCloud: false) { _ in }
            XCTFail("Light must reject cloud before calling Ollama")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("solo están disponibles en modo Normal"))
        }
        XCTAssertThrowsError(try StellarHTTP.request(StellarServer(id: "remote", title: "Remote", baseURL: "https://ollama.com", api: .ollama), path: "/api/show", body: ["model": "gemma4:cloud"], timeout: 1))
        XCTAssertTrue(StellarHTTP.safeModelError(status: 401, detail: "api_key=secret").localizedDescription.contains("ollama signin"))
        XCTAssertFalse(StellarHTTP.safeModelError(status: 401, detail: "api_key=secret").localizedDescription.contains("secret"))
        XCTAssertFalse(StellarHTTP.safeModelError(status: 401, detail: "unauthorized", serverTitle: "MLX").localizedDescription.contains("ollama"), "MLX errors must not be reported as Ollama account errors")
    }

    @MainActor func testStellarCloudTurnStopsWhenLightBeginsAndInspectedAliasIsRejected() async throws {
        let cloud = StellarModel(id: "ollama/account/model:latest", name: "account/model:latest", server: StellarServer.builtIn[0], tools: true, isCloud: true)
        let conversation = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .stellar, model: cloud.id)

        let activeDriver = StellarChatDriver()
        activeDriver.prepareServer = { _, _ in }
        activeDriver.inspectSelectedModel = { _, _ in cloud }
        var pendingStream: AsyncThrowingStream<StellarChunk, Error>.Continuation?
        var requestCount = 0
        activeDriver.streamRequest = { _, _, _, _, _ in
            requestCount += 1
            return AsyncThrowingStream { pendingStream = $0 }
        }
        let activeTurn = Task { try await activeDriver.run(conversation: conversation, prompt: "private request") { _ in } }
        for _ in 0..<100 where pendingStream == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(pendingStream)
        activeDriver.setEnergySaving(true)
        do { try await activeTurn.value; XCTFail("switching to Light cancels an active cloud turn") }
        catch { XCTAssertTrue(error is CancellationError || error.localizedDescription.contains("cancel")) }
        XCTAssertEqual(requestCount, 1)

        let inspectingDriver = StellarChatDriver()
        inspectingDriver.prepareServer = { _, _ in }
        var pendingInspection: CheckedContinuation<StellarModel, Error>?
        inspectingDriver.inspectSelectedModel = { _, _ in try await withCheckedThrowingContinuation { pendingInspection = $0 } }
        var requestsAfterInspection = 0
        inspectingDriver.streamRequest = { _, _, _, _, _ in
            requestsAfterInspection += 1
            return AsyncThrowingStream { $0.finish() }
        }
        let inspectingTurn = Task { try await inspectingDriver.run(conversation: conversation, prompt: "private request") { _ in } }
        for _ in 0..<100 where pendingInspection == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(pendingInspection)
        inspectingDriver.setEnergySaving(true)
        pendingInspection?.resume(returning: cloud)
        do { try await inspectingTurn.value; XCTFail("a cloud alias inspected after entering Light must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("solo están disponibles en modo Normal")) }
        XCTAssertEqual(requestsAfterInspection, 0)
    }

    @MainActor func testLightCancelsOnlyVerifiedCloudAsidesAndLivePolicyBlocksPendingMetadata() async throws {
        let asides = ChatAsides()
        let localConversation = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .claude, model: "haiku")
        var asideContinuation: CheckedContinuation<String, Never>?
        var localAsideWasCancelled = false
        asides.runAside = { _, _, _, _, _, _ in
            let result = await withCheckedContinuation { asideContinuation = $0 }
            localAsideWasCancelled = Task.isCancelled
            return result
        }
        asides.ask("local aside", about: localConversation)
        for _ in 0..<100 where asideContinuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(asideContinuation)
        asides.cancelCloudAsides()
        asideContinuation?.resume(returning: "ok")
        for _ in 0..<100 where asides.items[localConversation.id]?.finished != true { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(localAsideWasCancelled, "switching to Light must leave an unrelated local/provider aside running")

        let cloud = StellarModel(id: "ollama/account/model:latest", name: "account/model:latest", server: StellarServer.builtIn[0], tools: true, isCloud: true)
        let cloudAsides = ChatAsides()
        let cloudConversation = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .stellar, model: cloud.id)
        var cloudAsideContinuation: CheckedContinuation<String, Never>?
        var cloudAsideWasCancelled = false
        cloudAsides.runAside = { _, _, _, _, resolved, _ in
            resolved?()
            let result = await withCheckedContinuation { cloudAsideContinuation = $0 }
            cloudAsideWasCancelled = Task.isCancelled
            return result
        }
        cloudAsides.ask("cloud aside", about: cloudConversation, allowCloud: true, cloudAllowed: { true })
        for _ in 0..<100 where cloudAsideContinuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(cloudAsideContinuation)
        cloudAsides.cancelCloudAsides()
        cloudAsideContinuation?.resume(returning: "ok")
        for _ in 0..<100 where !cloudAsideWasCancelled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cloudAsideWasCancelled, "a cloud aside is registered and stopped after its model metadata resolves")

        let conversation = ChatConversation(projectPath: NSTemporaryDirectory(), provider: .stellar, model: cloud.id)
        var normalMode = true
        var inspection: CheckedContinuation<StellarModel, Error>?
        var streamCount = 0
        let asideTask = Task {
            try await StellarAside.ask("cloud aside", prompt: "question", about: conversation, allowCloud: true,
                                       cloudAllowed: { normalMode }, prepareServer: { _ in },
                                       inspectModel: { _, _ in try await withCheckedThrowingContinuation { inspection = $0 } },
                                       streamRequest: { _, _, _, _, _ in
                                           streamCount += 1
                                           return AsyncThrowingStream { $0.finish() }
                                       }) { _ in }
        }
        for _ in 0..<100 where inspection == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(inspection)
        normalMode = false
        inspection?.resume(returning: cloud)
        do { _ = try await asideTask.value; XCTFail("a pending cloud aside must recheck the live mode before streaming") }
        catch { XCTAssertTrue(error.localizedDescription.contains("solo están disponibles en modo Normal")) }
        XCTAssertEqual(streamCount, 0)
    }

    func testToolsReadEditAndRefuseAmbiguousEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-tools-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "a\nb\na\n".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        func call(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
            await StellarTools.execute(StellarToolCall(id: "1", name: name, arguments: boundedJSON(input)), root: root) { _ in }
        }
        let read = await call("read_file", ["path": "f.txt"])
        XCTAssertEqual(read.0, "1\ta\n2\tb\n3\ta\n4\t")
        let ambiguous = await call("edit_file", ["path": "f.txt", "old_string": "a", "new_string": "z"])
        XCTAssertTrue(ambiguous.1)
        let edit = await call("edit_file", ["path": "f.txt", "old_string": "b", "new_string": "c"])
        XCTAssertFalse(edit.1)
        XCTAssertEqual(try String(contentsOfFile: root + "/f.txt", encoding: .utf8), "a\nc\na\n")
        let listed = await call("list_files", [:])
        XCTAssertEqual(listed.0, "f.txt", "paths are relative even through /var → /private/var")
        try FileManager.default.createDirectory(atPath: root + "/nested", withIntermediateDirectories: true)
        try "nested file".write(toFile: root + "/nested/child.txt", atomically: true, encoding: .utf8)
        let shallow = await StellarTools.execute(StellarToolCall(id: "2", name: "list_files", arguments: "{}"), root: root, normalMode: true) { _ in }
        XCTAssertFalse(shallow.0.contains("child.txt"))
        let deep = await StellarTools.execute(StellarToolCall(id: "3", name: "list_files", arguments: "{\"recursive\":true}"), root: root, normalMode: true) { _ in }
        XCTAssertTrue(deep.0.contains("nested/child.txt"))
        let lightDeep = await call("list_files", [:])
        XCTAssertTrue(lightDeep.0.contains("nested/child.txt"))
        let command = await call("run_command", ["command": "echo hola; exit 3"])
        XCTAssertEqual(command.0, "hola\n\n[exit 3]")
        XCTAssertTrue(command.1)
    }

    func testNormalReadFilePagesOnlyWholeUnicodeLinesWithoutSkipping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-pages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = (1...24).map { "fila-\($0)-" + String(repeating: "ñ🪐", count: 340) }
        try (expected.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        var offset = 1
        var actual: [String] = []
        while offset <= expected.count {
            let input: [String: Any] = ["path": "large.txt", "offset": offset]
            let call = StellarToolCall(id: "page", name: "read_file", arguments: boundedJSON(input))
            let (page, failed) = await StellarTools.execute(call, root: root.path, normalMode: true) { _ in }
            XCTAssertFalse(failed)
            let rows = page.components(separatedBy: "\n")
            var next: Int?
            for row in rows {
                if row.hasPrefix("… (continúa con offset "), let value = row.split(separator: " ").last?.dropLast() { next = Int(value) }
                else if let tab = row.firstIndex(of: "\t"), let number = Int(row[..<tab]) {
                    XCTAssertEqual(number, actual.count + 1)
                    actual.append(String(row[row.index(after: tab)...]))
                }
            }
            if let next { XCTAssertGreaterThan(next, offset); offset = next }
            else { offset = expected.count + 1 }
        }
        XCTAssertEqual(actual, expected + [""])
    }

    func testNormalRecursiveListingNeverExceedsGlobalEntryLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-list-limit-" + UUID().uuidString)
        let subtree = root.appendingPathComponent("first")
        try FileManager.default.createDirectory(at: subtree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<405 {
            try "x".write(to: subtree.appendingPathComponent(String(format: "%03d.txt", index)), atomically: true, encoding: .utf8)
        }
        try "x".write(to: root.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
        let call = StellarToolCall(id: "list", name: "list_files", arguments: "{\"recursive\":true}")
        let (output, failed) = await StellarTools.execute(call, root: root.path, normalMode: true) { _ in }
        XCTAssertFalse(failed)
        let entries = output.components(separatedBy: "\n").filter { !$0.hasPrefix("…") }
        XCTAssertEqual(entries.count, 400)
        XCTAssertFalse(output.contains("sibling.txt"), "a parent must stop after a recursive child reaches the global cap")
        XCTAssertTrue(output.hasSuffix("… (listado acotado; especifica una subcarpeta o usa recursive=true)"))
    }

    func testPathsOutsideTheProjectAreDetected() {
        XCTAssertEqual(StellarTools.resolve("src/../a.swift", root: "/p"), "/p/a.swift")
        XCTAssertTrue(StellarTools.inside("/p/a.swift", roots: ["/p"]))
        XCTAssertFalse(StellarTools.inside("/pp/a.swift", roots: ["/p"]))
        XCTAssertFalse(StellarTools.inside(StellarTools.resolve("../x", root: "/p"), roots: ["/p"]))
    }

    func testMessagesMatchEachAPI() {
        let call = StellarToolCall(id: "c1", name: "read_file", arguments: "{\"path\":\"a\"}")
        let assistant = StellarMessage(role: "assistant", content: "", toolCalls: [call])
        let ollama = StellarClient.ollamaMessage(assistant)["tool_calls"] as? [[String: Any]]
        XCTAssertEqual((ollama?.first?["function"] as? [String: Any])?["arguments"] as? [String: String], ["path": "a"])
        let openAI = StellarClient.openAIMessage(assistant)["tool_calls"] as? [[String: Any]]
        XCTAssertEqual((openAI?.first?["function"] as? [String: Any])?["arguments"] as? String, "{\"path\":\"a\"}")
        let result = StellarMessage(role: "tool", content: "x", toolCallID: "c1", toolName: "read_file")
        XCTAssertEqual(StellarClient.openAIMessage(result)["tool_call_id"] as? String, "c1")
        XCTAssertEqual(StellarClient.ollamaMessage(result)["tool_name"] as? String, "read_file")
    }

    func testStellarIsBuiltInBetaAndAsksPermission() {
        XCTAssertTrue(ChatProvider.stellar.isBeta)
        XCTAssertTrue(ChatProvider.stellar.isBuiltIn)
        XCTAssertEqual(ChatRunMode.choices(for: .stellar).map(\.id), ["manual", "acceptEdits", "auto"])
    }

    func testNormalPromptAddsActionAndEvidenceGuidanceWhileLightPromptStaysLegacy() {
        let conversation = ChatConversation(projectPath: "/tmp/project", provider: .stellar)
        let light = StellarPrompt.system(conversation, tools: true)
        let normal = StellarPrompt.system(conversation, tools: true, normalMode: true, instructions: "No añadir a Light.")
        XCTAssertTrue(light.contains("When the task is done, stop calling tools and reply."))
        XCTAssertFalse(light.contains("No añadir a Light."))
        XCTAssertTrue(normal.contains("For analysis or review, report findings, their consequences and useful improvements"))
        XCTAssertTrue(normal.contains("Ollama Cloud model through the user's authenticated local Ollama daemon"))
        XCTAssertTrue(normal.contains("Only report checks actually run"))
        XCTAssertTrue(normal.contains("No añadir a Light."))
    }

    func testRootAndNestedInstructionsAreBoundedScopedAndFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-agents-" + UUID().uuidString)
        let nested = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Project rule".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "Source rule".write(to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StellarInstructions.root(projectPath: root.path), "Project rule")
        let applicable = StellarInstructions.loadApplicable(to: nested.appendingPathComponent("File.swift").path, projectPath: root.path)
        XCTAssertTrue(try XCTUnwrap(applicable.block).contains("Source rule"))
        XCTAssertEqual(applicable.files[nested.appendingPathComponent("AGENTS.md").path], "Source rule")
        XCTAssertTrue(applicable.complete)
        XCTAssertTrue(StellarInstructions.loadApplicable(to: "/tmp/outside/File.swift", projectPath: root.path).complete)

        let failedRead = StellarInstructions.loadApplicable(to: nested.appendingPathComponent("File.swift").path, projectPath: root.path, read: { _ in nil })
        XCTAssertFalse(failedRead.complete)
        XCTAssertTrue(StellarInstructions.needsDelivery(failedRead, previouslyDelivered: applicable.files))
        XCTAssertTrue(try XCTUnwrap(failedRead.block).contains("No se cargaron estas instrucciones"))

        let deeper = nested.appendingPathComponent("Deep")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        // Exhaust the nested instruction budget exactly, then ensure the deeper file is still discovered.
        let exactText = String(repeating: "x", count: StellarInstructions.nestedLimit - "--- \(nested.appendingPathComponent("AGENTS.md").path) ---\n".utf8.count)
        try exactText.write(to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "deeper rule".write(to: deeper.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let atLimit = StellarInstructions.loadApplicable(to: deeper.appendingPathComponent("File.swift").path, projectPath: root.path)
        XCTAssertFalse(atLimit.complete)
        XCTAssertTrue(try XCTUnwrap(atLimit.block).contains("Deep/AGENTS.md"))
        XCTAssertFalse(atLimit.files.keys.contains(deeper.appendingPathComponent("AGENTS.md").path))

        let external = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try "Outside rule".write(to: external.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: external)
        let escaped = StellarInstructions.loadApplicable(to: root.appendingPathComponent("linked/New.swift").path, projectPath: root.path)
        XCTAssertFalse(escaped.complete)
        XCTAssertTrue(try XCTUnwrap(escaped.block).lowercased().contains("enlace"))

        let newScope = root.appendingPathComponent("NewScope")
        try FileManager.default.createDirectory(at: newScope, withIntermediateDirectories: true)
        try "New scope rule".write(to: newScope.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let newlyCreatedFile = StellarInstructions.loadApplicable(to: newScope.appendingPathComponent("New.swift").path, projectPath: root.path)
        XCTAssertTrue(StellarInstructions.needsDelivery(newlyCreatedFile, previouslyDelivered: [:]))
        XCTAssertTrue(try XCTUnwrap(newlyCreatedFile.block).contains("New scope rule"))
        try String(repeating: "x", count: StellarInstructions.nestedLimit + 1).write(to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(StellarInstructions.loadApplicable(to: nested.appendingPathComponent("File.swift").path, projectPath: root.path).block).contains("excede 4 KiB"))
    }

    @MainActor func testContextBudgetKeepsLatestUserAndWholeToolTurnWithNotice() {
        let system = StellarMessage(role: "system", content: "instructions AGENTS immutable")
        let original = StellarMessage(role: "user", content: "objetivo original: preservar la decisión")
        let oldAssistant = StellarMessage(role: "assistant", content: "Decidimos editar sólo el módulo A.")
        let oldToolCall = StellarMessage(role: "assistant", content: "", toolCalls: [StellarToolCall(id: "call-1", name: "read_file", arguments: "{\"path\":\"README.md\"}")])
        let oldToolResult = StellarMessage(role: "tool", content: String(repeating: "resultado antiguo ", count: 1000), toolCallID: "call-1", toolName: "read_file")
        let latest = [StellarMessage(role: "user", content: "última petición: conserva la decisión y analiza"), StellarMessage(role: "assistant", content: "Haré el análisis solicitado.")]
        let history = [original, oldAssistant, oldToolCall, oldToolResult] + latest
        let definitions: [[String: Any]] = [["type": "function", "function": ["name": "read_file", "parameters": ["type": "object"]]]]
        let (messages, notice) = StellarChatDriver.contextBounded(history, system: system, contextLength: 2_500, toolDefinitions: definitions)
        XCTAssertEqual(messages.map(\.role), history.map(\.role))
        XCTAssertEqual(messages[0], original)
        XCTAssertEqual(messages[1], oldAssistant)
        XCTAssertEqual(messages[2].toolCalls?.first?.id, "call-1")
        XCTAssertEqual(messages[3].toolCallID, "call-1")
        XCTAssertTrue(messages[3].content.contains("Jack redujo un resultado antiguo"))
        XCTAssertEqual(messages.suffix(2), latest[...])
        XCTAssertTrue(try XCTUnwrap(notice).contains("Conservó los mensajes"))

        let compactPromptHistory = [StellarMessage(role: "user", content: "Resume: objetivos anteriores y decisiones"), original, oldAssistant, oldToolCall, oldToolResult, latest[0]]
        let (compactMessages, _) = StellarChatDriver.contextBounded(compactPromptHistory, system: system, contextLength: 2_500, toolDefinitions: definitions)
        XCTAssertTrue(compactMessages.contains { $0.content.contains("objetivo original") })
        XCTAssertTrue(compactMessages.contains { $0.content.contains("Decidimos editar sólo el módulo A") })
        XCTAssertTrue(compactMessages.last?.content.contains("última petición") == true)

        let hugeLatest = StellarMessage(role: "user", content: String(repeating: "última solicitud ", count: 1200))
        let (stillOversized, stillOversizedNotice) = StellarChatDriver.contextBounded([oldToolCall, oldToolResult, hugeLatest], system: system, contextLength: 300, toolDefinitions: definitions)
        XCTAssertTrue(stillOversized[1].content.contains("Jack redujo un resultado antiguo"))
        XCTAssertTrue(stillOversized.last?.content.contains("última solicitud") == true)
        XCTAssertTrue(try XCTUnwrap(stillOversizedNotice).contains("todavía exceden"))

        let oversized = StellarMessage(role: "user", content: String(repeating: "goal ", count: 5000))
        let (preserved, oversizedNotice) = StellarChatDriver.contextBounded([oversized], system: system, contextLength: 300, toolDefinitions: definitions)
        XCTAssertEqual(preserved, [oversized])
        XCTAssertTrue(try XCTUnwrap(oversizedNotice).contains("conservó todo"))
    }
}
