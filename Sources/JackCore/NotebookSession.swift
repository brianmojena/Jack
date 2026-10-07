import Foundation
import Darwin

/// Starts only on an explicit connection. No shell commands or installs are run implicitly.
@MainActor final class LocalJupyterServer {
    private var child: StructuredChild?
    private var drain: Task<Void, Never>?
    private var runtime: URL?

    func start(python: String, directory: String) async throws -> JupyterEndpoint {
        guard let executable = ExecutableResolver.resolve(python) else {
            throw NotebookError.message("No se encontró Python. Selecciona el ejecutable de tu entorno.")
        }
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("jack-jupyter-" + UUID().uuidString)
        self.runtime = runtime
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let spec = runtime.appendingPathComponent("share/jupyter/kernels/jack-python")
        try FileManager.default.createDirectory(at: spec, withIntermediateDirectories: true)
        let kernel: [String: Any] = ["argv": [executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"],
                                    "display_name": "Python (Jack)", "language": "python"]
        try JSONSerialization.data(withJSONObject: kernel).write(to: spec.appendingPathComponent("kernel.json"))
        let config = runtime.appendingPathComponent("jupyter_config.json")
        let token = UUID().uuidString + UUID().uuidString
        let settings: [String: Any] = [
            "ServerApp": ["ip": "127.0.0.1", "port": 0, "port_retries": 0, "open_browser": false,
                          "root_dir": directory, "runtime_dir": runtime.path,
                          "jpserver_extensions": [:]],
            "IdentityProvider": ["token": token]
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        do {
            let child = try StructuredChild(executable: executable, arguments: ["-m", "jupyter_server", "--config", config.path],
                                            directory: directory, environment: ["JUPYTER_PATH": runtime.appendingPathComponent("share/jupyter").path])
            self.child = child
            drain = Task { do { for try await _ in child.lines {} } catch {} }
            for _ in 0..<300 {
                try Task.checkCancellation()
                let files = (try? FileManager.default.contentsOfDirectory(at: runtime, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("jpserver-") && file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let port = info["port"] as? Int, port > 0 else { continue }
                    return try JupyterEndpoint(address: "http://127.0.0.1:\(port)/", token: token)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NotebookError.message("Jupyter no arrancó. En ese entorno instala jupyter_server e ipykernel: python -m pip install jupyter_server ipykernel.")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let child = child, runtime = runtime
        self.child = nil; self.runtime = nil
        child?.terminate()
        drain?.cancel(); drain = nil
        Task {
            await child?.waitForExit()
            if let runtime { try? FileManager.default.removeItem(at: runtime) }
        }
    }
}

@MainActor public final class NotebookSession: ObservableObject, Identifiable {
    public var id: String { path }
    public let path: String
    @Published public private(set) var document: NotebookDocument
    @Published public private(set) var dirty = false
    @Published public private(set) var conflict = false
    @Published public private(set) var runningCell: String?
    @Published public private(set) var busy = false
    @Published public private(set) var connecting = false
    @Published public private(set) var connected = false
    @Published public private(set) var kernelTitle = "Sin kernel"
    @Published public var error: String?
    @Published public private(set) var inputPrompt: String?
    @Published public private(set) var inputIsPassword = false
    private var diskData: Data
    private var kernel: JupyterKernel?
    private var local: LocalJupyterServer?
    private var watcher: DispatchSourceFileSystemObject?
    private var runTask: Task<Void, Never>?
    private var displayIDs: [String: [(cell: String, output: Int)]] = [:]
    private var deferredClear = Set<String>()
    private var enabled = true
    private var generation = 0

    public init(path: String) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        diskData = try Data(contentsOf: URL(fileURLWithPath: self.path))
        document = try NotebookDocument(data: diskData)
        watch()
    }

    public func updateCell(_ id: String, source: String? = nil, kind: String? = nil) throws {
        try requireEnabled()
        guard let index = document.cells.firstIndex(where: { $0.id == id }) else { throw NotebookError.message("La celda ya no existe.") }
        if let kind {
            guard ["code", "markdown", "raw"].contains(kind) else { throw NotebookError.message("Tipo de celda inválido.") }
            guard !busy else { throw NotebookError.message("Espera a que termine la ejecución antes de cambiar tipos de celda.") }
            if document.cells[index].kind != kind { document.cells[index].kind = kind }
        }
        if let source { document.cells[index].source = source }
        dirty = true
    }

    @discardableResult public func insertCell(after id: String? = nil, kind: String = "code", source: String = "") throws -> String {
        try requireEnabled()
        guard !busy, ["code", "markdown", "raw"].contains(kind) else { throw NotebookError.message("No se puede añadir esa celda ahora.") }
        let index: Int
        if let id {
            guard let found = document.cells.firstIndex(where: { $0.id == id }) else { throw NotebookError.message("La celda ya no existe.") }
            index = found + 1
        } else { index = document.cells.count }
        let cell = NotebookCell(kind: kind, source: source)
        document.cells.insert(cell, at: index); dirty = true
        return cell.id
    }
    public func deleteCell(_ id: String) throws {
        try requireEnabled()
        guard !busy else { throw NotebookError.message("Espera a que termine la ejecución antes de borrar celdas.") }
        document.cells.removeAll { $0.id == id }; dirty = true
    }
    public func moveCell(_ id: String, offset: Int) throws {
        try requireEnabled()
        guard !busy, let index = document.cells.firstIndex(where: { $0.id == id }), document.cells.indices.contains(index + offset) else { return }
        document.cells.swapAt(index, index + offset); dirty = true
    }
    public func clearOutputs() throws {
        try requireEnabled()
        guard !busy else { throw NotebookError.message("Espera a que termine la ejecución para limpiar las salidas.") }
        for index in document.cells.indices where document.cells[index].kind == "code" {
            document.cells[index].outputs = []; document.cells[index].executionCount = nil
        }
        displayIDs.removeAll(); dirty = true
    }
    public func save() throws {
        try requireEnabled()
        let url = URL(fileURLWithPath: path)
        guard try Data(contentsOf: url) == diskData else {
            conflict = true
            throw NotebookError.message("El archivo cambió fuera de Jack. Guarda una copia o recarga antes de sobrescribirlo.")
        }
        let data = try document.data()
        try data.write(to: url, options: .atomic)
        diskData = data; dirty = false; conflict = false
    }
    public func saveCopy(to url: URL) throws {
        try requireEnabled()
        guard url.standardizedFileURL.resolvingSymlinksInPath().path != path else {
            throw NotebookError.message("Elige otra ruta para guardar una copia.")
        }
        try document.data().write(to: url, options: .withoutOverwriting)
    }
    public func reload(discardChanges: Bool = false) throws {
        try requireEnabled()
        guard !busy else { throw NotebookError.message("Espera a que termine la ejecución antes de recargar.") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard discardChanges || !dirty else { conflict = data != diskData; return }
        let next = try NotebookDocument(data: data)
        document = next; diskData = data; dirty = false; conflict = false
        displayIDs.removeAll()
    }
    /// Filesystem events also see atomic saves by CLI agents. Unsaved edits are never discarded.
    private func diskChanged() {
        guard enabled, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data != diskData else { return }
        if dirty || busy { conflict = true }
        else { do { try reload() } catch { self.error = error.localizedDescription } }
    }

    public func connectLocal(python: String = "") async throws {
        try requireEnabled()
        guard !busy, !connecting else { throw NotebookError.message("El notebook está ocupado.") }
        connecting = true
        defer { connecting = false }
        await disconnect()
        let generation = self.generation
        let server = LocalJupyterServer(); local = server
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let executable = python.isEmpty ? Self.defaultPython(directory: directory) : python
            let endpoint = try await server.start(python: executable, directory: directory)
            guard enabled, self.generation == generation else { throw CancellationError() }
            try await connect(endpoint, name: "jack-python", directory: "", title: "Python local")
        } catch { server.stop(); local = nil; throw error }
    }
    public func remoteSpecifications(_ endpoint: JupyterEndpoint) async throws -> [JupyterKernelSpec] {
        try requireEnabled()
        let client = JupyterKernel(endpoint: endpoint)
        defer { client.closeChannel() }
        return try await client.specifications()
    }
    public func connectRemote(_ endpoint: JupyterEndpoint, name: String = "python3", directory: String = "") async throws {
        try requireEnabled()
        guard !busy, !connecting else { throw NotebookError.message("El notebook está ocupado.") }
        connecting = true
        defer { connecting = false }
        await disconnect()
        try await connect(endpoint, name: name, directory: directory, title: "\(endpoint.displayName) · \(name)")
    }
    private func connect(_ endpoint: JupyterEndpoint, name: String, directory: String, title: String) async throws {
        let generation = self.generation
        let client = JupyterKernel(endpoint: endpoint)
        kernel = client
        client.onDisconnected = { [weak self] message in self?.connected = false; self?.error = message }
        client.onInput = { [weak self] prompt, password in self?.inputPrompt = prompt; self?.inputIsPassword = password }
        do {
            try await client.connect(name: name, directory: directory)
            guard enabled, self.generation == generation else { await client.disconnect(); throw CancellationError() }
            connected = true; kernelTitle = title; error = nil
        } catch { await client.disconnect(); kernel = nil; throw error }
    }
    public func disconnect() async {
        generation += 1
        let client = kernel; kernel = nil
        connected = false; kernelTitle = "Sin kernel"; inputPrompt = nil
        await client?.disconnect()
        local?.stop(); local = nil
    }
    public func interrupt() async throws { try requireEnabled(); try await kernel?.interrupt() }
    public func restart() async throws {
        try requireEnabled()
        guard !busy else { throw NotebookError.message("Interrumpe la ejecución antes de reiniciar el kernel.") }
        try await kernel?.restart()
        inputPrompt = nil; displayIDs.removeAll()
    }
    public func sendInput(_ value: String) async throws {
        try requireEnabled()
        try await kernel?.input(value); inputPrompt = nil
    }

    /// A single owner serializes both user and MCP executions; Run All stops on the first error.
    public func execute(cellIDs: [String]) async throws {
        try requireEnabled()
        guard !busy, !connecting else { throw NotebookError.message("Ya hay una ejecución en curso. Espera o interrumpe el kernel.") }
        guard let kernel, connected else { throw NotebookError.message("Selecciona y conecta un kernel primero.") }
        guard !cellIDs.isEmpty else { return }
        try save()
        busy = true; error = nil
        defer {
            busy = false; runningCell = nil; inputPrompt = nil
            if enabled { do { try save() } catch { self.error = error.localizedDescription } }
        }
        for id in cellIDs {
            try requireEnabled()
            guard let index = document.cells.firstIndex(where: { $0.id == id }) else { throw NotebookError.message("La celda ya no existe.") }
            guard document.cells[index].kind == "code" else { continue }
            let source = document.cells[index].source
            runningCell = id
            document.cells[index].outputs = []; document.cells[index].executionCount = nil
            displayIDs = displayIDs.mapValues { $0.filter { $0.cell != id } }
            deferredClear.remove(id); dirty = true
            do {
                let count = try await kernel.execute(source) { [weak self] type, content in self?.output(type, content: content, cellID: id) }
                if let index = document.cells.firstIndex(where: { $0.id == id }), let count { document.cells[index].executionCount = count }
            } catch { self.error = error.localizedDescription; throw error }
        }
    }
    public func run(_ id: String? = nil) {
        let ids = id.map { [$0] } ?? document.cells.filter { $0.kind == "code" }.map(\.id)
        runTask = Task { [weak self] in
            do { try await self?.execute(cellIDs: ids) }
            catch { self?.error = error.localizedDescription }
        }
    }

    func output(_ type: String, content: [String: Any], cellID: String) {
        guard let index = document.cells.firstIndex(where: { $0.id == cellID }) else { return }
        if type == "execute_input" {
            document.cells[index].executionCount = content["execution_count"] as? Int; return
        }
        if type == "clear_output" {
            if content["wait"] as? Bool == true { deferredClear.insert(cellID) }
            else { document.cells[index].outputs = []; removeDisplays(cellID) }
            dirty = true; return
        }
        guard ["stream", "display_data", "execute_result", "error", "update_display_data"].contains(type) else { return }
        if deferredClear.remove(cellID) != nil { document.cells[index].outputs = []; removeDisplays(cellID) }
        var fields: [String: Any] = ["output_type": type == "update_display_data" ? "display_data" : type]
        switch type {
        case "stream": fields["name"] = content["name"] ?? "stdout"; fields["text"] = content["text"] ?? ""
        case "error": for key in ["ename", "evalue", "traceback"] { fields[key] = content[key] ?? (key == "traceback" ? [] : "") }
        default:
            fields["data"] = content["data"] ?? [:]; fields["metadata"] = content["metadata"] ?? [:]
            if type == "execute_result" { fields["execution_count"] = content["execution_count"] ?? NSNull() }
        }
        guard let value = try? NotebookJSON.from(fields) else { return }
        let displayID = (content["transient"] as? [String: Any])?["display_id"] as? String
        if type == "update_display_data" {
            if let displayID {
                for target in displayIDs[displayID] ?? [] {
                    if let cell = document.cells.firstIndex(where: { $0.id == target.cell }),
                       document.cells[cell].outputs.indices.contains(target.output) {
                        var existing = document.cells[cell].outputs[target.output].object ?? [:]
                        existing["data"] = value.object?["data"]; existing["metadata"] = value.object?["metadata"]
                        document.cells[cell].outputs[target.output] = .object(existing)
                    }
                }
            }
        } else if type == "stream", let last = document.cells[index].outputs.last?.object,
                  last["output_type"]?.text == "stream", last["name"]?.text == content["name"] as? String {
            var merged = last
            merged["text"] = .string((last["text"]?.text ?? "") + (content["text"] as? String ?? ""))
            document.cells[index].outputs[document.cells[index].outputs.count - 1] = .object(merged)
        } else {
            if let displayID { displayIDs[displayID, default: []].append((cellID, document.cells[index].outputs.count)) }
            document.cells[index].outputs.append(value)
        }
        dirty = true
    }
    private func removeDisplays(_ id: String) { displayIDs = displayIDs.mapValues { $0.filter { $0.cell != id } } }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { watch(); diskChanged() }
        else { stop() }
    }
    public func stop() {
        generation += 1
        watcher?.cancel(); watcher = nil
        runTask?.cancel(); runTask = nil
        let client = kernel; kernel = nil
        client?.closeChannel()
        connected = false; kernelTitle = "Sin kernel"; inputPrompt = nil
        Task { await client?.disconnect() }
        local?.stop(); local = nil
    }
    private func watch() {
        guard watcher == nil, enabled else { return }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = Darwin.open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.diskChanged() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        watcher = source; source.resume()
    }
    private func requireEnabled() throws {
        guard enabled else { throw NotebookError.message("Los notebooks están disponibles en el modo Normal.") }
    }
    public static func defaultPython(directory: String) -> String {
        for name in [".venv/bin/python", "venv/bin/python"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ExecutableResolver.resolve("python3") ?? "python3"
    }
}

/// Lazy, shared by panels and MCP tools. Switching to Light removes all notebook background work.
@MainActor public final class NotebookWorkspace: ObservableObject {
    @Published public private(set) var sessions: [String: NotebookSession] = [:]
    public private(set) var enabled: Bool
    public var reveal: ((UUID, String) -> Void)?
    public init(enabled: Bool = true) { self.enabled = enabled }

    public func open(path: String, create: Bool = false) throws -> NotebookSession {
        guard enabled else { throw NotebookError.message("Los notebooks están disponibles en el modo Normal.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "ipynb" else { throw NotebookError.message("Selecciona un archivo .ipynb.") }
        if let session = sessions[url.path] { return session }
        if create {
            try NotebookDocument().data().write(to: url, options: .withoutOverwriting)
        }
        let session = try NotebookSession(path: url.path)
        sessions[url.path] = session
        return session
    }
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        for session in sessions.values { session.setEnabled(enabled) }
    }
    public func stop() { for session in sessions.values { session.stop() } }

    /// Canonical paths enforce the calling chat's project / explicitly authorized folders, including symlinks.
    public static func authorizedPath(_ path: String, conversation: ChatConversation) throws -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: conversation.projectPath).appendingPathComponent(path)
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [conversation.projectPath] + conversation.additionalDirectories + conversation.attachmentDirectories
        guard roots.contains(where: {
            let root = URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
            return canonical == root || canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else { throw NotebookError.message("El notebook está fuera de las carpetas autorizadas de este chat.") }
        return canonical
    }
}
