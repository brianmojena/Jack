import AppKit
import JackCore
import SwiftTerm
import SwiftUI
import WebKit

enum WorkspaceTool: String, CaseIterable, Identifiable {
    case terminal, browser, simulator
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .browser: "Navegador"
        case .simulator: "Simulador"
        }
    }
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .simulator: "iphone"
        }
    }
}

/// One tab of the right-hand pane: a shell, a web view or the iOS simulator.
struct WorkspaceTab: Identifiable, Equatable {
    let id: UUID
    let kind: WorkspaceTool
    let number: Int
}

/// Each agent's terminals and browser tabs. They stay alive while the user switches agents,
/// and only the pane observes this object, so opening a tab never re-renders the chat.
@MainActor final class WorkspaceSessions: ObservableObject {
    @Published private(set) var tabs: [UUID: [WorkspaceTab]] = [:]
    @Published private(set) var selection: [UUID: UUID] = [:]
    private var terminals: [UUID: TerminalSession] = [:]
    private var browsers: [UUID: BrowserSession] = [:]
    private var explorers: [String: FileTreeModel] = [:]
    /// Shared by every agent: there is one set of simulators on the Mac.
    private(set) lazy var simulator = SimulatorSession()
    /// Adds files, such as a simulator screenshot, to an agent's next message.
    var attach: ((UUID, [String]) -> Void)?

    var terminalCount: Int { tabs.values.reduce(0) { $0 + $1.filter { $0.kind == .terminal }.count } }

    func tabs(for conversation: UUID) -> [WorkspaceTab] { tabs[conversation] ?? [] }

    func selectedTab(for conversation: UUID) -> WorkspaceTab? {
        let list = tabs(for: conversation)
        return list.first { $0.id == selection[conversation] } ?? list.last
    }

    @discardableResult
    func open(_ kind: WorkspaceTool, for conversation: UUID) -> WorkspaceTab {
        let list = tabs(for: conversation)
        // One simulator tab per agent is enough: they all show the same device.
        if kind == .simulator, let existing = list.first(where: { $0.kind == .simulator }) {
            selection[conversation] = existing.id
            return existing
        }
        let number = (list.filter { $0.kind == kind }.map(\.number).max() ?? 0) + 1
        let tab = WorkspaceTab(id: UUID(), kind: kind, number: number)
        tabs[conversation] = list + [tab]
        selection[conversation] = tab.id
        return tab
    }

    func select(_ tab: UUID, for conversation: UUID) {
        if selection[conversation] != tab { selection[conversation] = tab }
    }

    func close(_ tab: UUID, for conversation: UUID) {
        var list = tabs(for: conversation)
        guard let index = list.firstIndex(where: { $0.id == tab }) else { return }
        list.remove(at: index)
        terminals.removeValue(forKey: tab)?.terminate()
        browsers[tab] = nil
        tabs[conversation] = list
        if selection[conversation] == tab {
            selection[conversation] = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        }
    }

    /// Selects a tab of this kind, opening one when the agent has none.
    func reveal(_ kind: WorkspaceTool, for conversation: UUID) {
        if let current = selectedTab(for: conversation), current.kind == kind { return }
        if let existing = tabs(for: conversation).last(where: { $0.kind == kind }) { select(existing.id, for: conversation) }
        else { open(kind, for: conversation) }
    }

    func terminal(_ tab: UUID, conversation: UUID, directory: String) -> TerminalSession {
        if let session = terminals[tab] { return session }
        let session = TerminalSession(directory: directory) { [weak self] url in self?.openLink(url, for: conversation) }
        terminals[tab] = session
        return session
    }

    func browser(_ tab: UUID) -> BrowserSession {
        if let session = browsers[tab] { return session }
        let session = BrowserSession()
        browsers[tab] = session
        return session
    }

    func existingBrowser(_ tab: UUID) -> BrowserSession? { browsers[tab] }
    func existingTerminal(_ tab: UUID) -> TerminalSession? { terminals[tab] }

    /// Web links from a terminal open in the agent's browser tab, or a new one.
    func openLink(_ url: URL, for conversation: UUID) {
        let tab = tabs(for: conversation).last { $0.kind == .browser } ?? open(.browser, for: conversation)
        select(tab.id, for: conversation)
        browser(tab.id).open(url)
    }

    func explorer(for path: String) -> FileTreeModel {
        if let model = explorers[path] { return model }
        let model = FileTreeModel(root: path)
        explorers[path] = model
        return model
    }

