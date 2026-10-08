import Combine
import Foundation

public struct FlowDiagram: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case start, process, decision, end
    }

    public struct Node: Codable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var kind: Kind
        public init(id: String, label: String, kind: Kind) { self.id = id; self.label = label; self.kind = kind }
    }

    public struct Edge: Codable, Equatable, Identifiable {
        public var id: String { "\(from)>\(to):\(label ?? "")" }
        public var from: String
        public var to: String
        public var label: String?
        public init(from: String, to: String, label: String? = nil) { self.from = from; self.to = to; self.label = label }
    }

    public var title: String
    public var nodes: [Node]
    public var edges: [Edge]

    public init(title: String, nodes: [Node], edges: [Edge]) {
        self.title = title; self.nodes = nodes; self.edges = edges
    }

    public static let maxResponseBytes = 24_000
    public static let maxNodes = 24
    public static let maxEdges = 48

    public static func parse(_ response: String) throws -> FlowDiagram {
        guard response.utf8.count <= maxResponseBytes else { throw FlowDiagramError.outputTooLarge }
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if text.hasPrefix("```") {
            guard let firstNewline = text.firstIndex(of: "\n"),
                  let fence = text.range(of: "```", options: .backwards), fence.lowerBound > firstNewline else {
                throw FlowDiagramError.invalidJSON
            }
            json = String(text[text.index(after: firstNewline)..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            json = text
        }
        guard let data = json.data(using: .utf8) else { throw FlowDiagramError.invalidJSON }
        let diagram: FlowDiagram
        do { diagram = try JSONDecoder().decode(FlowDiagram.self, from: data) }
        catch { throw FlowDiagramError.invalidJSON }
        try diagram.validate()
        return diagram
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 160, Self.hasNoControlCharacters(title),
              nodes.count >= 3, nodes.count <= Self.maxNodes,
              edges.count >= 2, edges.count <= Self.maxEdges else { throw FlowDiagramError.invalidGraph }

        var ids = Set<String>()
        for node in nodes {
            guard Self.validID(node.id), ids.insert(node.id).inserted,
                  !node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node.label.utf8.count <= 180, Self.hasNoForbiddenTextControls(node.label) else { throw FlowDiagramError.invalidGraph }
        }
        guard nodes.filter({ $0.kind == .start }).count == 1,
              nodes.contains(where: { $0.kind == .end }) else { throw FlowDiagramError.invalidGraph }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var edgeIDs = Set<String>()
        for edge in edges {
            guard byID[edge.from] != nil, byID[edge.to] != nil,
                  edge.label.map({ $0.utf8.count <= 100 && Self.hasNoForbiddenTextControls($0) }) ?? true,
                  edgeIDs.insert(edge.id).inserted else { throw FlowDiagramError.invalidGraph }
        }

        let start = nodes.first { $0.kind == .start }!.id
        guard !edges.contains(where: { $0.to == start }),
              !edges.contains(where: { byID[$0.from]?.kind == .end }) else { throw FlowDiagramError.invalidGraph }
        for decision in nodes where decision.kind == .decision {
            let branches = edges.filter { $0.from == decision.id }
            let labels = branches.compactMap { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard branches.count >= 2, labels.count == branches.count,
                  labels.allSatisfy({ !$0.isEmpty }), Set(labels).count >= 2,
                  Set(branches.map(\.to)).count >= 2 else { throw FlowDiagramError.invalidGraph }
        }
        let adjacency = Dictionary(grouping: edges, by: \.from).mapValues { $0.map(\.to) }
        let ends = Set(nodes.filter { $0.kind == .end }.map(\.id))
        let reverse = Dictionary(grouping: edges, by: \.to).mapValues { $0.map(\.from) }
        var canReachEnd = Set<String>()
        for end in ends { canReachEnd.formUnion(Self.reachable(from: end, adjacency: reverse)) }
        guard Self.reachable(from: start, adjacency: adjacency) == ids,
              canReachEnd == ids,
              !edges.contains(where: { byID[$0.from]?.kind == .end }) else {
            throw FlowDiagramError.invalidGraph
        }
    }

    /// A breadth-first layered view. Edges that point to earlier layers are retained as loops in Mermaid and the native view.
    public var layers: [[Node]] {
        guard let start = nodes.first(where: { $0.kind == .start }) else { return [nodes] }
        let adjacency = Dictionary(grouping: edges, by: \.from).mapValues { $0.map(\.to) }
        var depth = [start.id: 0], queue = [start.id]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for target in adjacency[id] ?? [] where depth[target] == nil {
                depth[target] = (depth[id] ?? 0) + 1
                queue.append(target)
            }
        }
        let maxDepth = depth.values.max() ?? 0
        return (0...maxDepth).map { layer in
            nodes.filter { depth[$0.id] == layer }
        }
    }

    public var mermaid: String {
        var lines = ["flowchart LR", "%% \(Self.mermaidText(title))"]
        let safeID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, "n\($0.offset)") })
        for node in nodes {
            let label = Self.mermaidText(node.label)
            let id = safeID[node.id]!
            switch node.kind {
            case .start, .end: lines.append("    \(id)([\"\(label)\"])")
            case .process: lines.append("    \(id)[\"\(label)\"]")
            case .decision: lines.append("    \(id){\"\(label)\"}")
            }
        }
        for edge in edges {
            let from = safeID[edge.from]!, to = safeID[edge.to]!
            if let label = edge.label, !label.isEmpty {
                lines.append("    \(from) -->|\"\(Self.mermaidText(label))\"| \(to)")
            } else {
                lines.append("    \(from) --> \(to)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0)
        }
    }

    private static func hasNoControlCharacters(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func hasNoForbiddenTextControls(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && !["\n", "\r"].contains(String($0)) }
    }

    private static func reachable(from start: String, adjacency: [String: [String]]) -> Set<String> {
        var seen: Set<String> = [start], queue = [start]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            for next in adjacency[node] ?? [] where seen.insert(next).inserted { queue.append(next) }
        }
        return seen
    }

    private static func mermaidText(_ raw: String) -> String {
        raw.unicodeScalars.map { scalar in
            switch scalar.value {
            case 10, 13: " "
            case 34: "#quot;"
            case 35: "#35;"
            case 38: "#38;"
            case 60: "#60;"
            case 62: "#62;"
            case 91: "#91;"
            case 93: "#93;"
            case 123: "#123;"
            case 125: "#125;"
            case 92: "#92;"
            case 96: "#96;"
            case 124: "#124;"
            default: String(scalar)
            }
        }.joined()
    }
}

