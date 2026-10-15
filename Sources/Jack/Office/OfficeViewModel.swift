import Combine
import JackCore
import SwiftUI

@MainActor
final class OfficeViewModel: ObservableObject {
    @Published private(set) var agents: [OfficeAgent] = []

    private let store: ChatStore
    private let onOpen: (UUID) -> Void
    private var observation: AnyCancellable?

    init(store: ChatStore, onOpen: @escaping (UUID) -> Void) {
        self.store = store
        self.onOpen = onOpen
        observation = store.$conversations
            .combineLatest(store.$statuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] conversations, statuses in
                self?.refresh(conversations: conversations, statuses: statuses)
            }
        refresh(conversations: store.conversations, statuses: store.statuses)
    }

    /// Opens the selected chat using the same store selection as a sidebar row.
    func open(agentID: String) {
        guard let id = UUID(uuidString: agentID), store.conversations.contains(where: { $0.id == id }) else { return }
        store.select(id)
        onOpen(id)
    }

    private func refresh(conversations: [ChatConversation], statuses: [UUID: ChatStatus]) {
        // UUID ordering keeps desk assignments stable while conversations stream or change status.
        agents = conversations.sorted { $0.id.uuidString < $1.id.uuidString }.map { conversation in
            let status = statuses[conversation.id] ?? .idle
            return OfficeAgent(
                id: conversation.id.uuidString,
                name: conversation.title,
                kind: conversation.provider.rawValue,
                state: OfficeStateMapper.state(for: status, lastMessageRole: conversation.messages.last?.role),
                activity: activity(conversation, status: status),
                seed: OfficeStateMapper.seed(for: conversation.id.uuidString)
            )
        }
    }

    private func activity(_ conversation: ChatConversation, status: ChatStatus) -> String? {
        switch status {
        case .waiting:
            return "Esperando tu respuesta"
        case .queued:
            return "En cola, esperando un espacio libre"
        case .running:
            guard let message = conversation.messages.last else { return "Preparando respuesta" }
            switch message.role {
            case "reasoning": return "Pensando"
            case "assistant": return "Escribiendo respuesta"
            case "tool":
                let tool = ToolPresentation(message: message, projectPath: conversation.projectPath)
                return [tool.verb(running: true), tool.subject]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            default: return "Preparando el siguiente paso"
            }
        case .failed:
            return conversation.messages.last(where: { $0.role == "error" })?.text ?? "Error"
        case .idle:
            return conversation.preview ?? "Inactivo"
        }
    }
}
