import AppKit
import JackCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Notebook entry point, kept exclusively in the Normal workspace.
struct NotebookTabPanel: View {
    @ObservedObject var notebooks: NotebookWorkspace
    let path: String?
    let projectPath: String
    let onOpen: (String) -> Void
    let onAskAgent: (String, [String]) -> Void
    @State private var error: String?

    var body: some View {
        Group {
            if let path, let session = notebooks.sessions[path] {
                NotebookPanel(session: session, onAskAgent: onAskAgent)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "book.closed").font(.system(size: 30)).foregroundStyle(JackPalette.muted)
                    Text("Jupyter notebooks").font(.headline)
                    Text("Edita celdas y ejecútalas en un kernel local o remoto.\nEl agente trabaja sobre el mismo notebook.")
                        .font(.system(size: 12)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center)
                    HStack {
                        Button("Abrir .ipynb…") { choose(create: false) }
                        Button("Nuevo notebook…") { choose(create: true) }
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func choose(create: Bool) {
        let panel: NSSavePanel = create ? NSSavePanel() : NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: projectPath)
        panel.allowedContentTypes = [UTType(filenameExtension: "ipynb") ?? .json]
        panel.nameFieldStringValue = "Untitled.ipynb"
        if let open = panel as? NSOpenPanel { open.canChooseDirectories = false; open.allowsMultipleSelection = false }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let session = try notebooks.open(path: url.path, create: create)
            onOpen(session.path)
        } catch { self.error = error.localizedDescription }
    }
}

struct NotebookPanel: View {
    @ObservedObject var session: NotebookSession
    let onAskAgent: (String, [String]) -> Void
    @State private var showConnection = false
    @State private var showReload = false
    @State private var previewMarkdown = Set<String>()
    @State private var input = ""
    @FocusState private var focusedCell: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.conflict { conflictBar }
            if let error = session.error {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 11)).textSelection(.enabled)
                    Spacer()
                    Button { session.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.foregroundStyle(.red).padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(session.document.cells.enumerated()), id: \.element.id) { index, cell in
                            cellView(cell, index: index).id(cell.id)
                        }
                        HStack {
                            Button("+ Código") { perform { focusedCell = try session.insertCell() } }
                            Button("+ Markdown") { perform { focusedCell = try session.insertCell(kind: "markdown") } }
                        }.controlSize(.small).disabled(session.busy)
                    }.padding(12)
                }
                .onChange(of: session.runningCell) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
            }
            if let prompt = session.inputPrompt { inputBar(prompt) }
            HStack {
                Text(session.busy ? "Ejecutando…" : "\(session.document.cells.count) celdas")
                Spacer()
                Text(session.dirty ? "Cambios pendientes" : "Guardado")
            }.font(.system(size: 10)).foregroundStyle(JackPalette.muted).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .sheet(isPresented: $showConnection) { NotebookConnectionSheet(session: session) }
        .confirmationDialog("Recargar descartará los cambios pendientes de Jack.", isPresented: $showReload) {
            Button("Recargar desde disco", role: .destructive) { perform { try session.reload(discardChanges: true) } }
        }
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.shift) || press.modifiers.contains(.command),
                  let id = focusedCell, !session.busy, session.connected else { return .ignored }
            session.run(id)
            return .handled
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { showConnection = true } label: {
                HStack(spacing: 4) {
                    if session.connecting { ProgressView().controlSize(.mini) }
                    Circle().fill(session.connected ? Color.green : JackPalette.faint).frame(width: 5, height: 5)
                    Text(session.kernelTitle).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }.disabled(session.busy || session.connecting)
            Spacer(minLength: 0)
            Button { session.run() } label: { Image(systemName: "play.fill") }
                .help("Ejecutar todas las celdas").disabled(!session.connected || session.busy || session.connecting || session.conflict)
            Button { performAsync { try await session.interrupt() } } label: { Image(systemName: "stop.fill") }
                .help("Interrumpir kernel").disabled(!session.busy)
            Button { perform { try session.save() } } label: { Image(systemName: "square.and.arrow.down") }
                .help("Guardar notebook").disabled(session.conflict)
            Menu {
                Button("Reiniciar kernel") { performAsync { try await session.restart() } }.disabled(!session.connected || session.busy)
                Button("Desconectar kernel") { performAsync { await session.disconnect() } }.disabled(!session.connected)
                Button("Limpiar salidas") { perform { try session.clearOutputs() } }.disabled(session.busy)
                Button("Recargar desde disco…") { showReload = true }.disabled(session.busy)
                Button("Guardar copia…", action: saveCopy)
                Divider()
                Button("Pedir al agente que trabaje en este notebook") {
                    perform {
                        try session.save()
                        onAskAgent("Trabaja en el notebook \(session.path). Usa las herramientas notebook de Jack para editar sus celdas y ejecutar con el kernel compartido. Revisa primero las celdas y los resultados actuales.", [session.path])
                    }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.system(size: 11)).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).frame(height: 38)
        .background(JackPalette.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
    private var conflictBar: some View {
        HStack {
            Text("El archivo cambió fuera de Jack. Tus cambios siguen aquí.").font(.system(size: 11))
            Spacer()
            Button("Guardar copia…", action: saveCopy)
            Button("Recargar…") { showReload = true }.disabled(session.busy)
        }.controlSize(.small).padding(10).background(.orange.opacity(0.12))
    }
    private func cellView(_ cell: NotebookCell, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("[\(cell.executionCount.map(String.init) ?? " ")]").font(.system(size: 11, design: .monospaced)).foregroundStyle(JackPalette.muted)
                Picker("Tipo", selection: Binding(get: {
                    session.document.cells.first { $0.id == cell.id }?.kind ?? cell.kind
                }, set: { kind in perform { try session.updateCell(cell.id, kind: kind) } })) {
                    Text("Código").tag("code"); Text("Markdown").tag("markdown"); Text("Texto").tag("raw")
                }.labelsHidden().fixedSize().disabled(session.busy)
                Text("Celda \(index + 1)").font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                Spacer()
                if cell.kind == "markdown" {
                    Button(previewMarkdown.contains(cell.id) ? "Editar" : "Vista previa") {
                        if !previewMarkdown.insert(cell.id).inserted { previewMarkdown.remove(cell.id) }
                    }
                }
                if cell.kind == "code" {
                    if session.runningCell == cell.id { ProgressView().controlSize(.mini) }
                    Button { session.run(cell.id) } label: { Image(systemName: "play.fill") }
                        .disabled(!session.connected || session.busy || session.connecting || session.conflict).help("Ejecutar celda (⇧↩)")
                }
                Menu {
                    Button("Añadir código debajo") { perform { focusedCell = try session.insertCell(after: cell.id) } }
                    Button("Añadir Markdown debajo") { perform { focusedCell = try session.insertCell(after: cell.id, kind: "markdown") } }
                    Button("Subir") { perform { try session.moveCell(cell.id, offset: -1) } }.disabled(index == 0)
                    Button("Bajar") { perform { try session.moveCell(cell.id, offset: 1) } }.disabled(index == session.document.cells.count - 1)
                    Button("Eliminar celda", role: .destructive) { perform { try session.deleteCell(cell.id) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(session.busy)
            }.controlSize(.small).buttonStyle(.borderless)
            if cell.kind == "markdown", previewMarkdown.contains(cell.id) {
                MarkdownText(text: cell.source).padding(6)
            } else {
                TextEditor(text: Binding(get: {
                    session.document.cells.first { $0.id == cell.id }?.source ?? cell.source
                }, set: { source in perform { try session.updateCell(cell.id, source: source) } }))
                    .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                    .frame(height: min(500, max(70, CGFloat(cell.source.components(separatedBy: "\n").count) * 17 + 20)))
                    .focused($focusedCell, equals: cell.id)
            }
            ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in NotebookOutputView(output: output) }
        }
        .padding(10).background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(session.runningCell == cell.id ? JackPalette.accent : JackPalette.hairline, lineWidth: 1) }
    }
    private func inputBar(_ prompt: String) -> some View {
        HStack {
            Text(prompt).font(.system(size: 11)).lineLimit(2)
            if session.inputIsPassword { SecureField("Respuesta", text: $input).onSubmit(submitInput) }
            else { TextField("Respuesta", text: $input).onSubmit(submitInput) }
            Button("Enviar", action: submitInput)
        }.controlSize(.small).padding(10).background(JackPalette.chrome)
    }
    private func submitInput() {
        let value = input; input = ""
        performAsync { try await session.sendInput(value) }
    }
    private func saveCopy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipynb") ?? .json]
        panel.directoryURL = URL(fileURLWithPath: session.path).deletingLastPathComponent()
        panel.nameFieldStringValue = URL(fileURLWithPath: session.path).deletingPathExtension().lastPathComponent + "-copy.ipynb"
        if panel.runModal() == .OK, let url = panel.url { perform { try session.saveCopy(to: url) } }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { session.error = error.localizedDescription }
    }
    private func performAsync(_ operation: @escaping () async throws -> Void) {
        Task { do { try await operation() } catch { session.error = error.localizedDescription } }
    }
}

