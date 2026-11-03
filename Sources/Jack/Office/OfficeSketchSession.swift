import Foundation
#if canImport(JackCore)
import JackCore
#endif

#if os(macOS)

/// Un personaje se para ante la pizarra y pinta a su manera un cuadro famoso elegido al azar: mientras camina hasta ella, Gemma escribe
/// el programa del cuadro (JavaScript para un canvas); al llegar, la pizarra se borra y el cuadro va apareciendo mientras su brazo
/// garabatea. Al acabar baja el rotulador y vuelve a su sofá. Lo que dice (qué va a pintar) se ve en su bocadillo.
@MainActor final class OfficeSketchSession: ObservableObject {
    /// Quién dibuja y lo que dice en su bocadillo.
    @Published private(set) var drawer: Int?
    @Published private(set) var said: [Int: String] = [:]
    private var task: Task<Void, Never>?
    private let artist = OfficeSketchArtist()

    /// Quién es: cómo se llama y, si su avatar tiene personalidad, cómo es.
    struct Person {
        var name: String
        var profile: String?
        /// El modelo con que piensa; sin elegir, Gemma.
        var brain: OfficeBrainChoice?
    }

    var isActive: Bool { drawer != nil }
    static let isAvailable = true

    func involves(_ slot: Int) -> Bool { drawer == slot }

    func start(slot: Int, person: Person, stage: OfficeStage, lightMode: @escaping @MainActor () -> Bool) {
        guard !isActive, stage.whiteboard != nil, stage.drawing == nil else { return }
        drawer = slot
        said = [:]
        stage.startDrawing(slot: slot)
        task = Task { [weak self] in await self?.run(slot: slot, person: person, stage: stage, lightMode: lightMode) }
    }

    /// Para lo que esté haciendo: baja el rotulador y vuelve al sofá (el dibujo que hubiera se queda en la pizarra).
    func stop(stage: OfficeStage) {
        task?.cancel()
        task = nil
        stage.releaseDrawer()
        drawer = nil
        said = [:]
    }

    private func run(slot: Int, person: Person, stage: OfficeStage, lightMode: @escaping @MainActor () -> Bool) async {
        guard let board = stage.whiteboard else { return stop(stage: stage) }
        // Mientras camina hasta la pizarra, se le ocurre el dibujo.
        let request = Task { @MainActor in
            try await artist.paintOrFallback(as: person.name, persona: person.profile, brain: person.brain, lightMode: lightMode())
        }
        defer { request.cancel() }
        // Hasta que llegue (si no puede ir, `stage.drawing` se libera enseguida).
        var waited = 0.0
        while !stage.isDrawing(slot: slot) {
            guard !Task.isCancelled, stage.drawing == slot, waited < 60 else { return finish(slot: slot, stage: stage) }
            try? await Task.sleep(for: .milliseconds(150))
            waited += 0.15
        }
        board.clear()
        said[slot] = "Déjame buscar un cuadro famoso en internet…"
        var drawing: OfficeDrawing
        do {
            drawing = try await request.value
        } catch {
            if !Task.isCancelled { said[slot] = "Hoy no se me ocurre nada…" }
            try? await Task.sleep(for: .seconds(2.5))
            return finish(slot: slot, stage: stage)
        }
        guard !Task.isCancelled else { return }
        // Un programa solo se enseña si carga y pinta algo; si no, uno de los dibujos de reserva.
        let runner = OfficeCanvasRunner()
        defer { runner.close() }
        if case .program(let program) = drawing {
            do { _ = try await runner.validate(program) } catch {
                guard !Task.isCancelled else { return }
                drawing = artist.fallback()
            }
        }
        guard !Task.isCancelled else { return }
        said[slot] = "Voy a pintar mi versión de \(drawing.title)."
        switch drawing {
        case .program(let program): await board.reveal(program, with: runner, over: 16)
        // Tarda más cuanto más lleva el dibujo, sin pasarse.
        case .vector(let sketch): await board.reveal(sketch, over: min(max(Double(sketch.shapeCount) * 0.4, 6), 14))
        }
        guard !Task.isCancelled else { return }
        said[slot] = "¡Listo! Mi versión de \(drawing.title)."
        try? await Task.sleep(for: .seconds(3.5))
        finish(slot: slot, stage: stage)
    }

    /// Suelta el rotulador y, cuando vuelve al sofá, termina la sesión.
    private func finish(slot: Int, stage: OfficeStage) {
        guard !Task.isCancelled else { return }
        stage.releaseDrawer()
        said[slot] = nil
        task = Task { [weak self] in
            var waited = 0.0
            while stage.drawing == slot, waited < 30, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 0.2
            }
            guard !Task.isCancelled else { return }
            self?.drawer = nil
            self?.said = [:]
            self?.task = nil
        }
    }
}
#else

/// En el iPhone todavía no se dibuja en la pizarra (el dibujo se pinta con AppKit y WebKit de la Mac).
@MainActor final class OfficeSketchSession: ObservableObject {
    struct Person {
        var name: String
        var profile: String?
        var brain: OfficeBrainChoice?
    }

    @Published private(set) var drawer: Int?
    @Published private(set) var said: [Int: String] = [:]
    static let isAvailable = false
    var isActive: Bool { false }
    func involves(_ slot: Int) -> Bool { false }
    func start(slot: Int, person: Person, stage: OfficeStage, lightMode: @escaping @MainActor () -> Bool) {}
    func stop(stage: OfficeStage) {}
}
#endif
