import AppKit
import JackCore
import UniformTypeIdentifiers
import SwiftUI

/// Everything a sidebar row shows. Rows are `Equatable`, so streaming in one chat only redraws its own row.
struct SidebarRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let projectName: String
    let provider: ChatProvider
    let model: String
    let status: ChatStatus
    let activity: String
    let unread: Bool
    let updatedAt: Date
    let canEdit: Bool
    var pinnedAt: Date? = nil
    var pending = false
    /// The agent that delegated this one, if any.
    var parentID: UUID? = nil
    /// Shown when the row is listed away from its parent ("Necesita atención", another space).
    var parentTitle: String? = nil
    var depth = 0

    var needsAttention: Bool { status == .waiting }
}

/// Sidebar grouping, shared with keyboard navigation so ⌥⌘↑/↓ follow what is on screen.
struct SidebarSections {
    typealias Space = (path: String, name: String, rows: [SidebarRowModel])
    /// Pinned chats, oldest pin first, shown above everything else.
    let pinned: [SidebarRowModel]
    let attention: [SidebarRowModel]
    let projects: [Space]

    init(rows: [SidebarRowModel], projectPaths: [UUID: String], projectOrder: [String] = [], alphabetical: Bool = false) {
        pinned = Array(rows.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            .prefix(ChatStore.maxPinned))
        let pinnedIDs = Set(pinned.map(\.id))
        let rest = rows.filter { !pinnedIDs.contains($0.id) }
        attention = rest.filter(\.needsAttention)
        let grouped = Dictionary(grouping: rest.filter { !$0.needsAttention }) { projectPaths[$0.id] ?? "" }
        let groupedProjects = grouped.map { path, rows in
            (path: path, name: URL(fileURLWithPath: path).lastPathComponent, rows: Self.nested(rows))
        }
        if alphabetical {
            projects = groupedProjects.sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
            }
        } else {
            let rank = projectOrder.enumerated().reduce(into: [String: Int]()) { ranks, item in
                if ranks[item.element] == nil { ranks[item.element] = item.offset }
            }
            projects = groupedProjects.sorted {
                let left = rank[$0.path], right = rank[$1.path]
                if let left, let right { return left < right }
                if left != nil { return true }
                if right != nil { return false }
                return ($0.rows.first?.updatedAt ?? .distantPast) > ($1.rows.first?.updatedAt ?? .distantPast)
            }
        }
    }

    /// Newest first, with each agent's sub-agents right below it in creation order.
    private static func nested(_ rows: [SidebarRowModel]) -> [SidebarRowModel] {
        let ids = Set(rows.map(\.id))
        let children = Dictionary(grouping: rows.filter { $0.parentID.map(ids.contains) == true }) { $0.parentID! }
        var result: [SidebarRowModel] = []
        for row in rows.filter({ $0.parentID.map(ids.contains) != true }).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            result.append(row)
            for var child in (children[row.id] ?? []).sorted(by: { $0.updatedAt < $1.updatedAt }) {
                child.depth = 1; child.parentTitle = nil
                result.append(child)
            }
        }
        return result
    }

    /// Agents in on-screen order, skipping folded spaces.
    func visibleIDs(collapsed: Set<String>) -> [UUID] {
        pinned.map(\.id) + attention.map(\.id) + projects.filter { !collapsed.contains($0.path) }.flatMap { $0.rows.map(\.id) }
    }

    static func movingProject(_ source: String, before destination: String, in projects: [String]) -> [String]? {
        movingProject(source, relativeTo: destination, after: false, in: projects)
    }

    static func movingProject(_ source: String, relativeTo destination: String, after: Bool, in projects: [String]) -> [String]? {
        guard source != destination, projects.contains(source), projects.contains(destination) else { return nil }
        var order = projects.filter { $0 != source }
        guard let index = order.firstIndex(of: destination) else { return nil }
        order.insert(source, at: index + (after ? 1 : 0))
        return order == projects ? nil : order
    }

    static func collapsed(_ value: String) -> Set<String> {
        Set(value.split(separator: "\n").map(String.init))
    }
}

