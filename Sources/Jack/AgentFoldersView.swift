import AppKit
import JackCore
import SwiftUI

/// Toolbar button that lists the folders an agent may use besides its project.
struct AgentFoldersButton: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    @State private var showing = false

    var body: some View {
        let count = conversation.additionalDirectories.count
        Button { showing.toggle() } label: {
            Label(count == 0 ? "Carpetas" : "Carpetas (\(count + 1))", systemImage: count == 0 ? "folder.badge.plus" : "folder.fill.badge.plus")
        }
        .help(count == 0 ? "Dar acceso a más carpetas" : "El agente tiene acceso a \(count + 1) carpetas")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AgentFoldersPanel(store: store, conversation: conversation)
        }
    }
}

private struct AgentFoldersPanel: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Carpetas del agente").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                row(conversation.projectPath, note: "Proyecto", removable: false)
                ForEach(conversation.additionalDirectories, id: \.self) { row($0, note: nil, removable: true) }
            }
            HStack {
                Button("Añadir carpeta…", systemImage: "plus", action: add)
                Spacer()
            }
            Text("El agente podrá leer y editar estas carpetas a partir de su próximo mensaje.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func row(_ path: String, note: String?, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(JackPalette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium))
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(JackPalette.faint) }
            if removable {
                Button { set(conversation.additionalDirectories.filter { $0 != path }) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless).foregroundStyle(JackPalette.muted)
                .help("Quitar acceso a esta carpeta")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 6))
        .help(path)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.title = "Dar acceso a carpetas"
        panel.prompt = "Añadir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: conversation.projectPath).deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        set(conversation.additionalDirectories + panel.urls.map { $0.standardizedFileURL.path })
    }

    private func set(_ directories: [String]) {
        var updated = conversation
        updated.extraDirectories = directories
        store.updateDirectories(id: conversation.id, directories: updated.additionalDirectories)
    }
}