struct NotebookOutputView: View {
    let output: NotebookJSON
    var body: some View {
        let fields = output.object ?? [:]
        let data = fields["data"]?.object ?? [:]
        Group {
            if fields["output_type"]?.text == "stream" {
                plain(fields["text"]?.text ?? "")
            } else if fields["output_type"]?.text == "error" {
                plain((fields["traceback"]?.array?.compactMap(\.text).joined(separator: "\n")) ?? "\(fields["ename"]?.text ?? "Error"): \(fields["evalue"]?.text ?? "")")
                    .foregroundStyle(.red)
            } else if let encoded = data["image/png"]?.text ?? data["image/jpeg"]?.text,
                      let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), let image = NSImage(data: bytes) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 500)
            } else if let html = data["text/html"]?.text {
                NotebookHTMLOutput(html: html).frame(height: 240)
            } else if let svg = data["image/svg+xml"]?.text {
                NotebookHTMLOutput(html: svg).frame(height: 300)
            } else if let markdown = data["text/markdown"]?.text {
                MarkdownText(text: markdown)
            } else {
                plain(data["text/plain"]?.text ?? "Salida MIME: \(data.keys.sorted().joined(separator: ", "))")
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(JackPalette.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
    }
    private func plain(_ text: String) -> some View {
        // Jupyter tracebacks commonly contain ANSI color sequences.
        Text(text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression))
            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
    }
}

