import Foundation
import Combine

public enum ArtifactKind: String, Codable, CaseIterable {
    case html, markdown, svg, code, image, pdf, link
    public var fileExtension: String {
        switch self { case .html: "html"; case .markdown: "md"; case .svg: "svg"; case .code: "txt"; case .image: "png"; case .pdf: "pdf"; case .link: "url" }
    }
    public var isText: Bool { ![.image, .pdf].contains(self) }
    public static func infer(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "html", "htm": .html
        case "md", "markdown": .markdown
        case "svg": .svg
        case "png", "jpg", "jpeg", "gif", "webp", "heic": .image
        case "pdf": .pdf
        default: .code
        }
    }
}

public struct ArtifactRevision: Codable, Identifiable, Equatable {
    public var id: Int
    public var date: Date
    public var author: String
    public var bytes: Int
}

public struct JackArtifact: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var kind: ArtifactKind
    public var projectPath: String
    public var conversationID: UUID?
    public var origin: String
    public var fileExtension: String
    public var revisions: [ArtifactRevision]
    public var version: Int { revisions.last?.id ?? 0 }
}

public struct ArtifactRevealRequest: Equatable {
    public var id = UUID()
    public var conversationID: UUID
}

public struct ArtifactDraft {
    public var version: Int
    public var text: String
    public init(version: Int, text: String) { self.version = version; self.text = text }
}

public struct ArtifactError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// Immutable content snapshots with an atomic metadata commit. Instantiated on demand in Normal only.
@MainActor public final class ArtifactLibrary: ObservableObject {
    public static let maximumBytes = 8 * 1024 * 1024
    @Published public private(set) var items: [JackArtifact] = []
    @Published public var selectedID: UUID?
    /// Unsaved editor state survives changing chats and closing the preview pane within this app session.
    public var drafts: [UUID: ArtifactDraft] = [:]
    @Published public private(set) var loadError: String?
    private let directory: URL
    private let enabled: () -> Bool

