import Combine
import JackCore
import SwiftUI

@MainActor
final class Office2DViewModel: ObservableObject {
    @Published private(set) var agents: [Office2DAgent] = []
    @Published private(set) var conversationsByAgent: [String: ChatConversation] = [:]

    private let store: ChatStore
    private let onOpen: (UUID) -> Void
    private var observation: AnyCancellable?
    private var roster: [UUID] = []

    init(store: ChatStore, onOpen: @escaping (UUID) -> Void) {
        self.store = store
        self.onOpen = onOpen
        observation = Publishers.CombineLatest3(store.$conversations, store.$statuses, store.$approvals)
            .receive(on: RunLoop.main)
            .sink { [weak self] conversations, statuses, approvals in
                self?.refresh(conversations: conversations, statuses: statuses, approvals: approvals)
            }
        refresh(conversations: store.conversations, statuses: store.statuses, approvals: store.approvals)
    }

    /// Opens the selected chat using the same store selection as a sidebar row.
    func open(agentID: String) {
        guard let id = UUID(uuidString: agentID), store.conversations.contains(where: { $0.id == id }) else { return }
        store.select(id)
        onOpen(id)
    }

    private func refresh(conversations: [ChatConversation], statuses: [UUID: ChatStatus], approvals: [UUID: [ChatApproval]]) {
        // Keep each desk stable as new agents arrive, and let finished agents celebrate and use the lounge.
        // Old idle history is not loaded into the office; only work seen during this visit stays here.
        let existing = Set(conversations.map(\.id))
        roster.removeAll { !existing.contains($0) }
        let live = conversations.filter {
            let status = statuses[$0.id] ?? .idle
            return status.isOffice2DActive || !(approvals[$0.id] ?? []).isEmpty
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        for conversation in live where !roster.contains(conversation.id) { roster.append(conversation.id) }
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let active = roster.compactMap { byID[$0] }

        conversationsByAgent = Dictionary(uniqueKeysWithValues: active.map { ($0.id.uuidString, $0) })
        agents = active.map { conversation in
            let status = statuses[conversation.id] ?? .idle
            let hasApproval = !(approvals[conversation.id] ?? []).isEmpty
            return Office2DAgent(
                id: conversation.id.uuidString,
                name: conversation.title,
                kind: conversation.provider.rawValue,
                state: hasApproval ? .waiting : Office2DStateMapper.state(for: status, lastMessageRole: conversation.messages.last?.role),
                activity: activity(conversation, status: status, hasApproval: hasApproval),
                seed: Office2DStateMapper.seed(for: conversation.id.uuidString)
            )
        }
    }

    private func activity(_ conversation: ChatConversation, status: ChatStatus, hasApproval: Bool) -> String? {
        if hasApproval { return "Esperando aprobación" }
        switch status {
        case .waiting:
            return "Esperando tu respuesta"
        case .queued:
            return "En cola"
        case .running:
            guard let message = conversation.messages.last else { return "Preparando respuesta" }
            switch message.role {
            case "reasoning": return "Pensando"
            case "assistant": return "Escribiendo respuesta"
            case "tool":
                let tool = ToolPresentation(message: message, projectPath: conversation.projectPath)
                return [tool.verb(running: true), tool.subject].filter { !$0.isEmpty }.joined(separator: " ")
            default: return "Preparando el siguiente paso"
            }
        case .failed:
            return conversation.messages.last(where: { $0.role == "error" })?.text ?? "Error"
        case .idle:
            return "Trabajo terminado · de descanso"
        }
    }
}

private extension ChatStatus {
    var isOffice2DActive: Bool { self == .running || self == .queued || self == .waiting }
}