struct JackSidebar: View {
    let rows: [SidebarRowModel]
    let projectPaths: [UUID: String]
    let selectedID: UUID?
    let onNewConversation: (String?) -> Void
    let onSelect: (UUID) -> Void
    let onRename: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onSetUnread: (UUID, Bool) -> Void
    let onSetPinned: (UUID, Bool) -> Void
    let onSetPending: (UUID, Bool) -> Void
    /// Claude Code conversations: continue the session in a terminal, or reread it after using one.
    let onContinueInTerminal: (UUID) -> Void
    let onReloadFromClaude: (UUID) -> Void
    /// Opens the agent in a pane beside the selected one; rows can also be dragged to the chat.
    let onOpenInPane: (UUID) -> Void
    let onHide: () -> Void
    /// Bumped by ⌘F to focus the search field.
    let searchRequest: Int
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Folded spaces, stored as newline-separated project paths.
    @AppStorage("collapsedSpaces") private var collapsedSpacesValue = ""
    @AppStorage("sidebarProjectsAlphabetical") private var alphabeticalProjects = false
    @AppStorage("sidebarProjectOrder") private var projectOrderValue = ""
    @Environment(\.interfaceStyle) private var style
    // Only the reorder surfaces observe pointer changes, not the sidebar's chats.
    @State private var folderDrag = SidebarFolderDragState()

    private var collapsedSpaces: Set<String> { SidebarSections.collapsed(collapsedSpacesValue) }
    private var projectOrder: [String] { projectOrderValue.split(separator: "\n").map(String.init) }

    private func sections(for rows: [SidebarRowModel]) -> SidebarSections {
        SidebarSections(rows: rows, projectPaths: projectPaths, projectOrder: folderDrag.source == nil ? projectOrder : folderDrag.order, alphabetical: alphabeticalProjects)
    }

