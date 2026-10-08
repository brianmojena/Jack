import XCTest
@testable import JackCore

final class FlowDiagramTests: XCTestCase {
    private let validGraph = FlowDiagram(
        title: "Aprobación",
        nodes: [
            .init(id: "end", label: "Inicio", kind: .start),
            .init(id: "subgraph", label: "¿Está listo?", kind: .decision),
            .init(id: "work", label: "Preparar", kind: .process),
            .init(id: "finish", label: "Fin", kind: .end),
        ],
        edges: [
            .init(from: "end", to: "subgraph"),
            .init(from: "subgraph", to: "work", label: "Sí"),
            .init(from: "subgraph", to: "finish", label: "No"),
            .init(from: "work", to: "finish"),
        ]
    )

    @MainActor func testServiceUsesVerifiedCloudWithoutToolsAndDoesNotTouchConversation() async throws {
        let service = mockService(outputs: [try json(validGraph)])
        var captured: [StellarMessage] = []
        service.streamRequest = { server, model, messages, tools, _, _ in
            XCTAssertEqual(server.api, .ollama)
            XCTAssertEqual(model, "gemma4:cloud")
            XCTAssertNil(tools, "Flow diagrams must work with cloud models without tools")
            captured = messages
            return Self.stream(try self.json(self.validGraph))
        }
        let context: [FlowDiagramContextMessage] = [
            .init(role: "assistant", content: "Visible answer"),
            .init(role: "reasoning", content: "hidden reasoning"),
            .init(role: "tool", content: "file content"),
        ]
        let graph = try await service.generate(modelID: "ollama/gemma4:cloud", question: "¿Cómo se decide?", context: context) { true }
        XCTAssertEqual(graph, validGraph)
        XCTAssertFalse(captured.map(\.content).joined(separator: "\n").contains("hidden reasoning"))
        XCTAssertFalse(captured.map(\.content).joined(separator: "\n").contains("file content"))
        XCTAssertTrue(captured.contains { $0.content == "Visible answer" })
        XCTAssertEqual(captured.last?.content, "¿Cómo se decide?")
    }

    @MainActor func testRejectsLocalModelAndRechecksLivePolicyAfterInspection() async throws {
        let service = FlowDiagramService()
        var inspectCalls = 0, streamCalls = 0
        service.inspectModel = { name, _ in
            inspectCalls += 1
            return StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: name != "local-model")
        }
        service.streamRequest = { _, _, _, _, _, _ in
            streamCalls += 1
            return Self.stream(try self.json(self.validGraph))
        }
        do {
            _ = try await service.generate(modelID: "ollama/local-model", question: "Pregunta", context: []) { true }
            XCTFail("A local model must not receive a flow request")
        } catch { XCTAssertTrue(error is FlowDiagramError) }
        XCTAssertEqual(inspectCalls, 1, "Cloud identity may come from /api/show metadata, so the selected model must be inspected")
        XCTAssertEqual(streamCalls, 0)

        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        let metadataAlias = try await service.generate(modelID: "ollama/account/gemma4", question: "Pregunta", context: []) { true }
        XCTAssertEqual(metadataAlias, validGraph)
        XCTAssertEqual(streamCalls, 1, "Metadata-verified cloud aliases without :cloud are accepted")

        var allowed = true
        service.inspectModel = { name, _ in
            allowed = false // Simulate switching to Light while local Ollama metadata is being read.
            return StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        do {
            _ = try await service.generate(modelID: "ollama/gemma4:cloud", question: "Pregunta", context: []) { allowed }
            XCTFail("A stale Normal request must not stream after the mode changes")
        } catch { XCTAssertTrue(error is FlowDiagramError) }
        XCTAssertEqual(streamCalls, 1)

        var allowedDuringRepair = true
        streamCalls = 0
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        service.streamRequest = { _, _, _, _, _, _ in
            streamCalls += 1
            allowedDuringRepair = false // Light switch while the invalid response would otherwise trigger repair.
            return Self.stream("{}")
        }
        do {
            _ = try await service.generate(modelID: "ollama/gemma4:cloud", question: "Pregunta", context: []) { allowedDuringRepair }
            XCTFail("A stale response must not start a repair request")
        } catch { XCTAssertTrue(error is FlowDiagramError) }
        XCTAssertEqual(streamCalls, 1)
    }

