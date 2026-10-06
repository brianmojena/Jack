import JackCore
import SwiftUI

/// One-line live summary of what the agent is doing, shown above the composer.
struct AgentActivityView: View {
    let conversation: ChatConversation
    let status: ChatStatus
    let tokens: ChatTokenUsage?
    let projectPath: String
    private var activity: ChatMessage? { conversation.messages.last.flatMap { $0.role == "user" ? nil : $0 } }

    private var title: String {
        if status == .queued { return "En cola, esperando un espacio libre" }
        if status == .waiting { return "Esperando tu respuesta" }
        guard let activity else { return "Preparando respuesta" }
        if activity.role == "reasoning" { return "Pensando" }
        if activity.role == "assistant" { return "Escribiendo respuesta" }
        if activity.role == "tool", ["running", "inProgress", "pending"].contains(activity.status) {
            let tool = ToolPresentation(message: activity, projectPath: projectPath)
            return [tool.verb(running: true), tool.subject].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return "Preparando el siguiente paso"
    }

    var body: some View {
        HStack(spacing: 8) {
            if status == .waiting {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(JackPalette.amber)
            } else if status == .queued {
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(JackPalette.muted)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JackPalette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let tokens, case let total = tokens.input + tokens.output, total > 0 {
                Text("\(total.formatted(.number.notation(.compactName))) tokens")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(JackPalette.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}
