import AppKit
import JackCore
import SwiftUI

enum BotTab: CaseIterable {
    case table, agents, routines, channels
    var title: String { switch self { case .table: return "Mesa"; case .agents: return "Agentes"; case .routines: return "Rutinas"; case .channels: return "Canales" } }
}

// MARK: - Top bar

/// The floating bar: logo and views on the left, the session in the middle, the mode and the stop buttons on the right.
struct BotTopBar: View {
    @ObservedObject var orchestrator: BotOrchestrator
    @Binding var tab: BotTab
    var onTab: (BotTab) -> Void
    @State private var confirmStop = false
    @State private var confirmDissolve = false

    private var autonomous: Bool { orchestrator.approvalMode == .autonomous }
    private var jack: BotAgent? { orchestrator.principal() }

    var body: some View {
        HStack(spacing: 10) {
            logo
            HStack(spacing: 6) {
                ForEach(BotTab.allCases, id: \.self) { item in
                    Button { tab = item; onTab(item) } label: {
                        Text(item.title).font(BC.sf(12, .medium)).foregroundStyle(tab == item ? Color.white : BC.dim)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tab == item ? Color.white.opacity(0.14) : BC.bar))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(tab == item ? 0.16 : 0.07), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            sessionChip
            Spacer(minLength: 8)
            modeSwitch
            Button("Disolver equipo") { confirmDissolve = true }
                .disabled(jack.map { orchestrator.children(of: $0.id).isEmpty } ?? true).buttonStyle(BCButtonStyle())
            Button { confirmStop = true } label: { Label("Detener todo", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                .disabled(orchestrator.activeSession == nil).buttonStyle(BCButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16).padding(.top, 12).frame(height: 56)
        .confirmationDialog("¿Detener a todos los bots?", isPresented: $confirmStop) {
            Button("Detener todo", role: .destructive) { orchestrator.stopAll() }
        } message: { Text("Para a Jack y a sus bots hijos y termina la sesión. Lo que ya hicieron se queda como está.") }
        .confirmationDialog("¿Disolver el equipo?", isPresented: $confirmDissolve) {
            Button("Disolver", role: .destructive) { orchestrator.dissolveTeam() }
        } message: { Text("Quita los bots hijos de Jack Bot. Sus conversaciones se quedan como chats normales.") }
    }

    private var logo: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2).frame(width: 22, height: 22)
            Circle().fill(Color.white).frame(width: 7, height: 7).offset(x: 6, y: -6)
        }
        .frame(width: 34, height: 34).accessibilityLabel("Jack Bot")
    }

    private var sessionChip: some View {
        HStack(spacing: 7) {
            Circle().fill(autonomous ? BC.pink : orchestrator.activeSession == nil ? BC.faint : BC.green).frame(width: 6, height: 6)
            Text(chipText).font(BC.sf(11.5, .medium)).foregroundStyle(autonomous ? BC.pink : BC.text).lineLimit(1)
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Capsule().fill(autonomous ? BC.pink.opacity(0.12) : BC.bar))
        .overlay(Capsule().strokeBorder(autonomous ? BC.pink.opacity(0.5) : Color.white.opacity(0.07), lineWidth: 1))
        .help("Una sesión empieza cuando le escribes a Jack y termina a los \(Int(orchestrator.policy.sessionDuration / 60)) minutos o con «Detener todo». Cada sesión nueva empieza en Preguntar.")
    }

    private var chipText: String {
        guard orchestrator.activeSession != nil else { return "Sin sesión · equipo de Jack" }
        let left = Int((orchestrator.timeLeft() ?? 0) / 60)
        return (autonomous ? "AUTÓNOMO · " : "Sesión · ") + "\(left) min"
    }

    /// PREGUNTAR / AUTÓNOMO. Only this switch or the user's own message to Jack can make it autonomous.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach([(BotApprovalMode.ask, "Preguntar"), (BotApprovalMode.autonomous, "Autónomo")], id: \.1) { item in
                let on = item.0 == (autonomous ? .autonomous : .ask)
                let tint = item.0 == .autonomous ? BC.pink : Color.white
                Button { if let jack { orchestrator.setApprovalMode(item.0, principal: jack) } } label: {
                    Text(item.1).font(BC.sf(11.5, .medium)).foregroundStyle(on ? (item.0 == .autonomous ? Color.black : Color.black) : BC.dim)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(Capsule().fill(on ? tint : Color.clear)).contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(jack == nil)
            }
        }
        .bcPill(padding: 3)
        .help("Preguntar: crear bots necesita tu aprobación. Autónomo: Jack crea y lanza bots sin preguntar. Solo tú puedes activarlo y vuelve a Preguntar en cada sesión nueva.")
    }
}

