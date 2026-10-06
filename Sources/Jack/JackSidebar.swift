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
    let activeCount: Int
    let maxConcurrent: Int
    let usage: [ChatProvider: ProviderUsage]
    let refreshingUsage: Bool
    let onRefreshUsage: () -> Void
    let onSetConcurrency: (Int) -> Void
    let onNewConversation: () -> Void
    let onSelect: (UUID) -> Void
    let onRename: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onSetUnread: (UUID, Bool) -> Void
    @State private var query = ""
    @State private var showingUsage = false
    /// Bumped by ⌘F to focus the search field.
    let searchRequest: Int
    @FocusState private var searchFocused: Bool
    /// Folded spaces, stored as newline-separated project paths.
    @AppStorage("collapsedSpaces") private var collapsedSpacesValue = ""

    private var collapsedSpaces: Set<String> { SidebarSections.collapsed(collapsedSpacesValue) }

    private func toggleSpace(_ path: String) {
        var spaces = collapsedSpaces
        if spaces.contains(path) { spaces.remove(path) } else { spaces.insert(path) }
        withAnimation(.snappy(duration: 0.2)) {
            collapsedSpacesValue = spaces.sorted().joined(separator: "\n")
        }
    }

    private var filtered: [SidebarRowModel] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return rows }
        return rows.filter { row in
            [row.title, row.projectName, row.provider.title, row.model, row.activity].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private var sections: SidebarSections {
        SidebarSections(rows: filtered, projectPaths: projectPaths)
    }

    var body: some View {
        let sections = self.sections
        List(selection: Binding(get: { selectedID }, set: { if let id = $0 { onSelect(id) } })) {
            if !sections.attention.isEmpty {
                Section {
                    ForEach(sections.attention) { row in
                        rowView(row, showProject: true)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(JackPalette.amber)
                        Text("Necesita atención")
                        Spacer()
                        Text("\(sections.attention.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(JackPalette.amber, in: Capsule())
                    }
                }
            }
            ForEach(sections.projects, id: \.path) { project in
                // While searching every space stays open so no match is hidden.
                let expanded = !collapsedSpaces.contains(project.path) || !query.isEmpty
                Section {
                    if expanded {
                        ForEach(project.rows) { row in
                            rowView(row, showProject: false)
                        }
                    }
                } header: {
                    SpaceHeader(name: project.name, path: project.path, rows: project.rows, expanded: expanded) {
                        toggleSpace(project.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if rows.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("Sin resultados para “\(query)”")
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Buscar agentes")
        .searchFocused($searchFocused)
        .onChange(of: searchRequest) { _, _ in searchFocused = true }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .toolbar {
            ToolbarItem {
                Button(action: onNewConversation) { Label("Nuevo agente", systemImage: "square.and.pencil") }
                    .help("Nuevo agente (⌘N)")
            }
        }
    }

    private func rowView(_ row: SidebarRowModel, showProject: Bool) -> some View {
        SidebarRow(row: row, showProject: showProject)
            .equatable()
            .tag(row.id)
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
                .font(.system(size: 26)).foregroundStyle(JackPalette.faint)
            Text("Sin agentes").font(.system(size: 13, weight: .semibold))
            Text("Crea uno para empezar a trabajar en un proyecto.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .multilineTextAlignment(.center)
            Button("Nuevo agente", action: onNewConversation).controlSize(.small).padding(.top, 2)
        }
        .padding(20)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Menu {
                    Section("Agentes en paralelo") {
                        ForEach([1, 2, 3, 4, 6, 8], id: \.self) { count in
                            Button { onSetConcurrency(count) } label: {
                                if count == maxConcurrent { Label("\(count)", systemImage: "checkmark") } else { Text("\(count)") }
                            }
                        }
                        Button { onSetConcurrency(0) } label: {
                            if maxConcurrent == 0 { Label("Sin límite", systemImage: "checkmark") } else { Text("Sin límite") }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(activeCount > 0 ? JackPalette.green : JackPalette.faint).frame(width: 6, height: 6)
                        Text(maxConcurrent == 0 ? "\(activeCount) activos" : "\(activeCount) de \(maxConcurrent) activos")
                            .font(.system(size: 11).monospacedDigit())
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Agentes trabajando ahora y máximo en paralelo")
                Spacer()
                Button { showingUsage.toggle() } label: {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                }
                .buttonStyle(.borderless)
                .help("Uso y límites")
                .popover(isPresented: $showingUsage, arrowEdge: .top) {
                    ProviderUsageView(usage: usage, refreshing: refreshingUsage, refresh: onRefreshUsage)
                }
            }
            .foregroundStyle(JackPalette.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// Header of a space (a project folder): larger than plain section titles and foldable.
private struct SpaceHeader: View {
    let name: String
    let path: String
    let rows: [SidebarRowModel]
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let running = rows.filter { $0.status == .running || $0.status == .queued }.count
        let unread = rows.contains { $0.unread }
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(JackPalette.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(JackPalette.accent)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !expanded, unread {
                    Circle().fill(JackPalette.accent).frame(width: 6, height: 6).help("Hay agentes sin leer")
                }
                if running > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(JackPalette.green).frame(width: 6, height: 6)
                        Text("\(running)").monospacedDigit()
                    }
                    .help("\(running) trabajando")
                }
                Text("\(rows.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(JackPalette.muted)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(JackPalette.panelStrong, in: Capsule())
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(JackPalette.muted)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("\(name), \(rows.count) agentes")
        .accessibilityValue(expanded ? "Desplegado" : "Plegado")
        .accessibilityHint("Muestra u oculta los agentes de este space")
    }
}

struct SidebarRow: View, Equatable {
    let row: SidebarRowModel
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if row.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(JackPalette.faint)
                    .padding(.top, 4)
                    .padding(.leading, 6)
            }
            Circle()
                .fill(row.unread ? JackPalette.accent : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityLabel(row.unread ? "No leído" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 12, weight: row.unread || row.needsAttention ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    RelativeTime(date: row.updatedAt)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(JackPalette.faint)
                        .lineLimit(1)
                        .fixedSize()
                }
                if !(row.status == .idle && row.activity.isEmpty) { activityLine }
                if let parentTitle = row.parentTitle {
                    Label("Delegado por \(parentTitle)", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                        .lineLimit(1)
                }
                Text(([showProject ? row.projectName : nil, row.provider.title, row.model.isEmpty ? nil : (row.model as NSString).lastPathComponent] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(JackPalette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.status.title)
    }

    @ViewBuilder private var activityLine: some View {
        HStack(spacing: 4) {
            switch row.status {
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            case .queued, .waiting, .failed:
                Image(systemName: row.status.symbol).font(.system(size: 9, weight: .semibold))
            case .idle:
                EmptyView()
            }
            Text(activityText).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundStyle(activityColor)
    }

    private var activityText: String {
        switch row.status {
        case .queued: "En cola"
        case .waiting: row.activity.isEmpty ? "Necesita tu permiso" : row.activity
        case .failed: row.activity.isEmpty ? "Error" : row.activity
        case .running: row.activity.isEmpty ? "Trabajando…" : row.activity
        case .idle: row.activity.isEmpty ? "Sin actividad" : row.activity
        }
    }

    private var activityColor: Color {
        switch row.status {
        case .waiting: JackPalette.amber
        case .failed: JackPalette.red
        case .running: JackPalette.secondaryText
        case .queued, .idle: JackPalette.muted
        }
    }
}

/// Coarse relative date ("hace 5 min") refreshed once a minute; `Text(_:style: .relative)` redraws continuously.
struct RelativeTime: View {
    let date: Date
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.label(for: date, now: context.date))
        }
    }

    static func label(for date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "ahora" : formatter.localizedString(for: date, relativeTo: now)
    }
}
