import Foundation
import JackCore

/// Una partida de ajedrez entre dos personajes de la oficina. Cada uno interpreta a un maestro: Gemma (en su papel) mira la foto
/// del tablero y elige la jugada; el personaje piensa, mueve la pieza con la mano y comenta la jugada en su bocadillo.
///
/// También puede jugarla el usuario contra un personaje: se sienta en la otra silla (la cámara pasa a su sitio), mueve sus piezas
/// pulsándolas, chatea con el maestro mientras juegan y puede levantarse a ver la oficina sin que la partida se acabe.
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

    /// Una línea de la charla de la mesa, con quien juega contra el personaje.
    struct ChatLine: Identifiable, Equatable {
        let id = UUID()
        var fromMe: Bool
        var text: String
    }

    @Published private(set) var players: [Player] = []
    @Published private(set) var phase = Phase.idle
    /// Lo que dice cada jugador en su bocadillo, por puesto.
    @Published private(set) var said: [Int: String] = [:]
    @Published private(set) var game = ChessGame()
    /// El color con el que juega el usuario; `nil` si la partida es entre dos personajes. En ese caso `players` solo lleva al personaje.
    @Published private(set) var human: ChessColor?
    /// El usuario está sentado a la mesa (con la cámara en su silla). Puede levantarse y volver a sentarse con la partida en marcha.
    @Published private(set) var humanSeated = false
    /// Le toca mover al usuario y la partida lo espera.
    @Published private(set) var awaitingMove = false
    @Published private(set) var chat: [ChatLine] = []
    /// El maestro está escribiendo la respuesta a un mensaje.
    @Published private(set) var replying = false
    private var humanName = "Tú"
    private var moveWaiter: CheckedContinuation<ChessMove?, Never>?
    private var replyTask: Task<Void, Never>?
    private var chairTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private let advisor = OfficeChessPlayer()
    /// Cómo se llama cada puesto (el nombre de su avatar).
    private var names: [Int: String] = [:]

    var isActive: Bool { phase != .idle }

    func involves(_ slot: Int) -> Bool { players.contains { $0.slot == slot } }

    func seat(of slot: Int) -> ChessColor? { players.first { $0.slot == slot }?.color }

    /// Dos maestros distintos al azar.
    static func randomMasters() -> (ChessMaster, ChessMaster) {
        let shuffled = ChessMasters.all.shuffled()
        return (shuffled[0], shuffled[1])
    }

    func start(white: Player, black: Player, stage: OfficeStage, names: [Int: String], lightMode: @escaping @MainActor () -> Bool) {
        guard phase == .idle, stage.chess != nil, white.slot != black.slot else { return }
        players = [white, black]
        human = nil
        begin(stage: stage, names: names, lightMode: lightMode)
    }

    /// El usuario juega contra `opponent` (que lleva el color contrario al suyo): el personaje va a la mesa y, cuando se sienta, el
    /// usuario también.
    func start(against opponent: Player, as humanName: String, stage: OfficeStage, names: [Int: String], lightMode: @escaping @MainActor () -> Bool) {
        guard phase == .idle, stage.chess != nil else { return }
        players = [opponent]
        human = opponent.color.opposite
        self.humanName = humanName
        begin(stage: stage, names: names, lightMode: lightMode)
        // Su silla se aparta para sentarse en ella cuando llegue el rival.
        slideChair(to: 1.5, stage: stage)
    }

    private func begin(stage: OfficeStage, names: [Int: String], lightMode: @escaping @MainActor () -> Bool) {
        self.names = names
        said = [:]
        chat = []
        replying = false
        game = ChessGame()
        phase = .seating
        task = Task { [weak self] in await self?.run(stage: stage, lightMode: lightMode) }
    }

    /// Termina la partida (con lo que haya en el tablero): los jugadores se levantan y el personaje vuelve a su sofá.
    func stop(stage: OfficeStage?) {
        task?.cancel()
        task = nil
        replyTask?.cancel()
        replyTask = nil
        chairTask?.cancel()
        chairTask = nil
        resumeWaiter(with: nil)
        stage?.chess?.reset()
        if let human, let chess = stage?.chess { chess.setChair(human, offset: 0) }
        for player in players { stage?.actors[safe: player.slot]?.chessMood = .waiting }
        players = []
        human = nil
        humanSeated = false
        awaitingMove = false
        replying = false
        chat = []
        said = [:]
        phase = .idle
    }

    // MARK: - El usuario en la mesa

    /// Se sienta a la mesa (la silla se acerca y la cámara pasa a su sitio, que lo hace la vista al verlo).
    func sit(stage: OfficeStage?) {
        guard human != nil, phase != .idle, !humanSeated else { return }
        humanSeated = true
        slideChair(to: 0, stage: stage, duration: 0.9)
    }

    /// Se levanta a ver la oficina; la partida y el rival se quedan esperando.
    func standUp(stage: OfficeStage?) {
        guard humanSeated else { return }
        humanSeated = false
        slideChair(to: 1.5, stage: stage)
    }

    private func slideChair(to offset: Float, stage: OfficeStage?, duration: Double = 0.7) {
        guard let human, let chess = stage?.chess else { return }
        chairTask?.cancel()
        chairTask = Task { await chess.slideChair(human, to: offset, duration: duration) }
    }

    /// Las jugadas legales del usuario desde `square` (vacío si no le toca o la casilla no es suya).
    func moves(from square: Int) -> [ChessMove] {
        guard awaitingMove else { return [] }
        return game.position.legalMoves().filter { $0.from == square }
    }

    /// El usuario mueve: `from` y `to` de una jugada legal (la coronación es siempre a dama).
    @discardableResult
    func move(from: Int, to: Int) -> Bool {
        let options = moves(from: from).filter { $0.to == to }
        guard let move = options.first(where: { $0.promotion == .queen }) ?? options.first else { return false }
        resumeWaiter(with: move)
        return true
    }

    private func resumeWaiter(with move: ChessMove?) {
        let waiter = moveWaiter
        moveWaiter = nil
        waiter?.resume(returning: move)
    }

    private func waitForHumanMove() async -> ChessMove? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ChessMove?, Never>) in
                if Task.isCancelled { continuation.resume(returning: nil) } else { moveWaiter = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(with: nil) }
        }
    }

    // MARK: - Charla

    /// Lo último que se han dicho, con el nombre de cada uno, para que el maestro lo tenga presente.
    private func recentChat(opponentName: String) -> [String] {
        chat.suffix(6).map { "\($0.fromMe ? humanName : opponentName): \($0.text)" }
    }

    /// El usuario le escribe al maestro; contesta en su bocadillo y en la charla de la mesa.
    func send(_ text: String, lightMode: @escaping @MainActor () -> Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard human != nil, let opponent = players.first, !message.isEmpty, !replying else { return }
        let opponentName = names[opponent.slot] ?? "Rival"
        let before = recentChat(opponentName: opponentName)
        chat.append(ChatLine(fromMe: true, text: message))
        replying = true
        replyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.replying = false }
            do {
                let answer = try await self.advisor.reply(to: message, game: self.game, as: opponent.master, color: opponent.color, playedBy: opponentName,
                                                          rivalName: self.humanName, chat: before, lightMode: lightMode())
                guard !Task.isCancelled else { return }
                // Un momento escribiendo, como una persona.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.phase != .idle else { return }
                self.chat.append(ChatLine(fromMe: false, text: answer))
                self.say(opponent.slot, answer)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.phase != .idle else { return }
                self.say(opponent.slot, "Perdona, me he distraído. ¿Qué decías?")
            }
        }
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
        // El usuario se sienta cuando su rival ya está en su silla.
        if human != nil { sit(stage: stage) }
        try? await Task.sleep(for: .milliseconds(600))
        var failures = 0
        var aborted = false
        while !game.outcome.isOver {
            guard !Task.isCancelled else { return }
            let color = game.position.turn
            // Le toca al usuario: la partida espera lo que haga falta (aunque se levante a ver la oficina).
            if color == human {
                for player in players { stage.actors[safe: player.slot]?.chessMood = .waiting }
                awaitingMove = true
                let mine = await waitForHumanMove()
                awaitingMove = false
                guard !Task.isCancelled, let mine else { return }
                let effects = game.position.effects(of: mine)
                game.play(mine)
                await chess.play(mine, effects: effects)
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }
            guard let me = players.first(where: { $0.color == color }),
                  let actor = stage.actors[safe: me.slot], let layout = stage.layout else { break }
            let rival = players.first(where: { $0.color != color })
            actor.chessMood = .thinking
            say(me.slot, "Déjame pensar…")
            let started = Date()
            let choice: ChessChoice
            do {
                let name = names[me.slot] ?? layout.slots[me.slot].name
                choice = try await advisor.choose(game: game, as: me.master, against: rival?.master, color: color, playedBy: name,
                                                  rivalName: human == nil ? nil : humanName, chat: recentChat(opponentName: name), lightMode: lightMode())
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
            // La partida con el usuario se queda en pantalla hasta que la cierre él.
            if human != nil { return }
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