// MARK: - Canvas model and input

/// Zoom, pan and the positions the user gave the nodes. Memory only: the layout is rebuilt each time the table opens,
/// which keeps the store free of view state.
@MainActor final class BotViewport: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
}

/// The viewport lives in its own object, observed only by the two small layers that draw with it. Panning and zooming
/// therefore redraw the dots and move the content, but never rebuild the nodes.
struct BotDotLayer: View {
    @ObservedObject var viewport: BotViewport
    var body: some View { BCDotGrid(scale: viewport.scale, offset: viewport.offset) }
}
struct BotCable: Equatable { var from: CGPoint; var to: CGPoint; var highlighted: Bool }

/// Thin soft bezier curves from output ports to input ports. Drawn in screen space on a canvas the size of the view (never a
/// huge canvas in node space), with the viewport applied by hand.
struct BotCableLayer: View {
    @ObservedObject var viewport: BotViewport
    let cables: [BotCable]
    var body: some View {
        Canvas { context, _ in
            let k = viewport.scale, o = viewport.offset
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * k + o.width, y: p.y * k + o.height) }
            for cable in cables {
                let a = map(cable.from), b = map(cable.to)
                let dx = max(60 * k, abs(b.x - a.x) * 0.5)
                var path = Path()
                path.move(to: a)
                path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
                context.stroke(path, with: .color(.white.opacity(cable.highlighted ? 0.6 : 0.3)), lineWidth: cable.highlighted ? 1.6 : 1.2)
            }
        }
        .allowsHitTesting(false)
    }
}

struct BotTransformLayer<Content: View>: View {
    @ObservedObject var viewport: BotViewport
    let content: Content
    var body: some View { content.scaleEffect(viewport.scale, anchor: .topLeading).offset(viewport.offset) }
}

@MainActor final class BotCanvasModel: ObservableObject {
    let viewport = BotViewport()
    var scale: CGFloat { get { viewport.scale } set { viewport.scale = newValue } }
    var offset: CGSize { get { viewport.offset } set { viewport.offset = newValue } }
    @Published var positions: [String: CGPoint] = [:]
    @Published var selectedChild: UUID?
    var viewSize: CGSize = .zero
    private var dragStart: [String: CGPoint] = [:]
    static let range: ClosedRange<CGFloat> = 0.3...2

    func zoom(by factor: CGFloat, at point: CGPoint? = nil) {
        let anchor = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let new = min(max(scale * factor, Self.range.lowerBound), Self.range.upperBound)
        let ratio = new / scale
        offset = CGSize(width: anchor.x - (anchor.x - offset.width) * ratio, height: anchor.y - (anchor.y - offset.height) * ratio)
        scale = new
    }
    func pan(_ delta: CGSize) { offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height) }

    func fit(_ rects: [CGRect], inset: CGFloat = 70) {
        guard let first = rects.first, viewSize.width > 0 else { return }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }
        let top: CGFloat = 80, bottom: CGFloat = 150, side = inset + 40   // the bar on top, the prompt panel below, the strip aside
        let available = CGSize(width: max(viewSize.width - side * 2, 100), height: max(viewSize.height - top - bottom, 100))
        let new = min(max(min(available.width / box.width, available.height / box.height, 1.1), Self.range.lowerBound), Self.range.upperBound)
        scale = new
        offset = CGSize(width: (viewSize.width - box.width * new) / 2 - box.minX * new, height: top + (available.height - box.height * new) / 2 - box.minY * new)
    }

    func drag(_ id: String, from origin: CGPoint, translation: CGSize) {
        let start = dragStart[id] ?? origin
        dragStart[id] = start
        positions[id] = CGPoint(x: start.x + translation.width / scale, y: start.y + translation.height / scale)
    }
    func endDrag(_ id: String) { dragStart[id] = nil }
    func resetLayout() { positions = [:] }
}

