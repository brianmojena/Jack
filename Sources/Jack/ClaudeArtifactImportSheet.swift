import AppKit
import JackCore
import SwiftUI
import WebKit

/// Created only by the Normal-mode artifact panel, and only after an explicit user action.
@MainActor final class ClaudeArtifactConnection: NSObject, ObservableObject, WKUIDelegate {
    let webView: WKWebView
    @Published var artifacts: [ClaudeArtifact] = []
    @Published var busy = false
    @Published var status = "Inicia sesión con la misma cuenta que usas en Claude Desktop y pulsa Cargar artefactos."
    @Published var error: String?
    private var job: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        // Persistent login isolated from artifact previews and Jack's general browser.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "0EBA18D8-223D-4BDE-A6B7-6F69DA17FB11")!)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func fetch(_ path: String) async throws -> Data {
        try Task.checkCancellation()
        guard webView.url?.scheme == "https", webView.url?.host == "claude.ai", path.hasPrefix("/api/organizations") else {
            throw ArtifactError("Completa el inicio de sesión en Claude antes de cargar los artefactos.")
        }
        let result = try await webView.callAsyncJavaScript("""
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 30000);
        try {
            const response = await fetch(path, { credentials: 'include', signal: controller.signal });
            if (!response.ok) return { status: response.status };
            const text = await response.text();
            if (text.length > 32 * 1024 * 1024) return { status: 413 };
            return { status: 200, text };
        } finally { clearTimeout(timer); }
        """, arguments: ["path": path], in: nil, in: .defaultClient)
        try Task.checkCancellation()
        guard let response = result as? [String: Any], let status = response["status"] as? Int else {
            throw ArtifactError("No se pudo leer la respuesta de Claude.")
        }
        guard status == 200, let text = response["text"] as? String else {
            if status == 401 || status == 403 {
                throw ArtifactError("Claude no permitió el acceso. Inicia sesión o completa la verificación y vuelve a cargar.")
            }
            throw ArtifactError("Claude no pudo completar la petición (\(status)). Vuelve a intentarlo.")
        }
        return Data(text.utf8)
    }

    func load() {
        guard !busy else { return }
        busy = true; error = nil; artifacts = []
        job = Task {
            defer { busy = false }
            do {
                struct Organization: Decodable { let uuid: String }
                let organizations = try JSONDecoder().decode([Organization].self, from: await fetch("/api/organizations"))
                var found: [ClaudeArtifact] = []
                var seen = Set<String>()
                for organization in organizations {
                    guard UUID(uuidString: organization.uuid) != nil else { throw ArtifactError("Claude devolvió una cuenta no válida.") }
                    var offset = 0
                    var cursor: String?
                    var cursors = Set<String>()
                    repeat {
                        status = "Cargando artefactos… \(found.count) encontrados"
                        var components = URLComponents()
                        components.path = "/api/organizations/\(organization.uuid)/user_artifacts"
                        components.queryItems = [.init(name: "limit", value: "100"), .init(name: "offset", value: String(offset)),
                                                 .init(name: "include_latest_published_artifact_uuid", value: "true")]
                        if let cursor { components.queryItems?.append(.init(name: "cursor", value: cursor)) }
                        let page = try JSONDecoder().decode(ClaudeArtifactPage.self, from: await fetch(components.string!))
                        var added = 0
                        for var artifact in page.artifacts {
                            guard UUID(uuidString: artifact.uuid) != nil, UUID(uuidString: artifact.chatConversationUUID) != nil else {
                                throw ArtifactError("Claude devolvió un artefacto con un identificador no válido.")
                            }
                            artifact.organizationID = organization.uuid
                            if seen.insert(artifact.origin).inserted { found.append(artifact); added += 1 }
                        }
                        cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
                        if let cursor, !cursors.insert(cursor).inserted { throw ArtifactError("Claude repitió una página. Vuelve a cargar la lista.") }
                        if page.artifacts.isEmpty { break }
                        if added == 0 { throw ArtifactError("Claude no avanzó a la siguiente página. Vuelve a cargar la lista.") }
                        offset += page.artifacts.count
                        if cursor == nil && page.artifacts.count < 100 { break }
                    } while true
                }
                artifacts = found
                status = found.isEmpty ? "No hay artefactos en esta cuenta de Claude." : "\(found.count) artefactos disponibles"
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; status = "No se pudo completar la lista de artefactos." }
        }
    }

    func importArtifacts(_ chosen: [ClaudeArtifact], library: ArtifactLibrary, conversation: ChatConversation,
                         completed: @escaping (Set<String>) -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        job = Task {
            defer { busy = false }
            var imported = Set<String>()
            var copies = 0, links = 0
            var failures: [String] = []
            var chats: [String: Data] = [:]
            for (index, artifact) in chosen.enumerated() {
                do {
                    try Task.checkCancellation()
                    status = "Importando \(index + 1) de \(chosen.count): \(artifact.title)"
                    let existing = try library.list(projectPath: conversation.projectPath).first { $0.origin == artifact.origin }
                    if let existing {
                        imported.insert(artifact.id)
                        if existing.kind == .link { links += 1 } else { copies += 1 }
                        continue
                    }
                    let key = artifact.organizationID + ":" + artifact.chatConversationUUID
                    let data: Data
                    if let cached = chats[key] { data = cached }
                    else {
                        data = try await fetch("/api/organizations/\(artifact.organizationID)/chat_conversations/\(artifact.chatConversationUUID)?tree=True&rendering_mode=raw")
                        // A bounded per-batch cache avoids refetching the same chat for adjacent artifacts.
                        if chats.count >= 4 { chats.removeAll() }
                        chats[key] = data
                    }
                    let content = try ClaudeArtifactContent.extract(from: data, identifier: artifact.artifactIdentifier)
                    let saved = try library.importClaudeArtifact(artifact, content: content, projectPath: conversation.projectPath, conversationID: conversation.id)
                    imported.insert(artifact.id)
                    if saved.kind == .link { links += 1 } else { copies += 1 }
                    await Task.yield()
                } catch is CancellationError { break }
                catch { failures.append("\(artifact.title): \(error.localizedDescription)") }
            }
            status = "\(copies) copias locales · \(links) enlaces de Claude · \(failures.count) errores"
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
            completed(imported)
        }
    }

    func cancel() { job?.cancel() }

    func disconnect() {
        guard !busy else { return }
        artifacts = []
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in
                self?.status = "Sesión desconectada. Puedes iniciar sesión con otra cuenta."
                self?.webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
            }
        }
    }
}

