import Foundation

public struct AgentMentionOption: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var insertion: String
    public init(id: String, title: String, subtitle: String, insertion: String) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.insertion = insertion
    }
}

public enum AgentMentionDelivery: Equatable {
    case started
    case queuedForSlot
    case handedToDriver
    case queuedUntilTurnEnds
    case declinedApproval
}

public enum AgentMentionRouteResult: Equatable {
    case created(conversationID: UUID, delivery: AgentMentionDelivery)
    case reused(conversationID: UUID, delivery: AgentMentionDelivery)
    case rejected(String)
}

/// Parsing and matching for the composer mention syntax. Existing agents use their UUID prefix as a
/// structured reference, so duplicate titles never route a message to the wrong conversation.
public enum AgentMentions {
    public static let providers: [ChatProvider] = [.codex, .claude, .opencode, .antigravity]

    /// The one unfinished mention at the start of a composer draft, if any.
    public static func query(in draft: String) -> String? {
        guard draft.first == "@", draft.last?.isWhitespace != true,
              !draft.dropFirst().contains(where: \.isWhitespace),
              !draft.dropFirst().contains("@") else { return nil }
        return String(draft.dropFirst()).lowercased()
    }

    /// Completes only a valid leading query; invalid drafts are left untouched.
    public static func completing(_ draft: String, with insertion: String) -> String {
        guard query(in: draft) != nil else { return draft }
        return insertion
    }

    /// A leading mention is a routing instruction. Mentions later in the prompt remain normal prose.
    public static func leadingRoute(in prompt: String) -> (reference: String, message: String)? {
        guard prompt.first == "@", let boundary = prompt.firstIndex(where: \.isWhitespace) else { return nil }
        let reference = String(prompt[..<boundary].dropFirst()).lowercased()
        let message = prompt[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !reference.contains("@") else { return nil }
        return (reference, message)
    }

    /// A structured UUID prefix. Hyphens are allowed only where the canonical UUID spelling has them.
    public static func isAgentReference(_ reference: String) -> Bool {
        let value = reference.lowercased()
        guard (8...36).contains(value.count) else { return false }
        let hyphenPositions: Set<Int> = [8, 13, 18, 23]
        for (index, character) in value.enumerated() {
            if hyphenPositions.contains(index) {
                guard character == "-" else { return false }
            } else if !character.isHexDigit {
                return false
            }
        }
        return true
    }

    public static func options(for query: String, conversations: [ChatConversation], projectPath: String, excluding id: UUID) -> [AgentMentionOption] {
        let normalized = query.lowercased()
        let providers = providers.compactMap { provider -> AgentMentionOption? in
            let key = provider.rawValue
            guard normalized.isEmpty || provider.title.lowercased().contains(normalized) || key.contains(normalized) else { return nil }
            return AgentMentionOption(id: "provider:\(key)", title: provider.title, subtitle: "Crear subagente", insertion: "@\(key) ")
        }
        let agents = conversations
            .filter { $0.id != id && $0.projectPath == projectPath }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { conversation -> AgentMentionOption? in
                let stableID = conversation.id.uuidString.lowercased()
                var length = 8
                while conversations.filter({ $0.id != id && $0.projectPath == projectPath && $0.id.uuidString.lowercased().hasPrefix(String(stableID.prefix(length))) }).count > 1,
                      length < stableID.count { length += 1 }
                let shortID = String(stableID.prefix(length))
                guard normalized.isEmpty || conversation.title.lowercased().contains(normalized) || shortID.lowercased().hasPrefix(normalized) else { return nil }
                return AgentMentionOption(id: "agent:\(stableID)", title: conversation.title,
                                          subtitle: "\(conversation.provider.title) · \(shortID)", insertion: "@\(shortID) ")
            }
        return providers + agents
    }
}