/// Reads the trackpad and the wheel over the canvas: two fingers pan, pinch or ⌘-scroll zoom. A scroll over something that
/// scrolls by itself (a text) is left alone.
private struct CanvasInput: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> InputView { let view = InputView(); view.owner = self; return view }
    func updateNSView(_ view: InputView, context: Context) { view.owner = self }

    final class InputView: NSView {
        var owner: CanvasInput?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                var hit = window.contentView?.hitTest(event.locationInWindow)
                while let view = hit { if view is NSScrollView { return event }; hit = view.superview }
                if event.type == .magnify { self.owner?.onZoom(1 + event.magnification, point); return nil }
                if event.modifierFlags.contains(.command) { self.owner?.onZoom(exp(event.scrollingDeltaY * 0.01), point); return nil }
                self.owner?.onPan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - The table

/// Approximate node sizes, for placing the nodes and fitting them on screen. (Outside the generic view: static values.)
private enum BotNodeSize {
    static let jack = CGSize(width: 300, height: 360)
    static let proposal = CGSize(width: 330, height: 330)
    static let proposalEmpty = CGSize(width: 330, height: 150)
    static let child = CGSize(width: 250, height: 190)
    static let report = CGSize(width: 380, height: 400)
}


/// Jack and its team as nodes on a canvas, left to right: Jack, the proposal, the bots, the report.
struct BotTableView<Chat: View>: View {
    @ObservedObject var orchestrator: BotOrchestrator
    @ObservedObject var bots: BotStore
    @ObservedObject var store: ChatStore
    let projectPaths: [String]
    @ViewBuilder let chat: () -> Chat
    @StateObject private var model = BotCanvasModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var prompt = ""
    @State private var folder = ""
    @State private var showChat = false
    @State private var showPanels = true
    @State private var didFit = false
    @State private var popover: PanelPopover?
    @State private var providerPopover = false
    @State private var showCounters = true
    @State private var showCables = true

    private enum PanelPopover { case history, provider, limits, settings }
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    @State private var tick = Date()

    private var jack: BotAgent? { orchestrator.principal() }
    private var session: BotOrchestrator.Session? { orchestrator.activeSession }
    private var team: [BotAgent] { jack.map { orchestrator.children(of: $0.id) } ?? [] }
    private var pending: BotProposal? { orchestrator.proposals.first { $0.state == .pending } }
    private var autonomous: Bool { orchestrator.approvalMode == .autonomous }
    private var providerChoices: [BotProviderOption] { orchestrator.providerOptions() }

    // MARK: Layout

    private func defaultOrigin(_ id: String) -> CGPoint {
        switch id {
        case "jack": return CGPoint(x: 40, y: 190)
        case "proposal": return CGPoint(x: 430, y: 110)
        case "report": return CGPoint(x: 1190, y: 120)
        default:
            let index = team.firstIndex { $0.id.uuidString == id } ?? 0
            return CGPoint(x: 850, y: 20 + CGFloat(index) * 215)
        }
    }
    private func origin(_ id: String) -> CGPoint { model.positions[id] ?? defaultOrigin(id) }

    private var nodeRects: [CGRect] {
        guard jack != nil else { return [] }
        var rects = [CGRect(origin: origin("jack"), size: BotNodeSize.jack),
                     CGRect(origin: origin("proposal"), size: pending == nil ? BotNodeSize.proposalEmpty : BotNodeSize.proposal)]
        for child in team { rects.append(CGRect(origin: origin(child.id.uuidString), size: BotNodeSize.child)) }
        if !team.isEmpty { rects.append(CGRect(origin: origin("report"), size: BotNodeSize.report)) }
        return rects
    }

    private func fitToScreen() {
        let apply = { model.fit(nodeRects) }
        if reduceMotion { apply() } else { withAnimation(.easeInOut(duration: 0.25)) { apply() } }
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                BC.canvas
                BotDotLayer(viewport: model.viewport)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(BCNode<EmptyView>.canvasSpace))
                        .onChanged { model.pan(CGSize(width: $0.location.x - $0.startLocation.x - panDone.width, height: $0.location.y - $0.startLocation.y - panDone.height)); panDone = CGSize(width: $0.location.x - $0.startLocation.x, height: $0.location.y - $0.startLocation.y) }
                        .onEnded { _ in panDone = .zero })
                    .onTapGesture(count: 2) { fitToScreen() }
                if jack == nil {
                    createJack
                } else {
                    if showCables { BotCableLayer(viewport: model.viewport, cables: cableList) }
                    BotTransformLayer(viewport: model.viewport, content: content)
                }
                CanvasInput(onPan: { model.pan($0) }, onZoom: { model.zoom(by: $0, at: $1) }).allowsHitTesting(false)
                overlays
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: BCNode<EmptyView>.canvasSpace)
            .clipped()
            .onAppear {
                model.viewSize = geo.size
                if folder.isEmpty { folder = projectPaths.first ?? "" }
                orchestrator.scanCLIs()
                if let jack, let id = jack.conversationID, store.conversations.contains(where: { $0.id == id }) { store.select(id) }
                if !didFit { didFit = true; model.fit(nodeRects) }
            }
            .onChange(of: geo.size) { _, new in model.viewSize = new }
            .onChange(of: jack?.id) { _, _ in if jack != nil { model.fit(nodeRects) } }
        }
        .tint(.white).toggleStyle(BCToggleStyle()).buttonStyle(BCButtonStyle())
        .preferredColorScheme(.dark)
        .onReceive(clock) { tick = $0 }
    }
    @State private var panDone: CGSize = .zero

    // MARK: Canvas content

    private struct Edge: Identifiable {
        var from: String, fromPort: Int, to: String, toPort: Int, highlighted = false
        var id: String { from + String(fromPort) + to + String(toPort) }
    }

    private var edges: [Edge] {
        guard jack != nil else { return [] }
        var list = [Edge(from: "jack", fromPort: 1, to: "proposal", toPort: 0)]
        let selected = selectedChild
        for child in team {
            list.append(Edge(from: "jack", fromPort: 0, to: child.id.uuidString, toPort: 0))
            list.append(Edge(from: child.id.uuidString, fromPort: 0, to: "report", toPort: 0, highlighted: child.id == selected))
        }
        return list
    }

    private func width(of id: String) -> CGFloat {
        switch id { case "jack": return BotNodeSize.jack.width; case "proposal": return BotNodeSize.proposal.width; case "report": return BotNodeSize.report.width; default: return BotNodeSize.child.width }
    }

    /// The child the report node shows: the one clicked, else the latest that reported, else the first.
    private var selectedChild: UUID? {
        if let id = model.selectedChild, team.contains(where: { $0.id == id }) { return id }
        if let s = session, let reported = team.last(where: { s.reports[$0.id] != nil }) { return reported.id }
        return team.first?.id
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            glow
            if let jack {
                jackNode(jack).offset(x: origin("jack").x, y: origin("jack").y)
                proposalNode.offset(x: origin("proposal").x, y: origin("proposal").y)
                ForEach(Array(team.enumerated()), id: \.element.id) { index, child in
                    childNode(child, index: index).offset(x: origin(child.id.uuidString).x, y: origin(child.id.uuidString).y)
                }
                if !team.isEmpty { reportNode.offset(x: origin("report").x, y: origin("report").y) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The cables in node coordinates, from the nodes' positions alone: moving a node redraws them.
    private var cableList: [BotCable] {
        edges.map { edge in
            BotCable(from: CGPoint(x: origin(edge.from).x + width(of: edge.from), y: origin(edge.from).y + BCLayout.portY(edge.fromPort)),
                     to: CGPoint(x: origin(edge.to).x, y: origin(edge.to).y + BCLayout.portY(edge.toPort)), highlighted: edge.highlighted)
        }
    }

    /// One soft pastel halo behind the node that needs attention. A static gradient: no blur, nothing animated.
    private var glow: some View {
        let focus = pending != nil ? "proposal" : "jack"
        let size = focus == "proposal" ? BotNodeSize.proposal : BotNodeSize.jack
        let center = CGPoint(x: origin(focus).x + size.width / 2, y: origin(focus).y + size.height / 2)
        return ZStack {
            RadialGradient(colors: [BC.orange.opacity(autonomous ? 0.0 : 0.26), BC.pink.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 230)
                .frame(width: 460, height: 460).offset(x: center.x - 230 - 60, y: center.y - 230 - 20)
            RadialGradient(colors: [(autonomous ? BC.pink : BC.blue).opacity(0.24), .clear], center: .center, startRadius: 0, endRadius: 200)
                .frame(width: 400, height: 400).offset(x: center.x - 200 + 70, y: center.y - 200 - 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
    }

    private func nodeDrag(_ id: String) -> (drag: (DragGesture.Value) -> Void, end: () -> Void) {
        ({ model.drag(id, from: origin(id), translation: $0.translation) }, { model.endDrag(id) })
    }

    // MARK: Nodes

    private func jackNode(_ agent: BotAgent) -> some View {
        let working = agent.conversationID.map { store.statuses[$0]?.isActive == true } ?? false
        let waiting = agent.conversationID.map { (store.approvals[$0] ?? []).count } ?? 0
        let d = nodeDrag("jack")
        let pill: (String, Color)? = autonomous ? ("AUTÓNOMO", BC.pink) : waiting > 0 ? ("ESPERANDO APROBACIÓN", BC.yellow) : working ? ("TRABAJANDO", BC.green) : nil
        return BCNode(title: "Jack · principal", dot: working ? BC.green : .white, width: BotNodeSize.jack.width, pill: pill,
                      accent: autonomous ? BC.pink : working ? BC.green : nil, onDrag: d.drag, onDragEnd: d.end) {
            VStack(alignment: .leading, spacing: 0) {
                BCPort(label: "equipo", color: BC.green, side: .output)
                BCPort(label: "propuesta", color: BC.yellow, side: .output)
                fieldLabel("Proveedor")
                Button { providerPopover.toggle() } label: {
                    HStack {
                        Text(providerLabel(agent)).font(BC.sf(12)).foregroundStyle(BC.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(BC.dim)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BC.field))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $providerPopover, arrowEdge: .bottom) { providerPicker(agent) }
                fieldLabel("Instrucciones")
                InstructionsField(agent: agent, bots: bots, store: store)
                Text("~/" + URL(fileURLWithPath: agent.projectPath).lastPathComponent).font(BC.sf(10)).foregroundStyle(BC.faint).padding(.top, 8).lineLimit(1)
            }
        }
    }

    private var proposalNode: some View {
        let d = nodeDrag("proposal")
        return BCNode(title: "Propuesta", dot: BC.yellow, width: BotNodeSize.proposal.width, pill: pending == nil ? nil : ("ESPERANDO APROBACIÓN", BC.yellow),
                      accent: pending == nil ? nil : BC.yellow, dimmed: pending == nil, onDrag: d.drag, onDragEnd: d.end) {
            VStack(alignment: .leading, spacing: 0) {
                BCPort(label: "propuesta", color: BC.yellow, side: .input)
                if let proposal = pending {
                    if !proposal.rationale.isEmpty {
                        Text(proposal.rationale).font(BC.sf(11.5)).foregroundStyle(BC.text).padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(proposal.children.enumerated()), id: \.offset) { index, child in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(BC.code("H", index)).font(BC.sf(10, .semibold)).foregroundStyle(BC.yellow)
                                        Text(child.name).font(BC.sf(11.5, .medium)).foregroundStyle(BC.text)
                                        Spacer()
                                        Text(child.providerLabel).font(BC.sf(10)).foregroundStyle(BC.dim)
                                    }
                                    Text(child.task).font(BC.sf(11)).foregroundStyle(BC.dim).lineLimit(3)
                                }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BC.field))
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                    HStack {
                        Spacer()
                        Button("Rechazar") { orchestrator.reject(proposal.id) }
                        Button("Aprobar y lanzar") {
                            if case .failure(let error) = orchestrator.approve(proposal.id) { store.errorMessage = error.message }
                        }
                        .buttonStyle(BCButtonStyle(prominent: true))
                    }
                    .padding(.top, 10)
                } else {
                    Text(autonomous ? "Modo autónomo: Jack lanza los bots sin pedirte aprobación." : "Cuando Jack proponga un equipo aparecerá aquí para que lo apruebes.")
                        .font(BC.sf(11)).foregroundStyle(BC.dim).padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func childState(_ agent: BotAgent) -> (text: String, color: Color)? {
        let state = orchestrator.session?.children[agent.id]
        if state == .stopped { return ("DETENIDO", BC.orange) }
        if !(agent.conversationID.map { (store.approvals[$0] ?? []).isEmpty } ?? true) { return ("ESPERANDO APROBACIÓN", BC.yellow) }
        let status = agent.conversationID.flatMap { store.statuses[$0] }
        if status == .failed { return ("ERROR", BC.red) }
        if state == .reported { return ("TERMINADO", BC.blue) }
        if status?.isActive == true { return ("TRABAJANDO", BC.green) }
        return nil
    }

    private func childNode(_ agent: BotAgent, index: Int) -> some View {
        let id = agent.id.uuidString
        let state = childState(agent)
        let isSelected = agent.id == selectedChild
        let used = orchestrator.session?.children[agent.id] != nil ? (orchestrator.session?.perChild[agent.id] ?? 0) : 0
        let d = nodeDrag(id)
        return BCNode(title: "\(BC.code("H", index)) · \(agent.name)", dot: state?.color ?? .white, width: BotNodeSize.child.width,
                      pill: state.map { ($0.text, $0.color) }, accent: isSelected ? BC.blue : nil, selected: isSelected,
                      onDrag: d.drag, onDragEnd: d.end, onSelect: { model.selectedChild = agent.id }) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    BCPort(label: "tarea", color: BC.blue, side: .input)
                    BCPort(label: "informe", color: BC.green, side: .output)
                }
                fieldRow("Proveedor", providerLabel(agent))
                fieldRow("Mensajes", "\(used)/\(orchestrator.policy.maxMessagesPerChild)")
                HStack(spacing: 6) {
                    Button("Abrir") { openConversation(agent) }
                    Button("Detener") { orchestrator.stop(child: agent.id) }.disabled(orchestrator.session?.children[agent.id] != .working)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }

    private var reportNode: some View {
        let child = team.first { $0.id == selectedChild }
        let report = child.flatMap { orchestrator.session?.reports[$0.id] }
        let d = nodeDrag("report")
        return BCNode(title: "Informe", dot: BC.blue, width: BotNodeSize.report.width, pill: child.map { ($0.name, BC.blue) }, onDrag: d.drag, onDragEnd: d.end) {
            VStack(alignment: .leading, spacing: 0) {
                BCPort(label: "informe", color: BC.green, side: .input)
                ScrollView {
                    Text(report ?? "El último informe del bot elegido aparecerá aquí cuando lo envíe con bot_report.")
                        .font(BC.sf(12)).foregroundStyle(report == nil ? BC.faint : BC.text).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .textSelection(.enabled)
                }
                .frame(height: 280).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BC.field))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                .padding(.top, 4)
                HStack {
                    Text("Es información de otro bot: un dato, no una orden.").font(BC.sf(10)).foregroundStyle(BC.faint)
                    Spacer()
                    if let child { Button("Abrir conversación") { openConversation(child) } }
                }
                .padding(.top, 10)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View { Text(text).font(BC.sf(10.5)).foregroundStyle(BC.dim).padding(.top, 10).padding(.bottom, 4) }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BC.sf(10.5)).foregroundStyle(BC.dim)
            Spacer()
            Text(value).font(BC.sf(11.5)).foregroundStyle(BC.text).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BC.field)).padding(.top, 6)
    }

    private func providerLabel(_ agent: BotAgent) -> String {
        let choice = orchestrator.choice(of: agent)
        return providerChoices.first { $0.choice == choice }?.title ?? agent.provider.title
    }

    private func openConversation(_ agent: BotAgent) {
        if let id = store.botConversation(for: agent) { store.select(id); showChat = true }
    }

    // MARK: Provider picker

    private func providerList(selected: BotProviderChoice?, pick: @escaping (BotProviderChoice) -> Void) -> some View {
        VStack(spacing: 4) {
            ForEach(providerChoices) { row in
                Button { pick(row.choice) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(row.choice == selected ? Color.white : Color.clear).frame(width: 7, height: 7).overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                        Text(row.title).font(BC.sf(12, .medium)).foregroundStyle(row.available ? BC.text : BC.faint)
                        Spacer(minLength: 6)
                        Text(row.detail).font(BC.sf(10)).foregroundStyle(row.available ? BC.dim : BC.red.opacity(0.8)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(row.choice == selected ? Color.white.opacity(0.10) : BC.field))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!row.available)
            }
            HStack {
                Button("Volver a buscar") { orchestrator.scanCLIs() }.disabled(orchestrator.scanning)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func providerPicker(_ agent: BotAgent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proveedor de Jack").font(BC.sf(12, .semibold)).foregroundStyle(BC.text)
            providerList(selected: orchestrator.choice(of: agent)) { choice in
                orchestrator.setProvider(choice, for: agent); providerPopover = false; popover = nil
            }
            Text("Un bot que está trabajando cambia de motor cuando termine. Solo aparecen los motores que Jack ya integra y tienes instalados.")
                .font(BC.sf(10.5)).foregroundStyle(BC.faint)
        }
        .padding(14).frame(width: 330).background(BC.canvas).tint(.white).buttonStyle(BCButtonStyle()).preferredColorScheme(.dark)
    }

    // MARK: Create Jack

    private var createJack: some View {
        BCNode(title: "Jack · principal", dot: .white, width: 360) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Jack es el bot principal. Tú le hablas; cuando la tarea lo pide, te propone un equipo de bots y tú lo apruebas. Elige con qué motor trabaja (las CLI que Jack ya integra).")
                    .font(BC.sf(11.5)).foregroundStyle(BC.dim).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                fieldLabel("Carpeta de trabajo")
                HStack(spacing: 8) {
                    Picker("", selection: $folder) {
                        ForEach(projectPaths, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                        if !folder.isEmpty && !projectPaths.contains(folder) { Text(URL(fileURLWithPath: folder).lastPathComponent).tag(folder) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                    Button("Elegir…") { chooseFolder() }
                }
                fieldLabel("Crear a Jack con")
                providerList(selected: nil) { choice in create(choice) }
            }
        }
    }

    private func create(_ choice: BotProviderChoice) {
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { store.errorMessage = "Elige la carpeta donde trabajará Jack."; return }
        let agent = orchestrator.ensurePrincipal(projectPath: folder, choice: choice)
        if let id = agent.conversationID { store.select(id) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"; panel.message = "Carpeta de trabajo de Jack"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    // MARK: Floating panels

    private var overlays: some View {
        ZStack {
            if showCounters && showPanels { counters }
            if jack != nil {
                VStack(spacing: 0) {
                    Spacer()
                    if showPanels { promptPanel }
                }
                .padding(.bottom, 22).frame(maxWidth: .infinity)
                strip
                if showChat { chatPanel }
            }
        }
    }

    private var counters: some View {
        let policy = orchestrator.policy
        let s = session
        let left = orchestrator.timeLeft().map { "\(Int($0 / 60)) min" } ?? "—"
        _ = tick
        return VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HIJOS  \(s.map { orchestrator.activeChildren(in: $0).count } ?? 0)/\(policy.maxActiveChildren)")
                    Text("CREADOS  \(s?.spawned ?? 0)/\(policy.maxChildrenPerSession)")
                    Text("PROFUNDIDAD  \(policy.maxDepth)")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("MENSAJES  \(s?.messages ?? 0)/\(policy.maxMessagesPerSession)")
                    Text("TIEMPO  \(left)")
                    Text("MODO  \(autonomous ? "AUTÓNOMO" : "PREGUNTAR")")
                }
            }
            .font(BC.mono(9.5)).foregroundStyle(Color.white.opacity(0.36)).padding(.horizontal, 22).padding(.bottom, 18)
        }
        .allowsHitTesting(false)
    }

    private var promptPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Pídele algo a Jack…", text: $prompt, axis: .vertical).textFieldStyle(.plain).lineLimit(1...4)
                    .font(BC.sf(12.5)).foregroundStyle(BC.text).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(BCIconButtonStyle(active: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Enviar a Jack")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10).frame(minHeight: 56, alignment: .top)
            HStack(spacing: 6) {
                panelButton(.history, "clock", "Historial de propuestas e informes")
                panelButton(.provider, "cube", "Proveedor de Jack")
                panelButton(.limits, "gauge.with.dots.needle.33percent", "Límites de la sesión")
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4)
                panelButton(.settings, "gearshape", "Ajustes de la mesa")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.black.opacity(0.28))
        }
        .frame(width: 540)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.095)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0.05), Color.white.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
    }

    private func panelButton(_ kind: PanelPopover, _ symbol: String, _ help: String) -> some View {
        Button { popover = popover == kind ? nil : kind } label: { Image(systemName: symbol) }
            .buttonStyle(BCIconButtonStyle(active: popover == kind)).help(help).accessibilityLabel(help)
            .popover(isPresented: Binding(get: { popover == kind }, set: { if !$0, popover == kind { popover = nil } }), arrowEdge: .top) { popoverContent(kind) }
    }

    @ViewBuilder private func popoverContent(_ kind: PanelPopover) -> some View {
        Group {
            switch kind {
            case .history: historyContent
            case .provider: if let jack { providerPicker(jack) }
            case .limits: limitsContent
            case .settings: settingsContent
            }
        }
        .tint(.white).buttonStyle(BCButtonStyle()).toggleStyle(BCToggleStyle()).preferredColorScheme(.dark)
    }

    private var historyContent: some View {
        let decided = orchestrator.proposals.reversed()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Historial").font(BC.sf(12, .semibold)).foregroundStyle(BC.text)
            if decided.isEmpty { Text("Todavía no hay propuestas en esta sesión de la app.").font(BC.sf(11)).foregroundStyle(BC.dim) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(decided)) { proposal in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(proposal.children.map(\.name).joined(separator: ", ")).font(BC.sf(11.5, .medium)).foregroundStyle(BC.text).lineLimit(1)
                                Spacer()
                                BCStatusPill(text: proposal.state == .pending ? "PENDIENTE" : proposal.state == .rejected ? "RECHAZADA" : proposal.auto ? "AUTO" : "APROBADA",
                                             color: proposal.state == .pending ? BC.yellow : proposal.state == .rejected ? BC.red : BC.green)
                            }
                            if !proposal.rationale.isEmpty { Text(proposal.rationale).font(BC.sf(10.5)).foregroundStyle(BC.dim).lineLimit(2) }
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BC.field))
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(14).frame(width: 340).background(BC.canvas)
    }

    private var limitsContent: some View {
        let p = orchestrator.policy
        let rows: [(String, String)] = [("Hijos a la vez", "\(p.maxActiveChildren)"), ("Hijos por sesión", "\(p.maxChildrenPerSession)"), ("Profundidad", "\(p.maxDepth) (los hijos no crean bots)"),
                                       ("Mensajes por hijo", "\(p.maxMessagesPerChild)"), ("Mensajes por sesión", "\(p.maxMessagesPerSession)"), ("Duración de la sesión", "\(Int(p.sessionDuration / 60)) min")]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Límites de la sesión").font(BC.sf(12, .semibold)).foregroundStyle(BC.text)
            ForEach(rows, id: \.0) { row in
                HStack { Text(row.0).foregroundStyle(BC.dim); Spacer(); Text(row.1).foregroundStyle(BC.text) }.font(BC.sf(11.5))
            }
            Text("Valen igual en Preguntar y en Autónomo. No hay precio por token: el tope de gasto de un motor de pago son los turnos y el tiempo. «Detener todo» para a todos y termina la sesión.")
                .font(BC.sf(10.5)).foregroundStyle(BC.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 320).background(BC.canvas)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ajustes de la mesa").font(BC.sf(12, .semibold)).foregroundStyle(BC.text)
            Toggle("Mostrar cables", isOn: $showCables)
            Toggle("Mostrar contadores", isOn: $showCounters)
            Button("Restablecer posiciones") { model.resetLayout(); fitToScreen() }
            Text("Zoom: pellizco o ⌘ + rueda. Paneo: dos dedos o arrastrar el fondo. Doble clic en el fondo: encajar. Las posiciones de los nodos no se guardan al cerrar.")
                .font(BC.sf(10.5)).foregroundStyle(BC.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 300).background(BC.canvas)
    }

    private func send() {
        guard let jack else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch orchestrator.ask(text, principal: jack) {
        case .success(let id): prompt = ""; store.select(id); showChat = true
        case .failure(let error): store.errorMessage = error.message
        }
    }

    // MARK: Right strip and chat

    private var strip: some View {
        VStack(spacing: 8) {
            stripButton("plus", "Acercar") { model.zoom(by: 1.2) }
            stripButton("minus", "Alejar") { model.zoom(by: 1 / 1.2) }
            stripButton("arrow.up.left.and.arrow.down.right", "Encajar en pantalla") { fitToScreen() }
            stripButton(showPanels ? "eye" : "eye.slash", showPanels ? "Ocultar paneles" : "Mostrar paneles") { showPanels.toggle() }
            stripButton("bubble.left.and.bubble.right", showChat ? "Ocultar la conversación" : "Mostrar la conversación", active: showChat) { showChat.toggle() }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BC.bar.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 16)
    }

    private func stripButton(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(BCIconButtonStyle(active: active)).help(help).accessibilityLabel(help)
    }

    private var chatPanel: some View {
        Group {
            if store.selectedID != nil { chat() } else { Text("La conversación aparece aquí").font(BC.sf(11)).foregroundStyle(BC.faint).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 420).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BC.card))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 70).padding(.top, 68).padding(.bottom, 118)
    }
}

/// Jack's instructions, edited in place. Saved when the field loses focus; the conversation takes them from its next message.
private struct InstructionsField: View {
    let agent: BotAgent
    @ObservedObject var bots: BotStore
    @ObservedObject var store: ChatStore
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text).focused($focused).bcEditor(height: 92).font(BC.sf(11)).foregroundStyle(BC.text.opacity(0.85))
            .onAppear { text = agent.instructions }
            .onChange(of: agent.instructions) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        guard text != agent.instructions, var current = bots.agents.first(where: { $0.id == agent.id }) else { return }
        current.instructions = text
        bots.upsert(current)
        if current.conversationID != nil { _ = store.botConversation(for: current) }
    }
}
