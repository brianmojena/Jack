import AppKit
import JackCore
import SwiftUI
import UniformTypeIdentifiers

/// Agents dragged from the sidebar travel as plain text with this prefix.
enum AgentDrag {
    static let prefix = "jack-agent:"
    static func provider(_ id: UUID) -> NSItemProvider { NSItemProvider(object: (prefix + id.uuidString) as NSString) }
    static func id(in text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
    /// The agent in a drop, if there is one.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor (UUID) -> Void) {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, let id = id(in: text) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(id) } }
        }
    }
}

/// Sizes for the chats in the window.
enum AgentPanes {
    /// Narrower than this a chat wraps every line; columns that do not fit wait until the window grows.
    static let minimumWidth: CGFloat = 340
    /// Lower than this a stacked chat shows a line or two above its composer.
    static let minimumHeight: CGFloat = 200

    /// How many columns fit in `width` points.
    static func columns(in width: CGFloat) -> Int {
        max(1, Int((width + 1) / (minimumWidth + 1)))
    }

    /// Each chat's share of the space, as the user left it; equal shares when the chats changed.
    static func weights(_ stored: String, count: Int) -> [CGFloat] {
        let equal = Array(repeating: 1 / CGFloat(max(count, 1)), count: count)
        let values = stored.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        guard values.count == count, values.allSatisfy({ $0 > 0 }) else { return equal }
        let total = values.reduce(0, +)
        return values.map { $0 / total }
    }

    static func encode(_ weights: [CGFloat]) -> String {
        weights.map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
    }
}

/// Chats side by side or one above another, resized by dragging the lines between them.
/// Dragging only moves this view's state: the chats relayout, but the window's body does not run again.
struct PaneStack<Content: View>: View {
    let axis: Axis
    let count: Int
    let content: Content
    @AppStorage private var storedWeights: String
    @State private var liveWeights: [CGFloat]?
    @State private var dragStart: [CGFloat]?

    init(_ axis: Axis, count: Int, key: String, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.count = count
        self.content = content()
        _storedWeights = AppStorage(wrappedValue: "", key)
    }

    private var minimum: CGFloat { axis == .horizontal ? AgentPanes.minimumWidth : AgentPanes.minimumHeight }

    var body: some View {
        let weights = liveWeights ?? AgentPanes.weights(storedWeights, count: count)
        StackLayout(axis: axis, weights: weights) { content }
            .overlay {
                if count > 1 {
                    GeometryReader { geometry in
                        let length = axis == .horizontal ? geometry.size.width : geometry.size.height
                        let usable = length - CGFloat(count - 1)
                        ForEach(1..<count, id: \.self) { index in
                            let at = StackLayout.origin(of: index, weights: weights, usable: usable) - 0.5
                            divider(index, weights: weights, usable: usable)
                                .frame(width: axis == .horizontal ? nil : geometry.size.width,
                                       height: axis == .horizontal ? geometry.size.height : nil)
                                .position(x: axis == .horizontal ? at : geometry.size.width / 2,
                                          y: axis == .horizontal ? geometry.size.height / 2 : at)
                        }
                    }
                }
            }
    }

    private func divider(_ index: Int, weights: [CGFloat], usable: CGFloat) -> some View {
        let horizontal = axis == .horizontal
        return Rectangle().fill(JackPalette.hairline)
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                // A wider invisible grip than the 1-point line.
                Color.clear.frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7).contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? weights
                                if dragStart == nil { dragStart = start }
                                guard usable > 0 else { return }
                                let pair = start[index - 1] + start[index]
                                let least = min(minimum / usable, pair / 2)
                                let moved = (horizontal ? value.translation.width : value.translation.height) / usable
                                var next = start
                                next[index - 1] = min(max(start[index - 1] + moved, least), pair - least)
                                next[index] = pair - next[index - 1]
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { liveWeights = next }
                            }
                            .onEnded { _ in
                                if let liveWeights { storedWeights = AgentPanes.encode(liveWeights) }
                                liveWeights = nil
                                dragStart = nil
                            }
                    )
                    // Double-click shares the space equally again.
                    .onTapGesture(count: 2) { storedWeights = "" }
            }
            .help("Arrastra para cambiar el tamaño; doble clic para igualarlos")
    }
}