    public init(directory: URL, enabled: @escaping () -> Bool = { true }) {
        self.directory = directory; self.enabled = enabled
        guard enabled() else { return }
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
                do {
                    let artifact = try JSONDecoder().decode(JackArtifact.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                    guard artifact.id.uuidString.lowercased() == folder.lastPathComponent.lowercased(),
                          !artifact.revisions.isEmpty, artifact.revisions.enumerated().allSatisfy({ $0.element.id == $0.offset + 1 }) else {
                        throw ArtifactError("El índice de un artefacto no es válido.")
                    }
                    items.append(artifact)
                } catch {
                    loadError = "No se pudo cargar un artefacto; los demás siguen disponibles. " + error.localizedDescription
                }
            }
            items.sort { ($0.revisions.last?.date ?? .distantPast) > ($1.revisions.last?.date ?? .distantPast) }
        } catch { loadError = error.localizedDescription }
    }

    public func list(projectPath: String) throws -> [JackArtifact] {
        try requireEnabled()
        return items.filter { $0.projectPath == projectPath }
    }

    public func find(_ id: UUID, projectPath: String) throws -> JackArtifact {
        try requireEnabled()
        guard let artifact = items.first(where: { $0.id == id && $0.projectPath == projectPath }) else {
            throw ArtifactError("El artefacto no existe en este proyecto.")
        }
        return artifact
    }

    @discardableResult public func create(title: String, kind: ArtifactKind, data: Data, projectPath: String,
                                         conversationID: UUID? = nil, origin: String = "Jack", author: String = "Usuario",
                                         fileExtension: String? = nil) throws -> JackArtifact {
        try requireEnabled(); try validate(data, kind: kind)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw ArtifactError("El título debe tener entre 1 y 200 caracteres.") }
        let suffix = fileExtension ?? kind.fileExtension
        guard !suffix.isEmpty, suffix.count <= 16, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ArtifactError("La extensión del archivo no es válida.")
        }
        let artifact = JackArtifact(id: UUID(), title: title, kind: kind, projectPath: projectPath,
                                    conversationID: conversationID, origin: origin, fileExtension: suffix,
                                    revisions: [.init(id: 1, date: Date(), author: author, bytes: data.count)])
        try commit(artifact, data: data)
        items.insert(artifact, at: 0); selectedID = artifact.id
        return artifact
    }

    @discardableResult public func update(_ id: UUID, projectPath: String, expectedVersion: Int, data: Data,
                                         author: String = "Usuario") throws -> JackArtifact {
        var artifact = try find(id, projectPath: projectPath)
        guard artifact.version == expectedVersion else { throw ArtifactError("Conflicto: existe la versión \(artifact.version). Lee esa versión antes de guardar.") }
        try validate(data, kind: artifact.kind)
        artifact.revisions.append(.init(id: artifact.version + 1, date: Date(), author: author, bytes: data.count))
        try commit(artifact, data: data)
        items.removeAll { $0.id == id }; items.insert(artifact, at: 0)
        selectedID = id
        return artifact
    }

    public func content(_ id: UUID, projectPath: String, version: Int? = nil) throws -> Data {
        let artifact = try find(id, projectPath: projectPath)
        let revision = version ?? artifact.version
        guard artifact.revisions.contains(where: { $0.id == revision }) else { throw ArtifactError("La versión no existe.") }
        return try Data(contentsOf: contentURL(id, version: revision))
    }

    @discardableResult public func importFile(_ url: URL, projectPath: String, conversationID: UUID? = nil) throws -> JackArtifact {
        try requireEnabled()
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= Self.maximumBytes else { throw ArtifactError("Selecciona un archivo de hasta 8 MB.") }
        return try create(title: url.deletingPathExtension().lastPathComponent, kind: .infer(url), data: Data(contentsOf: url),
                          projectPath: projectPath, conversationID: conversationID, origin: url.path,
                          fileExtension: url.pathExtension.isEmpty ? "txt" : url.pathExtension.lowercased())
    }

    @discardableResult public func importLink(_ url: URL, title: String, projectPath: String, conversationID: UUID? = nil) throws -> JackArtifact {
        guard Self.isClaudeArtifactURL(url) else { throw ArtifactError("Usa un enlace HTTPS de artefacto de claude.ai.") }
        if let existing = try list(projectPath: projectPath).first(where: { $0.kind == .link && $0.origin == url.absoluteString }) {
            selectedID = existing.id; return existing
        }
        return try create(title: title, kind: .link, data: Data(url.absoluteString.utf8), projectPath: projectPath,
                          conversationID: conversationID, origin: url.absoluteString)
    }

    public static func isClaudeArtifactURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "claude.ai" && url.user == nil && url.password == nil
            && (url.path.hasPrefix("/public/artifacts/") || url.path.hasPrefix("/code/artifact/") || url.path.hasPrefix("/artifacts/"))
    }

    public static func claudeLinks(in messages: [ChatMessage]) -> [URL] {
        guard let expression = try? NSRegularExpression(pattern: "https://claude\\.ai/(?:public/artifacts|code/artifact|artifacts)/[A-Za-z0-9_-]+") else { return [] }
        var seen = Set<String>()
        return messages.flatMap { message -> [URL] in
            let text = message.text + "\n" + message.detail
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let range = Range(match.range, in: text), seen.insert(String(text[range])).inserted else { return nil }
                return URL(string: String(text[range]))
            }
        }
    }

    /// Candidate files only: the UI asks the user to choose before reading or importing any path.
    public static func sessionFiles(in messages: [ChatMessage], projectPath: String) -> [URL] {
        let supported: Set<String> = ["html", "htm", "md", "markdown", "svg", "png", "jpg", "jpeg", "gif", "webp", "pdf"]
        let pattern = "\"(?:file_path|path)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"
        let expression = try? NSRegularExpression(pattern: pattern)
        var paths = messages.flatMap { $0.attachments ?? [] }
        for message in messages where message.role == "tool" {
            for match in expression?.matches(in: message.detail, range: NSRange(message.detail.startIndex..., in: message.detail)) ?? [] {
                guard let range = Range(match.range(at: 1), in: message.detail),
                      let path = try? JSONDecoder().decode(String.self, from: Data(message.detail[range].utf8)) else { continue }
                paths.append(path)
            }
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: projectPath).appendingPathComponent(path)).standardizedFileURL
            guard supported.contains(url.pathExtension.lowercased()), seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    private func requireEnabled() throws {
        guard enabled() else { throw ArtifactError("Los artefactos solo están disponibles en modo Normal.") }
    }
    private func validate(_ data: Data, kind: ArtifactKind) throws {
        guard data.count <= Self.maximumBytes else { throw ArtifactError("El artefacto supera el límite de 8 MB.") }
        if kind.isText, String(data: data, encoding: .utf8) == nil { throw ArtifactError("El contenido debe ser texto UTF-8.") }
        if kind == .link {
            guard let url = URL(string: String(decoding: data, as: UTF8.self)), Self.isClaudeArtifactURL(url) else { throw ArtifactError("El enlace de Claude no es válido.") }
        }
    }
    private func contentURL(_ id: UUID, version: Int) -> URL { directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("\(version).data") }
    private func commit(_ artifact: JackArtifact, data: Data) throws {
        let folder = directory.appendingPathComponent(artifact.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: contentURL(artifact.id, version: artifact.version), options: .atomic)
        try JSONEncoder().encode(artifact).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
