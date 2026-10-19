import Foundation

/// El Mentiroso (también «Cheat» o «Bullshit») para varios jugadores con la baraja entera repartida. Por turnos se juegan cartas
/// boca abajo diciendo que son del valor que toca (as, 2, 3… rey y vuelta a empezar); cualquiera de los demás puede decir
/// «¡mentiroso!»: si mentía, se lleva el montón; si decía la verdad, se lo lleva quien lo acusó. Gana quien se queda sin cartas.
public struct LiarGame: Sendable {
    /// Lo que se acaba de jugar: quién, las cartas de verdad (boca abajo para los demás) y lo que dijo que eran.
    public struct Play: Equatable, Sendable {
        public var player: Int
        public var cards: [PlayingCard]
        public var claim: CardRank
        public var count: Int { cards.count }
        public var isHonest: Bool { cards.allSatisfy { $0.rank == claim } }
    }

    public enum Phase: Equatable, Sendable {
        /// Le toca jugar a este jugador.
        case playing(turn: Int)
        /// Los demás deciden si lo acusan, de uno en uno.
        case responding(responder: Int)
        case over(winner: Int)
    }

    /// Lo que pasó al acusar.
    public struct Resolution: Equatable, Sendable {
        public var play: Play
        public var caller: Int
        /// Quién se lleva el montón: quien mentía o, si decía la verdad, quien lo acusó.
        public var taker: Int
        public var pileSize: Int
        public var wasLie: Bool { !play.isHonest }
    }

    /// El orden de los valores: del as al rey.
    public static let ranks: [CardRank] = [.ace, .two, .three, .four, .five, .six, .seven, .eight, .nine, .ten, .jack, .queen, .king]
    public static let maxPlay = 4

    public private(set) var hands: [[PlayingCard]]
    public private(set) var pile: [PlayingCard] = []
    public private(set) var phase: Phase
    /// El valor que hay que decir ahora.
    public private(set) var requiredRank: CardRank = .ace
    public private(set) var lastPlay: Play?
    /// Cuántos jugadores han dicho ya que no acusan lo último que se jugó.
    private var passed: [Int] = []

    public var playerCount: Int { hands.count }

    public init(players: Int = 3) {
        precondition(players >= 2)
        var deck = PlayingCard.deck.shuffled()
        var dealt = Array(repeating: [PlayingCard](), count: players)
        var index = 0
        while let card = deck.popLast() {
            dealt[index % players].append(card)
            index += 1
        }
        hands = dealt.map(Self.sorted)
        phase = .playing(turn: 0)
    }

    /// Con manos dadas (para las pruebas).
    public init(hands: [[PlayingCard]], turn: Int = 0, requiredRank: CardRank = .ace) {
        self.hands = hands.map(Self.sorted)
        self.requiredRank = requiredRank
        phase = .playing(turn: turn)
    }

    public static func sorted(_ cards: [PlayingCard]) -> [PlayingCard] {
        cards.sorted { ($0.rank.rawValue, $0.suit.rawValue) < ($1.rank.rawValue, $1.suit.rawValue) }
    }

    public var winner: Int? { if case .over(let winner) = phase { winner } else { nil } }

    /// A quién le toca jugar o decidir si acusa.
    public var active: Int? {
        switch phase {
        case .playing(let turn): turn
        case .responding(let responder): responder
        case .over: nil
        }
    }

    private func next(after player: Int) -> Int { (player + 1) % playerCount }

    private func rankAfter(_ rank: CardRank) -> CardRank {
        let index = Self.ranks.firstIndex(of: rank) ?? 0
        return Self.ranks[(index + 1) % Self.ranks.count]
    }

    // MARK: - Jugar

    /// El jugador al que le toca juega `cards` (de su mano, de 1 a 4) diciendo que son del valor que toca.
    @discardableResult
    public mutating func play(_ cards: [PlayingCard]) -> Bool {
        guard case .playing(let turn) = phase, !cards.isEmpty, cards.count <= Self.maxPlay, Set(cards).count == cards.count,
              cards.allSatisfy({ hands[turn].contains($0) }) else { return false }
        hands[turn].removeAll { cards.contains($0) }
        pile += cards
        lastPlay = Play(player: turn, cards: cards, claim: requiredRank)
        passed = []
        phase = .responding(responder: next(after: turn))
        return true
    }

    /// El jugador que decide dice que no acusa. Si ya no queda nadie por decidir, sigue el juego (o gana quien se quedó sin cartas).
    public mutating func pass() {
        guard case .responding(let responder) = phase, let play = lastPlay else { return }
        passed.append(responder)
        let following = next(after: responder)
        if following == play.player {
            finishTurn(after: play.player)
        } else {
            phase = .responding(responder: following)
        }
    }

