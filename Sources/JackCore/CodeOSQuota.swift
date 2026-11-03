import Foundation

// CodeOS (modo Normal): perfiles que comparten una cuenta de Claude. Lo que queda de la ventana de 5 horas se reparte a partes iguales
// entre los perfiles activos; cada Mac mide lo que gasta su perfil y se lo cuenta a las demás por la red local. Aquí está la lógica pura
// (sin red ni pantalla), para poder probarla.

/// Una persona que trabaja con la cuenta compartida.
public struct QuotaProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Tono del avatar, de 0 a 1.
    public var hue: Double

    public init(id: UUID = UUID(), name: String, hue: Double) {
        self.id = id
        self.name = name
        self.hue = hue
    }
}

/// Lo que una Mac cuenta de su perfil a las demás.
public struct QuotaPeerState: Codable, Equatable, Sendable {
    public var instance: String
    public var profile: UUID
    public var name: String
    public var hue: Double
    /// Si pide entrar en el reparto.
    public var active: Bool
    /// Tokens (ponderados) que ha gastado desde que empezó `epoch`.
    public var tokens: Double
    public var epoch: String
    public var updatedAt: Date

    public init(instance: String, profile: UUID, name: String, hue: Double, active: Bool, tokens: Double, epoch: String, updatedAt: Date = Date()) {
        self.instance = instance; self.profile = profile; self.name = name; self.hue = hue
        self.active = active; self.tokens = tokens; self.epoch = epoch; self.updatedAt = updatedAt
    }
}

/// Un trozo de su parte que un perfil cede a otro, dentro de una época.
public struct QuotaGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public var percent: Double
    public var epoch: String

    public init(id: UUID = UUID(), from: UUID, to: UUID, percent: Double, epoch: String) {
        self.id = id; self.from = from; self.to = to; self.percent = percent; self.epoch = epoch
    }
}

/// Alguien que se ha quedado sin parte y pide a otro perfil que le ceda.
public struct QuotaRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var from: UUID
    public var fromName: String
    /// A quién se lo pide.
    public var to: UUID
    public var percent: Double
    public var epoch: String

    public init(id: UUID = UUID(), from: UUID, fromName: String, to: UUID, percent: Double, epoch: String) {
        self.id = id; self.from = from; self.fromName = fromName; self.to = to; self.percent = percent; self.epoch = epoch
    }
}

/// Lo que viaja entre las Macs, una por línea.
public struct QuotaMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case state, request, grant, decline }
    public var kind: Kind
    public var state: QuotaPeerState?
    public var request: QuotaRequest?
    public var grant: QuotaGrant?
    /// Para `decline`: la petición que se rechaza.
    public var declined: UUID?

    public init(kind: Kind, state: QuotaPeerState? = nil, request: QuotaRequest? = nil, grant: QuotaGrant? = nil, declined: UUID? = nil) {
        self.kind = kind; self.state = state; self.request = request; self.grant = grant; self.declined = declined
    }
}

/// El reparto vigente: desde cuándo, con cuánto consumido de la cuenta y entre quiénes. Cambia cuando se reinicia la ventana de 5 horas o
/// cuando entra o sale alguien del reparto.
public struct QuotaEpoch: Equatable, Sendable {
    public var key: String
    /// Porcentaje de la ventana de 5 horas ya gastado cuando empezó.
    public var usedAtStart: Double
    public var active: [UUID]

    public init(key: String, usedAtStart: Double, active: [UUID]) {
        self.key = key; self.usedAtStart = usedAtStart; self.active = active
    }

    /// La clave es igual en todas las Macs que ven lo mismo: la ventana de 5 horas (su hora de reinicio) y los perfiles activos.
    public static func key(windowResetsAt: Date?, active: [UUID]) -> String {
        let window = windowResetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "sin-ventana"
        return window + "|" + active.map(\.uuidString).sorted().joined(separator: ",")
    }
}

/// La parte de un perfil en este momento, en puntos porcentuales de la ventana de 5 horas de la cuenta.
public struct QuotaShare: Identifiable, Equatable, Sendable {
    public var id: UUID { profile }
    public var profile: UUID
    public var name: String
    public var hue: Double
    public var active: Bool
    /// Lo que le tocaba al empezar el reparto, más lo que le han cedido y menos lo que ha cedido.
    public var base: Double
    public var spent: Double
    public var remaining: Double { base - spent }
}

public enum QuotaPool {
    /// Los pesos con que un turno gasta la cuota: la entrada y la salida cuentan; lo que sale de la caché pesa mucho menos.
    public static func weightedTokens(input: Int, output: Int, cached: Int) -> Double {
        Double(input) + Double(output) * 4 + Double(cached) * 0.1
    }

    /// El reparto de la época: `(100 - gastado al empezar) / activos` para cada activo, ajustado por las cesiones, y lo gastado desde
    /// entonces atribuido a cada perfil en proporción a sus tokens.
    public static func shares(epoch: QuotaEpoch, states: [QuotaPeerState], grants: [QuotaGrant], usedNow: Double) -> [QuotaShare] {
        let active = Set(epoch.active)
        guard !active.isEmpty else { return [] }
        let each = max(0, 100 - epoch.usedAtStart) / Double(active.count)
        let delta = max(0, usedNow - epoch.usedAtStart)
        // Solo cuentan los informes de esta época, de perfiles que están en ella.
        let reports = Dictionary(states.filter { $0.epoch == epoch.key && active.contains($0.profile) }.map { ($0.profile, max(0, $0.tokens)) }, uniquingKeysWith: max)
        let total = reports.values.reduce(0, +)
        return states.filter { active.contains($0.profile) }.reduce(into: [UUID: QuotaShare]()) { result, state in
            var base = each
            for grant in grants where grant.epoch == epoch.key {
                if grant.to == state.profile { base += grant.percent }
                if grant.from == state.profile { base -= grant.percent }
            }
            let spent = total > 0 ? delta * (reports[state.profile] ?? 0) / total : 0
            result[state.profile] = QuotaShare(profile: state.profile, name: state.name, hue: state.hue, active: true, base: base, spent: spent)
        }.values.sorted { $0.name < $1.name }
    }

    /// Por qué no puede enviar un perfil, o nil si puede.
    public static func refusal(for profile: UUID, active: Bool, shares: [QuotaShare]) -> String? {
        guard active else { return "Tu perfil está en pausa: actívalo en CodeOS (tecla U) para volver a entrar en el reparto de la cuenta." }
        guard let own = shares.first(where: { $0.profile == profile }) else { return nil }
        if own.remaining <= 0 {
            return "Has gastado tu parte de la ventana de 5 horas (\(Int(own.base.rounded())) %). Pide a otro perfil que te ceda: tecla U en CodeOS."
        }
        return nil
    }
}
