import Foundation

/// Quien pinta el cuadro: Gemma 4 31B Cloud, como la persona que está ante la pizarra. Se elige un cuadro famoso al azar, se busca su
/// imagen en internet (Wikimedia Commons) y Gemma, que la ve, lo reproduce a su manera como un SVG. Si no responde o lo que da no
/// sirve, se usa uno de los dibujos de reserva.
@MainActor public final class OfficeSketchArtist {
    var inspectModel: @MainActor () async throws -> StellarModel = {
        try await StellarModels.inspectOllamaModel(named: OfficeNarrator.modelName, includeCloud: true)
    }
    var streamRequest: @MainActor (StellarModel, [StellarMessage], Int) throws -> AsyncThrowingStream<StellarChunk, Error> = { model, messages, context in
        try StellarClient.stream(server: model.server, model: model.name, messages: messages, tools: nil, contextLength: context, timeout: 150)
    }
    private var model: StellarModel?
    /// El último título, para no repetir el mismo dibujo dos veces seguidas.
    public private(set) var last: String?
    /// Quien busca las fotos de inspiración y lo último que se buscó (para que no se repita).
    var finder = OfficeInspirationFinder()
    private var searched: [String] = []

    public init() {}

    /// Pinta un cuadro famoso a su manera: el modelo escribe el programa que lo dibuja. Con `lightMode` no se pide nada al modelo.
    public func paint(as name: String, persona: String? = nil, brain: OfficeBrainChoice? = nil, lightMode: Bool) async throws -> OfficeDrawing {
        guard !lightMode else { throw CancellationError() }
        // Primero se elige un cuadro famoso y se busca su imagen en internet (sin ella, se pinta de memoria).
        let work = OfficeInspirationFinder.pick(excluding: searched)
        searched.append(work.title)
        if searched.count > 20 { searched.removeFirst() }
        var inspiration = try await finder.inspire(by: work)
        // Los CLI (Claude Code, Codex, OpenCode) no reciben imágenes: con ellos el cuadro se pinta de memoria.
        if let brain, brain.provider != .stellar { inspiration.image = nil; inspiration.fileTitle = nil }
        try Task.checkCancellation()
        let system = """
        Eres \(name) y estás de pie ante la pizarra de la oficina de Jack. Hoy te ha dado por pintar a tu manera un cuadro famoso: \
        «\(work.title)», de \(work.author). Lo pintas escribiendo un programa de JavaScript que dibuja en un canvas 2D.

        \(inspiration.image == nil
            ? "No has podido buscar el cuadro en internet: píntalo de memoria."
            : "Has buscado el cuadro en internet y te enseñan la imagen que has encontrado (si no fuera el cuadro, píntalo de memoria).")
        Haz una versión COMPLETA y reconocible: toda la composición, con el fondo incluido, los mismos personajes, objetos y paisaje en su \
        sitio y su paleta de colores, pero a tu manera (pinceladas, remolinos, manchas, degradados, un guiño gracioso si quieres). Que \
        parezca pintado, no un esquema.

        Responde SOLO con dos cosas: en la primera línea, el título («\(work.title), de \(work.author)» o tu versión del nombre) y a \
        continuación un único bloque de código ```js con el programa. Nada más: sin explicaciones.

        Reglas del programa:
        - Define una función `function pintar(ctx, w, h, p)`. `ctx` es el contexto 2D de un canvas de \(OfficeCanvasProgram.width) × \
        \(OfficeCanvasProgram.height) píxeles (`w` y `h` valen eso), ya en blanco. `p` va de 0 a 1.
        - Pinta el cuadro entero hasta el punto `p`: se llama muchas veces con `p` creciente y cada vez empiezas de cero, así que tiene que \
        ser determinista. Construye la lista de todo lo que pintas (capas de fondo, grandes manchas, pinceladas, detalles) de atrás hacia \
        delante y dibuja solo las primeras `Math.ceil(p * total)`. Con `p = 1` el cuadro está terminado; con `p = 0` no hay nada.
        - Nada de `Math.random()`: para el azar usa un generador con semilla fija creado dentro de `pintar` (por ejemplo mulberry32 con la \
        semilla 7). Sin animaciones ni temporizadores.
        - Solo la API del Canvas 2D y `Math`. Sin red, sin imágenes externas, sin DOM, sin `import`, `eval`, `fetch` ni almacenamiento.
        - Bucles acotados: menos de 40.000 pinceladas y nada de bucles infinitos; tiene que acabar en menos de un segundo.
        - Empieza con las capas grandes que cubren todo el lienzo (cielo, suelo, paredes) y termina con los detalles pequeños.\(OfficeNarrator.personaBlock(persona))
        """
        var user = "Pinta a tu manera «\(work.title)», de \(work.author)."
        var images: [String]?
        if let data = inspiration.image {
            user = "Esta es la imagen que has encontrado en internet" + (inspiration.fileTitle.map { " (archivo «\($0)»)" } ?? "") + ". " + user
            images = [data.base64EncodedString()]
        }
        var output = ""
        let messages = [StellarMessage(role: "system", content: system), StellarMessage(role: "user", content: user, images: images)]
        for try await chunk in try await chunks(messages, brain: brain) {
            try Task.checkCancellation()
            if case .text(let text) = chunk {
                output += text
                if output.utf8.count > OfficeCanvasProgram.sizeLimit + 2_000 { break }
            }
        }
        var program = try OfficeCanvasProgram.parse(output)
        program.title = work.label
        program.inspiration = inspiration.fileTitle == nil ? nil : work.label
        last = program.title
        return .program(program)
    }

    /// Lo mismo, pero sin fallar: si el modelo no responde o su programa no sirve, uno de los dibujos de reserva.
    public func paintOrFallback(as name: String, persona: String? = nil, brain: OfficeBrainChoice? = nil, lightMode: Bool) async throws -> OfficeDrawing {
        do {
            return try await paint(as: name, persona: persona, brain: brain, lightMode: lightMode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback()
        }
    }

    /// Un dibujo de reserva, distinto del último.
    public func fallback() -> OfficeDrawing {
        let drawing = OfficeSketch.fallback(excluding: last)
        last = drawing.title
        return .vector(drawing)
    }

    /// El texto que va diciendo el modelo: el elegido para el personaje (`brain`) o, sin elegir, Gemma.
    private func chunks(_ messages: [StellarMessage], brain: OfficeBrainChoice?) async throws -> AsyncThrowingStream<StellarChunk, Error> {
        if let brain { return try OfficeBrain.stream(messages, choice: brain, timeout: 180) }
        let model = try await verifiedModel()
        try Task.checkCancellation()
        let context = min(model.contextLength ?? StellarServer.defaultContextLength, 16_384)
        return try streamRequest(model, messages, context)
    }

    private func verifiedModel() async throws -> StellarModel {
        if let model { return model }
        let found = try await inspectModel()
        guard found.name == OfficeNarrator.modelName, found.server == StellarServer.builtIn[0], found.isCloud else {
            throw StellarError.message("La pizarra necesita \(OfficeNarrator.modelName) verificado en Ollama Cloud.")
        }
        model = found
        return found
    }
}
