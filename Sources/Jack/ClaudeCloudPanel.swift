import AppKit
import SwiftUI
import WebKit

/// The official cloud UI, with its own persistent login and no Jack native bridge.
/// Owned lazily by the Normal workspace; entering Light destroys the web views.
@MainActor final class ClaudeCloudSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let home = URL(string: "https://claude.ai/code")!
    static let dataStoreID = UUID(uuidString: "AC6788A1-1C7E-47F5-8A6C-F65104ACFE83")!
    let webView: WKWebView
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var error: String?
    private var observations: [NSKeyValueObservation] = []
    private var popups: [NSWindow] = []

    init(loadImmediately: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configure(webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observations = [
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.loading = view.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            }
        ]
        if loadImmediately { home() }
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
    }

    func home() { error = nil; webView.load(URLRequest(url: Self.home)) }
    func reload() { error = nil; webView.reload() }
    func stop() {
        webView.stopLoading()
        // Remove the documents too, so hidden cloud pages do not keep running in Light.
        webView.loadHTMLString("", baseURL: nil)
        for window in popups {
            (window.contentView as? WKWebView)?.stopLoading()
            window.delegate = nil
            window.close()
        }
        popups.removeAll()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { error = nil }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }
    private func failed(_ view: WKWebView, _ error: Error) {
        guard view === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = error.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { error = "La página de Claude se ha cerrado. Pulsa Reintentar para volver a cargarla." }
    }

    // Keep real OAuth popups: loading their requests into the main view breaks window.opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude Code Cloud"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.delegate = self
        popups.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentView as? WKWebView)?.stopLoading()
        popups.removeAll { $0 === window }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = webView.window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = "Claude Code Cloud"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = "Claude Code Cloud"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

struct ClaudeCloudPanel: View {
    @ObservedObject var session: ClaudeCloudSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Claude Code Cloud", systemImage: "cloud").font(.system(size: 13, weight: .semibold))
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).help("Atrás")
                Button { session.home() } label: { Image(systemName: "house") }.help("Lista de sesiones cloud")
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Recargar")
                if session.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abrir en navegador", systemImage: "safari") {
                    NSWorkspace.shared.open(session.webView.url ?? ClaudeCloudSession.home)
                }.help("También puedes abrir Claude en tu navegador para configurar tu cuenta")
            }
            .buttonStyle(.borderless).padding(.horizontal, 14).frame(height: 44)
            .background(JackPalette.chrome)
            Text("Inicia sesión en Claude para crear y continuar tareas en la nube. Elige el repositorio y el entorno en Claude.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ZStack {
                ClaudeCloudWebHost(webView: session.webView)
                if let error = session.error {
                    VStack(spacing: 12) {
                        Text("No se pudo cargar Claude Code Cloud").font(.headline)
                        Text(error).font(.callout).multilineTextAlignment(.center)
                        Button("Reintentar") { session.reload() }
                        Button("Ir a las sesiones") { session.home() }
                    }.padding(24).frame(maxWidth: 420).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

private struct ClaudeCloudWebHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        webView.removeFromSuperview()
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
