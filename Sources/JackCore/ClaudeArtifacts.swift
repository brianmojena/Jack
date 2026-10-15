import Foundation

/// Metadata returned by Claude's signed-in artifact gallery. No credentials are stored here.
public struct ClaudeArtifact: Decodable, Identifiable, Sendable {
    public let uuid: String
    public let artifactIdentifier: String
    public let artifactType: String
    public let title: String
    public let chatConversationUUID: String
    public let chatConversationName: String?
    public let latestPublishedArtifactUUID: String?
    public var id: String { organizationID + ":" + uuid }
    public var organizationID = ""
    public var origin: String { "Claude:\(organizationID):\(uuid)" }
    public var sourceURL: URL {
        if let published = latestPublishedArtifactUUID, UUID(uuidString: published) != nil {
            return URL(string: "https://claude.ai/public/artifacts/\(published)")!
        }
        var components = URLComponents(string: "https://claude.ai/chat/\(chatConversationUUID)")!
        components.queryItems = [.init(name: "artifact", value: artifactIdentifier)]
        return components.url!
    }
    enum CodingKeys: String, CodingKey {
        case uuid, title
        case artifactIdentifier = "artifact_identifier", artifactType = "artifact_type"
        case chatConversationUUID = "chat_conversation_uuid", chatConversationName = "chat_conversation_name"
        case latestPublishedArtifactUUID = "latest_published_artifact_uuid"
    }
}

public struct ClaudeArtifactPage: Decodable, Sendable {
    public var artifacts: [ClaudeArtifact]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case artifacts; case nextCursor = "next_cursor" }
}

public enum ClaudeArtifactContent {
    /// Only complete artifact tool payloads qualify; gallery previews are truncated excerpts.
    public static func extract(from data: Data, identifier: String) throws -> String? {
        guard let chat = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = chat["chat_messages"] as? [[String: Any]] else {
            throw ArtifactError("Claude devolvió una conversación con un formato no reconocido.")
        }
        var ordered = messages
        if let leaf = chat["current_leaf_message_uuid"] as? String {
            let byID = Dictionary(messages.compactMap { message -> (String, [String: Any])? in
                guard let id = message["uuid"] as? String else { return nil }
                return (id, message)
            }, uniquingKeysWith: { _, last in last })
            var branch: [[String: Any]] = []
            var cursor: String? = leaf
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted, let message = byID[id] {
                branch.append(message)
                cursor = message["parent_message_uuid"] as? String
            }
            guard !branch.isEmpty else { return nil }
            ordered = branch.reversed()
        }
        var latest: String?
        for message in ordered {
            for block in message["content"] as? [[String: Any]] ?? [] {
                guard block["type"] as? String == "tool_use", block["name"] as? String == "artifacts",
                      let input = block["input"] as? [String: Any], input["id"] as? String == identifier else { continue }
                // Partial updates cannot be imported as a complete document.
                if let content = input["content"] as? String { latest = content }
                else if input["command"] as? String == "update" { latest = nil }
            }
        }
        return latest
    }
    public static func kind(for type: String) -> ArtifactKind {
        switch type { case "text/html": .html; case "text/markdown": .markdown; case "image/svg+xml": .svg; default: .code }
    }
}

extension ArtifactLibrary {
    /// Repeat imports preserve local edits. An explicit import never publishes or shares in Claude.
    @discardableResult public func importClaudeArtifact(_ artifact: ClaudeArtifact, content: String?,
                                                       projectPath: String, conversationID: UUID?) throws -> JackArtifact {
        if let existing = try list(projectPath: projectPath).first(where: { $0.origin == artifact.origin }) {
            selectedID = existing.id
            return existing
        }
        let title = String(artifact.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let kind = content == nil ? ArtifactKind.link : ClaudeArtifactContent.kind(for: artifact.artifactType)
        return try create(title: title.isEmpty ? "Artefacto de Claude" : title, kind: kind,
                          data: Data((content ?? artifact.sourceURL.absoluteString).utf8), projectPath: projectPath,
                          conversationID: conversationID, origin: artifact.origin, author: "Claude")
    }
}
