import Foundation

/// Small metadata index; transcripts are read only when a conversation is opened.
public final class ChatArchive {
    public let directory: URL
    private let writer = DispatchQueue(label: "dev.jack.chat.persistence", qos: .utility)
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jack/Chats", isDirectory: true)
    }
    public func loadIndex() throws -> [ChatConversation] {
        let url = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ChatConversation].self, from: Data(contentsOf: url))
    }
    public func load(_ id: UUID) throws -> ChatConversation? {
        flush()
        let url = transcriptURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ChatConversation.self, from: Data(contentsOf: url))
    }
    public func save(index: [ChatConversation], conversation: ChatConversation? = nil, removedID: UUID? = nil, completion: @escaping (Error?) -> Void = { _ in }) {
        let summaries = index.map { value -> ChatConversation in var summary = value; summary.messages = []; return summary }
        writer.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                if let conversation { try encoder.encode(conversation).write(to: transcriptURL(conversation.id), options: .atomic) }
                try encoder.encode(summaries).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
                if let removedID, FileManager.default.fileExists(atPath: transcriptURL(removedID).path) { try FileManager.default.removeItem(at: transcriptURL(removedID)) }
                completion(nil)
            } catch { completion(error) }
        }
    }
    public func flush() { writer.sync {} }
    private func transcriptURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
