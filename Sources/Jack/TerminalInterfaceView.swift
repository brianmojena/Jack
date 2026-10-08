import AppKit
import Combine
import JackCore
import SwiftUI

/// Owned by WorkspaceSessions, so switching interfaces never destroys a live PTY.
/// Constructed lazily in Normal; persisted metadata does not launch agents at startup.
@MainActor final class NativeTerminalWorkspace: ObservableObject {
    @Published private(set) var snapshot = TerminalWorkspaceSnapshot()
    @Published private(set) var sessions: [UUID: TerminalSession] = [:]
    @Published var error: String?
    private let archive: TerminalWorkspaceArchive
    private var writable = true
    private var firstVisit = false
    private weak var chatStore: ChatStore?
    private var exitObservers: [UUID: AnyCancellable] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        archive = TerminalWorkspaceArchive(url: support.appendingPathComponent("Jack/terminal-workspace.json"))
        firstVisit = !FileManager.default.fileExists(atPath: archive.url.path)
        do { snapshot = try archive.load() }
        catch { writable = false; self.error = "No se pudieron leer las terminales guardadas: \(error.localizedDescription)" }
    }
    func attach(_ store: ChatStore) {
        chatStore = store
        guard firstVisit, writable, !store.lightModeEnabled else { return }
        firstVisit = false
        var known = Set(snapshot.entries.filter { $0.kind == .claude }.map(\.claudeSessionID))
        for chat in store.conversations where chat.provider == .claude && chat.remote == nil {
            guard let session = chat.sessionID.flatMap(UUID.init(uuidString:)), known.insert(session).inserted else { continue }
            snapshot.entries.append(TerminalWorkspaceEntry(id: chat.id, title: chat.title, projectPath: chat.projectPath,
                                                           kind: .claude, claudeSessionID: session))
        }
        snapshot.selectedID = snapshot.entries.first(where: { $0.id == store.selectedID })?.id ?? snapshot.entries.first?.id
        save()
    }
    var selected: TerminalWorkspaceEntry? { snapshot.entries.first { $0.id == snapshot.selectedID } }
    func select(_ id: UUID) {
        guard snapshot.entries.contains(where: { $0.id == id }) else { return }
        snapshot.selectedID = id
        save()
    }
    func create(kind: TerminalWorkspaceEntry.Kind, directory: String, allowed: Bool) {
        guard allowed, writable else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "La carpeta del proyecto ya no existe."; return
        }
        let kindTitle = kind == .claude ? "Claude Code" : "Terminal"
        let number = snapshot.entries.filter { $0.projectPath == directory && $0.kind == kind }.count + 1
        let entry = TerminalWorkspaceEntry(title: "\(kindTitle) \(number)", projectPath: directory, kind: kind)
        snapshot.entries.append(entry); snapshot.selectedID = entry.id
        save()
        start(entry.id, allowed: allowed)
    }
    func start(_ id: UUID, allowed: Bool) {
        guard allowed, let entry = snapshot.entries.first(where: { $0.id == id }), sessions[id]?.running != true else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "La carpeta del proyecto ya no existe."; return
        }
        let launch: TerminalProcessLaunch?
        if entry.kind == .claude {
            guard let executable = ExecutableResolver.resolve("claude", override: UserDefaults.standard.string(forKey: "providerExecutablePath.claude")) else {
                error = "No se encontró Claude Code. Instálalo o indica su ejecutable en Ajustes → Agentes."; return
            }
            launch = TerminalProcessLaunch(executable: executable, arguments: entry.claudeArguments(),
                                           environment: ["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "false"])
        } else { launch = nil }
        if entry.kind == .claude {
            guard chatStore?.claimClaudeSessionForTerminal(entry.claudeSessionID) == true else {
                error = "Esta sesión sigue activa o tiene trabajo pendiente en el chat. Detén ese agente antes de abrirla en la terminal."; return
            }
        }
        exitObservers[id] = nil
        sessions.removeValue(forKey: id)?.terminate()
        let session = TerminalSession(directory: entry.projectPath, directLaunch: launch) { url in NSWorkspace.shared.open(url) }
        sessions[id] = session
        if entry.kind == .claude {
            exitObservers[id] = session.$running.dropFirst().sink { [weak self, weak session] running in
                guard !running else { return }
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.sessions[id] === session else { return }
                    self.chatStore?.releaseClaudeSessionFromTerminal(entry.claudeSessionID)
                }
            }
        }
    }
    func importSession(_ session: ClaudeSessionSummary, allowed: Bool) {
        guard allowed, writable, let sessionID = UUID(uuidString: session.id) else { return }
        if let existing = snapshot.entries.first(where: { $0.kind == .claude && $0.claudeSessionID == sessionID }) {
            select(existing.id); return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "La carpeta de esa sesión ya no existe."; return
        }
        let entry = TerminalWorkspaceEntry(title: session.title, projectPath: session.projectPath, kind: .claude, claudeSessionID: sessionID)
        snapshot.entries.append(entry); snapshot.selectedID = entry.id; save()
        start(entry.id, allowed: allowed)
    }
    func stopAll() {
        exitObservers.removeAll()
        for entry in snapshot.entries where entry.kind == .claude && sessions[entry.id] != nil {
            chatStore?.releaseClaudeSessionFromTerminal(entry.claudeSessionID)
        }
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
    }
    func remove(_ id: UUID) {
        exitObservers[id] = nil
        if let entry = snapshot.entries.first(where: { $0.id == id }), entry.kind == .claude, sessions[id] != nil {
            chatStore?.releaseClaudeSessionFromTerminal(entry.claudeSessionID)
        }
        sessions.removeValue(forKey: id)?.terminate()
        snapshot.entries.removeAll { $0.id == id }
        if snapshot.selectedID == id { snapshot.selectedID = snapshot.entries.last?.id }
        save()
    }
    func rename(_ id: UUID, title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = snapshot.entries.firstIndex(where: { $0.id == id }) else { return }
        snapshot.entries[i].title = String(text.prefix(120)); save()
    }
    private func save() {
        guard writable else { return }
        do { try archive.save(snapshot) }
        catch { self.error = "No se pudieron guardar las terminales: \(error.localizedDescription)" }
    }
}

