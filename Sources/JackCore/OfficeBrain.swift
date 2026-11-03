import Foundation

/// El modelo con que piensa un personaje de la oficina 3D: cualquiera de los que ofrece Jack. Sin elegir, es Gemma 4 31B Cloud.
public struct OfficeBrainChoice: Codable, Hashable, Sendable {
    public var provider: ChatProvider
    /// Claude: el alias («sonnet»); Codex: el modelo; OpenCode: «proveedor/modelo»; Stellar Code: «servidor/modelo».
    public var model: String

    public init(provider: ChatProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    /// «Claude Code · sonnet».
    public var title: String { model.isEmpty ? provider.title : "\(provider.title) · \(model)" }
}

/// Oficina 3D (modo Normal): lo que piensa y dice cada personaje lo escribe un modelo a elegir por personaje. Los de Stellar Code se
/// piden directamente a su servidor; Claude Code, Codex y OpenCode, a través de su CLI en una consulta suelta (sin herramientas, sin
/// historial y sin guardar nada). Los CLI no reciben imágenes: el modelo trabaja solo con el texto.
@MainActor public enum OfficeBrain {
    public enum Failure: LocalizedError {
        case unknownModel(String)
        case needsMac

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let id): "No se reconoce el modelo «\(id)» de Stellar Code."
            case .needsMac: "Conecta el iPhone con Jack en la Mac para usar este modelo."
            }
        }
    }

    /// Lo que se hace con una consulta a un CLI: proveedor, modelo, instrucciones y conversación. Cambiable en las pruebas; en el
    /// iPhone, la consulta la hace la Mac (Jack Remote).
    public static var askCLI: @MainActor (ChatProvider, String, String, String) async throws -> String = { provider, model, system, prompt in
        #if os(macOS)
        try await ChatAsideService.oneShot(provider: provider, model: model, system: system, prompt: prompt)
        #else
        throw Failure.needsMac
        #endif
    }
    static var askStellar: @MainActor (StellarServer, String, [StellarMessage], Int, TimeInterval) throws -> AsyncThrowingStream<StellarChunk, Error> = { server, model, messages, context, timeout in
        try StellarClient.stream(server: server, model: model, messages: messages, tools: nil, contextLength: context, timeout: timeout)
    }

    /// La respuesta de `choice` a la conversación `messages`, como un chorro de texto (los CLI lo dan de una vez, al terminar).
    static func stream(_ messages: [StellarMessage], choice: OfficeBrainChoice, timeout: TimeInterval = 120) throws -> AsyncThrowingStream<StellarChunk, Error> {
        if choice.provider == .stellar {
            guard let (server, name) = StellarModels.resolve(choice.model, allowOllamaName: true) else { throw Failure.unknownModel(choice.model) }
            return try askStellar(server, name, messages, StellarServer.defaultContextLength, timeout)
        }
        let (system, prompt) = flatten(messages)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let answer = try await askCLI(choice.provider, choice.model, system, prompt)
                    continuation.yield(.text(answer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Las instrucciones (los mensajes de sistema) y la conversación como texto, para los CLI que solo reciben una pregunta.
    static func flatten(_ messages: [StellarMessage]) -> (system: String, prompt: String) {
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != "system" }
        // Una sola intervención del usuario: se pasa tal cual.
        if turns.count == 1, turns[0].role == "user" { return (system, turns[0].content) }
        let prompt = turns.map { ($0.role == "assistant" ? "Tú" : "Interlocutor") + ": " + $0.content }.joined(separator: "\n\n")
            + "\n\nContesta ahora como «Tú», solo con tu siguiente intervención."
        return (system, prompt)
    }
}
