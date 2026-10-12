import AppKit
import JackCore
import SwiftUI
import WebKit
import PDFKit

struct ArtifactPanel: View {
    @ObservedObject var library: ArtifactLibrary
    let conversation: ChatConversation
    let openLink: (URL) -> Void
    let askAgent: (String) -> Void
    @State private var selection: UUID?
    @State private var selectedVersion = 0
    @State private var source = ""
    @State private var savedSource = ""
    @State private var data = Data()
    @State private var editing = false
    @State private var error: String?
    @State private var importLink = false
    @State private var link = ""
    @State private var newArtifact = false
    @State private var title = ""
    @State private var kind = ArtifactKind.html
    @State private var importSession = false
    @State private var candidates: [URL] = []
    @State private var candidateSource = ""
    private var items: [JackArtifact] { library.items.filter { $0.projectPath == conversation.projectPath } }
    private var selected: JackArtifact? { items.first { $0.id == selection } }
    private var dirty: Bool { source != savedSource }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Menu("Importar", systemImage: "square.and.arrow.down") {
                    Button("Archivo…", action: chooseFile)
                    Button("Enlace de Claude…") { importLink = true }
                    Button("Desde una sesión de Claude Code…") { importSession = true }
                    Button("Archivos y enlaces de esta conversación") { showLinks(conversation.messages, title: conversation.title, projectPath: conversation.projectPath) }
                }
                Button("Nuevo", systemImage: "plus") { newArtifact = true }
                Spacer()
            }.controlSize(.small).disabled(dirty)
            if let error = error ?? library.loadError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !items.isEmpty {
                Picker("Artefacto", selection: Binding(get: { selection }, set: { id in
                    guard !dirty else { error = "Guarda o descarta los cambios antes de cambiar de artefacto."; return }
                    selection = id
                })) {
                    Text("Selecciona…").tag(nil as UUID?)
                    ForEach(items) { artifact in Text(artifact.title).tag(Optional(artifact.id)) }
                }
            }
            if let artifact = selected {
                HStack {
                    Picker("Versión", selection: Binding(get: { selectedVersion }, set: { version in
                        guard !dirty else { error = "Guarda o descarta los cambios antes de cambiar de versión."; return }
                        load(artifact, version: version)
                    })) {
                        ForEach(artifact.revisions.reversed()) { revision in
                            Text("v\(revision.id) · \(revision.author)").tag(revision.id)
                        }
                    }.frame(maxWidth: 220)
                    Spacer()
                    if artifact.kind.isText && artifact.kind != .link {
                        Toggle("Código", isOn: $editing).toggleStyle(.button)
                    }
                    Button("Exportar", systemImage: "square.and.arrow.up") { export(artifact) }.disabled(dirty)
                }.controlSize(.small)
                Text(artifact.origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(artifact.origin)
                if dirty && selectedVersion != artifact.version {
                    Text("Hay una versión más reciente. Guarda como copia o descarta y carga la última.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if editing && artifact.kind.isText && artifact.kind != .link {
                    TextEditor(text: Binding(get: { source }, set: { value in
                        source = value
                        library.drafts[artifact.id] = dirty ? ArtifactDraft(version: selectedVersion, text: value) : nil
                    })).font(.system(size: 12, design: .monospaced))
                } else {
                    preview(artifact)
                }
                HStack {
                    if dirty {
                        Button("Guardar versión") { save(artifact) }
                        Button("Guardar como copia") { copy(artifact) }
                        Button("Descartar") { library.drafts[artifact.id] = nil; load(artifact, version: artifact.version) }
                    } else if selectedVersion != artifact.version {
                        Button("Restaurar como nueva versión") { restore(artifact) }
                    }
                    Spacer()
                    Button("Editar con agente") {
                        askAgent("Edita el artefacto \(artifact.id.uuidString.lowercased()) «\(artifact.title)» usando artifact_read y artifact_update. Lee primero la versión actual (v\(artifact.version)).")
                    }
                }.controlSize(.small)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Artefactos del proyecto").font(.headline)
                    Text("Importa un archivo o un enlace de Claude, o pide a un agente que cree uno.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            openLink(url); return .handled
        })
        .onAppear { selection = items.first(where: { $0.id == library.selectedID })?.id ?? items.first?.id; reload() }
        .onChange(of: selection) { _, _ in reload() }
        .onChange(of: library.selectedID) { _, id in
            guard !dirty else { error = "Otro agente cambió la biblioteca. Guarda o descarta tus cambios antes de abrir otro artefacto."; return }
            if items.contains(where: { $0.id == id }) { selection = id }
        }
        .onChange(of: selected?.version) { _, _ in if !dirty { reload() } }
        .sheet(isPresented: $importLink) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Importar enlace de Claude").font(.headline)
                TextField("https://claude.ai/…", text: $link).textFieldStyle(.roundedBorder)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Se guarda una referencia alojada en Claude. Para editar con otros agentes, importa también su archivo exportado.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Button("Cancelar") { importLink = false }; Spacer(); Button("Importar") {
                    perform {
                        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ArtifactError("Enlace inválido.") }
                        _ = try library.importLink(url, title: "Artefacto de Claude", projectPath: conversation.projectPath, conversationID: conversation.id)
                        importLink = false; link = ""
                    }
                } }
            }.padding(20).frame(width: 440)
        }
        .sheet(isPresented: $newArtifact) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nuevo artefacto").font(.headline)
                TextField("Título", text: $title).textFieldStyle(.roundedBorder)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Picker("Formato", selection: $kind) {
                    ForEach([ArtifactKind.html, .markdown, .svg, .code], id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                HStack { Button("Cancelar") { newArtifact = false }; Spacer(); Button("Crear") {
                    perform {
                        _ = try library.create(title: title, kind: kind, data: Data(), projectPath: conversation.projectPath, conversationID: conversation.id)
                        newArtifact = false; title = ""; editing = true
                    }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(20).frame(width: 360)
        }
        .sheet(isPresented: $importSession) {
            ArtifactSessionPicker { session in
                importSession = false
                Task {
                    let messages = await Task.detached { ClaudeSessions.load(session).messages }.value
                    showLinks(messages, title: session.title, projectPath: session.projectPath)
                }
            } cancel: { importSession = false }
        }
        .sheet(isPresented: Binding(get: { !candidates.isEmpty }, set: { if !$0 { candidates = [] } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Artefactos de \(candidateSource)").font(.headline)
                Text("Elige archivos o enlaces para conservar una copia en este proyecto.").font(.caption)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                List(candidates, id: \.absoluteString) { url in
                    Button(url.isFileURL ? url.path : url.absoluteString) {
                        perform {
                            if url.isFileURL {
                                _ = try library.importFile(url, projectPath: conversation.projectPath, conversationID: conversation.id)
                            } else {
                                _ = try library.importLink(url, title: candidateSource, projectPath: conversation.projectPath, conversationID: conversation.id)
                            }
                            candidates.removeAll { $0 == url }
                        }
                    }.lineLimit(2)
                }.frame(height: 240)
                Button("Cerrar") { candidates = [] }
            }.padding(20).frame(width: 500)
        }
    }

    @ViewBuilder private func preview(_ artifact: JackArtifact) -> some View {
        switch artifact.kind {
        case .html, .svg:
            VStack(alignment: .leading, spacing: 4) {
                Text("Vista local · sin red ni acceso a Jack").font(.caption2).foregroundStyle(.secondary)
                ArtifactWebPreview(source: savedSource, svg: artifact.kind == .svg)
            }
        case .markdown:
            ScrollView { MarkdownText(text: savedSource).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
        case .image:
            if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Text("No se pudo mostrar la imagen.") }
        case .pdf: ArtifactPDFPreview(data: data)
        case .link:
            VStack(spacing: 12) {
                Text("Este artefacto está alojado en Claude.").font(.headline)
                Text("Se abrirá en el navegador de Jack. Puede requerir iniciar sesión. Para modificar una copia local, importa su archivo exportado.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Abrir en Claude") { if let url = URL(string: savedSource), ArtifactLibrary.isClaudeArtifactURL(url) { openLink(url) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .code: ScrollView { Text(savedSource).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func reload() {
        guard let selected else { return }
        if let draft = library.drafts[selected.id] {
            load(selected, version: draft.version)
            source = draft.text; editing = true
        } else { load(selected, version: selected.version) }
    }
    private func load(_ artifact: JackArtifact, version: Int) {
        perform {
            data = try library.content(artifact.id, projectPath: conversation.projectPath, version: version)
            source = artifact.kind.isText ? String(decoding: data, as: UTF8.self) : ""
            savedSource = source; selectedVersion = version
        }
    }
    private func save(_ artifact: JackArtifact) {
        perform {
            let updated = try library.update(artifact.id, projectPath: conversation.projectPath, expectedVersion: selectedVersion, data: Data(source.utf8))
            library.drafts[artifact.id] = nil
            load(updated, version: updated.version)
        }
    }
    private func copy(_ artifact: JackArtifact) {
        perform {
            let copy = try library.create(title: artifact.title + " (copia)", kind: artifact.kind, data: Data(source.utf8),
                                          projectPath: conversation.projectPath, conversationID: conversation.id, origin: artifact.origin, fileExtension: artifact.fileExtension)
            library.drafts[artifact.id] = nil
            savedSource = source; selection = copy.id
        }
    }
    private func restore(_ artifact: JackArtifact) {
        perform {
            let updated = try library.update(artifact.id, projectPath: conversation.projectPath, expectedVersion: artifact.version, data: data)
            load(updated, version: updated.version)
        }
    }
    private func chooseFile() {
        guard !dirty else { error = "Guarda o descarta los cambios antes de importar."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            perform { _ = try library.importFile(url, projectPath: conversation.projectPath, conversationID: conversation.id) }
        }
    }
    private func export(_ artifact: JackArtifact) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = artifact.title + "." + artifact.fileExtension
        if panel.runModal() == .OK, let url = panel.url { perform { try data.write(to: url, options: .atomic) } }
    }
    private func showLinks(_ messages: [ChatMessage], title: String, projectPath: String) {
        candidates = ArtifactLibrary.claudeLinks(in: messages) + ArtifactLibrary.sessionFiles(in: messages, projectPath: projectPath); candidateSource = title
        if candidates.isEmpty { error = "No hay enlaces de artefactos en esta sesión. Puedes importar sus archivos exportados." }
    }
}

private struct ArtifactSessionPicker: View {
    let select: (ClaudeSessionSummary) -> Void
    let cancel: () -> Void
    @State private var sessions: [ClaudeSessionSummary] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar desde Claude Code").font(.headline)
            Text("Busca enlaces y archivos en el historial local de una sesión.").font(.caption)
            List(sessions) { session in Button { select(session) } label: {
                VStack(alignment: .leading) { Text(session.title); Text(session.projectPath).font(.caption).foregroundStyle(.secondary) }
            }.buttonStyle(.plain) }.frame(height: 300)
            Button("Cancelar", action: cancel)
        }.padding(20).frame(width: 500)
        .task { sessions = await Task.detached { ClaudeSessions.list() }.value }
    }
}

/// Separate ephemeral web view: inline scripts can render a tool, but no native bridge or network exists.
struct ArtifactWebPreview: NSViewRepresentable {
    let source: String
    let svg: Bool
    static func configuredView(svg: Bool) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = !svg
        return WKWebView(frame: .zero, configuration: config)
    }
    func makeNSView(context: Context) -> WKWebView {
        let view = Self.configuredView(svg: svg); view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.source != source else { return }
        context.coordinator.source = source
        view.loadHTMLString(Self.document(source), baseURL: nil)
    }
    static func document(_ source: String) -> String {
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
        let prefix = "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head><body>"
        return prefix + source + "</body></html>"
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var source: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

private struct ArtifactPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateNSView(_ view: PDFView, context: Context) { if context.coordinator.data != data { context.coordinator.data = data; view.document = PDFDocument(data: data) } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}
