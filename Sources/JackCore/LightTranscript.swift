import Foundation

/// A bounded projection for Light's native text view. Thinking and tool output never enter it.
public enum LightTranscript {
    public static func messages(in conversation: ChatConversation, limit: Int = 100) -> [ChatMessage] {
        let recent = Array(conversation.messages.reversed().lazy.filter {
            ["user", "assistant", "jack", "error"].contains($0.role)
        }.prefix(max(0, limit)))
        return Array(recent.reversed())
    }

    public static func text(of message: ChatMessage) -> String {
        let heading: String
        switch message.role {
        case "user": heading = "Tú"
        case "jack": heading = "Jack"
        case "error": heading = "Error"
        default: heading = "Agente"
        }
        let files = (message.attachments ?? []).map { "Adjunto: " + $0 }
        return heading + "\n" + ([message.text] + files).joined(separator: "\n") + "\n\n"
    }
}