/// Deterministic orthogonal routing for same-layer and backward edges; return lanes sit above every node.
public struct FlowDiagramLayout {
    public struct Point: Equatable { public var x: Double; public var y: Double }
    public struct Frame: Equatable {
        public var x: Double; public var y: Double; public var width: Double; public var height: Double
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var midY: Double { y + height / 2 }
    }
    public struct EdgeRoute: Equatable { public var points: [Point]; public var labelPoint: Point }

    public let frames: [String: Frame]
    public let returnRoutes: [String: EdgeRoute]
    public let size: (width: Double, height: Double)

    public init(graph: FlowDiagram, nodeWidth: Double = 224, nodeHeight: Double = 82, columnGap: Double = 96, rowGap: Double = 52, laneGap: Double = 24) {
        let layers = graph.layers
        let columns = Dictionary(uniqueKeysWithValues: layers.enumerated().flatMap { column, nodes in nodes.map { ($0.id, column) } })
        let returns = graph.edges.filter { (columns[$0.to] ?? 0) <= (columns[$0.from] ?? 0) }
        let top = 24 + Double(returns.count) * laneGap
        var frames: [String: Frame] = [:]
        for (column, nodes) in layers.enumerated() {
            for (row, node) in nodes.enumerated() {
                frames[node.id] = Frame(x: Double(column) * (nodeWidth + columnGap), y: top + Double(row) * (nodeHeight + rowGap), width: nodeWidth, height: nodeHeight)
            }
        }
        var routes: [String: EdgeRoute] = [:]
        for (index, edge) in returns.enumerated() {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let laneY = 12 + Double(index) * laneGap
            let rightPort = from.maxX + 18
            let leftPort = to.x - 18
            let points = [
                Point(x: from.maxX, y: from.midY), Point(x: rightPort, y: from.midY),
                Point(x: rightPort, y: laneY), Point(x: leftPort, y: laneY),
                Point(x: leftPort, y: to.midY), Point(x: to.x, y: to.midY),
            ]
            routes[edge.id] = EdgeRoute(points: points, labelPoint: Point(x: (rightPort + leftPort) / 2, y: laneY))
        }
        self.frames = frames
        returnRoutes = routes
        let rowCount = max(1, layers.map(\.count).max() ?? 1)
        size = (Double(max(1, layers.count)) * (nodeWidth + columnGap) + 24, top + Double(rowCount) * (nodeHeight + rowGap) + 24)
    }
}