private struct ClaudeLoginView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) { }
}

struct ClaudeArtifactImportSheet: View {
    @ObservedObject var library: ArtifactLibrary
    let conversation: ChatConversation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var connection = ClaudeArtifactConnection()
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var showLogin = true
    private var filtered: [ClaudeArtifact] {
        connection.artifacts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.chatConversationName ?? "").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Importar desde Claude Desktop").font(.headline)
                Spacer()
                Button(showLogin ? "Ocultar sesión" : "Mostrar sesión") { showLogin.toggle() }
                Button("Desconectar") { selection = []; connection.disconnect(); showLogin = true }.disabled(connection.busy)
            }
            Text("Conecta la misma cuenta de Claude Desktop. Se copiará el contenido disponible; los demás artefactos se conservarán como enlaces a su conversación en Claude.")
                .font(.caption).foregroundStyle(.secondary)
            if showLogin { ClaudeLoginView(webView: connection.webView).frame(minHeight: 280) }
            HStack {
                Text(connection.status).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Cargar artefactos") { selection = []; connection.load() }.disabled(connection.busy)
            }
            if let error = connection.error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70)
            }
            if !connection.artifacts.isEmpty {
                TextField("Buscar por título o conversación", text: $search).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Seleccionar todos (\(connection.artifacts.count))") { selection = Set(connection.artifacts.map(\.id)) }
                    Button("Deseleccionar") { selection = [] }
                    Spacer()
                    Text("\(selection.count) seleccionados").font(.caption)
                }.disabled(connection.busy)
                List(filtered) { artifact in
                    Toggle(isOn: Binding(get: { selection.contains(artifact.id) }, set: { selected in
                        if selected { selection.insert(artifact.id) } else { selection.remove(artifact.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artifact.title)
                            Text(artifact.chatConversationName ?? artifact.artifactType).font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.checkbox).disabled(connection.busy)
                }.frame(minHeight: 160)
            }
            HStack {
                Button(connection.busy ? "Cancelar y cerrar" : "Cerrar") { connection.cancel(); dismiss() }
                Spacer()
                Button("Importar seleccionados (\(selection.count))") { runImport(connection.artifacts.filter { selection.contains($0.id) }) }
                    .disabled(connection.busy || selection.isEmpty)
                Button("Importar todos (\(connection.artifacts.count))") { runImport(connection.artifacts) }
                    .disabled(connection.busy || connection.artifacts.isEmpty)
            }
        }.padding(20).frame(width: 800, height: 720)
            .onChange(of: connection.artifacts.count) { _, count in if count > 0 { showLogin = false; selection = Set(connection.artifacts.map(\.id)) } }
            .onDisappear { connection.cancel() }
    }
    private func runImport(_ artifacts: [ClaudeArtifact]) {
        connection.importArtifacts(artifacts, library: library, conversation: conversation) { imported in
            selection.subtract(imported)
        }
    }
}