/// Places chats in a row or a column with a 1-point gap for the line between them, each with its share.
private struct StackLayout: Layout {
    let axis: Axis
    let weights: [CGFloat]

    static func origin(of index: Int, weights: [CGFloat], usable: CGFloat) -> CGFloat {
        (weights.prefix(index).reduce(0, +) * usable).rounded() + CGFloat(index)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let shares = weights.count == count ? weights : Array(repeating: 1 / CGFloat(count), count: count)
        let length = axis == .horizontal ? bounds.width : bounds.height
        let usable = max(0, length - CGFloat(count - 1))
        for (index, subview) in subviews.enumerated() {
            let start = Self.origin(of: index, weights: shares, usable: usable)
            let end = index == count - 1 ? length : Self.origin(of: index + 1, weights: shares, usable: usable) - 1
            let size = max(0, end - start)
            if axis == .horizontal {
                subview.place(at: CGPoint(x: bounds.minX + start, y: bounds.minY), proposal: ProposedViewSize(width: size, height: bounds.height))
            } else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + start), proposal: ProposedViewSize(width: bounds.width, height: size))
            }
        }
    }
}

/// The one chat shaded under a drag, shared by the whole window. A chat that never heard the drag
/// leave (dropped on its composer, on the sidebar, or SwiftUI simply not saying) cannot stay shaded:
/// entering another chat moves the shade, and once the drag stops reporting it fades by itself.
@MainActor final class PaneDropState: ObservableObject {
    struct Shade: Equatable {
        let slot: PaneLayout.Slot
        let target: PaneDropTarget
    }

    @Published private(set) var shade: Shade?
    private var lastUpdate = Date.distantPast
    private var timer: Timer?

    func show(_ slot: PaneLayout.Slot, _ target: PaneDropTarget) {
        lastUpdate = .now
        let next = Shade(slot: slot, target: target)
        if shade != next { shade = next }
        guard timer == nil else { return }
        // In the common modes, so it also runs while AppKit tracks the drag.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func clear(_ slot: PaneLayout.Slot? = nil) {
        if let slot, shade?.slot != slot { return }
        if shade != nil { shade = nil }
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let quiet = Date.now.timeIntervalSince(lastUpdate)
        // The button is up and no update came: the drag ended somewhere else. A long silence ends it too.
        if (NSEvent.pressedMouseButtons & 1 == 0 && quiet > 0.25) || quiet > 3 { clear() }
    }
}

/// One chat in the window, and where a drag over it would land: files attach to its agent,
/// an agent goes beside it, above, below or in its place, depending on the edge it is nearest.
struct PaneCell<Content: View>: View {
    let slot: PaneLayout.Slot
    let drops: PaneDropState
    /// Whether this chat can take files and other agents: the start page cannot hold a split.
    let accepts: Bool
    let onFiles: ([NSItemProvider]) -> Void
    let onAgent: (UUID, PaneLayout.Zone) -> Void
    let content: Content
    @State private var size: CGSize = .zero

    init(_ slot: PaneLayout.Slot, drops: PaneDropState, accepts: Bool = true, onFiles: @escaping ([NSItemProvider]) -> Void,
         onAgent: @escaping (UUID, PaneLayout.Zone) -> Void, @ViewBuilder content: () -> Content) {
        self.slot = slot
        self.drops = drops
        self.accepts = accepts
        self.onFiles = onFiles
        self.onAgent = onAgent
        self.content = content()
    }

    var body: some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onDrop(of: AttachmentDrop.types + [.plainText],
                    delegate: PaneDropDelegate(slot: slot, size: size, accepts: accepts, drops: drops, onFiles: onFiles, onAgent: onAgent))
            .overlay { PaneDropShade(drops: drops, slot: slot) }
    }
}

enum PaneDropTarget: Equatable {
    case files
    case agent(PaneLayout.Zone)
}

/// Only this small view watches the drag, so moving over a chat redraws the shade, not the chat.
private struct PaneDropShade: View {
    @ObservedObject var drops: PaneDropState
    let slot: PaneLayout.Slot