enum FlowDiagramError: LocalizedError {
    case invalidJSON, invalidGraph, invalidQuestion, outputTooLarge, requestTooLarge, repairTooLarge, timeout, cancelled, cloudOnly, authentication, cloudUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidJSON: "La respuesta no era un JSON válido de diagrama. Puedes reintentar."
        case .invalidGraph: "El modelo devolvió un diagrama incompleto o con conexiones inválidas. Puedes reintentar."
        case .invalidQuestion: "Escribe una pregunta de hasta 4.000 bytes para generar el diagrama."
        case .outputTooLarge: "La respuesta del modelo superó el límite de tamaño del diagrama. Prueba una pregunta más concreta."
        case .requestTooLarge: "La pregunta y las instrucciones ocupan más que la ventana disponible del modelo. Acorta la pregunta e inténtalo de nuevo."
        case .repairTooLarge: "La respuesta inválida y el contexto no caben juntos en la ventana del modelo para repararla. Regenera con una pregunta más concreta."
        case .timeout: "Ollama Cloud tardó demasiado en generar el diagrama. Puedes reintentar."
        case .cancelled: "La generación se canceló al cambiar el modo o cerrar la conversación."
        case .cloudOnly: "Elige un modelo de Ollama Cloud validado para generar diagramas."
        case .authentication: "Ollama no autorizó la solicitud. Abre Ollama e inicia sesión con `ollama signin`."
        case .cloudUnavailable: "Ollama Cloud no está disponible. Revisa tu cuenta, conexión y cuota, y vuelve a intentarlo."
        }
    }
}

struct FlowDiagramContextMessage: Equatable {
    var role: String
    var content: String
}

enum FlowDiagramContext {
    static let maxBytes = 6_000
    static let maxMessages = 8

    static func recentVisible(from messages: [ChatMessage], maxBytes: Int = maxBytes) -> [FlowDiagramContextMessage] {
        var remaining = max(0, maxBytes)
        var collected: [FlowDiagramContextMessage] = []
        for message in messages.reversed() where ["user", "assistant"].contains(message.role) && !message.text.isEmpty {
            guard remaining > 0, collected.count < maxMessages else { break }
            let content = StellarTools.prefixUTF8(message.text, bytes: remaining)
            guard !content.isEmpty else { continue }
            collected.append(FlowDiagramContextMessage(role: message.role, content: content))
            remaining -= content.utf8.count
        }
        return collected.reversed()
    }
}

typealias FlowDiagramPolicy = @MainActor () -> Bool

@MainActor final class FlowDiagramService {
    typealias Inspector = @MainActor (String, Bool) async throws -> StellarModel
    typealias StreamFactory = @MainActor (StellarServer, String, [StellarMessage], [[String: Any]]?, Int, TimeInterval) throws -> AsyncThrowingStream<StellarChunk, Error>

    var inspectModel: Inspector = { name, includeCloud in
        try await StellarModels.inspectOllamaModel(named: name, includeCloud: includeCloud)
    }
    var streamRequest: StreamFactory = { server, model, messages, tools, context, timeout in
        try StellarClient.stream(server: server, model: model, messages: messages, tools: tools, contextLength: context, timeout: timeout)
    }
    var timeout: Duration = .seconds(50)
    var contextLimit = StellarServer.defaultContextLength

