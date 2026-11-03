import Foundation
#if canImport(JackCore)
import JackCore
#endif

/// Lo que la interfaz de la oficina necesita de los agentes de programación. En la Mac lo da `ChatStore` (los agentes corren
/// en ella); en el iPhone, la conexión con la Mac (que los ejecuta y le cuenta qué hacen). La interfaz es la misma en los dos.
@MainActor protocol OfficeHost: ObservableObject {
    var conversations: [ChatConversation] { get }
    var selectedID: UUID? { get }
    var statuses: [UUID: ChatStatus] { get }
    var errorMessage: String? { get }
    /// El modo Light de Jack (en el iPhone, siempre apagado).
    var lightModeEnabled: Bool { get }
    /// El uso de Claude, para la tele.
    var officeUsage: ProviderUsage? { get }

    func modelChoices(for provider: ChatProvider) -> [ChatModelChoice]
    /// Un agente nuevo con `task`; la carpeta la elige el propio Jack (el de la Mac) según el encargo.
    func officeCreate(_ task: String, provider: ChatProvider, model: String?) async -> UUID?
    func officeSend(_ text: String, to id: UUID)
    func stop(_ id: UUID)
    func select(_ id: UUID)
    func setUnread(_ id: UUID, _ unread: Bool)
    func updateSettings(id: UUID, model: String, effort: String)
}