    @MainActor func testRetriesInvalidGraphOnceWithValidationReasonAndCapsRepairInput() async throws {
        var invalid = validGraph
        invalid.edges[2].to = "work" // distinct labels, but both decision branches go to the same target
        let outputs = [try json(invalid), try json(validGraph)]
        var calls = 0
        let service = FlowDiagramService()
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, contextLength: 4096, isCloud: true)
        }
        service.streamRequest = { _, _, messages, _, _, _ in
            calls += 1
            if calls == 2 {
                XCTAssertTrue(messages.last?.content.contains("validación JSON") == true)
                XCTAssertTrue(messages.contains { $0.role == "assistant" && $0.content == outputs[0] })
            }
            XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.utf8.count + 12 }, (4096 - 800) * 3)
            return Self.stream(outputs[min(calls - 1, outputs.count - 1)])
        }
        let result = try await service.generate(modelID: "ollama/gemma4:cloud", question: "Diseña el proceso", context: [.init(role: "user", content: String(repeating: "contexto", count: 500))]) { true }
        XCTAssertEqual(result, validGraph)
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testTooSmallContextFailsBeforeSendingRequest() async {
        let service = FlowDiagramService()
        var streamCalls = 0
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, contextLength: 1024, isCloud: true)
        }
        service.streamRequest = { _, _, _, _, _, _ in streamCalls += 1; return Self.stream("{}") }
        do {
            _ = try await service.generate(modelID: "ollama/gemma4:cloud", question: "Haz un diagrama", context: []) { true }
            XCTFail("The system prompt must fit before any request is made")
        } catch let error as FlowDiagramError {
            XCTAssertEqual(error.localizedDescription, FlowDiagramError.requestTooLarge.localizedDescription)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(streamCalls, 0)
    }

    func testMermaidUsesSyntheticIDsAndEscapesUntrustedTextAndEdges() throws {
        var graph = validGraph
        graph.nodes[0].id = "end"
        graph.nodes[1].id = "subgraph"
        graph.nodes[1].label = "¿Listo? [A] \"sí\"\n#35; & <b>\\"
        graph.edges[1].label = "Sí | [cita] \"ok\"\n#35; &"
        try graph.validate()
        let parsed = graph
        let mermaid = parsed.mermaid
        XCTAssertTrue(mermaid.hasPrefix("flowchart TD\n"))
        XCTAssertTrue(mermaid.contains("n0([\"Inicio\"])") )
        XCTAssertTrue(mermaid.contains("n1{\"¿Listo? #91;A#93; #quot;sí#quot; #35;35; #38; #60;b#62;#92;\"}"))
        XCTAssertTrue(mermaid.contains("n1 -->|\"Sí #124; #91;cita#93; #quot;ok#quot; #35;35; #38;\"| n2"))
        XCTAssertFalse(mermaid.contains(" subgraph "))
        XCTAssertFalse(mermaid.contains(" end["))
    }

    func testBranchesRequireDistinctTargetsAndMultipleTerminalOutcomesAreValid() throws {
        var invalid = validGraph
        invalid.edges[2].to = "work"
        XCTAssertThrowsError(try invalid.validate())

        let multipleEnds = FlowDiagram(title: "Outcome", nodes: [
            .init(id: "s", label: "Start", kind: .start), .init(id: "d", label: "Decision", kind: .decision),
            .init(id: "yes", label: "Approved", kind: .end), .init(id: "no", label: "Rejected", kind: .end),
        ], edges: [.init(from: "s", to: "d"), .init(from: "d", to: "yes", label: "Yes"), .init(from: "d", to: "no", label: "No")])
        XCTAssertNoThrow(try multipleEnds.validate())
    }

    func testParserFencesReferencesDuplicatesAndConnectivity() throws {
        let fenced = "```json\n\(try json(validGraph))\n```"
        XCTAssertEqual(try FlowDiagram.parse(fenced), validGraph)

        var missingReference = validGraph
        missingReference.edges[0].to = "missing"
        XCTAssertThrowsError(try missingReference.validate())

        var duplicate = validGraph
        duplicate.nodes[1].id = duplicate.nodes[0].id
        XCTAssertThrowsError(try duplicate.validate())

        var disconnected = validGraph
        disconnected.nodes.append(.init(id: "island", label: "Aislado", kind: .process))
        XCTAssertThrowsError(try disconnected.validate())
    }

    func testContextUsesOnlyRecentVisibleMessagesAndRespectsUTF8Cap() {
        let messages = [
            ChatMessage(role: "user", text: "old"), ChatMessage(role: "reasoning", text: "secret"),
            ChatMessage(role: "tool", text: "tool output"), ChatMessage(role: "assistant", text: String(repeating: "é", count: 20)),
        ]
        let context = FlowDiagramContext.recentVisible(from: messages, maxBytes: 7)
        XCTAssertEqual(context.map(\.role), ["user", "assistant"])
        XCTAssertEqual(context.last?.content, String(repeating: "é", count: 3))
        XCTAssertTrue(context.allSatisfy { ["user", "assistant"].contains($0.role) })
        XCTAssertLessThanOrEqual(context.reduce(0) { $0 + $1.content.utf8.count }, 7)
        XCTAssertFalse(context.contains { $0.content.contains("secret") || $0.content.contains("tool output") })
    }

    @MainActor func testCanceledGenerationCannotOverwriteNewerResult() async throws {
        var newer = validGraph
        newer.title = "Resultado nuevo"
        let service = FlowDiagramService()
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        var calls = 0
        var firstContinuation: AsyncThrowingStream<StellarChunk, Error>.Continuation?
        service.streamRequest = { _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                return AsyncThrowingStream { firstContinuation = $0 }
            }
            return Self.stream(try self.json(newer))
        }
        let state = FlowDiagramState(service: service)
        state.question = "Petición vieja"
        state.generate(modelID: "ollama/gemma4:cloud", context: []) { true }
        for _ in 0..<100 where calls == 0 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        state.cancel()
        state.question = "Petición nueva"
        state.generate(modelID: "ollama/gemma4:cloud", context: []) { true }
        for _ in 0..<100 where state.isGenerating { await Task.yield() }
        firstContinuation?.yield(.text(try json(validGraph)))
        firstContinuation?.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(state.graph, newer)
        XCTAssertEqual(state.graphQuestion, "Petición nueva")
    }

    @MainActor func testStoreGenerationForCodexLeavesAgentUntouchedAndCreatesNoDriver() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-diagram-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var driverCreations = 0
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in
            driverCreations += 1
            return FlowNoopDriver()
        })
        defer { store.shutdown() }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex, model: "gpt-6-luna"))
        let cloud = StellarModel(id: "ollama/gemma4:cloud", name: "gemma4:cloud", server: StellarServer.builtIn[0], tools: false, isCloud: true)
        store.loadStellarModels = { _ in [cloud] }
        await store.refreshLocalModels()

        let service = FlowDiagramService()
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        service.streamRequest = { _, _, _, tools, _, _ in
            XCTAssertNil(tools)
            return Self.stream(try self.json(self.validGraph))
        }
        store.makeFlowDiagramState = { FlowDiagramState(service: service) }
        let state = store.flowDiagramState(for: id)
        state.question = "¿Cómo decido?"
        let before = try XCTUnwrap(store.conversations.first { $0.id == id })
        let messages = before.messages, sessionID = before.sessionID, model = before.model
        store.generateFlowDiagram(in: id, modelID: cloud.id)
        for _ in 0..<100 where state.isGenerating { await Task.yield() }
        XCTAssertEqual(state.graph, validGraph)
        let after = try XCTUnwrap(store.conversations.first { $0.id == id })
        XCTAssertEqual(after.provider, .codex)
        XCTAssertEqual(after.model, model)
        XCTAssertEqual(after.messages, messages)
        XCTAssertEqual(after.sessionID, sessionID)
        XCTAssertEqual(driverCreations, 0)
    }

    @MainActor func testTimeoutAndOversizeResponseDoNotStartRepair() async {
        let service = FlowDiagramService()
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        var calls = 0
        var stalledContinuation: AsyncThrowingStream<StellarChunk, Error>.Continuation?
        service.timeout = .milliseconds(10)
        service.streamRequest = { _, _, _, _, _, _ in
            calls += 1
            return AsyncThrowingStream { stalledContinuation = $0 }
        }
        do {
            _ = try await service.generate(modelID: "ollama/gemma4:cloud", question: "timeout", context: []) { true }
            XCTFail("A stalled local daemon stream must time out")
        } catch let error as FlowDiagramError {
            XCTAssertEqual(error.localizedDescription, FlowDiagramError.timeout.localizedDescription)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
        stalledContinuation?.finish()

        calls = 0
        service.timeout = .seconds(1)
        service.streamRequest = { _, _, _, _, _, _ in
            calls += 1
            return Self.stream(String(repeating: "x", count: FlowDiagram.maxResponseBytes + 1))
        }
        do {
            _ = try await service.generate(modelID: "ollama/gemma4:cloud", question: "oversize", context: []) { true }
            XCTFail("Oversize output must stop before repair")
        } catch let error as FlowDiagramError {
            XCTAssertEqual(error.localizedDescription, FlowDiagramError.outputTooLarge.localizedDescription)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)

        calls = 0
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, contextLength: 4096, isCloud: true)
        }
        service.streamRequest = { _, _, _, _, _, _ in
            calls += 1
            return Self.stream(String(repeating: "x", count: FlowDiagram.maxResponseBytes))
        }
        do {
            _ = try await service.generate(modelID: "ollama/gemma4:cloud", question: "repair too large", context: []) { true }
            XCTFail("A repair that cannot fit must fail explicitly")
        } catch let error as FlowDiagramError {
            XCTAssertEqual(error.localizedDescription, FlowDiagramError.repairTooLarge.localizedDescription)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1, "Repair-cap failure must not make a second request")
    }

    func testLayoutFlowsDownwardAndCentersBranchesInEachRow() throws {
        let layout = FlowDiagramLayout(graph: validGraph, nodeWidth: 180, nodeHeight: 70, columnGap: 40, rowGap: 90)
        let start = try XCTUnwrap(layout.frames["end"])
        let decision = try XCTUnwrap(layout.frames["subgraph"])
        let work = try XCTUnwrap(layout.frames["work"])
        let finish = try XCTUnwrap(layout.frames["finish"])
        XCTAssertEqual(start.midX, decision.midX)
        XCTAssertGreaterThan(decision.y, start.maxY)
        XCTAssertGreaterThan(work.y, decision.maxY)
        XCTAssertEqual(work.y, finish.y, "Branches at the same depth sit side by side")
        XCTAssertGreaterThan(finish.x, work.maxX)
        XCTAssertEqual(start.midX, (work.midX + finish.midX) / 2)
        for frame in layout.frames.values {
            XCTAssertGreaterThanOrEqual(frame.x, 0)
            XCTAssertGreaterThanOrEqual(frame.y, 0)
            XCTAssertLessThan(frame.maxX, layout.size.width)
            XCTAssertLessThan(frame.maxY, layout.size.height)
        }
    }

    func testLayoutRoutesBackEdgesAndSelfLoopsOutsideEveryNodeFrame() throws {
        let graph = FlowDiagram(title: "Loop", nodes: [
            .init(id: "s", label: "Start", kind: .start), .init(id: "d", label: "Check", kind: .decision),
            .init(id: "p", label: "Repeat", kind: .process), .init(id: "e", label: "Done", kind: .end),
        ], edges: [
            .init(from: "s", to: "d"), .init(from: "d", to: "p", label: "repeat"),
            .init(from: "p", to: "p", label: "again"), .init(from: "d", to: "e", label: "finish"),
            .init(from: "p", to: "e"), .init(from: "p", to: "d", label: "retry"),
        ])
        try graph.validate()
        let layout = FlowDiagramLayout(graph: graph)
        XCTAssertEqual(layout.returnRoutes.count, 3, "Self, same-row and backward edges each need a return lane")
        var laneXs = Set<Double>()
        for edge in [graph.edges[2], graph.edges[4], graph.edges[5]] {
            let route = try XCTUnwrap(layout.returnRoutes[edge.id])
            let from = try XCTUnwrap(layout.frames[edge.from])
            let to = try XCTUnwrap(layout.frames[edge.to])
            XCTAssertEqual(route.points.first, .init(x: from.midX, y: from.maxY))
            XCTAssertEqual(route.points.last, .init(x: to.midX, y: to.y))
            XCTAssertGreaterThan(route.points[1].y, from.maxY)
            XCTAssertLessThan(route.points[4].y, to.y, "Every arrow enters from above")
            XCTAssertLessThan(route.points[2].x, layout.frames.values.map(\.x).min() ?? .infinity)
            XCTAssertTrue(laneXs.insert(route.points[2].x).inserted, "Return lanes stay separate")
            XCTAssertEqual(route.labelPoint.x, route.points[2].x)
            for point in route.points {
                XCTAssertGreaterThanOrEqual(point.x, 0)
                XCTAssertGreaterThanOrEqual(point.y, 0)
                XCTAssertLessThan(point.x, layout.size.width)
                XCTAssertLessThan(point.y, layout.size.height)
            }
            for (a, b) in zip(route.points, route.points.dropFirst()) {
                XCTAssertTrue(a.x == b.x || a.y == b.y)
                for frame in layout.frames.values {
                    let crossesInterior: Bool
                    if a.x == b.x {
                        crossesInterior = a.x > frame.x && a.x < frame.maxX
                            && max(a.y, b.y) > frame.y && min(a.y, b.y) < frame.maxY
                    } else {
                        crossesInterior = a.y > frame.y && a.y < frame.maxY
                            && max(a.x, b.x) > frame.x && min(a.x, b.x) < frame.maxX
                    }
                    XCTAssertFalse(crossesInterior, "Return connections must avoid every node")
                }
            }
        }
    }

    @MainActor func testStoreModeSwitchDuringInspectionCancelsAndDoesNotMutateMainHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-diagram-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = ChatArchive(directory: folder)
        let store = ChatStore(archive: archive, preferences: nil)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .stellar))
        let cloud = StellarModel(id: "ollama/gemma4:cloud", name: "gemma4:cloud", server: StellarServer.builtIn[0], tools: false, isCloud: true)
        store.loadStellarModels = { _ in [cloud] }
        await store.refreshLocalModels()
        let service = FlowDiagramService()
        service.inspectModel = { [weak store] name, _ in
            store?.setLightMode(true)
            store?.setLightMode(false)
            return StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        var streamCalls = 0
        service.streamRequest = { _, _, _, _, _, _ in streamCalls += 1; return Self.stream(try self.json(self.validGraph)) }
        store.makeFlowDiagramState = { FlowDiagramState(service: service) }
        let state = store.flowDiagramState(for: id)
        state.question = "¿Cómo funciona?"
        let before = try XCTUnwrap(store.conversations.first { $0.id == id }).messages
        store.generateFlowDiagram(in: id, modelID: cloud.id)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(streamCalls, 0)
        XCTAssertNil(state.graph)
        XCTAssertEqual(store.conversations.first { $0.id == id }?.messages, before)
    }

    @MainActor func testLightThenNormalDuringCloudStreamKeepsOldGenerationStale() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-diagram-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex, model: "gpt-6-luna"))
        let cloud = StellarModel(id: "ollama/gemma4:cloud", name: "gemma4:cloud", server: StellarServer.builtIn[0], tools: false, isCloud: true)
        store.loadStellarModels = { _ in [cloud] }
        await store.refreshLocalModels()
        let service = FlowDiagramService()
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        var continuation: AsyncThrowingStream<StellarChunk, Error>.Continuation?
        var streamCalls = 0
        service.streamRequest = { _, _, _, _, _, _ in
            streamCalls += 1
            return AsyncThrowingStream { continuation = $0 }
        }
        store.makeFlowDiagramState = { FlowDiagramState(service: service) }
        let state = store.flowDiagramState(for: id)
        state.question = "Pregunta explícita"
        let before = try XCTUnwrap(store.conversations.first { $0.id == id })
        let oldMessages = before.messages, oldModel = before.model, oldSession = before.sessionID
        store.generateFlowDiagram(in: id, modelID: cloud.id)
        for _ in 0..<100 where streamCalls == 0 { await Task.yield() }
        XCTAssertEqual(streamCalls, 1)
        store.setLightMode(true)
        store.setLightMode(false)
        continuation?.yield(.text(try json(validGraph)))
        continuation?.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(state.graph)
        let after = try XCTUnwrap(store.conversations.first { $0.id == id })
        XCTAssertEqual(after.messages, oldMessages)
        XCTAssertEqual(after.model, oldModel)
        XCTAssertEqual(after.sessionID, oldSession)
    }

    @MainActor func testRemoveAndShutdownCancelPendingDiagramStreams() async throws {
        for action in ["remove", "shutdown"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-diagram-cancel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil)
            let id = try XCTUnwrap(store.create(projectPath: folder.path, provider: .codex, model: "gpt-6-luna"))
            let cloud = StellarModel(id: "ollama/gemma4:cloud", name: "gemma4:cloud", server: StellarServer.builtIn[0], tools: false, isCloud: true)
            store.loadStellarModels = { _ in [cloud] }
            await store.refreshLocalModels()
            let service = FlowDiagramService()
            service.inspectModel = { name, _ in
                StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
            }
            var continuation: AsyncThrowingStream<StellarChunk, Error>.Continuation?
            service.streamRequest = { _, _, _, _, _, _ in AsyncThrowingStream { continuation = $0 } }
            store.makeFlowDiagramState = { FlowDiagramState(service: service) }
            let state = store.flowDiagramState(for: id)
            state.question = "Cancelar"
            store.generateFlowDiagram(in: id, modelID: cloud.id)
            for _ in 0..<100 where continuation == nil { await Task.yield() }
            XCTAssertNotNil(continuation)
            if action == "remove" { store.remove(id) } else { store.shutdown() }
            continuation?.yield(.text(try json(validGraph)))
            continuation?.finish()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(state.graph)
            if action == "remove" { XCTAssertFalse(store.conversations.contains { $0.id == id }) }
            store.shutdown()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor private func mockService(outputs: [String]) -> FlowDiagramService {
        let service = FlowDiagramService()
        service.inspectModel = { name, _ in
            StellarModel(id: "ollama/\(name)", name: name, server: StellarServer.builtIn[0], tools: false, isCloud: true)
        }
        service.streamRequest = { _, _, _, _, _, _ in Self.stream(outputs[0]) }
        return service
    }

    private func json(_ graph: FlowDiagram) throws -> String {
        String(decoding: try JSONEncoder().encode(graph), as: UTF8.self)
    }

    private static func stream(_ text: String) -> AsyncThrowingStream<StellarChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }
}

@MainActor private final class FlowNoopDriver: ChatDriver {
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {}
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() {}
}
