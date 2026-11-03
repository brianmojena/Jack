import Foundation
#if canImport(JackCore)
import JackCore
#endif
import SwiftUI

/// Una partida de cartas en la mesa de la oficina: el usuario contra dos compañeros (Mentiroso, póker) o contra uno que hace de
/// crupier (blackjack). Las reglas viven en JackCore; aquí se llevan los turnos, se mueven las cartas en 3D, juegan los
/// compañeros (reglas + una IA sencilla) y hablan con la voz de Gemma, y se le pregunta al usuario lo que le toca decidir.
@MainActor final class OfficeCardSession: ObservableObject {
    enum Game: String, CaseIterable, Identifiable {
        case liar, poker, blackjack

        var id: String { rawValue }
        var title: String { ["liar": "Mentiroso", "poker": "Póker", "blackjack": "Blackjack"][rawValue]! }
        var symbol: String { ["liar": "theatermasks.fill", "poker": "suit.spade.fill", "blackjack": "suit.diamond.fill"][rawValue]! }
        var blurb: String {
            switch self {
            case .liar: "Tú y dos compañeros. Se juegan cartas boca abajo diciendo qué son; si crees que mienten, ¡acúsalos!"
            case .poker: "Texas hold'em contra dos compañeros, con fichas, faroles y charla."
            case .blackjack: "Contra el crupier: acércate a 21 sin pasarte."
            }
        }
        /// Cuántos compañeros hacen falta.
        var opponents: Int { self == .blackjack ? 1 : 2 }
        /// «el Mentiroso», para las frases.
        var phrase: String { ["liar": "el Mentiroso", "poker": "el póker", "blackjack": "el blackjack"][rawValue]! }
    }

    struct Person {
        var slot: Int
        var name: String
        var profile: String?
        /// El modelo con que piensa; sin elegir, Gemma.
        var brain: OfficeBrainChoice?
    }

    struct Player: Identifiable, Equatable {
        /// El orden en la mesa: 0 es el usuario.
        var id: Int
        /// El puesto de la oficina; `nil` es el usuario.
        var slot: Int?
        var name: String
        var seat: String
        var profile: String?
        /// El modelo con que piensa; sin elegir, Gemma.
        var brain: OfficeBrainChoice?
        var isHuman: Bool { slot == nil }
    }

    enum Phase: Equatable {
        case idle
        /// Los compañeros van a la mesa.
        case seating
        case playing
        case finished
    }

    struct PokerOptions: Equatable {
        var toCall: Int
        var canCheck: Bool
        var raise: ClosedRange<Int>?
        var pot: Int
        var stack: Int
    }

    /// Lo que se le pregunta al usuario.
    enum Prompt: Equatable {
        case bet(chips: Int)
        case blackjack(canDouble: Bool)
        case liarPlay(rank: CardRank)
        case liarRespond(claim: String)
        case poker(PokerOptions)
        case next(String)
    }

    enum Input {
        case bet(Int)
        case blackjack(BlackjackAction)
        case liarPlay([PlayingCard])
        case liarCall(Bool)
        case poker(PokerAction)
        case next
    }

    @Published private(set) var game: Game?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var players: [Player] = []
    @Published private(set) var humanSeated = false
    /// Lo que dice cada compañero en su bocadillo, por puesto.
    @Published private(set) var said: [Int: String] = [:]
    @Published private(set) var chat: [OfficeChessGame.ChatLine] = []
    @Published private(set) var replying = false
    @Published private(set) var prompt: Prompt?
    /// Las líneas de estado de arriba (bote, turno, fichas…).
    @Published private(set) var hud: [String] = []
    /// El resultado de la mano o la partida, en grande.
    @Published private(set) var banner: String?
    @Published private(set) var liar: LiarGame?
    @Published private(set) var poker: PokerTable?
    @Published private(set) var blackjack: BlackjackTable?
    /// Las cartas que el usuario va eligiendo de su mano en el Mentiroso.
    @Published var selection: Set<PlayingCard> = []

