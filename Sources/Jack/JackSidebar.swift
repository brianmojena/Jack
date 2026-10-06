import JackCore
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
    let attention: [SidebarRowModel]
    let projects: [Space]

    init(rows: [SidebarRowModel], projectPaths: [UUID: String]) {
        attention = rows.filter(\.needsAttention)
        let grouped = Dictionary(grouping: rows.filter { !$0.needsAttention }) { projectPaths[$0.id] ?? "" }
        projects = grouped.map { path, rows in
            (path: path, name: URL(fileURLWithPath: path).lastPathComponent, rows: Self.nested(rows))
        }
        .sorted { ($0.rows.first?.updatedAt ?? .distantPast) > ($1.rows.first?.updatedAt ?? .distantPast) }
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
        attention.map(\.id) + projects.filter { !collapsed.contains($0.path) }.flatMap { $0.rows.map(\.id) }
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
    let onHide: () -> Void
    /// Bumped by ⌘F to focus the search field.
    let searchRequest: Int
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Folded spaces, stored as newline-separated project paths.
    @AppStorage("collapsedSpaces") private var collapsedSpacesValue = ""

    private var collapsedSpaces: Set<String> { SidebarSections.collapsed(collapsedSpacesValue) }

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
        .background(JackPalette.chrome)
        .onChange(of: searchRequest) { _, _ in searchFocused = true }
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
        let sections = SidebarSections(rows: filtered, projectPaths: projectPaths)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !sections.attention.isEmpty {
                    sectionLabel("Necesita atención", count: sections.attention.count, tint: JackPalette.amber)
                    ForEach(sections.attention) { row in rowView(row, showProject: true, now: now) }
                }
                HStack {
                    sectionLabel("Proyectos")
                    Spacer()
                    Button { onNewConversation(nil) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                    .help("Nuevo agente")
                }
                ForEach(sections.projects, id: \.path) { project in
                    // While searching every space stays open so no match is hidden.
                    let expanded = !collapsedSpaces.contains(project.path) || !query.isEmpty
                    ProjectRow(name: project.name, path: project.path, rows: project.rows, expanded: expanded,
                               onToggle: { toggleSpace(project.path) }, onNew: { onNewConversation(project.path) })
                    if expanded {
                        ForEach(project.rows) { row in rowView(row, showProject: false, now: now) }
                    }
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

    private func rowView(_ row: SidebarRowModel, showProject: Bool, now: Date) -> some View {
        Button { onSelect(row.id) } label: {
            SidebarRow(row: row, showProject: showProject, selected: row.id == selectedID, age: compactAge(row.updatedAt, now: now))
                .equatable()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(row.unread ? "Marcar como leído" : "Marcar como no leído", systemImage: row.unread ? "envelope.open" : "envelope.badge") {
                onSetUnread(row.id, !row.unread)
            }
            if let path = projectPaths[row.id] {
                Button("Mostrar space en Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Divider()
            Button("Renombrar…", systemImage: "pencil") { onRename(row.id) }
                .disabled(!row.canEdit)
            Button("Eliminar conversación…", systemImage: "trash", role: .destructive) { onDelete(row.id) }
                .disabled(!row.canEdit)
        }
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
                Spacer(minLength: 4)
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
        .padding(.leading, 18 + CGFloat(row.depth) * 4).padding(.trailing, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
