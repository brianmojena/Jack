import Foundation

/// La mano de blackjack: las cartas y su valor (el as vale 11 mientras no se pase de 21, y si no, 1).
public struct BlackjackHand: Equatable, Sendable {
    public private(set) var cards: [PlayingCard] = []

    public init(_ cards: [PlayingCard] = []) { self.cards = cards }

    mutating func add(_ card: PlayingCard) { cards.append(card) }

    public static func points(_ rank: CardRank) -> Int {
        switch rank {
        case .ace: 11
        case .jack, .queen, .king, .ten: 10
        default: rank.rawValue
        }
    }

    /// El mejor total y si lleva un as contando como 11 («blanda»).
    private var evaluation: (total: Int, soft: Bool) {
        var total = cards.reduce(0) { $0 + Self.points($1.rank) }
        var aces = cards.filter { $0.rank == .ace }.count
        while total > 21, aces > 0 {
            total -= 10
            aces -= 1
        }
        return (total, aces > 0)
    }

    public var total: Int { evaluation.total }
    public var isSoft: Bool { evaluation.soft }
    public var isBust: Bool { total > 21 }
    public var isBlackjack: Bool { cards.count == 2 && total == 21 }
}

public enum BlackjackAction: Sendable { case hit, stand, double }

public enum BlackjackOutcome: Equatable, Sendable {
    case blackjack, win, push, lose, bust
    /// El crupier se pasa de 21.
    case dealerBust
    /// El crupier tiene blackjack y el jugador no.
    case dealerBlackjack

    public var playerWon: Bool { self == .blackjack || self == .win || self == .dealerBust }

    public var title: String {
        switch self {
        case .blackjack: "¡Blackjack!"
        case .win: "Ganas"
        case .push: "Empate"
        case .lose: "Pierde"
        case .bust: "Te pasas"
        case .dealerBust: "El crupier se pasa"
        case .dealerBlackjack: "Blackjack del crupier"
        }
    }
}

/// Una mesa de blackjack contra el crupier: fichas del jugador, un zapato de 4 barajas y la mano en curso. El crupier pide hasta
/// 17 (se planta en todos los 17). El blackjack paga 3 a 2 y se puede doblar con las dos primeras cartas.
public struct BlackjackTable: Sendable {
    public enum Phase: Equatable, Sendable {
        /// A la espera de la apuesta.
        case betting
        case playerTurn
        case dealerTurn
        case finished(BlackjackOutcome)
    }

    public private(set) var chips: Int
    public private(set) var bet = 0
    public private(set) var player = BlackjackHand()
    public private(set) var dealer = BlackjackHand()
    public private(set) var phase = Phase.betting
    public private(set) var doubled = false
    public private(set) var shoe: [PlayingCard]
    /// Cuántas barajas lleva el zapato al barajarlo.
    private let decks: Int

    public init(chips: Int = 500, decks: Int = 4) {
        self.chips = chips
        self.decks = decks
        shoe = Self.shuffled(decks)
    }

    /// Con un zapato dado (la primera carta que se reparte es la última de la lista); para las pruebas.
    public init(chips: Int, shoe: [PlayingCard]) {
        self.chips = chips
        decks = 4
        self.shoe = shoe
    }

    private static func shuffled(_ decks: Int) -> [PlayingCard] {
        (0..<decks).flatMap { _ in PlayingCard.deck }.shuffled()
    }

    private mutating func draw() -> PlayingCard {
        // Con pocas cartas se baraja un zapato nuevo (entre manos, nunca en mitad de una).
        if shoe.count < 12 { shoe = Self.shuffled(decks) }
        return shoe.removeLast()
    }

    public var canDouble: Bool { phase == .playerTurn && player.cards.count == 2 && chips >= bet }
    public var isOver: Bool { if case .finished = phase { true } else { false } }
    public var outcome: BlackjackOutcome? { if case .finished(let outcome) = phase { outcome } else { nil } }

    /// Reparte: jugador, crupier (carta vista), jugador y crupier (carta tapada). Con blackjack de alguien, la mano acaba ya.
    @discardableResult
    public mutating func deal(bet amount: Int) -> Bool {
        guard phase == .betting || isOver, amount > 0, amount <= chips else { return false }
        chips -= amount
        bet = amount
        doubled = false
        player = BlackjackHand()
        dealer = BlackjackHand()
        player.add(draw())
        dealer.add(draw())
        player.add(draw())
        dealer.add(draw())
        phase = .playerTurn
        if player.isBlackjack || dealer.isBlackjack { settle() }
        return true
    }

    public mutating func hit() {
        guard phase == .playerTurn else { return }
        player.add(draw())
        if player.isBust { settle() } else if player.total == 21 { stand() }
    }

    public mutating func stand() {
        guard phase == .playerTurn else { return }
        phase = .dealerTurn
    }

    /// Dobla la apuesta, recibe una sola carta y se planta.
    public mutating func doubleDown() {
        guard canDouble else { return }
        chips -= bet
        bet *= 2
        doubled = true
        player.add(draw())
        if player.isBust { settle() } else { phase = .dealerTurn }
    }

    /// El crupier roba una carta si le toca (pide con 16 o menos; se planta en 17). Devuelve si robó; al plantarse, la mano acaba.
    @discardableResult
    public mutating func dealerDraws() -> Bool {
        guard phase == .dealerTurn else { return false }
        if dealer.total < 17 {
            dealer.add(draw())
            return true
        }
        settle()
        return false
    }

    private mutating func settle() {
        let result: BlackjackOutcome
        if player.isBust {
            result = .bust
        } else if player.isBlackjack, !dealer.isBlackjack {
            result = .blackjack
        } else if dealer.isBlackjack, !player.isBlackjack {
            result = .dealerBlackjack
        } else if player.isBlackjack, dealer.isBlackjack {
            result = .push
        } else if dealer.isBust {
            result = .dealerBust
        } else if player.total > dealer.total {
            result = .win
        } else if player.total < dealer.total {
            result = .lose
        } else {
            result = .push
        }
        switch result {
        case .blackjack: chips += bet + bet * 3 / 2
        case .win, .dealerBust: chips += bet * 2
        case .push: chips += bet
        case .lose, .bust, .dealerBlackjack: break
        }
        phase = .finished(result)
    }

    /// Lo que haría el crupier-amigo con la estrategia básica (para un consejo): `true` si conviene pedir.
    public var basicStrategyHits: Bool {
        guard let up = dealer.cards.first else { return false }
        let upValue = BlackjackHand.points(up.rank)
        let total = player.total
        if player.isSoft {
            return total <= 17 || (total == 18 && upValue >= 9)
        }
        if total <= 11 { return true }
        if total >= 17 { return false }
        if total == 12 { return !(4...6).contains(upValue) }
        return upValue >= 7
    }
}
