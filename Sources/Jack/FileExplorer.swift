import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A project's folder tree. Folders are listed only when opened, off the main thread,
/// and the visible rows are flattened once per change so the list scrolls without work.
@MainActor final class FileTreeModel: ObservableObject {
    struct Entry: Equatable {
        let path: String
        let name: String
        let isDirectory: Bool
        let isHidden: Bool
    }

    struct Row: Identifiable, Equatable {
        let entry: Entry
        let depth: Int
        let expanded: Bool
        var id: String { entry.path }
    }

    let root: String
    @Published private(set) var rows: [Row] = []
    @Published var selection: String?
    private var expanded: Set<String> = []
    private var children: [String: [Entry]] = [:]
    nonisolated private static let skipped: Set<String> = [".git", ".DS_Store"]

    init(root: String) {
        self.root = root
        Task { await load([root]) }
    }

    func toggle(_ entry: Entry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
            rebuild()
        } else {
            expanded.insert(entry.path)
            if children[entry.path] == nil { Task { await load([entry.path]) } } else { rebuild() }
        }
    }

    /// Lists the root and every open folder again, e.g. after an agent's turn.
    func refresh() {
        Task { await load([root] + expanded.sorted()) }
    }

    private func load(_ paths: [String]) async {
        let listed = await Task.detached(priority: .userInitiated) { () -> [String: [Entry]] in
            var result: [String: [Entry]] = [:]
            for path in paths { result[path] = Self.list(path) }
            return result
        }.value
        for (path, entries) in listed { children[path] = entries }
        // Folders that vanished close themselves.
        expanded = expanded.filter { FileManager.default.fileExists(atPath: $0) }
        rebuild()
    }

    nonisolated private static func list(_ path: String) -> [Entry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            guard !skipped.contains(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(path: url.path, name: name, isDirectory: values?.isDirectory ?? false, isHidden: values?.isHidden ?? name.hasPrefix("."))
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func rebuild() {
        var result: [Row] = []
        func add(_ path: String, depth: Int) {
            for entry in children[path] ?? [] {
                let open = expanded.contains(entry.path)
                result.append(Row(entry: entry, depth: depth, expanded: open))
                if open { add(entry.path, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        if result != rows { rows = result }
    }
}

/// The project's files beside the chat. Files can be dragged into the chat to attach them.
struct FileExplorer: View, Equatable {
    @ObservedObject var model: FileTreeModel
    let onAttach: (String) -> Void
    let onClose: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11.5)).foregroundStyle(JackPalette.muted)
                Text(URL(fileURLWithPath: model.root).lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                StripIconButton(symbol: "arrow.clockwise", help: "Actualizar") { model.refresh() }
                StripIconButton(symbol: "xmark", help: "Ocultar archivos", action: onClose)
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(height: JackMetrics.stripHeight)
            .jackSurface(.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        FileRow(row: row, selected: model.selection == row.id)
                            .equatable()
                            // Separate gestures: a single click acts at once instead of waiting for a double click.
                            .onTapGesture {
                                model.selection = row.id
                                model.toggle(row.entry)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(row.entry) })
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: row.entry.path) as NSURL) }
                            .contextMenu { menu(row.entry) }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
        .jackSurface(.chrome)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func open(_ entry: FileTreeModel.Entry) {
        if entry.isDirectory { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    @ViewBuilder private func menu(_ entry: FileTreeModel.Entry) -> some View {
        if !entry.isDirectory {
            Button("Adjuntar al chat", systemImage: "paperclip") { onAttach(entry.path) }
            Button("Abrir", systemImage: "arrow.up.forward.app") { open(entry) }
        }
        Button("Mostrar en Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
        Button("Copiar ruta", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }
}

private struct FileRow: View, Equatable {
    let row: FileTreeModel.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(JackPalette.faint)
                .rotationEffect(.degrees(row.expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(row.entry.isDirectory ? 1 : 0)
            Image(systemName: Self.symbol(for: row.entry))
                .font(.system(size: 11.5))
                .foregroundStyle(row.entry.isDirectory ? JackPalette.muted : JackPalette.faint)
                .frame(width: 16)
            Text(row.entry.name)
                .font(.system(size: 12.5))
                .foregroundStyle(row.entry.isHidden ? JackPalette.muted : Color.primary.opacity(0.88))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 14).padding(.trailing, 8)
        .frame(height: 24)
        .background(selected ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    static func symbol(for entry: FileTreeModel.Entry) -> String {
        if entry.isDirectory { return "folder" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "m", "cpp", "java", "kt", "sh", "zsh": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "md", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "icns": return "photo"
        case "pdf": return "doc.richtext"
        case "lock": return "lock"
        default: return "doc"
        }
    }
}