    private var canReorderProjects: Bool { !alphabeticalProjects && query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func moveProject(_ source: String, relativeTo destination: String, after: Bool) -> Bool {
        guard canReorderProjects,
              let order = SidebarSections.movingProject(source, relativeTo: destination, after: after,
                                                       in: sections(for: rows).projects.map(\.path)) else { return false }
        withAnimation(.easeInOut(duration: 0.18)) { projectOrderValue = order.joined(separator: "\n") }
        return true
    }

    private func dragHandle(for project: SidebarSections.Space) -> some View {
        SidebarFolderDragHandle(path: project.path, name: project.name, state: folderDrag,
                                order: sections(for: rows).projects.map(\.path))
            .frame(width: 16, height: 24)
            .help("Arrastra para ordenar \(project.name)")
    }

    private func toggleSpace(_ path: String) {
        var spaces = collapsedSpaces
        if spaces.contains(path) { spaces.remove(path) } else { spaces.insert(path) }
        collapsedSpacesValue = spaces.sorted().joined(separator: "\n")
    }

    private var filtered: [SidebarRowModel] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return rows }
        return rows.filter { row in
            [row.title, row.projectName, row.provider.title, row.model, row.activity].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    var body: some View {
        Group { if style == .ice { nativeBody } else { basicBody } }
            .onChange(of: alphabeticalProjects) { _, _ in folderDrag.end() }
            .onChange(of: query) { _, _ in folderDrag.end() }
            .onDisappear { folderDrag.end() }
    }

    private var basicBody: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 1) {
                navButton("square.and.pencil", "Nuevo agente", shortcut: "⌘N") { onNewConversation(nil) }
                searchField
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            // One timeline for the whole list: ages refresh once a minute without a timer per row.
            TimelineView(.everyMinute) { context in
                list(now: context.date)
            }
            footer
        }
        .jackSurface(.chrome)
        .onChange(of: searchRequest) { _, _ in searchFocused = true }
    }

    /// Ice: the system's sidebar list, which macOS 26 floats as a Liquid Glass panel.
    private var nativeBody: some View {
        TimelineView(.everyMinute) { context in
            let sections = sections(for: filtered)
            List(selection: Binding(get: { selectedID }, set: { id in if let id { onSelect(id) } })) {
                if !sections.pinned.isEmpty {
                    Section {
                        ForEach(sections.pinned) { row in nativeRow(row, showProject: true, now: context.date) }
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: "pin.fill").font(.system(size: 9))
                            Text("Fijados")
                        }
                    }
                }
                if !sections.attention.isEmpty {
                    Section {
                        ForEach(sections.attention) { row in nativeRow(row, showProject: true, now: context.date) }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Necesita atención").foregroundStyle(JackPalette.amber)
                            Text("\(sections.attention.count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(JackPalette.amber, in: Capsule())
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Proyectos").font(.system(size: 12, weight: .medium))
                        Spacer()
                        projectOrderMenu
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                ForEach(sections.projects, id: \.path) { project in
                    // While searching every space stays open so no match is hidden.
                    Section(isExpanded: Binding(get: { !collapsedSpaces.contains(project.path) || !query.isEmpty },
                                                set: { _ in toggleSpace(project.path) })) {
                        ForEach(project.rows) { row in nativeRow(row, showProject: false, now: context.date) }
                    } header: {
                        HStack(spacing: 4) {
                            if canReorderProjects { dragHandle(for: project) }
                            NativeProjectHeader(name: project.name, path: project.path, rows: project.rows,
                                                onNew: { onNewConversation(project.path) })
                        }
                        .modifier(SidebarFolderDropSurface(path: project.path, state: folderDrag,
                                                           enabled: canReorderProjects, move: moveProject))
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Buscar")
        .searchFocused($searchFocused)
        .overlay {
            if rows.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("Sin resultados para “\(query)”").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                SettingsLink { Label("Ajustes", systemImage: "gearshape") }
                    .help("Ajustes (⌘,)")
                Spacer()
                Button("Nuevo agente", systemImage: "plus") { onNewConversation(nil) }
                    .help("Nuevo agente (⌘N)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onChange(of: searchRequest) { _, _ in searchFocused = true }
    }

    private func nativeRow(_ row: SidebarRowModel, showProject: Bool, now: Date) -> some View {
        SidebarRow(row: row, showProject: showProject, selected: row.id == selectedID, age: compactAge(row.updatedAt, now: now), native: true)
            .equatable()
            .tag(row.id)
            .onDrag { AgentDrag.provider(row.id) }
            .contextMenu { rowMenu(row) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Jack").font(.system(size: 13, weight: .semibold)).foregroundStyle(JackPalette.secondaryText)
            Spacer(minLength: 0)
            Button(action: onHide) {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .regular))
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
            .help("Ocultar la barra lateral (⌃⌘S)")
        }
        // Room for the window's traffic lights.
        .padding(.leading, 80).padding(.trailing, 8)
        .frame(height: JackMetrics.stripHeight)
        .background(WindowDragArea())
    }

    private func navButton(_ symbol: String, _ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 4)
                Text(shortcut).font(.system(size: 10.5)).foregroundStyle(JackPalette.faint)
            }
            .foregroundStyle(JackPalette.secondaryText)
            .padding(.horizontal, 8).frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).frame(width: 16).foregroundStyle(JackPalette.secondaryText)
            TextField("Buscar", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.faint)
            } else {
                Text("⌘F").font(.system(size: 10.5)).foregroundStyle(JackPalette.faint)
            }
        }
        .padding(.horizontal, 8).frame(height: 27)
        .background(searchFocused ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func list(now: Date) -> some View {
        let sections = sections(for: filtered)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !sections.pinned.isEmpty {
                    sectionLabel("Fijados", count: sections.pinned.count)
                    ForEach(sections.pinned) { row in rowView(row, showProject: true, now: now) }
                }
                if !sections.attention.isEmpty {
                    sectionLabel("Necesita atención", count: sections.attention.count, tint: JackPalette.amber)
                    ForEach(sections.attention) { row in rowView(row, showProject: true, now: now) }
                }
                HStack {
                    sectionLabel("Proyectos")
                    Spacer()
                    projectOrderMenu
                    Button { onNewConversation(nil) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                    .help("Nuevo agente")
                }
                ForEach(sections.projects, id: \.path) { project in
                    // While searching every space stays open so no match is hidden.
                    let expanded = !collapsedSpaces.contains(project.path) || !query.isEmpty
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            if canReorderProjects { dragHandle(for: project) }
                            ProjectRow(name: project.name, path: project.path, rows: project.rows, expanded: expanded,
                                       onToggle: { toggleSpace(project.path) }, onNew: { onNewConversation(project.path) })
                        }
                        if expanded {
                            ForEach(project.rows) { row in rowView(row, showProject: false, now: now) }
                        }
                    }
                    .modifier(SidebarFolderDropSurface(path: project.path, state: folderDrag,
                                                       enabled: canReorderProjects, move: moveProject))
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
        }
        .scrollIndicators(.never)
        .overlay {
            if rows.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("Sin resultados para “\(query)”").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            }
        }
    }

    private func sectionLabel(_ title: String, count: Int? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint ?? JackPalette.muted)
            if let count {
                Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tint ?? JackPalette.muted, in: Capsule())
            }
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
    }

    private var projectOrderMenu: some View {
        Menu {
            Toggle("Orden alfabético", isOn: $alphabeticalProjects)
        } label: {
            Image(systemName: alphabeticalProjects ? "textformat.abc" : "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(JackPalette.muted)
        .help(alphabeticalProjects ? "Orden alfabético activado" : "Orden manual; usa el tirador para colocar cada carpeta antes o después de otra")
    }

    private func rowView(_ row: SidebarRowModel, showProject: Bool, now: Date) -> some View {
        Button { onSelect(row.id) } label: {
            SidebarRow(row: row, showProject: showProject, selected: row.id == selectedID, age: compactAge(row.updatedAt, now: now))
                .equatable()
        }
        .buttonStyle(.plain)
        .onDrag { AgentDrag.provider(row.id) }
        .contextMenu { rowMenu(row) }
    }

    @ViewBuilder private func rowMenu(_ row: SidebarRowModel) -> some View {
        if row.id != selectedID {
            Button("Abrir al lado", systemImage: "rectangle.split.2x1") { onOpenInPane(row.id) }
            Divider()
        }
        Button(row.unread ? "Marcar como leído" : "Marcar como no leído", systemImage: row.unread ? "envelope.open" : "envelope.badge") {
            onSetUnread(row.id, !row.unread)
        }
        Button(row.pending ? "Quitar de pendientes" : "Marcar como pendiente", systemImage: row.pending ? "circle.slash" : "circle.fill") {
            onSetPending(row.id, !row.pending)
        }
        Button(row.pinnedAt == nil ? "Fijar arriba" : "Quitar de fijados", systemImage: row.pinnedAt == nil ? "pin" : "pin.slash") {
            onSetPinned(row.id, row.pinnedAt == nil)
        }
        .disabled(row.pinnedAt == nil && rows.filter { $0.pinnedAt != nil }.count >= ChatStore.maxPinned)
        if let path = projectPaths[row.id] {
            Button("Mostrar space en Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        if row.provider == .claude {
            Divider()
            Button("Continuar en la terminal", systemImage: "apple.terminal") { onContinueInTerminal(row.id) }
                .disabled(!row.canEdit)
            Button("Actualizar desde Claude Code", systemImage: "arrow.clockwise") { onReloadFromClaude(row.id) }
                .disabled(!row.canEdit)
        }
        Divider()
        Button("Renombrar…", systemImage: "pencil") { onRename(row.id) }
            .disabled(!row.canEdit)
        Button("Eliminar conversación…", systemImage: "trash", role: .destructive) { onDelete(row.id) }
            .disabled(!row.canEdit)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 24)).foregroundStyle(JackPalette.faint)
            Text("Sin agentes").font(.system(size: 13, weight: .semibold))
            Text("Crea uno para empezar a trabajar en un proyecto.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .multilineTextAlignment(.center)
            Button("Nuevo agente") { onNewConversation(nil) }.controlSize(.small).padding(.top, 2)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 12.5)).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
            .help("Ajustes (⌘,)")
            Spacer()
        }
        .padding(.horizontal, 8).frame(height: 34)
    }
}