    var body: some View {
        if let shade = drops.shade, shade.slot == slot {
            switch shade.target {
            case .files: AttachmentDropOverlay()
            case .agent(let zone): PaneDropOverlay(zone: zone)
            }
        }
    }
}

private struct PaneDropDelegate: DropDelegate {
    let slot: PaneLayout.Slot
    let size: CGSize
    let accepts: Bool
    let drops: PaneDropState
    let onFiles: ([NSItemProvider]) -> Void
    let onAgent: (UUID, PaneLayout.Zone) -> Void

    /// The nearest edge within the outer quarter of the chat, otherwise its middle.
    private func zone(at point: CGPoint) -> PaneLayout.Zone {
        guard accepts, size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width, y = point.y / size.height
        let edges: [(PaneLayout.Zone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let nearest = edges.min { $0.1 < $1.1 }!
        return nearest.1 < 0.25 ? nearest.0 : .center
    }

    private func target(of info: DropInfo) -> PaneDropTarget? {
        if info.hasItemsConforming(to: AttachmentDrop.types) { return accepts ? .files : nil }
        if info.hasItemsConforming(to: [.plainText]) { return .agent(zone(at: info.location)) }
        return nil
    }
    private func update(_ info: DropInfo) {
        if let target = target(of: info) { drops.show(slot, target) } else { drops.clear(slot) }
    }
    func validateDrop(info: DropInfo) -> Bool { target(of: info) != nil }
    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) { drops.clear(slot) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: info.hasItemsConforming(to: AttachmentDrop.types) ? .copy : .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        let target = target(of: info)
        drops.clear()
        switch target {
        case .files: onFiles(info.itemProviders(for: AttachmentDrop.types))
        case .agent(let zone): AgentDrag.load(info.itemProviders(for: [.plainText])) { onAgent($0, zone) }
        case nil: return false
        }
        return true
    }
}

/// Where the dragged agent would land, shaded over the chat it would split.
private struct PaneDropOverlay: View {
    let zone: PaneLayout.Zone