/// MIME HTML is displayed without scripts, external resources or navigation.
struct NotebookHTMLOutput: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; form-action 'none'; base-uri 'none'"
        view.loadHTMLString("""
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="color-scheme" content="light dark"><style>body{font:12px -apple-system; margin:8px}table{border-collapse:collapse}th,td{padding:5px;border:1px solid #8885}img,svg{max-width:100%}</style></head>
        <body>\(html)</body></html>
        """, baseURL: nil)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

private struct NotebookConnectionSheet: View {
    @ObservedObject var session: NotebookSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "local"
    @State private var python = ""
    @State private var address = ""
    @State private var token = ""
    @State private var kernel = "python3"
    @State private var directory = ""
    @State private var specs: [JupyterKernelSpec] = []
    @State private var working = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conectar kernel").font(.headline)
            Picker("Ejecutar en", selection: $mode) {
                Text("Python local").tag("local"); Text("Jupyter remoto").tag("remote"); Text("Colab existente").tag("colab")
            }.pickerStyle(.segmented)
            if mode == "local" {
                TextField("Ejecutable de Python", text: $python)
                Text("Requiere jupyter_server e ipykernel en ese entorno. Puedes usar el Python de tu .venv.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                Text("Instalar en ese entorno: python -m pip install jupyter_server ipykernel")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            } else {
                TextField(mode == "colab" ? "URL del proxy del runtime" : "URL del servidor Jupyter", text: $address)
                SecureField(mode == "colab" ? "Token del proxy de Colab" : "Token (también puede venir en la URL)", text: $token)
                HStack {
                    if specs.isEmpty { TextField("Kernel", text: $kernel) }
                    else { Picker("Kernel", selection: $kernel) { ForEach(specs) { Text($0.title).tag($0.id) } } }
                    Button("Buscar kernels") { loadSpecs() }
                }
                TextField("Carpeta remota (opcional, relativa a la raíz del servidor)", text: $directory)
                Text("El código se ejecuta con los archivos del servidor remoto. Los archivos locales no se suben automáticamente.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                if mode == "colab" {
                    Text("Usa la URL y el token de conexión de un runtime ya asignado; el enlace colab.research.google.com de un notebook no sirve. El token caduca y se conserva solo en memoria.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    Text("Crear runtimes e iniciar sesión directamente requiere que Google autorice el proyecto de Jack. La autorización de Drive y los widgets interactivos aún no están disponibles.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Conectar") { connect() }.keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .textFieldStyle(.roundedBorder).padding(22).frame(width: 500)
        .disabled(working)
        .onAppear { python = NotebookSession.defaultPython(directory: URL(fileURLWithPath: session.path).deletingLastPathComponent().path) }
        .onChange(of: mode) { _, _ in specs = []; token = ""; address = ""; error = nil }
    }
    private func endpoint() throws -> JupyterEndpoint {
        try JupyterEndpoint(address: address, token: token, authentication: mode == "colab" ? .colab : .jupyter)
    }
    private func loadSpecs() {
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                specs = try await session.remoteSpecifications(endpoint())
                if !specs.contains(where: { $0.id == kernel }), let first = specs.first { kernel = first.id }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func connect() {
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                if mode == "local" { try await session.connectLocal(python: python) }
                else { try await session.connectRemote(endpoint(), name: kernel, directory: directory) }
                token = ""; dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