    /// Ends the shells and pages of agents that no longer exist.
    func prune(keeping ids: Set<UUID>) {
        for id in tabs.keys where !ids.contains(id) {
            for tab in tabs[id] ?? [] { close(tab.id, for: id) }
            tabs[id] = nil
            selection[id] = nil
        }
    }

    func terminateAll() { terminals.values.forEach { $0.terminate() } }
}

// MARK: - Pane

/// The right-hand pane: the selected agent's terminals and browser tabs.
struct WorkspacePane: View, Equatable {
    @ObservedObject var sessions: WorkspaceSessions
    let conversationID: UUID
    let projectPath: String
    let onClose: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversationID == rhs.conversationID && lhs.projectPath == rhs.projectPath
    }

    var body: some View {
        let tabs = sessions.tabs(for: conversationID)
        let selected = sessions.selectedTab(for: conversationID)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            StripTab(selected: tab.id == selected?.id, onSelect: { sessions.select(tab.id, for: conversationID) },
                                     onClose: { sessions.close(tab.id, for: conversationID) }) {
                                Image(systemName: tab.kind.symbol).font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                            } title: {
                                WorkspaceTabTitle(tab: tab, browser: sessions.existingBrowser(tab.id))
                            }
                            .contextMenu {
                                if tab.kind == .terminal, let terminal = sessions.existingTerminal(tab.id) {
                                    Button("Reiniciar terminal", systemImage: "arrow.counterclockwise") { terminal.restart() }
                                }
                                Button("Cerrar pestaña", systemImage: "xmark") { sessions.close(tab.id, for: conversationID) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: tabs.count < 4, vertical: false)
                Menu {
                    Button("Nuevo terminal", systemImage: "apple.terminal") { sessions.open(.terminal, for: conversationID) }
                    Button("Nuevo navegador", systemImage: "globe") { sessions.open(.browser, for: conversationID) }
                    Button("Simulador de iOS", systemImage: "iphone") { sessions.open(.simulator, for: conversationID) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                } primaryAction: {
                    sessions.open(selected?.kind == .browser ? .browser : .terminal, for: conversationID)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(JackPalette.muted)
                .padding(.horizontal, 10)
                .help("Nueva pestaña · mantén pulsado para elegir")
                WindowDragArea()
                StripIconButton(symbol: "xmark", help: "Ocultar el panel", action: onClose).padding(.trailing, 6)
            }
            .frame(height: JackMetrics.stripHeight)
            .background(JackPalette.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }

            Group {
                if let selected {
                    switch selected.kind {
                    case .terminal:
                        TerminalPanel(session: sessions.terminal(selected.id, conversation: conversationID, directory: projectPath))
                    case .browser:
                        BrowserPanel(session: sessions.browser(selected.id))
                    case .simulator:
                        SimulatorPanel(session: sessions.simulator) { paths in sessions.attach?(conversationID, paths) }
                    }
                } else {
                    emptyState
                }
            }
            .id(selected?.id)
            // A fixed minimum keeps the pane's size stable while its content changes.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
        }
        .background(JackPalette.canvas)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Sin pestañas").font(.system(size: 12.5, weight: .medium)).foregroundStyle(JackPalette.muted)
            HStack(spacing: 8) {
                Button("Terminal") { sessions.open(.terminal, for: conversationID) }
                Button("Navegador") { sessions.open(.browser, for: conversationID) }
                Button("Simulador") { sessions.open(.simulator, for: conversationID) }
            }
            .controlSize(.small)
        }
    }
}

private struct WorkspaceTabTitle: View {
    let tab: WorkspaceTab
    let browser: BrowserSession?

    var body: some View {
        if tab.kind == .browser, let browser {
            BrowserTitle(session: browser)
        } else {
            switch tab.kind {
            case .terminal: Text("Terminal \(tab.number)")
            case .browser: Text("Nueva pestaña")
            case .simulator: Text("Simulador")
            }
        }
    }
}

private struct BrowserTitle: View {
    @ObservedObject var session: BrowserSession
    var body: some View {
        Text(session.title.isEmpty ? (URL(string: session.address)?.host.map { host in
            URL(string: session.address)?.port.map { "\(host):\($0)" } ?? host
        } ?? "Nueva pestaña") : session.title)
    }
}

// MARK: - Terminal

