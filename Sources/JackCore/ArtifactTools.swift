import Foundation

extension ArtifactLibrary {
    nonisolated static let agentInstructions = """
    Jack has a local artifact library in Normal mode. Use artifact_create for self-contained HTML, Markdown, SVG or code that the user should preview and reuse. All agents in the same project share these artifacts.
    Use artifact_list and artifact_read before editing; artifact_update requires the exact expected_version you read and creates an immutable revision. If a conflict occurs, read the newer version and reconcile your changes. Never silently overwrite another agent's work.
    artifact_create accepts UTF-8 content or a path in your authorized local folders. Imported files are snapshots; the original stays unchanged. Claude artifact links remain hosted references; importing one does not migrate its backend, account storage or connectors. Keep HTML self-contained: preview allows local inline JavaScript but blocks network, popups and native app access. React/JSX requires a compiled HTML file.
    """
}

extension AgentBridge {
    static let artifactTools: [[String: Any]] = [
        tool("artifact_create", "Create a local, versioned artifact shared with agents in this project. Opens in Jack's artifact library. Provide exactly one of content, path or url.", [
            "title": ["type": "string"],
            "kind": ["type": "string", "enum": ["html", "markdown", "svg", "code"]],
            "content": ["type": "string", "description": "Self-contained UTF-8 source."],
            "path": ["type": "string", "description": "Existing local file in an authorized folder. Imported as a snapshot."],
            "url": ["type": "string", "description": "Claude artifact HTTPS link. Stored as a hosted reference, not downloaded."],
        ], required: []),
        tool("artifact_list", "List artifact IDs, kinds, titles and current versions in this project only.", [:], required: []),
        tool("artifact_read", "Read metadata and a bounded UTF-8 content chunk of an artifact revision. Binary artifacts return metadata only.", [
            "artifact_id": ["type": "string"], "version": ["type": "integer"],
            "offset": ["type": "integer", "description": "Character offset, default 0."],
            "limit": ["type": "integer", "description": "Character count, default 30000; maximum 100000."],
        ], required: ["artifact_id"]),
        tool("artifact_update", "Save a new revision. Rejects stale expected_version. Supply exactly one of content or authorized local path.", [
            "artifact_id": ["type": "string"], "expected_version": ["type": "integer"],
            "content": ["type": "string"], "path": ["type": "string"],
        ], required: ["artifact_id", "expected_version"]),
    ]

    func artifactCall(_ name: String, arguments: [String: Any], conversation: ChatConversation, library: ArtifactLibrary) -> (String, Bool) {
        do {
            func metadata(_ artifact: JackArtifact) -> [String: Any] {
                ["artifact_id": artifact.id.uuidString.lowercased(), "title": artifact.title,
                 "kind": artifact.kind.rawValue, "version": artifact.version, "origin": artifact.origin,
                 "versions": artifact.revisions.map { ["version": $0.id, "author": $0.author, "bytes": $0.bytes] as [String: Any] }]
            }
            func localData(_ path: String) throws -> Data {
                guard conversation.remote == nil else { throw ArtifactError("Este path es remoto. Envía el contenido UTF-8, no una ruta de la máquina remota.") }
                let canonical = try NotebookWorkspace.authorizedPath(path, conversation: conversation)
                let url = URL(fileURLWithPath: canonical)
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= ArtifactLibrary.maximumBytes else { throw ArtifactError("Selecciona un archivo regular de hasta 8 MB.") }
                return try Data(contentsOf: url)
            }
            var result: [String: Any]
            switch name {
            case "artifact_list":
                result = ["artifacts": try library.list(projectPath: conversation.projectPath).map(metadata)]
            case "artifact_create":
                let inputs = ["content", "path", "url"].filter { arguments[$0] is String }
                guard inputs.count == 1 else { throw ArtifactError("Proporciona exactamente uno de content, path o url.") }
                let artifact: JackArtifact
                if let input = arguments["url"] as? String, let url = URL(string: input) {
                    artifact = try library.importLink(url, title: arguments["title"] as? String ?? "Artefacto de Claude", projectPath: conversation.projectPath, conversationID: conversation.id)
                } else if let path = arguments["path"] as? String {
                    let canonical = try NotebookWorkspace.authorizedPath(path, conversation: conversation)
                    let data = try localData(path)
                    let url = URL(fileURLWithPath: canonical)
                    artifact = try library.create(title: arguments["title"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                                  kind: .infer(url), data: data, projectPath: conversation.projectPath,
                                                  conversationID: conversation.id, origin: canonical, author: conversation.provider.title,
                                                  fileExtension: url.pathExtension.isEmpty ? "txt" : url.pathExtension)
                } else {
                    guard let content = arguments["content"] as? String,
                          let kind = (arguments["kind"] as? String).flatMap(ArtifactKind.init(rawValue:)),
                          [.html, .markdown, .svg, .code].contains(kind), let title = arguments["title"] as? String else {
                        throw ArtifactError("Para contenido nuevo indica title, kind y content.")
                    }
                    artifact = try library.create(title: title, kind: kind, data: Data(content.utf8), projectPath: conversation.projectPath,
                                                  conversationID: conversation.id, author: conversation.provider.title)
                }
                result = metadata(artifact)
            case "artifact_read", "artifact_update":
                guard let input = arguments["artifact_id"] as? String, let id = UUID(uuidString: input) else { throw ArtifactError("artifact_id debe ser el UUID de artifact_list.") }
                let artifact = try library.find(id, projectPath: conversation.projectPath)
                if name == "artifact_update" {
                    guard let expected = arguments["expected_version"] as? Int else { throw ArtifactError("expected_version es obligatorio.") }
                    guard ["content", "path"].filter({ arguments[$0] is String }).count == 1 else { throw ArtifactError("Indica content o path, pero no ambos.") }
                    let data = try (arguments["path"] as? String).map(localData) ?? Data((arguments["content"] as? String ?? "").utf8)
                    result = metadata(try library.update(id, projectPath: conversation.projectPath, expectedVersion: expected, data: data, author: conversation.provider.title))
                } else {
                    let version = arguments["version"] as? Int ?? artifact.version
                    let data = try library.content(id, projectPath: conversation.projectPath, version: version)
                    result = metadata(artifact); result["read_version"] = version
                    if artifact.kind.isText {
                        let text = String(decoding: data, as: UTF8.self)
                        let offset = max(0, min(arguments["offset"] as? Int ?? 0, text.count))
                        let limit = max(1, min(arguments["limit"] as? Int ?? 30_000, 100_000))
                        let chunk = String(text.dropFirst(offset).prefix(limit))
                        result["content"] = chunk; result["offset"] = offset
                        result["next_offset"] = offset + chunk.count; result["total_characters"] = text.count
                    }
                }
            default: throw ArtifactError("Herramienta de artefactos desconocida.")
            }
            return (String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self), false)
        } catch { return (error.localizedDescription, true) }
    }
}
