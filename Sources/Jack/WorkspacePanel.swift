import AppKit
import JackCore
import SwiftTerm
import SwiftUI
import WebKit

enum WorkspaceTool: String, CaseIterable, Identifiable {
    case terminal, browser
    var id: String { rawValue }
    var title: String { self == .terminal ? "Terminal" : "Navegador" }
    var symbol: String { self == .terminal ? "terminal" : "globe" }
}

/// Keeps each agent's terminal and browser alive while the user switches between agents.
@MainActor final class WorkspaceSessions: ObservableObject {
    private var terminals: [UUID: TerminalSession] = [:]
    private var browsers: [UUID: BrowserSession] = [:]

    func terminal(for conversation: ChatConversation, openLink: @escaping (URL) -> Void) -> TerminalSession {
        if let session = terminals[conversation.id] { return session }
        let session = TerminalSession(directory: conversation.projectPath, openLink: openLink)
        terminals[conversation.id] = session
        return session
    }

    func browser(for id: UUID) -> BrowserSession {
        if let session = browsers[id] { return session }
        let session = BrowserSession()
        browsers[id] = session
        return session
    }

    /// Ends the shells and pages of agents that no longer exist.
    func prune(keeping ids: Set<UUID>) {
        for (id, session) in terminals where !ids.contains(id) { session.terminate(); terminals[id] = nil }
        for id in browsers.keys where !ids.contains(id) { browsers[id] = nil }
    }

    func terminateAll() { terminals.values.forEach { $0.terminate() } }
}

// MARK: - Terminal

/// A login shell in the agent's project folder.
@MainActor final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var title: String
    @Published private(set) var running = false
    let directory: String
    let view: JackTerminalView

    init(directory: String, openLink: @escaping (URL) -> Void) {
        self.directory = directory
        title = URL(fileURLWithPath: directory).lastPathComponent
        view = JackTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init()
        view.openLink = openLink
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.caretColor = .controlAccentColor
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
                          execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: directory)
        running = true
    }

    func restart() {
        terminate()
        view.getTerminal().resetToInitialState()
        start()
    }

    func terminate() {
        if running { view.terminate() }
        running = false
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = title } }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.running = false }
    }
}

/// Web links clicked in the terminal open in Jack's browser instead of the default one.
final class JackTerminalView: LocalProcessTerminalView {
    var openLink: ((URL) -> Void)?

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let openLink {
            openLink(url)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let view: JackTerminalView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }
    /// The same terminal view moves between containers when the panel is rebuilt.
    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

struct TerminalPanel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(session.running ? JackPalette.green : JackPalette.faint).frame(width: 7, height: 7)
                Text(session.title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { session.restart() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(session.running ? "Reiniciar el terminal" : "Abrir un terminal nuevo")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ZStack {
                TerminalHost(view: session.view)
                if !session.running {
                    VStack(spacing: 8) {
                        Text("El terminal se ha cerrado").font(.system(size: 12, weight: .medium))
                        Button("Abrir de nuevo") { session.restart() }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Browser

@MainActor final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var address = ""
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var error: String?
    @Published private(set) var hasPage = false
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] view, _ in Task { @MainActor in
                if let url = view.url { self?.address = url.absoluteString; self?.hasPage = true }
            } },
            webView.observe(\.title) { [weak self] view, _ in Task { @MainActor in self?.title = view.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.loading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
        ]
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
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { error = nil }

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
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }
    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

struct BrowserPanel: View {
    @ObservedObject var session: BrowserSession
    @FocusState private var addressFocused: Bool
    private static let ports = [3000, 5173, 8080, 8000, 4321]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).help("Atrás")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward).help("Adelante")
                Button { session.reloadOrStop() } label: { Image(systemName: session.loading ? "xmark" : "arrow.clockwise") }
                    .disabled(!session.hasPage).help(session.loading ? "Detener" : "Recargar")
                TextField("Dirección o puerto, p. ej. localhost:3000", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($addressFocused)
                    .onSubmit { session.open(session.address) }
                Button {
                    if let url = session.webView.url { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "safari") }
                    .disabled(session.webView.url == nil).help("Abrir en el navegador del sistema")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
            ProgressView(value: session.loading ? session.progress : 0)
                .progressViewStyle(.linear).controlSize(.mini)
                .opacity(session.loading ? 1 : 0)
                .frame(height: 2)
            Divider()
            ZStack {
                WebHost(webView: session.webView).opacity(session.hasPage ? 1 : 0)
                if !session.hasPage { start }
                if let error = session.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(JackPalette.amber)
                        Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Reintentar") { session.open(session.address) }
                    }
                    .padding(18).frame(maxWidth: 340)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear { if !session.hasPage { addressFocused = true } }
    }

    private var start: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe").font(.system(size: 30, weight: .light)).foregroundStyle(JackPalette.faint)
            Text("Escribe una dirección o abre tu servidor local").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            HStack(spacing: 6) {
                ForEach(Self.ports, id: \.self) { port in
                    Button(":\(port)") { session.open("localhost:\(port)") }
                        .controlSize(.small)
                }
            }
            Text("Los enlaces web que pulses en el terminal también se abren aquí.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
        }
        .padding(20)
    }
}

// MARK: - Panel

/// The inspector beside the conversation: terminal and browser for the selected agent.
struct WorkspacePanel: View {
    @ObservedObject var sessions: WorkspaceSessions
    let conversation: ChatConversation
    @Binding var tool: WorkspaceTool

    var body: some View {
        let browser = sessions.browser(for: conversation.id)
        VStack(spacing: 0) {
            Picker("Herramienta", selection: $tool) {
                ForEach(WorkspaceTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            switch tool {
            case .terminal:
                TerminalPanel(session: sessions.terminal(for: conversation) { url in
                    browser.open(url)
                    tool = .browser
                })
                .id(conversation.id)
            case .browser:
                BrowserPanel(session: browser).id(conversation.id)
            }
        }
    }
}