    func generate(modelID: String, question rawQuestion: String, context: [FlowDiagramContextMessage], allowed: @escaping FlowDiagramPolicy) async throws -> FlowDiagram {
        do {
            return try await generateChecked(modelID: modelID, question: rawQuestion, context: context, allowed: allowed)
        } catch is CancellationError {
            throw FlowDiagramError.cancelled
        } catch let error as FlowDiagramError {
            throw error
        } catch {
            throw Self.safeError(error)
        }
    }

    private func generateChecked(modelID: String, question rawQuestion: String, context: [FlowDiagramContextMessage], allowed: @escaping FlowDiagramPolicy) async throws -> FlowDiagram {
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 4_000 else {
            throw FlowDiagramError.invalidQuestion
        }
        guard let (server, model) = StellarModels.resolve(modelID), server.api == .ollama else { throw FlowDiagramError.cloudOnly }
        try StellarModels.requireCloudAllowed(name: model, includeCloud: allowed())
        let verified = try await inspectModel(model, allowed())
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        guard verified.server.api == .ollama, verified.id == modelID, verified.isCloud else { throw FlowDiagramError.cloudOnly }

        let contextLength = max(1, min(verified.contextLength ?? contextLimit, contextLimit))
        let reservedTokens = min(3_000, max(800, contextLength / 4))
        let questionBytes = question.utf8.count
        let contextBudget = max(0, min(FlowDiagramContext.maxBytes, (contextLength - reservedTokens) * 3 - questionBytes - 1_500))
        let boundedContext = Self.boundContext(context, bytes: contextBudget)
        let system = StellarMessage(role: "system", content: Self.systemPrompt(language: question))
        let userQuestion = StellarMessage(role: "user", content: question)
        let original = [system] + boundedContext.map { StellarMessage(role: $0.role, content: $0.content) } + [userQuestion]
        let maxInputBytes = max(0, (contextLength - 800) * 3)
        guard Self.messageBytes(original) <= maxInputBytes else { throw FlowDiagramError.requestTooLarge }
        let raw = try await request(messages: original, server: server, model: model, contextLength: contextLength, allowed: allowed)
        do { return try FlowDiagram.parse(raw) }
        catch {
            try Task.checkCancellation()
            guard allowed() else { throw CancellationError() }
            let repairInstruction = StellarMessage(role: "user", content: "La respuesta anterior falló la validación JSON del diagrama (esquema y estructura del grafo). Corrige el JSON para cumplir el esquema original, con IDs únicos, referencias válidas, inicio y finales alcanzables, y ramas de decisión etiquetadas a destinos distintos. Devuelve solo el JSON; no añadas hechos ni cambies la intención.")
            let repairCore = [system, userQuestion, StellarMessage(role: "assistant", content: raw), repairInstruction]
            let remainingContextBytes = maxInputBytes - Self.messageBytes(repairCore)
            guard remainingContextBytes >= 0 else { throw FlowDiagramError.repairTooLarge }
            let repairContext = Self.boundContext(boundedContext, bytes: remainingContextBytes)
            let repair = [system] + repairContext.map { StellarMessage(role: $0.role, content: $0.content) }
                + [userQuestion, StellarMessage(role: "assistant", content: raw), repairInstruction]
            guard Self.messageBytes(repair) <= maxInputBytes else { throw FlowDiagramError.repairTooLarge }
            return try FlowDiagram.parse(try await request(messages: repair, server: server, model: model, contextLength: contextLength, allowed: allowed))
        }
    }

