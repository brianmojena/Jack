import JackCore
import SwiftUI

/// Sessions started in Claude Code's terminal, newest first, to continue in Jack.
struct ClaudeSessionPicker: View {
    /// Session ids that already have a conversation in Jack.
    let imported: Set<String>
    let onOpen: (ClaudeSessionSummary) -> Void
    let onCancel: () -> Void
    @State private var sessions: [ClaudeSessionSummary]?
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [ClaudeSessionSummary] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return sessions ?? [] }
        return (sessions ?? []).filter { session in
            let haystack = (session.title + " " + session.projectPath).lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Retomar sesión de Claude Code").font(.system(size: 16, weight: .semibold))
                Text("Sigue en Jack una conversación empezada en la terminal, con su historial. Las dos comparten la misma sesión.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            TextField("Buscar por título o carpeta", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(openSelection)
            Group {
                if let sessions, sessions.isEmpty {
                    placeholder("No hay sesiones de Claude Code guardadas.")
                } else if sessions == nil {
                    placeholder("Buscando sesiones…", loading: true)
                } else if filtered.isEmpty {
                    placeholder("Sin resultados para “\(query)”")
                } else {
                    List(filtered, selection: $selection) { session in
                        row(session).tag(session.id)
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in openSelection() }
                }
            }
            .frame(height: 340)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Retomar", action: openSelection)
                    .buttonStyle(.borderedProminent).tint(JackPalette.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20).frame(width: 560).background(JackPalette.canvas)
        .onAppear { searchFocused = true }
        .task {
            let found = await Task.detached(priority: .userInitiated) { ClaudeSessions.list() }.value
            sessions = found
            selection = found.first?.id
        }
        .onChange(of: query) { _, _ in
            if let selection, filtered.contains(where: { $0.id == selection }) { return }
            selection = filtered.first?.id
        }
    }

    private var selected: ClaudeSessionSummary? { filtered.first { $0.id == selection } }

    private func openSelection() {
        if let selected { onOpen(selected) }
    }

    private func row(_ session: ClaudeSessionSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            providerGlyph(.claude, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text((session.projectPath as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(JackPalette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if imported.contains(session.id) {
                Text("En Jack").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(JackPalette.panelStrong, in: Capsule())
                    .foregroundStyle(JackPalette.muted)
            }
            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
        }
        .padding(.vertical, 3)
    }

    private func placeholder(_ text: String, loading: Bool = false) -> some View {
        VStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 12)).foregroundStyle(JackPalette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Brings recent Claude Code chats, from the terminal and the Claude app, into Jack in one go.
/// Offered once on first launch and from Settings; histories are read when each chat first opens.
struct ClaudeImportSheet: View {
    /// Already found, e.g. by the first-launch check; nil reads them when the sheet appears.
    var initial: [ClaudeSessionSummary]? = nil
    /// Session ids that already have a conversation in Jack.
    let imported: Set<String>
    let onImport: ([ClaudeSessionSummary]) -> Void
    let onCancel: () -> Void
    @State private var period = ClaudeImportPeriod.quarter
    @State private var sessions: [ClaudeSessionSummary]?
    @State private var skipped = Set<String>()

    static let offeredKey = "claudeImportOffered"

    private var projects: [(path: String, sessions: [ClaudeSessionSummary])] {
        Dictionary(grouping: sessions ?? [], by: \.projectPath)
            .map { ($0.key, $0.value) }
            .sorted { ($0.sessions.first?.updatedAt ?? .distantPast) > ($1.sessions.first?.updatedAt ?? .distantPast) }
    }
    private var chosen: [ClaudeSessionSummary] { (sessions ?? []).filter { !skipped.contains($0.projectPath) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Traer tus chats de Claude Code").font(.system(size: 16, weight: .semibold))
                Text("Los chats de la terminal y de la app de Claude aparecen en Jack y se pueden seguir: comparten la misma sesión. Su historial se lee al abrir cada uno.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Desde", selection: $period) {
                ForEach(ClaudeImportPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Group {
                if let sessions, sessions.isEmpty {
                    placeholder("No hay chats de Claude Code nuevos en este periodo.")
                } else if sessions == nil {
                    placeholder("Buscando chats…", loading: true)
                } else {
                    List(projects, id: \.path) { project in projectRow(project.path, count: project.sessions.count) }
                        .listStyle(.inset)
                }
            }
            .frame(height: 300)
            HStack {
                if period.limit != nil, (sessions?.count ?? 0) >= (period.limit ?? .max) {
                    Text("Los \(period.limit ?? 0) más recientes").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                }
                Spacer()
                Button("Ahora no", action: onCancel).keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Importar 1 chat" : "Importar \(chosen.count) chats") { onImport(chosen) }
                    .buttonStyle(.borderedProminent).tint(JackPalette.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20).frame(width: 520).background(JackPalette.canvas)
        .task(id: period) {
            if period == .quarter, let initial, sessions == nil { sessions = initial; return }
            sessions = nil
            sessions = await Self.find(period, excluding: imported)
        }
    }

    static func find(_ period: ClaudeImportPeriod, excluding: Set<String>) async -> [ClaudeSessionSummary] {
        await Task.detached(priority: .userInitiated) {
            ClaudeSessions.importCandidates(since: period.since, limit: period.limit ?? 2_000, excluding: excluding)
        }.value
    }

    private func projectRow(_ path: String, count: Int) -> some View {
        Toggle(isOn: Binding(get: { !skipped.contains(path) }, set: { if $0 { skipped.remove(path) } else { skipped.insert(path) } })) {
            HStack(spacing: 8) {
                Text((path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(JackPalette.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(count == 1 ? "1 chat" : "\(count) chats").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }

    private func placeholder(_ text: String, loading: Bool = false) -> some View {
        VStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 12)).foregroundStyle(JackPalette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ClaudeImportPeriod: String, CaseIterable, Identifiable {
    case month, quarter, year, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .month: "30 días"
        case .quarter: "90 días"
        case .year: "1 año"
        case .all: "Todo"
        }
    }
    var since: Date {
        switch self {
        case .month: Date().addingTimeInterval(-30 * 86_400)
        case .quarter: Date().addingTimeInterval(-90 * 86_400)
        case .year: Date().addingTimeInterval(-365 * 86_400)
        case .all: .distantPast
        }
    }
    /// The newest chats only, so the sidebar doesn't fill with old ones; "Todo" means all of them.
    var limit: Int? { self == .all ? nil : 100 }
}
