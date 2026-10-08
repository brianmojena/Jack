import AppKit
import JackCore
import SwiftUI

/// The Normal flow workspace can generate an on-demand graph; Light keeps the original plan viewer.
struct FlowPanel: View {
    @ObservedObject var store: ChatStore
    let conversationID: UUID

    var body: some View {
        if store.lightModeEnabled {
            PlanFlowView(plan: store.plan(for: conversationID)?.markdown).equatable()
        } else {
            NormalFlowDiagramPanel(store: store, conversationID: conversationID)
        }
    }
}

private struct NormalFlowDiagramPanel: View {
    @ObservedObject var store: ChatStore
    let conversationID: UUID
    @ObservedObject var diagram: FlowDiagramState
    @State private var modelToLink = ""
    @State private var linking = false
    @State private var linkError: String?
    @State private var linkRequestID = UUID()

    init(store: ChatStore, conversationID: UUID) {
        self.store = store
        self.conversationID = conversationID
        _diagram = ObservedObject(wrappedValue: store.flowDiagramState(for: conversationID))
    }

    private var cloudModels: [StellarModel] {
        store.localModels.filter { $0.server.api == .ollama && $0.isCloud }
    }
    private var conversation: ChatConversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { panelTitle; Spacer(minLength: 4); headerActions }
                VStack(alignment: .leading, spacing: 6) { panelTitle; headerActions }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { questionEditor.frame(minWidth: 220); modelPicker.frame(width: 245, alignment: .leading) }
                VStack(alignment: .leading, spacing: 10) { questionEditor; modelPicker }
            }
            .padding(10)
            .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }

            if let error = diagram.error {
                HStack(spacing: 8) {
                    Text(error).font(.system(size: 11)).foregroundStyle(JackPalette.red)
                    Spacer()
                    Button("Reintentar") { generate() }.controlSize(.small).disabled(diagram.isGenerating)
                }.padding(.horizontal, 12).padding(.vertical, 7)
            }

            if let graph = diagram.graph {
                NativeFlowGraph(graph: graph)
            } else if let plan = store.plan(for: conversationID)?.markdown, PlanFlow.parse(plan) != nil {
                PlanFlowView(plan: plan).equatable()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "flowchart").font(.system(size: 26, weight: .light)).foregroundStyle(JackPalette.faint)
                    Text("Sin diagrama todavía").font(.system(size: 12.5, weight: .medium)).foregroundStyle(JackPalette.muted)
                    Text("Escribe una pregunta arriba y pulsa Generar para crear un diagrama de flujo.")
                        .font(.system(size: 11.5)).foregroundStyle(JackPalette.faint).multilineTextAlignment(.center).frame(maxWidth: 270)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: chooseInitialModel)
        .onChange(of: cloudModels.map(\.id)) { _, _ in chooseInitialModel() }
        .onDisappear { linkRequestID = UUID(); linking = false }
    }

    private var panelTitle: some View {
        Text(diagram.graph?.title ?? "Diagrama de flujo").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if diagram.isGenerating {
                ProgressView().controlSize(.small)
                Button("Cancelar") { diagram.cancel() }.controlSize(.small)
            } else {
                Button(diagram.graph == nil ? "Generar" : "Regenerar", systemImage: "sparkles") { generate() }
                    .controlSize(.small).disabled(diagram.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cloudModels.contains(where: { $0.id == diagram.selectedModelID }))
            }
            if let graph = diagram.graph {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(graph.mermaid, forType: .string)
                } label: { Label("Copiar Mermaid", systemImage: "doc.on.doc") }.controlSize(.small)
            }
        }
    }

    private var questionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pregunta").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(JackPalette.muted)
            TextEditor(text: $diagram.question).font(.system(size: 12)).frame(minHeight: 48, maxHeight: 72)
                .scrollContentBackground(.hidden).padding(5)
                .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JackPalette.hairline))
            HStack {
                Button("Usar última pregunta") {
                    if let latest = conversation?.messages.last(where: { $0.role == "user" })?.text { diagram.question = latest }
                }.controlSize(.small).disabled(conversation?.messages.last(where: { $0.role == "user" }) == nil)
                Spacer(minLength: 4)
                Text("Pregunta y contexto visible reciente se envían a Ollama Cloud.")
                    .font(.system(size: 10)).foregroundStyle(JackPalette.faint).lineLimit(2)
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modelo de nube").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(JackPalette.muted)
            if cloudModels.isEmpty {
                Text("Vincula un modelo :cloud en Ollama (cuenta iniciada con ollama signin).")
                    .font(.system(size: 10.5)).foregroundStyle(JackPalette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Modelo de nube", selection: $diagram.selectedModelID) {
                    ForEach(cloudModels) { model in Text(model.title).tag(model.id) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 5) {
                TextField("p. ej. gemma4:cloud", text: $modelToLink).textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button(linking ? "Validando…" : "Vincular") { linkModel() }.controlSize(.small)
                    .disabled(linking || modelToLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { Task { await store.refreshLocalModels() } } label: { Image(systemName: "arrow.clockwise") }
                    .controlSize(.small).help("Actualizar modelos de nube")
            }
            if let linkError { Text(linkError).font(.system(size: 10.5)).foregroundStyle(JackPalette.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func chooseInitialModel() {
        guard !cloudModels.isEmpty else { return }
        if cloudModels.contains(where: { $0.id == diagram.selectedModelID }) { return }
        if let selected = conversation?.model, cloudModels.contains(where: { $0.id == selected }) { diagram.selectedModelID = selected }
        else { diagram.selectedModelID = cloudModels[0].id }
    }

    private func generate() {
        guard !store.lightModeEnabled, !diagram.isGenerating else { return }
        store.generateFlowDiagram(in: conversationID, modelID: diagram.selectedModelID)
    }

    private func linkModel() {
        guard !linking else { return }
        linking = true; linkError = nil
        let requestID = UUID()
        linkRequestID = requestID
        let name = modelToLink
        Task {
            do {
                let model = try await store.linkOllamaCloudModel(name)
                guard linkRequestID == requestID, !store.lightModeEnabled else { return }
                diagram.selectedModelID = model.id
                modelToLink = ""
            } catch {
                guard linkRequestID == requestID else { return }
                linkError = error.localizedDescription
            }
            guard linkRequestID == requestID else { return }
            linking = false
        }
    }
}

private struct NativeFlowGraph: View {
    let graph: FlowDiagram
    private let nodeWidth: CGFloat = 224
    private let nodeHeight: CGFloat = 82

    var body: some View {
        let diagramLayout = FlowDiagramLayout(graph: graph)
        let positions = diagramLayout.frames.mapValues { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let size = CGSize(width: CGFloat(diagramLayout.size.width), height: CGFloat(diagramLayout.size.height))
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                        let route = diagramLayout.returnRoutes[edge.id]
                        let start = CGPoint(x: from.x + nodeWidth / 2, y: from.y + nodeHeight)
                        let end = CGPoint(x: to.x + nodeWidth / 2, y: to.y)
                        var path = Path(); path.move(to: start)
                        if let route {
                            for point in route.points.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
                        } else {
                            let bend = (end.y - start.y) * 0.45
                            path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y - bend))
                        }
                        context.stroke(path, with: .color(JackPalette.faint), lineWidth: 1.4)
                        let previous: CGPoint = {
                            if let point = route?.points.dropLast().last {
                                return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                            }
                            return CGPoint(x: end.x, y: end.y - 8)
                        }()
                        let dx = end.x - previous.x, dy = end.y - previous.y
                        let length = max(1, hypot(dx, dy)), ux = dx / length, uy = dy / length
                        let base = CGPoint(x: end.x - ux * 8, y: end.y - uy * 8)
                        var arrow = Path(); arrow.move(to: end); arrow.addLine(to: CGPoint(x: base.x - uy * 4, y: base.y + ux * 4)); arrow.move(to: end); arrow.addLine(to: CGPoint(x: base.x + uy * 4, y: base.y - ux * 4))
                        context.stroke(arrow, with: .color(JackPalette.faint), lineWidth: 1.4)
                    }
                }.frame(width: size.width, height: size.height)
                ForEach(graph.edges.filter { !($0.label ?? "").isEmpty }) { edge in
                    let from = positions[edge.from] ?? .zero, to = positions[edge.to] ?? .zero
                    let labelPoint: CGPoint = {
                        if let route = diagramLayout.returnRoutes[edge.id] {
                            return CGPoint(x: CGFloat(route.labelPoint.x), y: CGFloat(route.labelPoint.y))
                        }
                        return CGPoint(x: (from.x + to.x + nodeWidth) / 2, y: (from.y + nodeHeight + to.y) / 2)
                    }()
                    Text(edge.label ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(JackPalette.secondaryText)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(JackPalette.canvas.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                        .position(labelPoint).help(edge.label ?? "").textSelection(.enabled)
                }
                ForEach(graph.nodes) { node in
                    let point = positions[node.id] ?? .zero
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: node.kind == .decision ? "diamond.fill" : (node.kind == .start ? "play.circle.fill" : node.kind == .end ? "stop.circle.fill" : "circle.fill"))
                            Text(node.kind == .start ? "Inicio" : node.kind == .end ? "Fin" : node.kind == .decision ? "Decisión" : "Proceso")
                        }.font(.system(size: 9, weight: .bold)).foregroundStyle(node.kind == .decision ? JackPalette.amber : JackPalette.accent)
                        Text(node.label).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true).lineLimit(4)
                            .help(node.label).textSelection(.enabled)
                    }
                    .padding(10).frame(width: nodeWidth, height: nodeHeight, alignment: .leading)
                    .background {
                        if node.kind == .start || node.kind == .end { Capsule().fill(JackPalette.panel) }
                        else { RoundedRectangle(cornerRadius: 9).fill(JackPalette.panel) }
                    }
                    .overlay {
                        if node.kind == .start || node.kind == .end { Capsule().stroke(node.kind == .decision ? JackPalette.amber.opacity(0.6) : JackPalette.hairline) }
                        else { RoundedRectangle(cornerRadius: 9).stroke(node.kind == .decision ? JackPalette.amber.opacity(0.6) : JackPalette.hairline) }
                    }
                    .position(x: point.x + nodeWidth / 2, y: point.y + nodeHeight / 2)
                }
            }.padding(12)
        }
    }
}