/// A login shell in the agent's project folder.
@MainActor final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var running = false
    @Published private(set) var directory: String
    let projectPath: String
    let container: TerminalContainer
    var view: JackTerminalView { container.terminal }

    init(directory: String, openLink: @escaping (URL) -> Void) {
        self.directory = directory
        projectPath = directory
        container = TerminalContainer(terminal: JackTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)))
        super.init()
        view.openLink = openLink
        view.processDelegate = self
        start()
    }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Jack"
        if environment["LANG"] == nil { environment["LANG"] = "es_ES.UTF-8" }
        // A leading dash makes it a login shell, so the user's PATH and aliases load as in Terminal.app.
        view.startProcess(executable: shell, args: [], environment: environment.map { "\($0)=\($1)" },
                          execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: projectPath)
        directory = projectPath
        running = true
    }

    func restart() {
        terminate()
        view.getTerminal().resetToInitialState()
        start()
        view.window?.makeFirstResponder(view)
    }

    func terminate() {
        if running { view.terminate() }
        running = false
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let path = URL(string: directory)?.path ?? Optional(directory), !path.isEmpty else { return }
        Task { @MainActor in if self.directory != path { self.directory = path } }
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.running = false }
    }
}

/// Web links clicked in the terminal open in Jack's browser; colors follow the app's appearance.
final class JackTerminalView: LocalProcessTerminalView {
    var openLink: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollerStyle = .overlay
        optionAsMetaKey = false
        getTerminal().setCursorStyle(.steadyBar)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let openLink {
            openLink(url)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = JackPalette.canvasColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
            nativeForegroundColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .textColor
            selectedTextBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.38 : 0.24)
            caretColor = NSColor.controlAccentColor
        }
        installColors((dark ? Self.darkPalette : Self.lightPalette).map { value in
            SwiftTerm.Color(red8: UInt16(value >> 16 & 0xFF), green8: UInt16(value >> 8 & 0xFF), blue8: UInt16(value & 0xFF))
        })
    }

    /// ANSI colors tuned to the system palette, readable on the window's own background.
    private static let darkPalette: [Int] = [
        0x48484A, 0xFF6B63, 0x63D47A, 0xE8C766, 0x5EA8FF, 0xD48CF5, 0x63D2E2, 0xD1D1D6,
        0x6E6E73, 0xFF8F87, 0x86E29A, 0xF2D88A, 0x86BEFF, 0xE2AAFA, 0x8ADFEB, 0xF5F5F7,
    ]
    private static let lightPalette: [Int] = [
        0x1D1D1F, 0xC9342C, 0x1E8A3C, 0x946A00, 0x1D6FD6, 0x8E3FBA, 0x15808F, 0x8E8E93,
        0x6E6E73, 0xE0453D, 0x27A048, 0xB07F00, 0x3584EB, 0xA457D2, 0x1C98A8, 0xC7C7CC,
    ]
}

/// Holds the terminal with a small margin. Resizes reach the terminal once the user stops
/// dragging, since every resize reflows the whole scrollback and redraws the shell prompt.
final class TerminalContainer: NSView {
    let terminal: JackTerminalView
    private var pendingResize: DispatchWorkItem?

    init(terminal: JackTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var terminalFrame: NSRect {
        NSRect(x: 10, y: 6, width: max(40, bounds.width - 12), height: max(20, bounds.height - 8))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleResize()
    }

    override func layout() {
        super.layout()
        scheduleResize()
    }

    private func scheduleResize() {
        let target = terminalFrame
        guard terminal.frame != target else { return }
        pendingResize?.cancel()
        if window == nil || terminal.frame.width < 60 {
            terminal.frame = target
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.terminal.frame = self.terminalFrame
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        terminal.frame = terminalFrame
        // The GPU renderer draws only when content changes and keeps typing and output cheap.
        if !terminal.isUsingMetalRenderer { try? terminal.setUseMetal(true) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.terminal.window === window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }
}

/// Moves the session's terminal into whichever panel is showing it.
private struct TerminalHost: NSViewRepresentable {
    let container: TerminalContainer
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        if container.superview !== host { attach(to: host) }
    }
    private func attach(to host: NSView) {
        container.removeFromSuperview()
        container.frame = host.bounds
        container.autoresizingMask = [.width, .height]
        host.addSubview(container)
    }
}

struct TerminalPanel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        ZStack {
            TerminalHost(container: session.container)
            if !session.running {
                VStack(spacing: 8) {
                    Text("El terminal se ha cerrado").font(.system(size: 12, weight: .medium))
                    Button("Abrir de nuevo") { session.restart() }.controlSize(.small)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

// MARK: - Browser

@MainActor final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var address = ""
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var error: String?
    @Published private(set) var hasPage = false
    @Published private(set) var secure = false
    @Published private(set) var title = ""
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = JackPalette.canvasColor
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // KVO fires on the main thread; each value is published only when it changes.
        observations = [
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.urlChanged(view.url) } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.set(\.loading, view.isLoading) } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated {
                guard let self else { return }
                // Coarse steps are enough for a 2-point bar and avoid a redraw per network event.
                let value = (view.estimatedProgress * 10).rounded() / 10
                self.set(\.progress, value)
            } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.set(\.canGoBack, view.canGoBack) } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.set(\.title, view.title ?? "") } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.set(\.canGoForward, view.canGoForward) } },
        ]
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<BrowserSession, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func urlChanged(_ url: URL?) {
        guard let url else { return }
        set(\.address, url.absoluteString)
        set(\.secure, url.scheme == "https")
        set(\.hasPage, true)
    }

    func open(_ input: String) {
        guard let url = BrowserAddress.url(from: input) else { return }
        open(url)
    }

    func open(_ url: URL) {
        error = nil; hasPage = true
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() { if loading { webView.stopLoading() } else { webView.reload() } }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { set(\.error, nil) }

    /// Links that ask for a new window open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        if nsError.code == NSURLErrorCannotConnectToHost, let host = webView.url?.host ?? URL(string: address)?.host,
           ["localhost", "127.0.0.1", "0.0.0.0"].contains(host) {
            self.error = "No hay nada escuchando en \(address). ¿Está arrancado el servidor de desarrollo?"
        } else {
            self.error = error.localizedDescription
        }
    }
}