/// One native drag session. Its end callback clears both successful and cancelled drags.
@MainActor final class SidebarFolderDragState: ObservableObject {
    static let type = UTType(importedAs: "dev.jack.sidebar-project", conformingTo: .data)
    struct Target: Equatable {
        let path: String
        let after: Bool
    }
    @Published private(set) var source: String?
    @Published private(set) var target: Target?
    private(set) var order: [String] = []

    func begin(_ path: String, order: [String]) {
        self.order = order
        target = nil
        source = path
    }
    func show(_ path: String, after: Bool) {
        let next = Target(path: path, after: after)
        if target != next { target = next }
    }
    func clear(_ path: String) { if target?.path == path { target = nil } }
    func end() {
        target = nil
        source = nil
        order = []
    }
}

/// Insertion feedback spans the whole folder, including its expanded chats in the compact sidebar.
private struct SidebarFolderDropSurface: ViewModifier {
    let path: String
    @ObservedObject var state: SidebarFolderDragState
    let enabled: Bool
    let move: (String, String, Bool) -> Bool
    @State private var height: CGFloat = 28

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(state.source == path ? 0.4 : 1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .onDrop(of: [SidebarFolderDragState.type],
                        delegate: SidebarFolderDropDelegate(path: path, height: height, state: state, move: move))
                .overlay(alignment: state.target?.after == true ? .bottom : .top) {
                    if state.target?.path == path {
                        HStack(spacing: 0) {
                            Circle().fill(JackPalette.accent).frame(width: 5, height: 5)
                            Rectangle().fill(JackPalette.accent).frame(height: 2)
                        }
                        .padding(.horizontal, 3)
                        .allowsHitTesting(false)
                    }
                }
        } else { content }
    }
}