    private weak var stage: OfficeStage?
    private var table: OfficeCardTable?
    private var task: Task<Void, Never>?
    private var chairTask: Task<Void, Never>?
    private var talkTasks: [Task<Void, Never>] = []
    private var waiter: CheckedContinuation<Input?, Never>?
    private let talker = OfficeCardTalker()
    private var lightMode: @MainActor () -> Bool = { false }
    private var humanName = "Tú"
    private var talking: Set<Int> = []
    private var lastSpoke: [Int: Date] = [:]
    private var replyCount: [Int: Int] = [:]

    var isActive: Bool { phase != .idle }

    func involves(_ slot: Int) -> Bool { players.contains { $0.slot == slot } }

    /// En qué sitio de la mesa se sienta el personaje de ese puesto.
    func seat(of slot: Int) -> String? { players.first { $0.slot == slot }?.seat }

    var opponents: [Player] { players.filter { !$0.isHuman } }

    // MARK: - Empezar y terminar

    func start(_ game: Game, with people: [Person], as humanName: String, stage: OfficeStage, lightMode: @escaping @MainActor () -> Bool) {
        guard phase == .idle, let chess = stage.chess, people.count >= game.opponents else { return }
        self.stage = stage
        self.lightMode = lightMode
        self.humanName = humanName
        self.game = game
        let seats = ["white", "black", OfficeChessSet.northSeat]
        var made = [Player(id: 0, slot: nil, name: humanName, seat: seats[0], profile: nil)]
        for (index, person) in people.prefix(game.opponents).enumerated() {
            made.append(Player(id: index + 1, slot: person.slot, name: person.name, seat: seats[index + 1], profile: person.profile, brain: person.brain))
        }
        players = made
        said = [:]
        chat = []
        replying = false
        prompt = nil
        banner = nil
        selection = []
        liar = nil
        poker = nil
        blackjack = nil
        hud = []
        // La mesa se queda lisa: sin tablero ni piezas.
        chess.setVisible(false)
        table = OfficeCardTable(world: stage.world, center: SIMD3(chess.tableCenter.x, chess.tableTop, chess.tableCenter.y), seats: chess.seats)
        slideChair(to: 1.5)
        phase = .seating
        task = Task { [weak self] in await self?.run() }
    }

    /// Cierra la partida: se recoge la mesa, el tablero vuelve y los personajes se levantan.
    func stop() {
        task?.cancel()
        task = nil
        for talk in talkTasks { talk.cancel() }
        talkTasks = []
        chairTask?.cancel()
        chairTask = nil
        resume(with: nil)
        table?.tearDown()
        table = nil
        if let chess = stage?.chess {
            chess.setVisible(true)
            chess.setChair("white", offset: 0)
        }
        for player in players { mood(player.slot, .waiting) }
        players = []
        game = nil
        humanSeated = false
        phase = .idle
        said = [:]
        chat = []
        replying = false
        prompt = nil
        banner = nil
        hud = []
        liar = nil
        poker = nil
        blackjack = nil
        selection = []
        talking = []
    }

    // MARK: - El usuario en la mesa

    func sit() {
        guard game != nil, phase != .idle, !humanSeated else { return }
        humanSeated = true
        slideChair(to: 0, duration: 0.9)
    }

    func standUp() {
        guard humanSeated else { return }
        humanSeated = false
        slideChair(to: 1.5)
    }

    private func slideChair(to offset: Float, duration: Double = 0.7) {
        guard let chess = stage?.chess else { return }
        chairTask?.cancel()
        chairTask = Task { await chess.slideChair("white", to: offset, duration: duration) }
    }

    // MARK: - Lo que decide el usuario

