import Foundation

/// Files the user drops into a conversation. Every agent gets their paths; images also travel inline.
public enum ChatAttachments {
    /// Inline images stay under the API's 5 MB limit once base64 encoded.
    static let inlineLimit = 3_750_000

    /// Where Jack keeps attachments that have no file of their own, such as dragged image data.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jack/Attachments", isDirectory: true)
    }

    /// Saves dropped data as a file the agent can open.
    public static func store(_ data: Data, fileExtension: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString.prefix(8) + "." + fileExtension)
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// Files in temporary folders, such as a screenshot dragged from its thumbnail, may vanish before
    /// the agent reads them, so Jack keeps its own copy.
    public static func persist(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temporary = [NSTemporaryDirectory(), "/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard temporary.contains(where: { path.hasPrefix($0) }) else { return url.standardizedFileURL.path }
        let folder = directory.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy.path
        } catch { return url.standardizedFileURL.path }
    }

    /// The image's real format, read from its first bytes, if the providers accept it inline.
    public static func imageType(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// An image small enough to send inline, with its media type.
    static func inlineImage(_ path: String) -> (mediaType: String, data: Data)? {
        guard let type = imageType(path), let data = FileManager.default.contents(atPath: path), data.count <= inlineLimit else { return nil }
        return (type, data)
    }

    /// The message plus where each attachment lives, so the agent can open any of them.
    static func promptText(_ prompt: String, attachments: [String]) -> String {
        guard !attachments.isEmpty else { return prompt }
        let list = attachments.map { "- \($0)" }.joined(separator: "\n")
        return (prompt.isEmpty ? "" : prompt + "\n\n")
            + "Archivos adjuntos por el usuario (ábrelos desde estas rutas antes de responder sobre ellos; las imágenes también van incluidas en el mensaje):\n" + list
    }
}

public extension ChatConversation {
    /// Files attached to the message that starts the current turn.
    var turnAttachments: [String] {
        guard let last = messages.last, last.role == "user" else { return [] }
        return last.attachments ?? []
    }

    /// Folders holding this turn's attachments that the agent could not otherwise read.
    var attachmentDirectories: [String] {
        var seen = Set([projectPath] + additionalDirectories)
        return turnAttachments.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let folder = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
            guard !folder.hasPrefix(projectPath + "/") else { return nil }
            return seen.insert(folder).inserted ? folder : nil
        }
    }
}