private struct SidebarFolderDropDelegate: DropDelegate {
    let path: String
    let height: CGFloat
    let state: SidebarFolderDragState
    let move: (String, String, Bool) -> Bool

    private func accepts(_ info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [SidebarFolderDragState.type]), let source = state.source else { return false }
        return SidebarSections.movingProject(source, relativeTo: path, after: info.location.y >= height / 2, in: state.order) != nil
    }
    private func update(_ info: DropInfo) {
        if accepts(info) { state.show(path, after: info.location.y >= height / 2) }
        else { state.clear(path) }
    }
    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [SidebarFolderDragState.type]), let source = state.source else { return false }
        // Validate the folder, not a particular half: an adjacent no-op above must still let the pointer move below.
        return source != path && state.order.contains(source) && state.order.contains(path)
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) { state.clear(path) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: accepts(info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard accepts(info), let source = state.source else { state.clear(path); return false }
        let moved = move(source, path, info.location.y >= height / 2)
        state.end()
        return moved
    }
}

/// A dedicated grip keeps folding a folder and starting a drag separate. AppKit provides reliable cancellation.
private struct SidebarFolderDragHandle: NSViewRepresentable {
    let path: String
    let name: String
    let state: SidebarFolderDragState
    let order: [String]

    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) {
        view.path = path
        view.name = name
        view.begin = { state.begin(path, order: order) }
        view.end = { state.end() }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Ordenar carpeta \(name)")
    }

    final class Grip: NSView, NSDraggingSource {
        var path = ""
        var name = ""
        var begin: () -> Void = {}
        var end: () -> Void = {}
        private var mouseDownEvent: NSEvent?
        private var dragging = false
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setFill()
            for x in [CGFloat(5), 10] {
                for y in [-CGFloat(4), 0, 4] {
                    NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY + y - 1, width: 2, height: 2)).fill()
                }
            }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }
        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let down = mouseDownEvent else { return }
            guard hypot(event.locationInWindow.x - down.locationInWindow.x,
                        event.locationInWindow.y - down.locationInWindow.y) >= 4 else { return }
            dragging = true
            begin()
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(path, forType: NSPasteboard.PasteboardType(SidebarFolderDragState.type.identifier))
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            let image = preview()
            let origin = convert(down.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: origin.x - 18, y: origin.y - 18, width: image.size.width, height: image.size.height), contents: image)
            let session = beginDraggingSession(with: [item], event: down, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            mouseDownEvent = nil
            end()
        }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

        private func preview() -> NSImage {
            let title = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
            let size = NSSize(width: min(280, max(120, title.size().width + 48)), height: 36)
            return NSImage(size: size, flipped: false) { rect in
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
                NSColor.windowBackgroundColor.setFill(); shape.fill()
                NSColor.separatorColor.setStroke(); shape.stroke()
                NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.draw(in: NSRect(x: 10, y: 10, width: 16, height: 16))
                title.draw(with: NSRect(x: 34, y: 9, width: size.width - 42, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                return true
            }
        }
    }
}

/// A project folder as a section header of the system sidebar, which adds the fold chevron.
private struct NativeProjectHeader: View {
    let name: String
    let path: String
    let rows: [SidebarRowModel]
    let onNew: () -> Void