private struct PlanFlowView: View, Equatable {
    let plan: String?

    var body: some View {
        if let plan, let flow = PlanFlow.parse(plan) {
            VStack(spacing: 0) {
                header(flow)
                ScrollView {
                    FlowChart(flow: flow)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "flowchart").font(.system(size: 26, weight: .light)).foregroundStyle(JackPalette.faint)
                Text(plan == nil ? "Sin plan todavía" : "El plan no tiene pasos que dibujar")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(JackPalette.muted)
                Text("Cuando un agente en modo Plan proponga un plan, su diagrama de flujo aparece aquí.")
                    .font(.system(size: 11.5)).foregroundStyle(JackPalette.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ flow: PlanFlow) -> some View {
        HStack(spacing: 8) {
            Text(flow.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text("\(flow.steps.count) pasos").font(.system(size: 11.5)).foregroundStyle(JackPalette.muted)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(flow.mermaid, forType: .string)
            } label: {
                Label("Copiar Mermaid", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copia el diagrama como `flowchart TD` de Mermaid")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
}

private struct FlowChart: View {
    let flow: PlanFlow
    private let width: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            terminal(flow.title, symbol: "play.fill")
            ForEach(Array(flow.steps.enumerated()), id: \.element.id) { index, step in
                let previous = index > 0 ? flow.steps[index - 1] : nil
                if let phase = step.phase, phase != previous?.phase {
                    FlowArrow(label: nil)
                    phaseLabel(phase)
                    FlowArrow(label: nil)
                } else {
                    FlowArrow(label: previous?.isDecision == true ? "sí" : nil)
                }
                FlowNode(step: step)
            }
            FlowArrow(label: flow.steps.last?.isDecision == true ? "sí" : nil)
            terminal("Listo", symbol: "checkmark")
        }
        .frame(maxWidth: width)
    }

    private func terminal(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(JackPalette.secondaryText)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(JackPalette.panelStrong, in: Capsule())
    }

    private func phaseLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(JackPalette.muted).lineLimit(1)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowNode: View {
    let step: PlanFlow.Step

    var body: some View {
        let tint = step.isDecision ? JackPalette.amber : JackPalette.accent
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if step.isDecision {
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.2)).frame(width: 18, height: 18).rotationEffect(.degrees(45))
                    Image(systemName: "questionmark").font(.system(size: 8, weight: .bold)).foregroundStyle(tint)
                } else {
                    Circle().fill(tint.opacity(0.18)).frame(width: 22, height: 22)
                    Text("\(step.id + 1)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(step.details.enumerated()), id: \.offset) { _, detail in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(JackPalette.faint)
                        Text(detail).foregroundStyle(JackPalette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11.5))
                }
                if !step.files.isEmpty {
                    FlowFiles(files: step.files)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(step.isDecision ? tint.opacity(0.5) : JackPalette.hairline, lineWidth: 1))
        .textSelection(.enabled)
        .contextMenu {
            Button("Copiar paso", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(([step.title] + step.details.map { "- " + $0 }).joined(separator: "\n"), forType: .string)
            }
        }
    }
}

private struct FlowFiles: View {
    let files: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(files.prefix(4), id: \.self) { file in
                Text(file.split(separator: "/").last.map(String.init) ?? file)
                    .font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: 4))
                    .help(file)
            }
            if files.count > 4 { Text("+\(files.count - 4)").font(.system(size: 10.5)).foregroundStyle(JackPalette.muted) }
        }
    }
}

/// The line between two nodes, ending in an arrowhead.
private struct FlowArrow: View {
    let label: String?

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: 16))
                path.move(to: CGPoint(x: -3.5, y: 12))
                path.addLine(to: CGPoint(x: 0.5, y: 17))
                path.addLine(to: CGPoint(x: 4.5, y: 12))
            }
            .stroke(JackPalette.faint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: 1, height: 18)
            if let label {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(JackPalette.muted)
                    .offset(x: 16)
            }
        }
        .frame(height: 18)
    }
}
