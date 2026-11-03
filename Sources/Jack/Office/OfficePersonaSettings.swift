import Foundation
#if canImport(JackCore)
import JackCore
#endif

/// Los ajustes de cada personaje de la oficina, por avatar: con qué modelo piensa (sin elegir, Gemma), cómo es (la personalidad
/// que viene con el avatar o la que el usuario escribió) y si la personalidad está encendida. Se recuerdan entre sesiones.
@MainActor final class OfficePersonaSettings: ObservableObject {
    static let key = "officePersonaSettings"

    struct Entry: Codable, Equatable {
        /// El modelo con que piensa; `nil` es Gemma.
        var brain: OfficeBrainChoice?
        /// La personalidad escrita por el usuario; `nil` es la que trae el avatar.
        var profile: String?
        /// Sin personalidad: habla como un compañero normal.
        var personalityOff = false
    }

    @Published private(set) var entries: [String: Entry]

    init() {
        entries = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func entry(for avatar: String) -> Entry { entries[avatar] ?? Entry() }

    func brain(for avatar: String) -> OfficeBrainChoice? { entry(for: avatar).brain }

    /// La personalidad que trae el avatar, si la trae.
    func defaultProfile(for avatar: String) -> String? { OfficePersonas.persona(forAvatar: avatar)?.profile }

    /// La personalidad escrita por el usuario, o la del avatar; no tiene en cuenta si está apagada.
    func storedProfile(for avatar: String) -> String? { entry(for: avatar).profile ?? defaultProfile(for: avatar) }

    /// Hay personalidad que encender o apagar.
    func hasPersonality(_ avatar: String) -> Bool { storedProfile(for: avatar) != nil }

    func isOff(_ avatar: String) -> Bool { entry(for: avatar).personalityOff }

    /// La persona tal como la ven los modelos: sin personalidad si está apagada o si no tiene. `name` es cómo se llama en la oficina.
    func persona(forAvatar avatar: String, name: String) -> OfficePersona? {
        guard !isOff(avatar), let profile = storedProfile(for: avatar) else { return nil }
        if entry(for: avatar).profile == nil, let original = OfficePersonas.persona(forAvatar: avatar) { return original }
        return OfficePersona(name: name, profile: profile, about: Self.about(name: name, profile: profile))
    }

    /// Una línea sobre quién es, para que los demás lo conozcan: su nombre y el principio de su personalidad.
    static func about(name: String, profile: String) -> String {
        let flat = profile.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let sentence = flat.firstIndex(of: ".").map { String(flat[...$0]) } ?? flat
        return "\(name): " + (sentence.count > 160 ? String(sentence.prefix(159)) + "…" : sentence)
    }

    func setBrain(_ brain: OfficeBrainChoice?, for avatar: String) {
        update(avatar) { $0.brain = brain }
    }

    /// Guarda la personalidad escrita; igual a la del avatar (o vacía) es volver a la original.
    func setProfile(_ text: String, for avatar: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = trimmed.isEmpty || trimmed == defaultProfile(for: avatar)?.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : trimmed
        update(avatar) { $0.profile = custom }
    }

    func setOff(_ off: Bool, for avatar: String) {
        update(avatar) { $0.personalityOff = off }
    }

    private func update(_ avatar: String, _ change: (inout Entry) -> Void) {
        var entry = self.entry(for: avatar)
        change(&entry)
        entries[avatar] = entry == Entry() ? nil : entry
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