    /// El jugador que decide acusa de mentiroso al que acaba de jugar.
    @discardableResult
    public mutating func challenge() -> Resolution? {
        guard case .responding(let caller) = phase, let play = lastPlay else { return nil }
        let size = pile.count
        let taker = play.isHonest ? caller : play.player
        hands[taker] = Self.sorted(hands[taker] + pile)
        pile = []
        let resolution = Resolution(play: play, caller: caller, taker: taker, pileSize: size)
        finishTurn(after: play.player)
        return resolution
    }

    private mutating func finishTurn(after player: Int) {
        // Quien se queda sin cartas gana si nadie lo ha pillado mintiendo (si lo pillaron, se llevó el montón y ya tiene cartas).
        if hands[player].isEmpty {
            phase = .over(winner: player)
            return
        }
        requiredRank = rankAfter(requiredRank)
        lastPlay = nil
        passed = []
        phase = .playing(turn: next(after: player))
    }
}

// MARK: - Los jugadores de la IA

/// Cómo juega cada personaje: cuánto se tira faroles y cuánto desconfía.
public struct LiarPersonality: Sendable, Equatable {
    /// De 0 a 1: con qué frecuencia suelta más cartas de las que debería o miente de más.
    public var bluff: Double
    /// De 0 a 1: cuánto acusa.
    public var suspicion: Double

    public init(bluff: Double, suspicion: Double) {
        self.bluff = bluff
        self.suspicion = suspicion
    }

    public static let balanced = LiarPersonality(bluff: 0.35, suspicion: 0.5)
}

public enum LiarAI {
    /// Las cartas que juega `hand` cuando toca decir `required`: las que tiene de ese valor y, si no tiene, el farol de 1 o 2 cartas.
    public static func cards<G: RandomNumberGenerator>(hand: [PlayingCard], required: CardRank, personality: LiarPersonality, using rng: inout G) -> [PlayingCard] {
        guard !hand.isEmpty else { return [] }
        let own = hand.filter { $0.rank == required }
        let others = hand.filter { $0.rank != required }
        let frequency = Dictionary(grouping: others, by: \.rank).mapValues(\.count)
        // Para mentir se sueltan primero las cartas sueltas (las que menos se repiten): quedan menos cartas «malas» en la mano.
        let junk = others.sorted { (frequency[$0.rank] ?? 0, $0.rank.rawValue) < (frequency[$1.rank] ?? 0, $1.rank.rawValue) }
        if !own.isEmpty {
            var play = Array(own.prefix(LiarGame.maxPlay))
            // A veces se cuela una carta de más entre las buenas.
            if play.count < LiarGame.maxPlay, let extra = junk.first, Double.random(in: 0..<1, using: &rng) < personality.bluff * 0.3 { play.append(extra) }
            return play
        }
        var count = 1
        let roll = Double.random(in: 0..<1, using: &rng)
        if roll < personality.bluff * 0.35 { count = 2 }
        if roll < personality.bluff * 0.06 { count = 3 }
        return Array(junk.prefix(min(count, hand.count)))
    }

    /// Si `me` acusa de mentiroso al que acaba de jugar.
    public static func shouldChallenge<G: RandomNumberGenerator>(game: LiarGame, me: Int, personality: LiarPersonality, using rng: inout G) -> Bool {
        guard let play = game.lastPlay else { return false }
        let mine = game.hands[me].filter { $0.rank == play.claim }.count
        // Más de cuatro del mismo valor no existen: seguro que miente.
        if mine + play.count > 4 { return true }
        // Si se ha quedado sin cartas y nadie lo para, gana.
        if game.hands[play.player].isEmpty { return true }
        // Cuántas cartas quedan «por ahí» del valor dicho (sin contar las mías) y cuántas cartas desconocidas hay.
        let copies = 4 - mine
        let unknown = 52 - game.hands[me].count
        let size = game.hands[play.player].count + play.count
        let honest = hypergeometricAtLeast(play.count, copies: copies, unknown: unknown, draws: size)
        var probability = (1 - honest) * (0.5 + personality.suspicion)
        // Llevarse un montón enorme da miedo.
        if game.pile.count > 8 { probability *= 0.8 }
        // Cuantas más cartas dice, más se sospecha.
        probability += Double(play.count - 1) * 0.05
        return Double.random(in: 0..<1, using: &rng) < min(max(probability, 0.03), 0.97)
    }

    /// La probabilidad de que en `draws` cartas de entre `unknown` haya al menos `needed` de las `copies` que existen.
    static func hypergeometricAtLeast(_ needed: Int, copies: Int, unknown: Int, draws: Int) -> Double {
        guard needed > 0 else { return 1 }
        guard copies >= needed, unknown > 0, draws >= needed else { return 0 }
        func choose(_ n: Int, _ k: Int) -> Double {
            guard k >= 0, k <= n else { return 0 }
            var result = 1.0
            for i in 0..<k { result = result * Double(n - i) / Double(i + 1) }
            return result
        }
        let total = choose(unknown, min(draws, unknown))
        var sum = 0.0
        for k in needed...min(copies, draws) { sum += choose(copies, k) * choose(unknown - copies, min(draws, unknown) - k) }
        return min(1, sum / total)
    }
}
