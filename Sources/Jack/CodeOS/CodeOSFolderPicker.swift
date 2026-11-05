import AppKit
import SwiftUI

/// The folders of the computer, browsed like a catalogue: every folder is a tile with its own picture, and the focused one gets a page
/// with a big "open" button. Used to start a project in a folder that exists or in one that is created on the spot.
@MainActor final class CodeOSFolderPicker: ObservableObject {
    struct Place: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let url: URL
    }

    struct Entry: Identifiable {
        let url: URL
        let subfolders: Int
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var project: CodeOSProject { CodeOSProject(path: url.path) }
    }

    @Published private(set) var places: [Place] = []
    @Published private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = false
    /// 0 is the "new folder" tile; the folders follow.
    @Published private(set) var cursor = 0
    @Published private(set) var art: [String: CodeOSModel.Art] = [:]
    @Published private(set) var creating = false
    @Published var newName = ""
    @Published private(set) var message: String?
    /// Cells per row, reported by the view so up and down move a whole row.
    var columns = 6
    /// Called with the path of the folder to open as a project.
    var onOpen: (String) -> Void = { _ in }

    private let sound = CodeOSSound.shared
    private var listing: Task<Void, Never>?
    private var artTask: Task<Void, Never>?

    var focusedEntry: Entry? { entries.indices.contains(cursor - 1) ? entries[cursor - 1] : nil }
    var currentPlace: Place? { places.first { $0.url.path == directory.path } }
    var canGoUp: Bool { directory.path != "/" }

    // MARK: Opening

    /// Starts at the folder that holds most of the user's projects, or at the home folder.
    func start(near projects: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list: [Place] = []
        var counts: [String: Int] = [:]
        for path in projects { counts[(path as NSString).deletingLastPathComponent, default: 0] += 1 }
        if let best = counts.filter({ $0.key != home.path && $0.key != "/" }).max(by: { $0.value < $1.value })?.key,
           FileManager.default.fileExists(atPath: best) {
            list.append(Place(id: "projects", title: "Tus proyectos", symbol: "folder.badge.gearshape", url: URL(fileURLWithPath: best)))
        }
        list.append(Place(id: "home", title: "Inicio", symbol: "house.fill", url: home))
        for (id, title, symbol, name) in [("desktop", "Escritorio", "menubar.dock.rectangle", "Desktop"), ("documents", "Documentos", "doc.fill", "Documents"), ("downloads", "Descargas", "arrow.down.circle.fill", "Downloads")] {
            let url = home.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { list.append(Place(id: id, title: title, symbol: symbol, url: url)) }
        }
        places = list
        creating = false
        newName = ""
        message = nil
        go(to: list.first?.url ?? home)
    }

    func stop() {
        listing?.cancel()
        artTask?.cancel()
        creating = false
    }

    // MARK: Browsing

    private func go(to url: URL, focusing previous: String? = nil) {
        listing?.cancel()
        artTask?.cancel()
        directory = url.standardizedFileURL
        entries = []
        cursor = 0
        loading = true
        creating = false
        message = nil
        listing = Task {
            let found = await Task.detached(priority: .userInitiated) { Self.folders(in: url) }.value
            guard !Task.isCancelled else { return }
            entries = found
            loading = false
            if let previous, let index = found.firstIndex(where: { $0.id == previous }) { cursor = index + 1 }
            loadArt(for: found)
        }
    }

    /// The folders inside one folder: no hidden ones, no packages (an .app is not a place to start a project).
    nonisolated private static func folders(in url: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls
            .filter { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { item in
                let inside = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
                let count = inside.filter { sub in
                    let values = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return values?.isDirectory == true && values?.isPackage != true
                }.count
                return Entry(url: item, subfolders: count)
            }
    }

    /// Pictures for the folders that look like projects (a manifest, a `.git`): their own icon, or their framework's logo.
    private func loadArt(for found: [Entry]) {
        artTask = Task {
            for entry in found {
                if Task.isCancelled { return }
                let path = entry.url.path
                guard art[path] == nil else { continue }
                let looksLikeProject = await Task.detached(priority: .utility) {
                    FileManager.default.fileExists(atPath: path + "/.git") || CodeOSFramework.detect(in: path) != nil
                }.value
                guard looksLikeProject, !Task.isCancelled else { continue }
                let urls = await Task.detached(priority: .utility) { CodeOSIconFinder.candidates(in: path) }.value
                var found = false
                for url in urls {
                    guard let image = NSImage(contentsOf: url), image.size.width >= 24, image.isRoughlySquare else { continue }
                    art[path] = CodeOSModel.Art(image: image, tint: image.codeOSTint() ?? entry.project.color)
                    found = true
                    break
                }
                if !found, let logo = await CodeOSFramework.logo(for: path) {
                    art[path] = CodeOSModel.Art(image: logo.image, tint: logo.tint, framework: logo.name)
                }
            }
        }
    }

    func move(dx: Int, dy: Int) {
        guard !creating else { return }
        let target = min(max(cursor + dx + dy * columns, 0), entries.count)
        guard target != cursor else { return }
        sound.move(forward: target > cursor)
        cursor = target
    }

    func select(_ index: Int) {
        guard !creating, index != cursor, (0...entries.count).contains(index) else { return }
        sound.move(forward: index > cursor)
        cursor = index
    }

    /// Goes into the focused folder to see what it holds.
    func explore() {
        guard !creating, let entry = focusedEntry else { return }
        sound.play(.select)
        go(to: entry.url)
    }

    func up() {
        guard !creating, canGoUp else { return }
        let from = directory.path
        sound.play(.back)
        go(to: directory.deletingLastPathComponent(), focusing: from)
    }

    func show(_ place: Place) {
        guard place.url.path != directory.path else { return }
        sound.play(.tab)
        go(to: place.url)
    }

    func shiftPlace(_ delta: Int) {
        guard !creating, !places.isEmpty else { return }
        let index = places.firstIndex { $0.url.path == directory.path } ?? (delta > 0 ? -1 : places.count)
        let target = min(max(index + delta, 0), places.count - 1)
        if target != index { show(places[target]) }
    }

    // MARK: Opening or creating

    /// Enter on a folder opens it as a project; on the first tile it asks for the name of a new one.
    func activate() {
        if creating { return }
        if let entry = focusedEntry {
            onOpen(entry.url.path)
        } else {
            creating = true
            newName = ""
            message = nil
            sound.play(.select)
        }
    }

    func cancelCreating() {
        guard creating else { return }
        creating = false
        sound.play(.back)
    }

    func commitNew() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name != ".." else {
            message = "Ese nombre no es válido para una carpeta."
            return
        }
        let target = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            // It already exists: it is simply opened.
            guard isDirectory.boolValue else { message = "Ya hay un archivo con ese nombre."; return }
        } else {
            do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) } catch {
                message = "No se pudo crear la carpeta: \(error.localizedDescription)"
                return
            }
        }
        onOpen(target.standardizedFileURL.path)
    }
}

