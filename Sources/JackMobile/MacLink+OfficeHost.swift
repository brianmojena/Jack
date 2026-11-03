import Foundation

/// En el iPhone, los agentes de la oficina son los de Jack en la Mac: la misma interfaz que en la Mac, con lo que cuenta
/// Jack Remote.
extension MacLink: OfficeHost {
    var lightModeEnabled: Bool { false }

    /// El uso de Claude no viaja por Jack Remote: la tele enseña solo el logo.
    var officeUsage: ProviderUsage? { nil }

    func modelChoices(for provider: ChatProvider) -> [ChatModelChoice] {
        (providers.first { $0.id == provider.rawValue }?.models ?? []).map { ChatModelChoice(id: $0.id, title: $0.title) }
    }

    func officeCreate(_ task: String, provider: ChatProvider, model: String?) async -> UUID? {
        switch await create(task: task, project: "", provider: provider.rawValue, model: model) {
        case .success(let agent):
            return UUID(uuidString: agent)
        case .failure(let failure):
            fail(failure.message)
            return nil
        }
    }

    func officeSend(_ text: String, to id: UUID) {
        Task { if let failure = await write(text, to: id.uuidString) { fail(failure) } }
    }

    func stop(_ id: UUID) {
        Task { await stop(id.uuidString) }
    }

    func setUnread(_ id: UUID, _ unread: Bool) {
        markRead(id.uuidString, !unread)
    }

    func updateSettings(id: UUID, model: String, effort: String) {
        Task { if let failure = await configure(id.uuidString, model: model, effort: effort) { fail(failure) } }
    }
}