    private var label: String {
        switch zone {
        case .left: "A la izquierda"
        case .right: "A la derecha"
        case .top: "Arriba"
        case .bottom: "Abajo"
        case .center: "En lugar de este"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let full = CGRect(origin: .zero, size: geometry.size)
            let half = CGSize(width: full.width / 2, height: full.height / 2)
            let rect: CGRect = switch zone {
            case .left: CGRect(x: 0, y: 0, width: half.width, height: full.height)
            case .right: CGRect(x: half.width, y: 0, width: half.width, height: full.height)
            case .top: CGRect(x: 0, y: 0, width: full.width, height: half.height)
            case .bottom: CGRect(x: 0, y: half.height, width: full.width, height: half.height)
            case .center: full
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(JackPalette.accent.opacity(0.12))
                .strokeBorder(JackPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .overlay {
                    Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(JackPalette.accent)
                }
                .padding(6)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }
}

/// One agent beside the selected one: its transcript, what it is doing, its questions and a small composer.
/// Equatable on what it shows, so another agent streaming does not redraw it.
struct AgentPaneView: View, Equatable {
    let conversation: ChatConversation
    let status: ChatStatus
    let approvals: [ChatApproval]
    let locating: Bool
    let parentTitle: String?
    let monospaced: Bool
    let onSend: (String) -> Void
    let onStop: () -> Void
    let onPromote: () -> Void
    let onClose: () -> Void
    let onRespond: (_ approvalID: String, _ choice: String, _ message: String?) -> Void
    let onAnswer: (_ approvalID: String, _ answers: [String: String]) -> Void
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    /// Only the newest rows: a pane is a glance, the full history is one click away.
    private static let shownMessages = 60
    private static let bottomID = "jack-pane-bottom"

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation.id == rhs.conversation.id && lhs.conversation.title == rhs.conversation.title
            && lhs.conversation.projectPath == rhs.conversation.projectPath
            // Arrays compare their storage first, and a tool row finishing above the last one must still show.
            && lhs.conversation.messages == rhs.conversation.messages
            && lhs.status == rhs.status && lhs.approvals == rhs.approvals && lhs.locating == rhs.locating
            && lhs.parentTitle == rhs.parentTitle && lhs.monospaced == rhs.monospaced
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            transcript
            if !approvals.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(approvals) { approval in
                            ApprovalCard(approval: approval, provider: conversation.provider, projectPath: conversation.projectPath,
                                         repliesInChat: false, shortcutsEnabled: false,
                                         onRespond: { onRespond(approval.id, $0, $1) },
                                         onAnswer: { onAnswer(approval.id, $0) })
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            if status.isActive {
                AgentActivityView(conversation: conversation, status: status, tokens: nil, projectPath: conversation.projectPath, locating: locating)
                    .padding(.bottom, 4)
            }
            composer
        }
        .frame(minHeight: 160)
    }

    private var header: some View {
        AgentPaneHeader(conversation: conversation, status: status,
                        subtitle: parentTitle.map { "Sub-agente de \($0)" } ?? URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                        onStop: status.isActive ? onStop : nil, onPromote: onPromote, onClose: onClose)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let messages = conversation.messages
                    if messages.isEmpty {
                        Text(status.isActive ? "Empezando…" : "Sin mensajes todavía.")
                            .font(.system(size: 11.5)).foregroundStyle(JackPalette.muted)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        let start = max(0, messages.count - Self.shownMessages)
                        if start > 0 {
                            Button("Ver la conversación completa", action: onPromote)
                                .font(.system(size: 10.5, weight: .medium)).buttonStyle(.plain)
                                .foregroundStyle(JackPalette.accent)
                                .frame(maxWidth: .infinity).padding(.bottom, 10)
                        }
                        let lastID = messages.last?.id
                        ForEach(start..<messages.count, id: \.self) { index in
                            let message = messages[index]
                            ChatMessageRow(message: message, provider: conversation.provider, projectPath: conversation.projectPath,
                                           isStreaming: status.isActive && message.id == lastID,
                                           topSpacing: index == start ? 0 : ChatRowSpacing.between(messages[index - 1].role, message.role),
                                           monospaced: monospaced)
                                .equatable()
                                .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.count) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: conversation.messages.last?.text.count) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(status.isActive ? "Escribe; lo leerá al terminar su paso" : "Responder a este agente", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(canSend ? JackPalette.accent : JackPalette.panelStrong, in: Circle())
                    .foregroundStyle(canSend ? Color.white : JackPalette.muted)
            }
            .buttonStyle(.plain).disabled(!canSend)
            .help("Enviar")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 2)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

/// The bar over an agent shown beside the selected one: who it is and what to do with its pane.
struct AgentPaneHeader: View, Equatable {
    let conversation: ChatConversation
    let status: ChatStatus
    let subtitle: String
    let onStop: (() -> Void)?
    let onPromote: () -> Void
    let onClose: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation.id == rhs.conversation.id && lhs.conversation.title == rhs.conversation.title
            && lhs.conversation.provider == rhs.conversation.provider && lhs.status == rhs.status
            && lhs.subtitle == rhs.subtitle && (lhs.onStop == nil) == (rhs.onStop == nil)
    }

    var body: some View {
        HStack(spacing: 7) {
            providerGlyph(conversation.provider, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(JackPalette.muted).lineLimit(1)
            }
            StatusDot(status: status)
            Spacer(minLength: 4)
            if let onStop { iconButton("stop.fill", help: "Detener", action: onStop) }
            iconButton("arrow.up.left.and.arrow.down.right", help: "Abrir como agente principal", action: onPromote)
            iconButton("xmark", help: "Cerrar este panel", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPromote)
        // Drag the bar to move the chat: beside, above or below another one.
        .onDrag { AgentDrag.provider(conversation.id) }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
        .help(help).accessibilityLabel(help)
    }
}

/// Space between transcript rows, shared by the chat and the panes.
enum ChatRowSpacing {
    static func between(_ previous: String, _ current: String) -> CGFloat {
        let activity: Set<String> = ["tool", "reasoning"]
        if activity.contains(previous), activity.contains(current) { return 3 }
        if previous == "reasoning" || previous == "tool" || current == "reasoning" || current == "tool" { return 10 }
        return 16
    }
}