private struct WebHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        if webView.superview !== host { attach(to: host) }
    }
    private func attach(to host: NSView) {
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }
}

struct BrowserPanel: View {
    @ObservedObject var session: BrowserSession
    @FocusState private var addressFocused: Bool
    private static let ports = [3000, 5173, 8080, 8000, 4321]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                toolButton("chevron.left", help: "Atrás", enabled: session.canGoBack) { session.webView.goBack() }
                toolButton("chevron.right", help: "Adelante", enabled: session.canGoForward) { session.webView.goForward() }
                toolButton(session.loading ? "xmark" : "arrow.clockwise", help: session.loading ? "Detener" : "Recargar", enabled: session.hasPage) { session.reloadOrStop() }
                HStack(spacing: 6) {
                    Image(systemName: session.secure ? "lock.fill" : "globe")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(JackPalette.faint)
                    TextField("Dirección o puerto, p. ej. localhost:3000", text: $session.address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($addressFocused)
                        .onSubmit { session.open(session.address) }
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(addressFocused ? JackPalette.accent.opacity(0.6) : .clear, lineWidth: 1))
                .padding(.horizontal, 4)
                toolButton("safari", help: "Abrir en el navegador del sistema", enabled: session.hasPage) {
                    if let url = session.webView.url { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.horizontal, 6).frame(height: 36)
            .overlay(alignment: .bottom) {
                Rectangle().fill(JackPalette.accent).frame(height: 2)
                    .scaleEffect(x: max(0.05, session.progress), anchor: .leading)
                    .opacity(session.loading ? 1 : 0)
            }
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            ZStack {
                WebHost(webView: session.webView).opacity(session.hasPage ? 1 : 0)
                if !session.hasPage { start }
                if let error = session.error {
                    VStack(spacing: 9) {
                        Image(systemName: "bolt.horizontal.circle").font(.system(size: 24, weight: .light)).foregroundStyle(JackPalette.muted)
                        Text(error).font(.system(size: 12)).foregroundStyle(JackPalette.secondaryText)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Button("Reintentar") { session.open(session.address) }.controlSize(.small)
                    }
                    .padding(18).frame(maxWidth: 320)
                    .background(JackPalette.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(JackPalette.hairline))
                }
            }
        }
        .onAppear { if !session.hasPage { addressFocused = true } }
    }

    private func toolButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? JackPalette.secondaryText : JackPalette.faint)
        .disabled(!enabled)
        .help(help)
    }

    private var start: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe").font(.system(size: 28, weight: .light)).foregroundStyle(JackPalette.faint)
            VStack(spacing: 4) {
                Text("Vista previa").font(.system(size: 13, weight: .semibold))
                Text("Abre tu servidor local o cualquier dirección.").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            }
            HStack(spacing: 4) {
                ForEach(Self.ports, id: \.self) { port in
                    Button { session.open("localhost:\(port)") } label: {
                        Text(":\(port)").font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(JackPalette.panel, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.secondaryText)
                }
            }
            Text("Los enlaces web que pulses en el terminal también se abren aquí.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }
}
