import Foundation

extension NotebookWorkspace {
    public static let agentInstructions = """
    Jack supports shared Jupyter notebooks in Normal mode through the jack MCP tools.
    - Use notebook_open to open/create a .ipynb, read its current cells, ids, outputs and kernel state.
      The user sees the same document and kernel. Use notebook_edit_cell for edits instead of rewriting
      the file on disk, so unsaved user changes and metadata are preserved.
    - Use notebook_run to execute a cell, or all code cells in order; outputs appear live in the user's
      panel and are saved to the .ipynb. Read notebook_open afterwards to inspect rich output bundles.
      If a kernel requests input, the user answers it in the panel.
    - notebook_kernel can connect a local Python environment, interrupt/restart/disconnect or connect
      an existing remote Jupyter server. Prefer the kernel the user has already selected.
      Remote execution uses files on the remote machine; it does not upload local project files.
    - The Colab option connects an existing runtime's proxy URL and short-lived token. It does not
      allocate Colab compute or sign in to Google. Never put server tokens in notebook cells or replies.
    - A conflict means the file changed on disk while Jack held edits. Do not overwrite it; let the
      user save a copy or reload in the panel.
    """
}

extension AgentBridge {
    static let notebookTools: [[String: Any]] = [
        tool("notebook_open", "Open or create a Jupyter .ipynb in the shared editor; return cell ids, sources, outputs and kernel state. Existing unsaved edits are preserved.", [
            "path": ["type": "string"], "create": ["type": "boolean", "description": "Create a new file if it does not exist. Never overwrites an existing file."]
        ], required: ["path"]),
        tool("notebook_edit_cell", "Update, insert, delete or move a cell in the user's shared notebook and save it. All cell references are stable ids from notebook_open. Fails on external file conflicts.", [
            "path": ["type": "string"], "action": ["type": "string", "enum": ["update", "insert", "delete", "move"]],
            "cell_id": ["type": "string", "description": "Cell to update/delete/move, or predecessor for insert. Omit to append."],
            "source": ["type": "string"], "kind": ["type": "string", "enum": ["code", "markdown", "raw"]],
            "offset": ["type": "integer", "enum": [-1, 1]]
        ], required: ["path", "action"]),
        tool("notebook_run", "Execute one cell or all code cells in order in the SAME kernel as the user. Streams outputs to the panel, saves the file and stops on errors. A running notebook rejects concurrent runs.", [
            "path": ["type": "string"], "cell_id": ["type": "string", "description": "Omit to run all code cells."]
        ], required: ["path"]),
        tool("notebook_kernel", "Manage the shared notebook kernel. Remote connects to an existing Jupyter server or Colab runtime proxy; it does not allocate Colab runtimes. Tokens are held only in memory.", [
            "path": ["type": "string"],
            "action": ["type": "string", "enum": ["status", "connect_local", "connect_remote", "interrupt", "restart", "disconnect"]],
            "python": ["type": "string", "description": "Python executable, preferably the project's venv; needs jupyter_server and ipykernel."],
            "url": ["type": "string", "description": "Jupyter base URL or Colab runtime proxy URL, never a Colab notebook page."],
            "token": ["type": "string"], "colab": ["type": "boolean"],
            "kernel": ["type": "string", "description": "Remote kernelspec name, default python3."],
            "directory": ["type": "string", "description": "Working directory on remote server, relative to its root."]
        ], required: ["path", "action"])
    ]

    func notebookCall(_ name: String, arguments: [String: Any], conversation: ChatConversation, workspace: NotebookWorkspace) async -> (String, Bool) {
        do {
            guard let input = arguments["path"] as? String, !input.isEmpty else { throw NotebookError.message("path is required.") }
            let path = try NotebookWorkspace.authorizedPath(input, conversation: conversation)
            let session = try workspace.open(path: path, create: name == "notebook_open" && arguments["create"] as? Bool == true && !FileManager.default.fileExists(atPath: path))
            workspace.reveal?(conversation.id, path)
            switch name {
            case "notebook_open":
                let data = try session.document.data()
                let notebook = try JSONSerialization.jsonObject(with: data)
                let result: [String: Any] = ["path": path, "dirty": session.dirty, "conflict": session.conflict,
                                           "busy": session.busy, "kernel": session.kernelTitle,
                                           "connected": session.connected, "notebook": notebook]
                let text = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
                return (bounded(text), false)
            case "notebook_edit_cell":
                try session.save()
                let id = arguments["cell_id"] as? String
                switch arguments["action"] as? String {
                case "update":
                    guard let id else { throw NotebookError.message("cell_id is required.") }
                    try session.updateCell(id, source: arguments["source"] as? String, kind: arguments["kind"] as? String)
                case "insert":
                    let id = try session.insertCell(after: id, kind: arguments["kind"] as? String ?? "code", source: arguments["source"] as? String ?? "")
                    try session.save()
                    return ("Inserted cell \(id).", false)
                case "delete":
                    guard let id else { throw NotebookError.message("cell_id is required.") }
                    try session.deleteCell(id)
                case "move":
                    guard let id, let offset = arguments["offset"] as? Int, [-1, 1].contains(offset) else { throw NotebookError.message("cell_id and offset (-1 or 1) are required.") }
                    try session.moveCell(id, offset: offset)
                default: throw NotebookError.message("Unknown cell action.")
                }
                try session.save()
                return ("Notebook saved. Read notebook_open to inspect the shared cells.", false)
            case "notebook_run":
                let ids = (arguments["cell_id"] as? String).map { [$0] } ?? session.document.cells.filter { $0.kind == "code" }.map(\.id)
                try await session.execute(cellIDs: ids)
                let result = session.document.cells.filter { ids.contains($0.id) }.map { cell in
                    ["id": cell.id, "execution_count": cell.executionCount.map { $0 as Any } ?? NSNull(),
                     "outputs": cell.outputs.map { output -> Any in
                         (try? JSONEncoder().encode(output)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
                     }] as [String: Any]
                }
                let text = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
                return (bounded(text), session.conflict)
            case "notebook_kernel":
                switch arguments["action"] as? String {
                case "status": break
                case "connect_local": try await session.connectLocal(python: arguments["python"] as? String ?? "")
                case "connect_remote":
                    let endpoint = try JupyterEndpoint(address: arguments["url"] as? String ?? "", token: arguments["token"] as? String ?? "",
                                                       authentication: arguments["colab"] as? Bool == true ? .colab : .jupyter)
                    try await session.connectRemote(endpoint, name: arguments["kernel"] as? String ?? "python3", directory: arguments["directory"] as? String ?? "")
                case "interrupt": try await session.interrupt()
                case "restart": try await session.restart()
                case "disconnect": await session.disconnect()
                default: throw NotebookError.message("Unknown kernel action.")
                }
                return ("Kernel: \(session.kernelTitle). Connected: \(session.connected). Busy: \(session.busy).", false)
            default: throw NotebookError.message("Unknown notebook tool.")
            }
        } catch { return (error.localizedDescription, true) }
    }
    private func bounded(_ text: String) -> String {
        text.count > 128_000 ? String(text.prefix(128_000)) + "\n[Output truncated; full content is available in the shared editor and .ipynb.]" : text
    }
}
