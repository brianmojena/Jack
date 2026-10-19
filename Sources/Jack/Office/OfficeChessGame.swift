import Foundation
import JackCore

/// Una partida de ajedrez entre dos personajes de la oficina. Cada uno interpreta a un maestro: Gemma (en su papel) mira la foto
/// del tablero y elige la jugada; el personaje piensa, mueve la pieza con la mano y comenta la jugada en su bocadillo.
@MainActor final class OfficeChessGame: ObservableObject {
    struct Player: Equatable {
        var slot: Int
        var master: ChessMaster
        var color: ChessColor
    }

    enum Phase: Equatable {
        /// Sin partida.
        case idle
        /// Los jugadores van a la mesa y se sientan.
        case seating
        case playing
        /// Terminó: se celebra, se lamenta y se levantan.
        case finishing
    }

    @Published private(set) var players: [Player] = []
    @Published private(set) var phase = Phase.idle
    /// Lo que dice cada jugador en su bocadillo, por puesto.
    @Published private(set) var said: [Int: String] = [:]
    private(set) var game = ChessGame()
    private var task: Task<Void, Never>?
    private let advisor = OfficeChessPlayer()

    var isActive: Bool { phase != .idle }

    func involves(_ slot: Int) -> Bool { players.contains { $0.slot == slot } }

    func seat(of slot: Int) -> ChessColor? { players.first { $0.slot == slot }?.color }

    /// Dos maestros distintos al azar.
    static func randomMasters() -> (ChessMaster, ChessMaster) {
        let shuffled = ChessMasters.all.shuffled()
        return (shuffled[0], shuffled[1])
    }

    func start(white: Player, black: Player, stage: OfficeStage, lightMode: @escaping @MainActor () -> Bool) {
        guard phase == .idle, stage.chess != nil, white.slot != black.slot else { return }
        players = [white, black]
        said = [:]
        game = ChessGame()
        phase = .seating
        task = Task { [weak self] in await self?.run(stage: stage, lightMode: lightMode) }
    }

    /// Termina la partida (con lo que haya en el tablero): los dos jugadores se levantan y vuelven a su sofá.
    func stop(stage: OfficeStage?) {
        task?.cancel()
        task = nil
        stage?.chess?.reset()
        for player in players { stage?.actors[safe: player.slot]?.chessMood = .waiting }
        players = []
        said = [:]
        phase = .idle
    }

    private func say(_ slot: Int, _ text: String?) {
        if let text { said[slot] = text } else { said[slot] = nil }
    }

    // MARK: - La partida

    private func run(stage: OfficeStage, lightMode: @escaping @MainActor () -> Bool) async {
        guard let chess = stage.chess else { return }
        chess.reset()
        chess.onLand = { OfficeSound.select.play() }
        // Esperar a que los dos estén sentados.
        var waited = 0.0
        while !players.allSatisfy({ stage.actors[safe: $0.slot]?.isSeatedAtChess == true }) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            waited += 0.25
            if waited > 120 { stop(stage: stage); return }
        }
        phase = .playing
        try? await Task.sleep(for: .milliseconds(600))
        var failures = 0
        var aborted = false
        while !game.outcome.isOver {
            guard !Task.isCancelled else { return }
            let color = game.position.turn
            guard let me = players.first(where: { $0.color == color }), let rival = players.first(where: { $0.color != color }),
                  let actor = stage.actors[safe: me.slot], let layout = stage.layout else { break }
            actor.chessMood = .thinking
            say(me.slot, "Déjame pensar…")
            let started = Date()
            let choice: ChessChoice
            do {
                choice = try await advisor.choose(game: game, as: me.master, against: rival.master, color: color,
                                                  playedBy: layout.slots[me.slot].name, lightMode: lightMode())
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                guard failures < 3 else {
                    say(me.slot, "No consigo pensar la jugada (\(error.localizedDescription)). Lo dejamos aquí.")
                    aborted = true
                    break
                }
                say(me.slot, "Perdona, me he despistado un momento…")
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            guard !Task.isCancelled else { return }
            // Al menos un momento pensando, aunque Gemma conteste enseguida.
            let thought = Date().timeIntervalSince(started)
            if thought < 1.4 { try? await Task.sleep(for: .milliseconds(Int((1.4 - thought) * 1000))) }
            guard !Task.isCancelled else { return }
            actor.chessMood = .moving
            say(me.slot, choice.comment.isEmpty ? choice.san : "\(choice.san) · \(choice.comment)")
            // La mano llega al tablero y, entonces, la pieza se mueve.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let effects = game.position.effects(of: choice.move)
            game.play(choice.move)
            await chess.play(choice.move, effects: effects)
            for _ in 0..<40 where actor.chessMood == .moving {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !Task.isCancelled else { return }
        phase = .finishing
        if aborted {
            try? await Task.sleep(for: .seconds(4))
        } else {
            finishMoods(stage: stage)
            try? await Task.sleep(for: .seconds(8))
        }
        guard !Task.isCancelled else { return }
        stop(stage: nil)
    }

    private func finishMoods(stage: OfficeStage) {
        let outcome = game.outcome
        for player in players {
            guard let actor = stage.actors[safe: player.slot] else { continue }
            if let winner = outcome.winner {
                if player.color == winner {
                    actor.chessMood = .won
                    say(player.slot, "¡Jaque mate! Gracias por la partida.")
                } else {
                    actor.chessMood = .lost
                    say(player.slot, "No lo vi venir… Enhorabuena.")
                }
            } else {
                actor.chessMood = .waiting
                say(player.slot, "Tablas: \(outcome.title.replacingOccurrences(of: "tablas ", with: "")). Buena partida.")
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
