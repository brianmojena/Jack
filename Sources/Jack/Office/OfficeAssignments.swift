import Foundation
import JackCore

/// Qué agente de Jack ocupa cada puesto de la oficina, y quién está «trabajando» (sentado en su escritorio).
///
/// El reparto se guarda; el estado de trabajo no: al abrir Jack todos empiezan en su sofá.
@MainActor final class OfficeAssignments: ObservableObject {
    static let key = "officeSlotsV2"
    static let modelKey = "officeLastModel"
    static let chatsKey = "officeChats"

    /// El último proveedor y modelo con que se mandó a alguien a trabajar; «Trabajar» lo ofrece primero.
    struct ModelChoice: Equatable {
        var provider: ChatProvider
        var model: String
    }

    @Published private(set) var slots: [String: UUID]
    /// Puestos cuyo agente se ha mandado al escritorio aunque no esté ejecutando nada.
    @Published private(set) var working: Set<String> = []
    @Published private(set) var lastModel: ModelChoice?
    /// El chat con cada persona, por puesto: lo que le dice el usuario, lo que contesta y lo que le encarga a su agente.
    @Published private(set) var chats: [String: [OfficeLine]] = [:]
    /// Quién ayuda a quién: el puesto de cada ayudante y el de la persona que le pidió ayuda. No se guarda.
    @Published private(set) var leaders: [String: String] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        slots = saved.compactMapValues(UUID.init(uuidString:))
        if let last = defaults.dictionary(forKey: Self.modelKey) as? [String: String],
           let provider = last["provider"].flatMap(ChatProvider.init(rawValue:)) {
            lastModel = ModelChoice(provider: provider, model: last["model"] ?? "")
        }
        if let data = defaults.data(forKey: Self.chatsKey), let saved = try? JSONDecoder().decode([String: [OfficeLine]].self, from: data) {
            chats = saved
        }
    }

    func chat(in slot: String) -> [OfficeLine] { chats[slot] ?? [] }

    func append(_ line: OfficeLine, slot: String) {
        // Las últimas 80 líneas bastan para el chat y para el contexto de la persona.
        chats[slot] = Array((chats[slot] ?? []).suffix(79)) + [line]
        saveChats()
    }

    func setLeader(_ leader: String?, for helper: String) { leaders[helper] = leader }

    func helpers(of leader: String) -> [String] { leaders.filter { $0.value == leader }.map(\.key).sorted() }

    func clearChat(slot: String) {
        chats[slot] = nil
        saveChats()
    }

    private func saveChats() {
        if let data = try? JSONEncoder().encode(chats) { defaults.set(data, forKey: Self.chatsKey) }
    }

    func remember(provider: ChatProvider, model: String) {
        lastModel = ModelChoice(provider: provider, model: model)
        defaults.set(["provider": provider.rawValue, "model": model], forKey: Self.modelKey)
    }

    func conversation(in slot: String) -> UUID? { slots[slot] }

    func slot(of conversation: UUID) -> String? { slots.first { $0.value == conversation }?.key }

    func assign(_ conversation: UUID, to slot: String) {
        for (other, id) in slots where id == conversation { slots[other] = nil; working.remove(other) }
        slots[slot] = conversation
        save()
    }

    func clear(slot: String) {
        slots[slot] = nil
        working.remove(slot)
        save()
    }

    func setWorking(_ value: Bool, slot: String) {
        if value { working.insert(slot) } else { working.remove(slot) }
    }

    private func save() {
        defaults.set(slots.mapValues(\.uuidString), forKey: Self.key)
    }
}