/// The catalogue screen (key N): places on top, the focused folder's page, and a grid of the folders where the user is.
struct CodeOSFolderPickerView: View {
    @ObservedObject var model: CodeOSModel
    @FocusState private var nameFocused: Bool

    private var picker: CodeOSFolderPicker { model.picker }

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            let cell = 200 * u
            let spacing = 32 * u
            let inner = geo.size.width - 2 * 110 * u
            let columns = max(Int((inner + spacing) / (cell + spacing)), 1)
            ZStack {
                Color.canvas.opacity(0.82).background(.ultraThinMaterial).ignoresSafeArea()
                glow(size: geo.size)
                VStack(alignment: .leading, spacing: 22 * u) {
                    header(u)
                    places(u)
                    page(u)
                    grid(u, cell: cell, spacing: spacing, columns: columns)
                    hints(u)
                }
                .padding(.horizontal, 110 * u).padding(.top, 64 * u).padding(.bottom, 38 * u)
            }
            .onAppear { picker.columns = columns }
            .onChange(of: columns) { _, value in picker.columns = value }
        }
    }

    private var tint: Color {
        picker.focusedEntry.map { picker.art[$0.id]?.tint ?? $0.project.color } ?? Color(hue: 0.6, saturation: 0.5, brightness: 0.8)
    }

    private func glow(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.3), .clear], startPoint: .topTrailing, endPoint: .center)
            RadialGradient(colors: [tint.opacity(0.18), .clear], center: .topLeading, startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea().allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.5), value: picker.cursor)
    }

    // MARK: Top

    private func header(_ u: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20 * u) {
            Text("NUEVO PROYECTO").font(.system(size: 30 * u, weight: .heavy)).tracking(2 * u)
            Text(abbreviated(picker.directory.path)).font(.system(size: 19 * u, design: .monospaced)).foregroundStyle(.ink.opacity(0.55)).lineLimit(1).truncationMode(.head)
            Spacer()
        }
        .foregroundStyle(.ink)
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func places(_ u: CGFloat) -> some View {
        HStack(spacing: 24 * u) {
            Button { picker.shiftPlace(-1) } label: { keycap("Q", u) }.buttonStyle(.plain)
            ForEach(picker.places) { place in
                let current = picker.currentPlace == place
                Button { picker.show(place) } label: {
                    HStack(spacing: 10 * u) {
                        Image(systemName: place.symbol).font(.system(size: 18 * u))
                        Text(place.title.uppercased()).font(.system(size: 19 * u, weight: .heavy)).tracking(1.4 * u)
                    }
                    .padding(.horizontal, 20 * u).padding(.vertical, 9 * u)
                    .overlay(Capsule().strokeBorder(Color(red: 0.1, green: 0.45, blue: 1), lineWidth: current ? 3.5 * u : 0))
                    .opacity(current ? 1 : 0.8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { picker.shiftPlace(1) } label: { keycap("E", u) }.buttonStyle(.plain)
            Spacer()
        }
        .foregroundStyle(.ink)
        .animation(.easeOut(duration: 0.2), value: picker.directory)
    }

    // MARK: The focused folder's page

    @ViewBuilder private func page(_ u: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 44 * u) {
            if let entry = picker.focusedEntry {
                CodeOSArtwork(project: entry.project, art: picker.art[entry.id], corner: 22 * u)
                    .frame(width: 240 * u, height: 240 * u)
                    .shadow(color: tint.opacity(0.55), radius: 36 * u, y: 10 * u)
                VStack(alignment: .leading, spacing: 12 * u) {
                    Text(entry.name).font(.system(size: 56 * u, weight: .heavy)).lineLimit(1)
                    Label(subtitle(entry), systemImage: "folder").font(.system(size: 22 * u, weight: .semibold)).foregroundStyle(.ink.opacity(0.75))
                    Text(abbreviated(entry.url.path)).font(.system(size: 17 * u, design: .monospaced)).foregroundStyle(.ink.opacity(0.5)).lineLimit(1).truncationMode(.head)
                    HStack(spacing: 18 * u) {
                        primaryButton(model.allProjects.contains { $0.id == entry.id } ? "Abrir proyecto" : "Empezar proyecto aquí", symbol: "play.fill", u) { picker.activate() }
                        secondaryButton("Ver dentro", symbol: "chevron.right", u) { picker.explore() }
                        if model.allProjects.contains(where: { $0.id == entry.id }) {
                            Label("En tu lista", systemImage: "checkmark.circle.fill").font(.system(size: 18 * u, weight: .semibold)).foregroundStyle(.green)
                        }
                    }
                    .padding(.top, 8 * u)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 22 * u, style: .continuous).fill(.ink.opacity(0.1))
                    RoundedRectangle(cornerRadius: 22 * u, style: .continuous).strokeBorder(.ink.opacity(0.35), style: StrokeStyle(lineWidth: 3 * u, dash: [10 * u, 8 * u]))
                    Image(systemName: "folder.badge.plus").font(.system(size: 96 * u, weight: .light)).foregroundStyle(.ink)
                }
                .frame(width: 240 * u, height: 240 * u)
                VStack(alignment: .leading, spacing: 12 * u) {
                    Text("Carpeta nueva").font(.system(size: 56 * u, weight: .heavy))
                    Text("Se crea dentro de «\(picker.directory.lastPathComponent)» y se abre como proyecto.")
                        .font(.system(size: 22 * u, weight: .semibold)).foregroundStyle(.ink.opacity(0.75)).lineLimit(2)
                    if picker.creating {
                        TextField("Nombre de la carpeta", text: Binding(get: { picker.newName }, set: { picker.newName = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 28 * u, weight: .medium))
                            .focused($nameFocused).onSubmit { picker.commitNew() }
                            .onExitCommand { picker.cancelCreating() }
                            .padding(.horizontal, 26 * u).padding(.vertical, 12 * u).frame(width: 560 * u)
                            .background(.ink.opacity(0.14), in: Capsule())
                            .onAppear { nameFocused = true }
                            .padding(.top, 8 * u)
                        Text("ENTER para crear y abrir · ESC para cancelar").font(.system(size: 15 * u, weight: .bold)).tracking(1.4 * u).foregroundStyle(.ink.opacity(0.55))
                    } else {
                        primaryButton("Crear carpeta", symbol: "plus", u) { picker.activate() }.padding(.top, 8 * u)
                    }
                    if let message = picker.message {
                        Text(message).font(.system(size: 17 * u, weight: .medium)).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.ink)
        .frame(height: 260 * u)
        .id(picker.cursor)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: picker.cursor)
    }

    private func subtitle(_ entry: CodeOSFolderPicker.Entry) -> String {
        if let framework = picker.art[entry.id]?.framework { return "Proyecto \(framework)" }
        switch entry.subfolders {
        case 0: return "Sin subcarpetas"
        case 1: return "1 subcarpeta"
        default: return "\(entry.subfolders) subcarpetas"
        }
    }

    private func primaryButton(_ title: String, symbol: String, _ u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12 * u) {
                Image(systemName: symbol)
                Text(title).fontWeight(.bold)
            }
            .font(.system(size: 22 * u)).foregroundStyle(.canvas)
            .padding(.horizontal, 34 * u).padding(.vertical, 15 * u)
            .background(.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, symbol: String, _ u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10 * u) {
                Text(title).fontWeight(.bold)
                Image(systemName: symbol)
            }
            .font(.system(size: 20 * u)).foregroundStyle(.ink)
            .padding(.horizontal, 28 * u).padding(.vertical, 14 * u)
            .background(.ink.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Grid

    private func grid(_ u: CGFloat, cell: CGFloat, spacing: CGFloat, columns: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing, alignment: .top), count: columns), alignment: .leading, spacing: 30 * u) {
                    newTile(focused: picker.cursor == 0, side: cell, u: u)
                        .id(0)
                        .onTapGesture { if picker.cursor == 0 { picker.activate() } else { picker.select(0) } }
                    ForEach(Array(picker.entries.enumerated()), id: \.element.id) { index, entry in
                        folderTile(entry, focused: picker.cursor == index + 1, side: cell, u: u)
                            .id(index + 1)
                            .onTapGesture { if picker.cursor == index + 1 { picker.activate() } else { picker.select(index + 1) } }
                    }
                }
                .padding(.vertical, 22 * u).padding(.horizontal, 8 * u)
                if picker.loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if picker.entries.isEmpty {
                    Text("Aquí no hay carpetas. Crea una nueva o sube un nivel.")
                        .font(.system(size: 19 * u)).foregroundStyle(.ink.opacity(0.55)).frame(maxWidth: .infinity)
                }
            }
            .onChange(of: picker.cursor) { _, index in withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { proxy.scrollTo(index, anchor: .center) } }
        }
    }

    private func newTile(focused: Bool, side: CGFloat, u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * u) {
            ZStack {
                RoundedRectangle(cornerRadius: 7 * u, style: .continuous).fill(.ink.opacity(0.1))
                RoundedRectangle(cornerRadius: 7 * u, style: .continuous).strokeBorder(.ink.opacity(0.35), style: StrokeStyle(lineWidth: 2 * u, dash: [8 * u, 6 * u]))
                Image(systemName: "plus").font(.system(size: 62 * u, weight: .light)).foregroundStyle(.ink)
            }
            .frame(width: side, height: side)
            .focusRing(focused, u: u)
            .scaleEffect(focused ? 1.07 : 1)
            Text("Carpeta nueva").font(.system(size: 17 * u, weight: .semibold)).foregroundStyle(.ink.opacity(focused ? 1 : 0.65))
        }
        .frame(width: side, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }

    private func folderTile(_ entry: CodeOSFolderPicker.Entry, focused: Bool, side: CGFloat, u: CGFloat) -> some View {
        let known = model.allProjects.contains { $0.id == entry.id }
        return VStack(alignment: .leading, spacing: 10 * u) {
            CodeOSArtwork(project: entry.project, art: picker.art[entry.id], corner: 7 * u)
                .frame(width: side, height: side)
                .overlay(alignment: .bottomTrailing) {
                    if known {
                        Image(systemName: "checkmark").font(.system(size: 13 * u, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30 * u, height: 30 * u).background(Color.green, in: Circle()).padding(10 * u)
                    }
                }
                .focusRing(focused, u: u)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 22 * u, y: 8 * u)
                .scaleEffect(focused ? 1.07 : 1)
            Text(entry.name).font(.system(size: 17 * u, weight: .semibold)).foregroundStyle(.ink.opacity(focused ? 1 : 0.65)).lineLimit(1)
        }
        .frame(width: side, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }

    // MARK: Hints

    private func hints(_ u: CGFloat) -> some View {
        HStack(spacing: 34 * u) {
            hint("FLECHAS", "NAVEGAR", u, action: nil)
            hint("ENTER", "ABRIR AQUÍ", u) { picker.activate() }
            hint("ESPACIO", "VER DENTRO", u) { picker.explore() }
            hint("BORRAR", "SUBIR UN NIVEL", u) { picker.up() }
            hint("ESC", "CERRAR", u) { model.closePicker() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func hint(_ glyph: String, _ label: String, _ u: CGFloat, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 12 * u) {
                Text(glyph).font(.system(size: 16 * u, weight: .bold)).padding(.horizontal, 10 * u).frame(minWidth: 34 * u, minHeight: 34 * u)
                    .overlay(Capsule().strokeBorder(.ink.opacity(0.9), lineWidth: 2 * u))
                Text(label).font(.system(size: 16 * u, weight: .bold)).tracking(1.5 * u)
            }
            .foregroundStyle(.ink.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func keycap(_ label: String, _ u: CGFloat) -> some View {
        Text(label).font(.system(size: 15 * u, weight: .bold))
            .padding(.horizontal, 12 * u).padding(.vertical, 4 * u)
            .overlay(Capsule().strokeBorder(.ink.opacity(0.55), lineWidth: 1.6 * u))
            .foregroundStyle(.ink.opacity(0.7))
    }
}