    private func ask(_ prompt: Prompt) async -> Input? {
        guard !Task.isCancelled else { return nil }
        self.prompt = prompt
        let input = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Input?, Never>) in
                if Task.isCancelled { continuation.resume(returning: nil) } else { waiter = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(with: nil) }
        }
        self.prompt = nil
        return input
    }

    private func resume(with input: Input?) {
        let waiting = waiter
        waiter = nil
        waiting?.resume(returning: input)
    }

    /// Lo que elige el usuario (los botones de la interfaz).
    func submit(_ input: Input) {
        guard prompt != nil else { return }
        if case .liarPlay(let cards) = input {
            guard let liar, case .playing(let turn) = liar.phase, turn == 0, !cards.isEmpty, cards.count <= LiarGame.maxPlay,
                  cards.allSatisfy({ liar.hands[0].contains($0) }) else { return }
            selection = []
        }
        resume(with: input)
    }

    /// Elige o suelta una carta de la mano del Mentiroso (como mucho cuatro).
    func toggle(_ card: PlayingCard) {
        guard case .liarPlay? = prompt else { return }
        if selection.contains(card) { selection.remove(card) } else if selection.count < LiarGame.maxPlay { selection.insert(card) }
    }

    // MARK: - Hablar

    private func say(_ slot: Int?, _ text: String?) {
        guard let slot else { return }
        said[slot] = text
    }

    private func mood(_ slot: Int?, _ mood: OfficeChessMood) {
        guard let slot, let actor = stage?.actors[safe: slot] else { return }
        actor.chessMood = mood
    }

    private func speaker(for player: Player) -> OfficeCardTalker.Speaker {
        OfficeCardTalker.Speaker(name: player.name, profile: player.profile, game: game?.phrase ?? "las cartas",
                                 others: players.filter { $0.id != player.id }.map(\.name), brain: player.brain)
    }

    private func recentChat() -> [String] {
        chat.suffix(6).map { "\($0.speaker ?? ($0.fromMe ? humanName : "Rival")): \($0.text)" }
    }

    /// Un comentario de Gemma sobre lo que acaba de pasar, en su bocadillo; no más de uno cada pocos segundos por personaje.
    private func comment(_ player: Player, on event: String, secret: String? = nil, force: Bool = false) {
        guard let slot = player.slot, !talking.contains(slot) else { return }
        if !force, let last = lastSpoke[slot], Date().timeIntervalSince(last) < 9 { return }
        talking.insert(slot)
        let recent = recentChat()
        let light = lightMode
        let who = speaker(for: player)
        talkTasks.removeAll { $0.isCancelled }
        talkTasks.append(Task { [weak self] in
            guard let self else { return }
            defer { self.talking.remove(slot) }
            guard let text = try? await self.talker.comment(on: event, as: who, secret: secret, chat: recent, lightMode: light()),
                  !Task.isCancelled, self.phase != .idle else { return }
            self.lastSpoke[slot] = Date()
            self.say(slot, text)
        })
    }

    /// El usuario le escribe a la mesa; contesta el compañero al que se dirige o, si no, el que menos ha hablado.
    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase != .idle, !message.isEmpty, !replying else { return }
        let opponents = self.opponents
        guard !opponents.isEmpty else { return }
        let lowered = message.lowercased()
        let target = opponents.first { lowered.contains($0.name.lowercased()) }
            ?? opponents.min { (replyCount[$0.id] ?? 0) < (replyCount[$1.id] ?? 0) }!
        replyCount[target.id, default: 0] += 1
        let before = recentChat()
        chat.append(OfficeChessGame.ChatLine(fromMe: true, text: message))
        replying = true
        let light = lightMode
        let who = speaker(for: target)
        let state = hud.joined(separator: "; ")
        let name = humanName
        talkTasks.append(Task { [weak self] in
            guard let self else { return }
            defer { self.replying = false }
            do {
                let answer = try await self.talker.reply(to: message, from: name, as: who, state: state, chat: before, lightMode: light())
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.phase != .idle else { return }
                self.chat.append(OfficeChessGame.ChatLine(fromMe: false, text: answer, speaker: target.name))
                self.say(target.slot, answer)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.phase != .idle else { return }
                self.say(target.slot, "Perdona, me he distraído. ¿Qué decías?")
            }
        })
    }

    /// Cómo juega cada uno: se saca del nombre, así cada personaje tiene siempre el mismo carácter.
    private func trait(_ player: Player, _ salt: String, low: Double, high: Double) -> Double {
        let hash = (player.name + salt).unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 100_003 }
        return low + (high - low) * Double(hash % 100) / 100
    }

    // MARK: - La partida

    private func run() async {
        guard let stage, let game else { return }
        // Esperar a que los compañeros estén sentados.
        var waited = 0.0
        while !opponents.allSatisfy({ stage.actors[safe: $0.slot ?? -1]?.isSeatedAtChess == true }) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            waited += 0.25
            if waited > 120 { stop(); return }
        }
        phase = .playing
        sit()
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        switch game {
        case .blackjack: await runBlackjack()
        case .liar: await runLiar()
        case .poker: await runPoker()
        }
        guard !Task.isCancelled else { return }
        phase = .finished
        prompt = nil
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func thinkTime(_ player: Player, base: Double = 1.0) async {
        mood(player.slot, .thinking)
        await pause(base + Double.random(in: 0...1.2))
        mood(player.slot, .waiting)
    }

    // MARK: - Blackjack

    private func runBlackjack() async {
        guard let table, let dealer = opponents.first else { return }
        var game = BlackjackTable(chips: 500)
        blackjack = game
        let shoe = table.middle(viewer: "white", right: 1.6, forward: -0.2)
        await table.setStack("shoe", count: 40, at: shoe)
        while !Task.isCancelled {
            table.clear()
            await table.setStack("shoe", count: 40, at: shoe)
            banner = nil
            say(dealer.slot, nil)
            hud = ["Fichas: \(game.chips)"]
            guard game.chips > 0 else {
                banner = "Te has quedado sin fichas"
                return
            }
            guard case .bet(let amount)? = await ask(.bet(chips: game.chips)), game.deal(bet: amount) else { return }
            blackjack = game
            hud = ["Apuesta: \(game.bet)", "Fichas: \(game.chips)"]
            // Reparto: jugador, crupier (a la vista), jugador y crupier (tapada).
            var mine: [OfficeCardTable.Card] = []
            var theirs: [OfficeCardTable.Card] = []
            func deal(_ card: PlayingCard, to seat: String, faceUp: Bool) async -> OfficeCardTable.Card {
                let placed = await table.place(.face(card), at: shoe, faceUp: false)
                if seat == "white" { mine.append(placed) } else { theirs.append(placed) }
                let all = seat == "white" ? mine : theirs
                for (index, other) in all.enumerated() { table.slide(other, to: table.row(seat: seat, index: index, count: all.count, forward: 1.2), faceUp: other === placed ? faceUp : nil, duration: 0.4) }
                mood(dealer.slot, .moving)
                await pause(0.5)
                return placed
            }
            _ = await deal(game.player.cards[0], to: "white", faceUp: true)
            _ = await deal(game.dealer.cards[0], to: "black", faceUp: true)
            _ = await deal(game.player.cards[1], to: "white", faceUp: true)
            let hole = await deal(game.dealer.cards[1], to: "black", faceUp: false)
            mood(dealer.slot, .waiting)
            refreshBlackjackHUD(game, revealed: false)
            // Turno del jugador.
            while game.phase == .playerTurn {
                guard let input = await ask(.blackjack(canDouble: game.canDouble)), case .blackjack(let action) = input else { return }
                switch action {
                case .hit: game.hit()
                case .stand: game.stand()
                case .double: game.doubleDown()
                }
                blackjack = game
                if action != .stand, let card = game.player.cards.last {
                    _ = await deal(card, to: "white", faceUp: true)
                }
                refreshBlackjackHUD(game, revealed: false)
            }
            // Turno del crupier: destapa y pide hasta 17.
            if !game.player.isBust {
                table.slide(hole, to: hole.spot, faceUp: true, duration: 0.45)
                await pause(0.7)
                refreshBlackjackHUD(game, revealed: true)
                while game.phase == .dealerTurn, !Task.isCancelled {
                    mood(dealer.slot, .thinking)
                    await pause(0.8)
                    let drew = game.dealerDraws()
                    blackjack = game
                    if drew, let card = game.dealer.cards.last { _ = await deal(card, to: "black", faceUp: true) }
                    refreshBlackjackHUD(game, revealed: true)
                }
            } else {
                table.slide(hole, to: hole.spot, faceUp: true, duration: 0.45)
                await pause(0.6)
                refreshBlackjackHUD(game, revealed: true)
            }
            guard let outcome = game.outcome else { return }
            banner = "\(outcome.title) · fichas: \(game.chips)"
            mood(dealer.slot, outcome.playerWon ? .lost : (outcome == .push ? .waiting : .won))
            comment(dealer, on: "Reparto en el blackjack: tú eres el crupier, \(humanName) apostó \(game.bet) y tiene \(game.player.total) contra tus \(game.dealer.total). Resultado: \(outcome.title).",
                    force: true)
            refreshBlackjackHUD(game, revealed: true)
            if game.chips <= 0 {
                banner = "\(outcome.title) · te quedas sin fichas"
                return
            }
            guard await ask(.next("Otra mano")) != nil else { return }
        }
    }

    private func refreshBlackjackHUD(_ game: BlackjackTable, revealed: Bool) {
        var lines = ["Apuesta: \(game.bet) · Fichas: \(game.chips)"]
        let mine = game.player.cards.isEmpty ? "" : "Tú: \(game.player.total)\(game.player.isSoft ? " (blanda)" : "")"
        let dealerText: String
        if game.dealer.cards.isEmpty { dealerText = "" } else if revealed || game.isOver { dealerText = "Crupier: \(game.dealer.total)" } else {
            dealerText = "Crupier: \(BlackjackHand.points(game.dealer.cards[0].rank)) + ?"
        }
        lines.append([mine, dealerText].filter { !$0.isEmpty }.joined(separator: " · "))
        hud = lines.filter { !$0.isEmpty }
    }

    // MARK: - Mentiroso

    private func claimText(count: Int, rank: CardRank) -> String {
        let index = LiarGame.ranks.firstIndex(of: rank) ?? 0
        let plural = ["ases", "doses", "treses", "cuatros", "cincos", "seises", "sietes", "ochos", "nueves", "dieces", "jotas", "reinas", "reyes"][index]
        if count == 1 { return "\(rank == .queen || rank == .jack ? "Una" : "Un") \(Self.rankName(rank))." }
        return "\(["Dos", "Tres", "Cuatro"][min(count, 4) - 2]) \(plural)."
    }

    static func rankName(_ rank: CardRank) -> String {
        let singular = ["as", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez", "jota", "reina", "rey"]
        return singular[LiarGame.ranks.firstIndex(of: rank) ?? 0]
    }

    /// Cada jugador tiene delante un montón con sus cartas (el del usuario, en su sitio) y en el centro está el montón de la ronda.
    private func refreshLiarTable(_ game: LiarGame) async {
        guard let table else { return }
        for player in players {
            let id = "hand-\(player.id)"
            await table.setStack(id, count: game.hands[player.id].count, at: table.spot(seat: player.seat, forward: 1.55, right: player.isHuman ? 0 : 0))
        }
        await table.setStack("pile", count: game.pile.count, at: table.middle(viewer: "white"))
    }

    private func refreshLiarHUD(_ game: LiarGame) {
        var lines = ["Toca decir: \(Self.rankName(game.requiredRank))", "Montón: \(game.pile.count) cartas"]
        lines.append(players.map { "\($0.isHuman ? "Tú" : $0.name): \(game.hands[$0.id].count)" }.joined(separator: " · "))
        hud = lines
    }

    /// Una carta (un dorso) viaja entre dos sitios de la mesa.
    private func fly(count: Int, from: OfficeCardTable.Spot, to: OfficeCardTable.Spot) async {
        guard let table else { return }
        var flying: [OfficeCardTable.Card] = []
        for index in 0..<min(count, 4) {
            var start = from
            start.position.y += 0.05 + 0.01 * Float(index)
            let card = await table.place(nil, at: start, faceUp: false)
            flying.append(card)
            var end = to
            end.position.y += 0.05 + 0.01 * Float(index)
            table.slide(card, to: end, duration: 0.55)
            await pause(0.12)
        }
        await pause(0.55)
        for card in flying { table.remove(card) }
    }

    private func runLiar() async {
        guard let table else { return }
        var game = LiarGame(players: 3)
        liar = game
        await refreshLiarTable(game)
        let pileSpot = table.middle(viewer: "white")
        func handSpot(_ player: Player) -> OfficeCardTable.Spot { table.spot(seat: player.seat, forward: 1.55, right: 0) }
        while game.winner == nil, !Task.isCancelled {
            guard case .playing(let turn) = game.phase else { break }
            let player = players[turn]
            refreshLiarHUD(game)
            // Jugar.
            var chosen: [PlayingCard]
            if player.isHuman {
                guard case .liarPlay(let cards)? = await ask(.liarPlay(rank: game.requiredRank)) else { return }
                chosen = cards
            } else {
                await thinkTime(player)
                guard !Task.isCancelled else { return }
                var rng = SystemRandomNumberGenerator()
                let personality = LiarPersonality(bluff: trait(player, "b", low: 0.2, high: 0.65), suspicion: trait(player, "s", low: 0.3, high: 0.75))
                chosen = LiarAI.cards(hand: game.hands[turn], required: game.requiredRank, personality: personality, using: &rng)
            }
            guard game.play(chosen) else { continue }
            liar = game
            let claim = claimText(count: chosen.count, rank: game.requiredRank)
            say(player.slot, player.isHuman ? nil : claim)
            if player.isHuman { banner = "Dices: \(claim)" }
            mood(player.slot, .moving)
            await fly(count: chosen.count, from: handSpot(player), to: pileSpot)
            mood(player.slot, .waiting)
            await refreshLiarTable(game)
            if !player.isHuman, let lastPlay = game.lastPlay, !lastPlay.isHonest {
                comment(player, on: "Acabas de decir «\(claim)» al jugar tus cartas boca abajo.", secret: "Estás mintiendo: no son de ese valor.")
            }
            // Los demás deciden si acusan.
            var resolved = false
            while case .responding(let responder) = game.phase, !Task.isCancelled {
                let other = players[responder]
                var call = false
                if other.isHuman {
                    guard case .liarCall(let decision)? = await ask(.liarRespond(claim: "\(player.name): «\(claim)»")) else { return }
                    call = decision
                } else {
                    await thinkTime(other, base: 0.6)
                    var rng = SystemRandomNumberGenerator()
                    let personality = LiarPersonality(bluff: trait(other, "b", low: 0.2, high: 0.65), suspicion: trait(other, "s", low: 0.3, high: 0.75))
                    call = LiarAI.shouldChallenge(game: game, me: responder, personality: personality, using: &rng)
                }
                banner = nil
                if call {
                    say(other.slot, "¡Mentiroso!")
                    if other.isHuman { say(player.slot, nil) }
                    await pause(0.8)
                    guard let resolution = game.challenge() else { return }
                    liar = game
                    await reveal(resolution)
                    resolved = true
                    break
                } else {
                    game.pass()
                    liar = game
                }
            }
            _ = resolved
            for slot in players.compactMap(\.slot) { if said[slot] == "¡Mentiroso!" { said[slot] = nil } }
            await refreshLiarTable(game)
        }
        guard let winner = game.winner else { return }
        let winnerPlayer = players[winner]
        for player in opponents { mood(player.slot, player.id == winner ? .won : .lost) }
        banner = winner == 0 ? "¡Has ganado!" : "Gana \(winnerPlayer.name)"
        refreshLiarHUD(game)
        if winner != 0 {
            comment(winnerPlayer, on: "Te has quedado sin cartas y has ganado la partida.", force: true)
        } else {
            for player in opponents { comment(player, on: "\(humanName) se ha quedado sin cartas y ha ganado el Mentiroso.", force: true) }
        }
    }

    /// Se destapan las cartas que se jugaron, se dice quién se lleva el montón y las cartas viajan hasta él.
    private func reveal(_ resolution: LiarGame.Resolution) async {
        guard let table else { return }
        let taker = players[resolution.taker], caller = players[resolution.caller], liarPlayer = players[resolution.play.player]
        let cards = resolution.play.cards
        var shown: [OfficeCardTable.Card] = []
        let pileSpot = table.middle(viewer: "white")
        for (index, card) in cards.enumerated() {
            let placed = await table.place(.face(card), at: pileSpot, faceUp: false)
            shown.append(placed)
            let target = table.middle(viewer: "white", right: (Float(index) - Float(cards.count - 1) / 2) * 0.55, forward: 0.0, lift: 0.08)
            table.slide(placed, to: target, faceUp: true, duration: 0.5)
            await pause(0.15)
        }
        let claimed = Self.rankName(resolution.play.claim)
        banner = resolution.wasLie ? "¡Mentía! Eran: no \(claimed)" : "Decía la verdad: \(claimed)"
        say(liarPlayer.slot, resolution.wasLie ? "Vale, me has pillado…" : "¡Te lo dije!")
        mood(liarPlayer.slot, resolution.wasLie ? .lost : .won)
        await pause(2.4)
        let size = resolution.pileSize
        banner = "\(taker.isHuman ? "Te llevas" : "\(taker.name) se lleva") \(size) cartas"
        for card in shown { table.remove(card) }
        await fly(count: min(size, 4), from: pileSpot, to: table.spot(seat: taker.seat, forward: 1.55, right: 0))
        mood(liarPlayer.slot, .waiting)
        let event = "\(caller.name) acusó de mentiroso a \(liarPlayer.name) y \(resolution.wasLie ? "sí mentía" : "decía la verdad"); \(taker.name) se lleva \(size) cartas."
        for player in opponents { comment(player, on: event, secret: player.id == liarPlayer.id && resolution.wasLie ? "Tú eras quien mentía." : nil, force: player.id == taker.id) }
        banner = nil
    }

    // MARK: - Póker

    private func runPoker() async {
        guard let table else { return }
        var poker = PokerTable(stacks: [1000, 1000, 1000], dealer: Int.random(in: 0..<3))
        self.poker = poker
        // El mazo y las cartas que se retiran van a la esquina libre de la mesa (la del lado donde no se sienta nadie).
        let deck = table.middle(viewer: "white", right: 1.75, forward: 1.0)
        let muck = table.middle(viewer: "white", right: 1.75, forward: -1.1)
        // Las cartas de quien se sienta a un lado se colocan más lejos del centro para no pisar las cartas comunes.
        func holeForward(_ player: Player) -> Float { player.seat == "white" || player.seat == "black" ? 1.25 : 1.8 }
        var mucked = 0
        await table.setStack("deck", count: 30, at: deck)
        while !Task.isCancelled {
            table.clear()
            mucked = 0
            await table.setStack("deck", count: 30, at: deck)
            banner = nil
            for player in opponents { say(player.slot, nil); mood(player.slot, .waiting) }
            guard poker.startHand() else { break }
            self.poker = poker
            refreshPokerHUD(poker)
            // Dos cartas a cada uno, de una en una; las del usuario boca arriba.
            var holes: [Int: [OfficeCardTable.Card]] = [:]
            for round in 0..<2 {
                for player in players {
                    let card = poker.players[player.id].hole[round]
                    let placed = await table.place(.face(card), at: deck, faceUp: false)
                    holes[player.id, default: []].append(placed)
                    let count = 2
                    let spot = table.row(seat: player.seat, index: round, count: count, forward: holeForward(player))
                    table.slide(placed, to: spot, faceUp: player.isHuman, duration: 0.45)
                    await pause(0.3)
                }
            }
            var shownBoard: [OfficeCardTable.Card] = []
            func syncBoard() async {
                while shownBoard.count < poker.board.count {
                    let index = shownBoard.count
                    let placed = await table.place(.face(poker.board[index]), at: deck, faceUp: false)
                    shownBoard.append(placed)
                    table.slide(placed, to: table.middle(viewer: "white", right: (Float(index) - 2) * 0.5), faceUp: true, duration: 0.5)
                    await pause(0.45)
                }
            }
            while !poker.isHandOver, !Task.isCancelled {
                guard let seat = poker.toAct else { break }
                let player = players[seat]
                refreshPokerHUD(poker)
                var action: PokerAction
                if player.isHuman {
                    let options = PokerOptions(toCall: poker.toCall(seat), canCheck: poker.canCheck(seat), raise: poker.raiseRange(seat),
                                               pot: poker.totalPot, stack: poker.players[seat].stack)
                    guard case .poker(let chosen)? = await ask(.poker(options)) else { return }
                    action = chosen
                } else {
                    mood(player.slot, .thinking)
                    let snapshot = poker
                    let personality = PokerPersonality(aggression: trait(player, "a", low: 0.25, high: 0.85), bluff: trait(player, "b", low: 0.1, high: 0.5),
                                                       looseness: trait(player, "l", low: 0.2, high: 0.7))
                    let decision = Task.detached { () -> PokerAction in
                        var rng = SystemRandomNumberGenerator()
                        return PokerAI.decide(table: snapshot, seat: seat, personality: personality, trials: 220, using: &rng)
                    }
                    await pause(1.0 + Double.random(in: 0...1.0))
                    action = await decision.value
                    mood(player.slot, .waiting)
                }
                let before = poker.players[seat]
                // Una acción que no vale (pasar con apuesta por igualar) se cambia por la que corresponde.
                if !poker.apply(action) {
                    action = poker.canCheck(seat) ? .check : .call
                    poker.apply(action)
                }
                self.poker = poker
                let paid = before.stack - poker.players[seat].stack
                let text: String
                switch action {
                case .fold: text = "Me retiro."
                case .check: text = "Paso."
                case .call: text = poker.players[seat].allIn ? "¡Pago y voy all-in!" : "Pago \(paid)."
                case .raise: text = poker.players[seat].allIn ? "¡All-in!" : "Subo a \(poker.players[seat].bet)."
                }
                if player.isHuman { banner = "Tú: \(text.lowercased())" } else { say(player.slot, text); mood(player.slot, .moving) }
                if case .fold = action {
                    for card in holes[seat] ?? [] {
                        // Las cartas retiradas se apilan, algo torcidas, en la esquina.
                        var spot = muck
                        spot.position.y += 0.004 * Float(mucked)
                        spot.yaw += Float.random(in: -0.6...0.6)
                        mucked += 1
                        table.slide(card, to: spot, faceUp: false, duration: 0.5)
                    }
                }
                await pause(0.6)
                if !player.isHuman { mood(player.slot, .waiting) }
                banner = nil
                await syncBoard()
                refreshPokerHUD(poker)
            }
            await syncBoard()
            guard let result = poker.result else { break }
            // Se enseñan las cartas si hubo que llegar al final.
            if result.showdown {
                for player in opponents where !poker.players[player.id].folded {
                    for card in holes[player.id] ?? [] { table.slide(card, to: card.spot, faceUp: true, duration: 0.5) }
                }
                await pause(0.8)
            }
            let winners = result.winners.map { players[$0] }
            let names = winners.map { $0.isHuman ? "Tú" : $0.name }.joined(separator: " y ")
            let how = result.showdown ? " con \(winners.compactMap { result.scores[$0.id]?.title }.first ?? "")" : ""
            let won = result.payouts.values.reduce(0, +)
            banner = "\(winners.count == 1 && winners[0].isHuman ? "Ganas" : "Gana \(names)")\(how) · \(won) fichas"
            for player in opponents { mood(player.slot, result.winners.contains(player.id) ? .won : .lost) }
            refreshPokerHUD(poker)
            if let winner = winners.first, !winner.isHuman {
                comment(winner, on: "Has ganado la mano de póker\(how) y te llevas \(won) fichas.", force: true)
            } else if let loser = opponents.first(where: { !result.winners.contains($0.id) }) {
                comment(loser, on: "\(humanName) ha ganado la mano de póker\(how) y se lleva \(won) fichas.", force: true)
            }
            let alive = poker.players.indices.filter { poker.players[$0].chips > 0 }
            if poker.players[0].chips <= 0 {
                banner = "Te has quedado sin fichas"
                return
            }
            if alive.count < 2 {
                banner = "¡Has dejado sin fichas a todos! Ganas la partida"
                return
            }
            guard await ask(.next("Siguiente mano")) != nil else { return }
        }
    }

    private func refreshPokerHUD(_ poker: PokerTable) {
        var lines = ["Bote: \(poker.totalPot) · \(["Preflop", "Flop", "Turn", "River", "Showdown"][poker.street.rawValue])"]
        lines.append(players.map { "\($0.isHuman ? "Tú" : $0.name): \(poker.players[$0.id].chips)" }.joined(separator: " · "))
        let mine = poker.players[0]
        if mine.hole.count == 2, !mine.folded {
            lines.append(mine.hole.count + poker.board.count >= 5 ? "Tu mano: \(PokerEvaluator.best(of: mine.hole + poker.board).title)" : "")
        }
        hud = lines.filter { !$0.isEmpty }
    }
}
