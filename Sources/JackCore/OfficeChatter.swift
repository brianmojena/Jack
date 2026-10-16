import Foundation

/// Oficina 3D (modo Normal): dos personas en el sofá charlan de verdad. Cada línea la escribe Gemma 4 31B Cloud como esa persona,
/// viendo lo que se ha dicho hasta ahora; el tema sale de una semilla al azar y la primera persona lo saca como si se le acabara
/// de ocurrir.
@MainActor public final class OfficeChatter {
    var inspectModel: @MainActor () async throws -> StellarModel = {
        try await StellarModels.inspectOllamaModel(named: OfficeNarrator.modelName, includeCloud: true)
    }
    var streamRequest: @MainActor (StellarModel, [StellarMessage], Int) throws -> AsyncThrowingStream<StellarChunk, Error> = { model, messages, context in
        try StellarClient.stream(server: model.server, model: model.name, messages: messages, tools: nil, contextLength: context, timeout: 45)
    }
    private var model: StellarModel?

    public init() {}

    /// Lo que se ha dicho: quién y qué.
    public struct Line: Equatable, Sendable {
        public var speaker: String
        public var text: String

        public init(speaker: String, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// Ámbitos donde buscar un tema curioso; se elige uno al azar (y un detalle más) para que cada charla sea distinta.
    static let seeds = [
        "un animal con una habilidad rarísima", "algo del espacio que parece mentira", "un invento que nació por accidente",
        "una costumbre curiosa de otro país", "un error famoso de la historia", "algo que cuenta el cuerpo humano que casi nadie sabe",
        "la comida: un ingrediente con una historia sorprendente", "una película o serie y un dato de rodaje", "una palabra o expresión con un origen curioso",
        "el mar y lo poco que se conoce de él", "un experimento de psicología", "un récord absurdo",
        "una paradoja o acertijo que enreda", "la música: cómo se hizo una canción famosa", "un lugar del mundo que parece inventado",
        "un videojuego y un truco o historia detrás", "una teoría científica que cambió todo", "un fallo curioso de la tecnología",
        "los sueños y el sueño", "una pregunta tonta que no es tan tonta", "un deporte con reglas raras", "las matemáticas en la vida diaria"
    ]

    public static func randomSeed() -> String { seeds.randomElement() ?? seeds[0] }

    /// La siguiente línea de `name`, que charla con `other`. Si `transcript` está vacío, abre la charla con un tema curioso.
    public func line(as name: String, persona: String? = nil, with other: String, otherAbout: String? = nil, seed: String, transcript: [Line], lightMode: Bool) async throws -> String {
        guard !lightMode else { throw CancellationError() }
        let system = """
        Eres \(name) y trabajas en la oficina de Jack. Ahora estás en el sofá, de descanso, charlando con \(other), una compañera o \
        compañero de trabajo. Habláis como dos personas reales con confianza: español natural y cercano, frases cortas, con \
        humor cuando venga a cuento. Nada de «¡Claro!», ni de sonar a asistente, ni listas, ni Markdown, ni emojis, ni \
        comillas alrededor de lo que dices, ni empezar con tu nombre.

        Escribe SOLO tu siguiente intervención: una o dos frases (como mucho 170 caracteres). Reacciona a lo último que dijo \
        \(other) y aporta algo nuevo: un dato concreto, una anécdota, una duda o una opinión (puedes llevar la contraria con \
        simpatía). Alterna: a veces pregunta, a veces cuenta. No repitas lo ya dicho ni saludes otra vez. Si la charla se queda sin \
        gas, cambia de tema con naturalidad a otra cosa curiosa.
        \(OfficeNarrator.personaBlock(persona))\(otherAbout.map { "\nCon quien hablas: \($0)\n" } ?? "")
        """
        var messages = [StellarMessage(role: "system", content: system)]
        if transcript.isEmpty {
            messages.append(StellarMessage(role: "user", content: "Abre tú la charla con \(other): saca un tema curioso e interesante (un dato concreto y sorprendente, nada genérico) sobre «\(seed)», como si se te acabara de ocurrir. Una o dos frases, y acaba invitándole a opinar o a contar algo."))
        } else {
            for line in transcript.suffix(14) {
                let text = StellarTools.prefixUTF8(line.text, bytes: 600)
                messages.append(StellarMessage(role: line.speaker == name ? "assistant" : "user", content: text))
            }
            if messages.count > 1, messages[1].role == "assistant" { messages.insert(StellarMessage(role: "user", content: "(La charla acaba de empezar.)"), at: 1) }
            if messages.last?.role == "assistant" { messages.append(StellarMessage(role: "user", content: "(\(other) espera a que sigas hablando.)")) }
        }
        let model = try await verifiedModel()
        try Task.checkCancellation()
        let context = min(model.contextLength ?? StellarServer.defaultContextLength, 8_192)
        var output = ""
        for try await chunk in try streamRequest(model, messages, context) {
            try Task.checkCancellation()
            if case .text(let text) = chunk {
                output += text
                if output.count > 700 { break }
            }
        }
        guard let cleaned = OfficeNarrator.clean(output, limit: 220), !cleaned.isEmpty else { throw StellarError.message("Gemma no dijo nada.") }
        return cleaned
    }

    private func verifiedModel() async throws -> StellarModel {
        if let model { return model }
        let found = try await inspectModel()
        guard found.name == OfficeNarrator.modelName, found.server == StellarServer.builtIn[0], found.isCloud else {
            throw StellarError.message("La charla necesita \(OfficeNarrator.modelName) verificado en Ollama Cloud.")
        }
        model = found
        return found
    }
}