/// Orca-inspired terminal workspace: projects at left, live PTYs in tabs and a split at right.
struct TerminalInterfaceView: View {
    @ObservedObject var workspace: NativeTerminalWorkspace
    @ObservedObject var store: ChatStore
    let enterBatterySaver: () -> Void
    @AppStorage("terminalSidebarVisible") private var sidebarVisible = true
    @State private var query = ""
    @State private var splitID: UUID?
    @State private var closing: UUID?
    @State private var renaming: TerminalWorkspaceEntry?
    @State private var renameText = ""
    @State private var importingClaude = false
    @FocusState private var searchFocused: Bool

    private var normal: Bool { !store.lightModeEnabled }
    private var entries: [TerminalWorkspaceEntry] { workspace.snapshot.entries }
    private var projects: [String] { Array(Set(entries.map(\.projectPath))).sorted() }
    private var visible: [TerminalWorkspaceEntry] {
        entries.filter { query.isEmpty || ($0.title + " " + $0.projectPath).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneSplit(.leading, visible: sidebarVisible, widthKey: "terminalSidebarWidth", defaultWidth: 260,
                      range: 210...400, flexibleMinimum: 440) {
                sidebar
            } trailing: {
                VStack(spacing: 0) {
                    toolbar
                    tabBar
                    if let entry = workspace.selected {
                        if let second = entries.first(where: { $0.id == splitID }), second.id != entry.id {
                            HSplitView { pane(entry); pane(second) }
                        } else { pane(entry) }
                    } else { welcome }
                }
            }
            HStack(spacing: 12) {
                Label("Terminal nativa", systemImage: "terminal")
                Text("\(entries.count) terminales")
                Spacer()
                Text("Normal").foregroundStyle(JackPalette.muted)
                LightModeToggle()
            }
            .font(.system(size: 11)).padding(.horizontal, 14).frame(height: 30)
            .background(JackPalette.chrome)
        }
        .background(WindowChrome()).background(JackPalette.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .focusedSceneValue(\.jackActions, actions)
        .onAppear { workspace.attach(store) }
        .onChange(of: workspace.snapshot.selectedID) { _, id in if splitID == id { splitID = nil } }
        .alert("Terminal", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("Aceptar") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .confirmationDialog("¿Cerrar esta terminal y terminar su proceso?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("Cerrar terminal", role: .destructive) {
                if let closing { workspace.remove(closing); if splitID == closing { splitID = nil } }
                closing = nil
            }
            Button("Cancelar", role: .cancel) { closing = nil }
        }
        .sheet(item: $renaming) { entry in
            ChatRenameSheet(title: $renameText) {
                workspace.rename(entry.id, title: renameText); renaming = nil
            } onCancel: { renaming = nil }
        }
        .sheet(isPresented: $importingClaude) {
            ClaudeSessionPicker(imported: Set(entries.map { $0.claudeSessionID.uuidString.lowercased() })) { session in
                importingClaude = false
                importSession(session)
            } onCancel: { importingClaude = false }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Jack").font(.system(size: 17, weight: .semibold))
                Spacer()
                newMenu
            }.padding(.horizontal, 14).padding(.top, 42).padding(.bottom, 12)
            TextField("Buscar terminales", text: $query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).padding(.horizontal, 12).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(projects, id: \.self) { path in
                        let rows = visible.filter { $0.projectPath == path }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.muted)
                                    Spacer()
                                    Menu {
                                        Button("Claude Code") { create(.claude, directory: path) }
                                        Button("Terminal libre") { create(.shell, directory: path) }
                                    } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
                                }.padding(.horizontal, 8).help(path)
                                ForEach(rows) { row in
                                    Button { workspace.select(row.id) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: row.kind == .claude ? "sparkle" : "terminal")
                                            Text(row.title).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .font(.system(size: 12)).padding(8).contentShape(Rectangle())
                                        .background(row.id == workspace.snapshot.selectedID ? JackPalette.selection : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Abrir al lado") { splitID = row.id }
                                        Button("Renombrar") { renameText = row.title; renaming = row }
                                        Button("Cerrar terminal", role: .destructive) { close(row.id) }
                                    }
                                }
                            }
                        }
                    }
                }.padding(8)
            }
        }.background(JackPalette.chrome)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Mostrar u ocultar barra lateral")
            if let selected = workspace.selected {
                Text((selected.projectPath as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted).lineLimit(1).truncationMode(.middle)
            } else { Text("Terminal").font(.system(size: 13, weight: .medium)) }
            Spacer()
            Menu {
                Button("Sin división") { splitID = nil }
                ForEach(entries.filter { $0.id != workspace.snapshot.selectedID }) { entry in
                    Button(entry.title) { splitID = entry.id }
                }
            } label: { Image(systemName: "rectangle.split.2x1") }.help("Dividir terminales")
            newMenu
        }
        .buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 38).padding(.bottom, 12)
        .background(JackPalette.chrome)
    }

    private var newMenu: some View {
        Menu {
            if let directory = workspace.selected?.projectPath {
                Button("Claude Code en este proyecto") { create(.claude, directory: directory) }
                Button("Terminal libre en este proyecto") { create(.shell, directory: directory) }
                Divider()
            }
            Button("Claude Code en otra carpeta…") { chooseFolder(.claude) }
            Button("Terminal libre en otra carpeta…") { chooseFolder(.shell) }
            Button("Retomar sesión de Claude Code…") { importingClaude = true }
        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Nueva terminal")
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Button(entry.title) { workspace.select(entry.id) }.buttonStyle(.plain)
                        Button { close(entry.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).help("Cerrar terminal")
                    }
                    .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(entry.id == workspace.snapshot.selectedID ? JackPalette.canvas : .clear)
                }
            }
        }.scrollIndicators(.hidden).background(JackPalette.chrome)
    }

    private func pane(_ entry: TerminalWorkspaceEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.title).font(.system(size: 11, weight: .medium))
                Spacer()
                if entry.id == splitID {
                    Button { splitID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12).frame(height: 26).background(JackPalette.chrome)
            if let session = workspace.sessions[entry.id] {
                NativeTerminalPane(session: session) { workspace.start(entry.id, allowed: normal) }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(JackPalette.muted)
                    Text(entry.kind == .claude ? "Claude Code directo" : "Terminal del proyecto").font(.headline)
                    Text("\(entry.projectPath)").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    Button(entry.kind == .claude ? "Abrir Claude Code" : "Abrir terminal") { workspace.start(entry.id, allowed: normal) }
                    Text("Se abrirá solo al pulsar el botón.").font(.system(size: 11)).foregroundStyle(JackPalette.faint)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity).clipped().id(entry.id)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 38)).foregroundStyle(JackPalette.muted)
            Text("Tu proyecto, desde la terminal").font(.system(size: 22, weight: .medium))
            Text("Claude Code nativo, pestañas y terminales lado a lado.\nElige una carpeta para empezar.")
                .font(.system(size: 13)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center)
            HStack {
                Button("Abrir Claude Code…") { chooseFolder(.claude) }
                Button("Terminal libre…") { chooseFolder(.shell) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func create(_ kind: TerminalWorkspaceEntry.Kind, directory: String) {
        workspace.create(kind: kind, directory: directory, allowed: normal)
    }
    private func chooseFolder(_ kind: TerminalWorkspaceEntry.Kind) {
        guard normal else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Abrir terminal"
        if let path = workspace.selected?.projectPath { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let path = panel.url?.path { create(kind, directory: path) }
    }
    private func close(_ id: UUID) {
        if workspace.sessions[id]?.running == true { closing = id }
        else { workspace.remove(id); if splitID == id { splitID = nil } }
    }
    private func importSession(_ session: ClaudeSessionSummary) {
        workspace.importSession(session, allowed: normal)
    }
    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == workspace.snapshot.selectedID } ?? 0
        workspace.select(entries[(index + delta + entries.count) % entries.count].id)
    }
    private func focusTerminal() {
        if let id = workspace.snapshot.selectedID, let session = workspace.sessions[id] {
            session.view.window?.makeFirstResponder(session.view)
        }
    }
    private var actions: JackActions {
        JackActions(newAgent: { if let path = workspace.selected?.projectPath { create(.claude, directory: path) } else { chooseFolder(.claude) } },
                    resumeClaudeSession: { importingClaude = true }, move: move,
                    selectIndex: { if entries.indices.contains($0) { workspace.select(entries[$0].id) } },
                    nextAttention: focusTerminal, focusComposer: focusTerminal, focusSearch: { searchFocused = true },
                    toggleUnread: {}, toggleTerminal: { if let path = workspace.selected?.projectPath { create(.shell, directory: path) } else { chooseFolder(.shell) } },
                    toggleBrowser: {}, toggleSimulator: {}, toggleGit: {}, toggleExplorer: {},
                    toggleSidebar: { sidebarVisible.toggle() }, closeTab: { if let id = workspace.snapshot.selectedID { close(id) } },
                    cyclePane: { _ in if let id = splitID, let session = workspace.sessions[id] { session.view.window?.makeFirstResponder(session.view) } else { focusTerminal() } },
                    closePanes: { splitID = nil }, paneCount: splitID == nil ? 0 : 1,
                    enterBatterySaver: enterBatterySaver, hasSelection: workspace.selected != nil, agentCount: entries.count, terminalOnly: true)
    }
}

private struct NativeTerminalPane: View {
    @ObservedObject var session: TerminalSession
    let reopen: () -> Void
    var body: some View {
        ZStack {
            TerminalHost(container: session.container)
            if !session.running {
                VStack(spacing: 10) {
                    Text("El proceso ha terminado").font(.system(size: 12, weight: .medium))
                    Button("Abrir de nuevo", action: reopen)
                }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