    var body: some View {
        let running = rows.filter { $0.status == .running || $0.status == .queued }.count
        HStack(spacing: 6) {
            Text(name).lineLimit(1)
            Text("\(rows.count)").monospacedDigit().foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            if running > 0 {
                HStack(spacing: 3) {
                    Circle().fill(JackPalette.green).frame(width: 5, height: 5)
                    Text("\(running)").monospacedDigit()
                }
                .help("\(running) trabajando")
            }
        }
        .help(path)
        .contextMenu {
            Button("Nuevo agente aquí", systemImage: "plus", action: onNew)
            Button("Mostrar en Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }
}

/// A project folder: name, agent count and live work; folds its agents.
private struct ProjectRow: View {
    let name: String
    let path: String
    let rows: [SidebarRowModel]
    let expanded: Bool
    let onToggle: () -> Void
    let onNew: () -> Void

    var body: some View {
        let running = rows.filter { $0.status == .running || $0.status == .queued }.count
        let unread = rows.contains { $0.unread }
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: expanded ? "folder" : "folder.fill")
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    .frame(width: 16)
                Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.primary).lineLimit(1)
                Text("\(rows.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(JackPalette.faint)
                Spacer(minLength: 4)
                if !expanded, unread { Circle().fill(JackPalette.accent).frame(width: 6, height: 6).help("Hay agentes sin leer") }
                if running > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(JackPalette.green).frame(width: 5, height: 5)
                        Text("\(running)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(JackPalette.muted)
                    }
                    .help("\(running) trabajando")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(JackPalette.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .help(path)
        .contextMenu {
            Button("Nuevo agente aquí", systemImage: "plus", action: onNew)
            Button("Mostrar en Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .accessibilityLabel("\(name), \(rows.count) agentes")
        .accessibilityValue(expanded ? "Desplegado" : "Plegado")
    }
}

struct SidebarRow: View, Equatable {
    let row: SidebarRowModel
    let showProject: Bool
    let selected: Bool
    let age: String
    /// In the system's sidebar list, which draws the selection and the row insets itself.
    var native = false

    private var showsActivity: Bool { row.status == .running || row.status == .waiting || row.status == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                if row.depth > 0 {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(JackPalette.faint).frame(width: 10)
                }
                StatusDot(status: row.status, unread: row.unread)
                ProviderMark(provider: row.provider, size: 12)
                Text(row.title)
                    .font(.system(size: 12.5, weight: row.unread || row.needsAttention ? .semibold : .regular))
                    .foregroundStyle(selected || row.unread ? Color.primary : JackPalette.secondaryText)
                    .lineLimit(1)
                if row.provider.isBeta { BetaBadge() }
                if row.pending {
                    Circle().fill(JackPalette.pending).frame(width: 8, height: 8)
                        .shadow(color: JackPalette.pending.opacity(0.9), radius: 3)
                        .help("Pendiente")
                        .accessibilityLabel("Pendiente")
                }
                Spacer(minLength: 4)
                if row.pinnedAt != nil {
                    Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(JackPalette.faint)
                        .rotationEffect(.degrees(45)).accessibilityLabel("Fijado")
                }
                Text(age).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(JackPalette.faint).fixedSize()
            }
            if showsActivity || showProject || row.parentTitle != nil {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(activityColor)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, row.depth > 0 ? 55 : 38)
            }
        }
        .padding(.leading, native ? CGFloat(row.depth) * 4 : 18 + CGFloat(row.depth) * 4).padding(.trailing, native ? 0 : 8).padding(.vertical, native ? 3 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected && !native ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.status.title)
    }

    private var detail: String {
        var parts: [String] = []
        if showProject { parts.append(row.projectName) }
        if let parent = row.parentTitle { parts.append("de \(parent)") }
        if showsActivity || parts.isEmpty { parts.append(activityText) }
        return parts.joined(separator: " · ")
    }

    private var activityText: String {
        switch row.status {
        case .queued: "En cola"
        case .waiting: row.activity.isEmpty ? "Necesita tu permiso" : row.activity
        case .failed: row.activity.isEmpty ? "Error" : row.activity
        case .running: row.activity.isEmpty ? "Trabajando…" : row.activity
        case .idle: row.activity
        }
    }

    private var activityColor: Color {
        switch row.status {
        case .waiting: JackPalette.amber
        case .failed: JackPalette.red
        default: JackPalette.muted
        }
    }
}

enum JackMetrics {
    /// Height of the sidebar header and the tab strips, aligned with the traffic lights.
    static let stripHeight: CGFloat = 38
}