    private func request(messages: [StellarMessage], server: StellarServer, model: String, contextLength: Int, allowed: @escaping FlowDiagramPolicy) async throws -> String {
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        let stream = try streamRequest(server, model, messages, nil, contextLength, 50)
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var response = ""
                for try await chunk in stream {
                    try Task.checkCancellation()
                    if case .text(let delta) = chunk {
                        guard response.utf8.count + delta.utf8.count <= FlowDiagram.maxResponseBytes else { throw FlowDiagramError.outputTooLarge }
                        response += delta
                    }
                }
                return response
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw FlowDiagramError.timeout
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw FlowDiagramError.cloudUnavailable }
            return response
        }
    }

    private static func boundContext(_ context: [FlowDiagramContextMessage], bytes limit: Int) -> [FlowDiagramContextMessage] {
        var remaining = max(0, limit), result: [FlowDiagramContextMessage] = []
        let visible = context.filter { ["user", "assistant"].contains($0.role) }
        for message in visible.suffix(FlowDiagramContext.maxMessages).reversed() where remaining > 0 {
            let content = StellarTools.prefixUTF8(message.content, bytes: remaining)
            if !content.isEmpty { result.append(.init(role: message.role, content: content)); remaining -= content.utf8.count }
        }
        return result.reversed()
    }

    private static func messageBytes(_ messages: [StellarMessage]) -> Int {
        messages.reduce(0) { $0 + $1.role.utf8.count + $1.content.utf8.count + 12 }
    }

    private static func systemPrompt(language: String) -> String {
        return """
        You generate a flow diagram for the user's explicit question. Reply in the same language as that question. Use only the question and visible conversation context supplied; you have no repository or file access and must not invent repository facts. Return only JSON with this schema: {"title":"...","nodes":[{"id":"start","label":"...","kind":"start|process|decision|end"}],"edges":[{"from":"start","to":"step1","label":"optional branch label"}]}. Include exactly one start and at least one end, concise process nodes, and edges that represent the real order, branches, and loops. Each decision must have at least two distinct, labeled outgoing branches to distinct destinations. Preserve meaningful loops. Keep every node reachable from start and able to reach at least one end. Use 3–24 nodes and at most 48 edges. Node IDs may contain only ASCII letters, digits, and underscore. Do not add Markdown fences or commentary.
        """
    }

    private static func safeError(_ error: Error) -> FlowDiagramError {
        let detail = error.localizedDescription.lowercased()
        if let urlError = error as? URLError, [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(urlError.code) {
            return .cloudUnavailable
        }
        if ["401", "403", "unauthorized", "authentication", "not signed in", "signin"].contains(where: detail.contains) {
            return .authentication
        }
        if ["quota", "rate limit", "usage limit", "insufficient balance"].contains(where: detail.contains) {
            return .cloudUnavailable
        }
        if ["404", "not found", "no such model", "does not exist"].contains(where: detail.contains) {
            return .cloudOnly
        }
        return .cloudUnavailable
    }
}

@MainActor public final class FlowDiagramState: ObservableObject {
    @Published public var question = ""
    @Published public var selectedModelID = ""
    @Published public private(set) var graph: FlowDiagram?
    @Published public private(set) var graphQuestion: String?
    @Published public private(set) var isGenerating = false
    @Published public private(set) var error: String?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    let service: FlowDiagramService

    public convenience init() { self.init(service: FlowDiagramService()) }
    init(service: FlowDiagramService) { self.service = service }

    func generate(modelID: String, context: [FlowDiagramContextMessage], allowed: @escaping FlowDiagramPolicy) {
        guard !isGenerating else { return }
        let question = self.question
        let id = UUID()
        requestID = id
        error = nil
        isGenerating = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let graph = try await service.generate(modelID: modelID, question: question, context: context, allowed: allowed)
                guard requestID == id else { return }
                guard allowed() else { self.cancel(); return }
                self.graph = graph
                self.graphQuestion = question
                self.isGenerating = false
                self.task = nil
            } catch {
                guard requestID == id else { return }
                self.isGenerating = false
                self.task = nil
                if !Task.isCancelled, allowed() { self.error = error.localizedDescription }
            }
        }
    }

    public func cancel() {
        requestID = UUID()
        task?.cancel(); task = nil
        isGenerating = false
    }

    func fail(_ message: String) {
        error = message
    }
}
