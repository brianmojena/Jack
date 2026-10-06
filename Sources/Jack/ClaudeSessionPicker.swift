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
