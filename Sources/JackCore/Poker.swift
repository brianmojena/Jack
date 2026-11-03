import Foundation

// MARK: - Manos

public enum PokerCategory: Int, Comparable, Sendable {
    case highCard, pair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush

    public static func < (a: PokerCategory, b: PokerCategory) -> Bool { a.rawValue < b.rawValue }
}

/// El valor de una mano de cinco cartas: la categoría y los valores que desempatan, de mayor a menor importancia.
public struct PokerScore: Comparable, Equatable, Sendable {
    public var category: PokerCategory
    /// Los valores de las cartas (2…14, con el as en 14), agrupados primero por repetición y luego de mayor a menor.
    public var ranks: [Int]

    public static func < (a: PokerScore, b: PokerScore) -> Bool {
        if a.category != b.category { return a.category < b.category }
        return a.ranks.lexicographicallyPrecedes(b.ranks)
    }

    private static func plural(_ value: Int) -> String {
        ["", "", "doses", "treses", "cuatros", "cincos", "seises", "sietes", "ochos", "nueves", "dieces", "jotas", "damas", "reyes", "ases"][value]
    }

    private static func single(_ value: Int) -> String {
        ["", "", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez", "jota", "dama", "rey", "as"][value]
    }

    /// «pareja de reyes», «escalera al nueve», «full de ases y doses»…
    public var title: String {
        switch category {
        case .highCard: "carta alta: \(Self.single(ranks[0]))"
        case .pair: "pareja de \(Self.plural(ranks[0]))"
        case .twoPair: "doble pareja de \(Self.plural(ranks[0])) y \(Self.plural(ranks[1]))"
        case .threeOfAKind: "trío de \(Self.plural(ranks[0]))"
        case .straight: "escalera al \(Self.single(ranks[0]))"
        case .flush: "color al \(Self.single(ranks[0]))"
        case .fullHouse: "full de \(Self.plural(ranks[0])) y \(Self.plural(ranks[1]))"
        case .fourOfAKind: "póker de \(Self.plural(ranks[0]))"
        case .straightFlush: ranks[0] == 14 ? "escalera real" : "escalera de color al \(Self.single(ranks[0]))"
        }
    }
}

public enum PokerEvaluator {
    /// La mejor mano de cinco cartas que se puede hacer con 5 a 7 cartas.
    public static func best(of cards: [PlayingCard]) -> PokerScore {
        precondition(cards.count >= 5 && cards.count <= 7)
        var best: PokerScore?
        let n = cards.count
        // Las combinaciones de cinco cartas (como mucho 21).
        for a in 0..<n {
            for b in (a + 1)..<n {
                for c in (b + 1)..<n {
                    for d in (c + 1)..<n {
                        for e in (d + 1)..<n {
                            let score = score(five: [cards[a], cards[b], cards[c], cards[d], cards[e]])
                            if best == nil || score > best! { best = score }
                        }
                    }
                }
            }
        }
        return best!
    }

    static func score(five cards: [PlayingCard]) -> PokerScore {
        let values = cards.map(\.rank.rawValue).sorted(by: >)
        let counts = Dictionary(grouping: values, by: { $0 }).map { (value: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $0.value) > ($1.count, $1.value) }
        let flush = Set(cards.map(\.suit)).count == 1
        var straightHigh: Int?
        if Set(values).count == 5 {
            if values[0] - values[4] == 4 { straightHigh = values[0] } else if values == [14, 5, 4, 3, 2] { straightHigh = 5 }
        }
        if let high = straightHigh, flush { return PokerScore(category: .straightFlush, ranks: [high]) }
        if counts[0].count == 4 { return PokerScore(category: .fourOfAKind, ranks: counts.map(\.value)) }
        if counts[0].count == 3, counts[1].count == 2 { return PokerScore(category: .fullHouse, ranks: counts.map(\.value)) }
        if flush { return PokerScore(category: .flush, ranks: values) }
        if let high = straightHigh { return PokerScore(category: .straight, ranks: [high]) }
        if counts[0].count == 3 { return PokerScore(category: .threeOfAKind, ranks: counts.map(\.value)) }
        if counts[0].count == 2, counts[1].count == 2 { return PokerScore(category: .twoPair, ranks: counts.map(\.value)) }
        if counts[0].count == 2 { return PokerScore(category: .pair, ranks: counts.map(\.value)) }
        return PokerScore(category: .highCard, ranks: values)
    }
}

// MARK: - Mesa

public enum PokerAction: Equatable, Sendable {
    case fold
    case check
    case call
    /// Sube la apuesta de la ronda hasta este total (apostar, si nadie había apostado).
    case raise(to: Int)
}

public struct PokerPlayer: Equatable, Sendable {
    /// Fichas con las que juega la mano.
    public var stack: Int
    /// Fichas que se guardan aparte esta mano (ver `PokerTable`) y vuelven al acabar.
    public var reserve = 0
    public var hole: [PlayingCard] = []
    /// Lo apostado en la ronda actual.
    public var bet = 0
    public var folded = false
    public var allIn = false
    public var acted = false
    /// Sin fichas: ya no juega.
    public var out = false

    public var chips: Int { stack + reserve }
}

public struct PokerResult: Equatable, Sendable {
    public var winners: [Int]
    /// Lo que se lleva cada ganador.
    public var payouts: [Int: Int]
    /// Si hubo que enseñar las cartas (si no, todos se retiraron menos uno).
    public var showdown: Bool
    public var scores: [Int: PokerScore]
}

/// Una mesa de Texas hold'em sin límite para varios jugadores, mano a mano con fichas.
///
/// Para no tener botes laterales, cada mano todos juegan como mucho con las fichas del que menos tiene (lo que sobra se guarda
/// aparte y vuelve al acabar la mano), así que cualquier apuesta se puede igualar.
public struct PokerTable: Sendable {
    public enum Street: Int, Sendable { case preflop, flop, turn, river, showdown }

    public private(set) var players: [PokerPlayer]
    public private(set) var board: [PlayingCard] = []
    public private(set) var pot = 0
    public private(set) var street = Street.preflop
    public private(set) var dealer: Int
    public private(set) var toAct: Int?
    public private(set) var currentBet = 0
    public private(set) var minRaise: Int
    public private(set) var result: PokerResult?
    public private(set) var handNumber = 0
    public let smallBlind: Int
    public let bigBlind: Int
    private var deck: [PlayingCard] = []

    public init(stacks: [Int], smallBlind: Int = 10, bigBlind: Int = 20, dealer: Int = 0) {
        precondition(stacks.count >= 2)
        players = stacks.map { PokerPlayer(stack: $0, out: $0 <= 0) }
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.dealer = dealer
        minRaise = bigBlind
    }

    /// Los jugadores con fichas.
    public var alive: [Int] { players.indices.filter { !players[$0].out } }
    public var isHandOver: Bool { result != nil }
    /// Lo que hay en la mesa: el bote y lo apostado en esta ronda.
    public var totalPot: Int { pot + players.reduce(0) { $0 + $1.bet } }

    private func contenders() -> [Int] { players.indices.filter { !players[$0].folded && !players[$0].out } }

    private func nextAlive(after seat: Int) -> Int {
        var index = seat
        for _ in 0..<players.count {
            index = (index + 1) % players.count
            if !players[index].out { return index }
        }
        return seat
    }

    private func canAct(_ seat: Int) -> Bool {
        !players[seat].folded && !players[seat].allIn && !players[seat].out
    }

    // MARK: Empezar

    /// Reparte una mano nueva; `false` si no quedan dos jugadores con fichas. `deck` (el último se reparte primero) es para las pruebas.
    @discardableResult
    public mutating func startHand(deck given: [PlayingCard]? = nil) -> Bool {
        for index in players.indices {
            players[index].stack += players[index].reserve
            players[index].reserve = 0
            players[index].out = players[index].stack <= 0
        }
        guard alive.count >= 2 else { return false }
        result = nil
        board = []
        pot = 0
        street = .preflop
        currentBet = 0
        minRaise = bigBlind
        deck = given ?? PlayingCard.deck.shuffled()
        for index in players.indices {
            players[index].hole = []
            players[index].bet = 0
            players[index].folded = players[index].out
            players[index].allIn = false
            players[index].acted = false
        }
        // El botón pasa al siguiente con fichas (la primera mano, el que se eligió).
        if handNumber > 0 { dealer = nextAlive(after: dealer) } else if players[dealer].out { dealer = nextAlive(after: dealer) }
        handNumber += 1
        // Todos juegan con las fichas del que menos tiene.
        let cap = alive.map { players[$0].stack }.min() ?? 0
        for seat in alive {
            players[seat].reserve = players[seat].stack - cap
            players[seat].stack = cap
        }
        let headsUp = alive.count == 2
        let small = headsUp ? dealer : nextAlive(after: dealer)
        let big = nextAlive(after: small)
        post(small, smallBlind)
        post(big, bigBlind)
        currentBet = max(players[small].bet, players[big].bet)
        // Dos cartas a cada uno, de una en una, empezando por la ciega pequeña.
        var order: [Int] = []
        var seat = small
        for _ in alive { order.append(seat); seat = nextAlive(after: seat) }
        for _ in 0..<2 { for seat in order { players[seat].hole.append(self.deck.removeLast()) } }
        toAct = nil
        findNext(from: big)
        return true
    }

    private mutating func post(_ seat: Int, _ amount: Int) {
        let paid = min(amount, players[seat].stack)
        players[seat].stack -= paid
        players[seat].bet += paid
        if players[seat].stack == 0 { players[seat].allIn = true }
    }

    // MARK: Apuestas

    public func toCall(_ seat: Int) -> Int { max(0, currentBet - players[seat].bet) }

    public func canCheck(_ seat: Int) -> Bool { toCall(seat) == 0 }

    /// La apuesta más baja y más alta a la que puede subir el jugador (la más alta es todas sus fichas).
    public func raiseRange(_ seat: Int) -> ClosedRange<Int>? {
        let maximum = players[seat].bet + players[seat].stack
        guard maximum > currentBet else { return nil }
        return min(currentBet + minRaise, maximum)...maximum
    }

    /// Hace lo que decide el jugador al que le toca. `false` si no es válido.
    @discardableResult
    public mutating func apply(_ action: PokerAction) -> Bool {
        guard let seat = toAct, result == nil else { return false }
        switch action {
        case .fold:
            players[seat].folded = true
            players[seat].acted = true
            if contenders().count == 1 { endUncontested(); return true }
        case .check:
            guard canCheck(seat) else { return false }
            players[seat].acted = true
        case .call:
            let paid = min(toCall(seat), players[seat].stack)
            players[seat].stack -= paid
            players[seat].bet += paid
            if players[seat].stack == 0 { players[seat].allIn = true }
            players[seat].acted = true
        case .raise(let target):
            guard let range = raiseRange(seat) else { return false }
            let total = min(max(target, range.lowerBound), range.upperBound)
            let size = total - currentBet
            let paid = total - players[seat].bet
            players[seat].stack -= paid
            players[seat].bet = total
            if players[seat].stack == 0 { players[seat].allIn = true }
            if size >= minRaise { minRaise = size }
            currentBet = total
            for other in players.indices where other != seat { players[other].acted = false }
            players[seat].acted = true
        }
        findNext(from: seat)
        return true
    }

    /// Busca a quién le toca después de `seat`; si nadie tiene nada que decidir, acaba la ronda.
    private mutating func findNext(from seat: Int) {
        var index = seat
        for _ in 0..<players.count {
            index = (index + 1) % players.count
            if canAct(index), !players[index].acted || players[index].bet < currentBet {
                toAct = index
                return
            }
        }
        toAct = nil
        endStreet()
    }

    private mutating func endStreet() {
        pot += players.reduce(0) { $0 + $1.bet }
        for index in players.indices {
            players[index].bet = 0
            players[index].acted = false
        }
        currentBet = 0
        minRaise = bigBlind
        guard contenders().count > 1 else { endUncontested(); return }
        if street == .river { showdown(); return }
        street = Street(rawValue: street.rawValue + 1)!
        for _ in 0..<(street == .flop ? 3 : 1) { board.append(deck.removeLast()) }
        let waiting = players.indices.filter { canAct($0) }
        // Con uno solo (o ninguno) que pueda apostar, las cartas que faltan salen solas.
        if waiting.count <= 1 { endStreet(); return }
        var seat = dealer
        for _ in 0..<players.count {
            seat = (seat + 1) % players.count
            if canAct(seat) { toAct = seat; return }
        }
    }

    private mutating func endUncontested() {
        pot += players.reduce(0) { $0 + $1.bet }
        for index in players.indices { players[index].bet = 0 }
        let winner = contenders()[0]
        players[winner].stack += pot
        result = PokerResult(winners: [winner], payouts: [winner: pot], showdown: false, scores: [:])
        toAct = nil
        street = .showdown
        pot = 0
    }

    private mutating func showdown() {
        street = .showdown
        let seats = contenders()
        var scores: [Int: PokerScore] = [:]
        for seat in seats { scores[seat] = PokerEvaluator.best(of: players[seat].hole + board) }
        let top = scores.values.max()!
        let winners = seats.filter { scores[$0] == top }
        var payouts: [Int: Int] = [:]
        let share = pot / winners.count
        for (index, seat) in winners.enumerated() {
            let amount = share + (index == 0 ? pot % winners.count : 0)
            payouts[seat] = amount
            players[seat].stack += amount
        }
        result = PokerResult(winners: winners, payouts: payouts, showdown: true, scores: scores)
        toAct = nil
        pot = 0
    }
}

// MARK: - La IA

public enum PokerEquity {
    /// La probabilidad (de 0 a 1) de ganar el showdown contra `opponents` manos al azar, repartiendo las cartas que faltan.
    public static func estimate<G: RandomNumberGenerator>(hole: [PlayingCard], board: [PlayingCard], opponents: Int, trials: Int, using rng: inout G) -> Double {
        guard hole.count == 2, opponents > 0, trials > 0 else { return 0 }
        let known = Set(hole + board)
        var remaining = PlayingCard.deck.filter { !known.contains($0) }
        let needed = (5 - board.count) + opponents * 2
        var score = 0.0
        for _ in 0..<trials {
            // Las primeras `needed` cartas de un barajado parcial.
            for index in 0..<needed {
                let other = Int.random(in: index..<remaining.count, using: &rng)
                remaining.swapAt(index, other)
            }
            let fullBoard = board + remaining[0..<(5 - board.count)]
            let mine = PokerEvaluator.best(of: hole + fullBoard)
            var beaten = true
            var tied = 1
            for opponent in 0..<opponents {
                let start = (5 - board.count) + opponent * 2
                let theirs = PokerEvaluator.best(of: Array(remaining[start..<(start + 2)]) + fullBoard)
                if theirs > mine { beaten = false; break }
                if theirs == mine { tied += 1 }
            }
            if beaten { score += 1 / Double(tied) }
        }
        return score / Double(trials)
    }
}

/// Cómo juega cada personaje.
public struct PokerPersonality: Sendable, Equatable {
    /// De 0 a 1: cuánto sube con buena mano.
    public var aggression: Double
    /// De 0 a 1: con qué frecuencia se tira faroles.
    public var bluff: Double
    /// De 0 a 1: cuánto paga con manos dudosas.
    public var looseness: Double

    public init(aggression: Double, bluff: Double, looseness: Double) {
        self.aggression = aggression
        self.bluff = bluff
        self.looseness = looseness
    }

    public static let balanced = PokerPersonality(aggression: 0.5, bluff: 0.2, looseness: 0.4)
}

public enum PokerAI {
    public static func decide<G: RandomNumberGenerator>(table: PokerTable, seat: Int, personality: PokerPersonality, trials: Int = 300, using rng: inout G) -> PokerAction {
        let me = table.players[seat]
        let opponents = table.players.indices.filter { $0 != seat && !table.players[$0].folded && !table.players[$0].out }.count
        let equity = PokerEquity.estimate(hole: me.hole, board: table.board, opponents: max(1, opponents), trials: trials, using: &rng)
        let strength = equity + Double.random(in: -0.04...0.04, using: &rng)
        let call = table.toCall(seat)
        let pot = Double(table.totalPot)
        let range = table.raiseRange(seat)
        func raise(_ fraction: Double) -> PokerAction {
            guard let range else { return call > 0 ? .call : .check }
            return .raise(to: min(max(table.currentBet + Int(pot * fraction), range.lowerBound), range.upperBound))
        }
        func roll() -> Double { Double.random(in: 0..<1, using: &rng) }

        if call == 0 {
            if strength > 0.64 - 0.1 * personality.aggression { return raise(0.5 + 0.5 * strength) }
            if strength > 0.5, roll() < 0.35 * personality.aggression { return raise(0.4) }
            if strength < 0.38, roll() < personality.bluff * 0.25 { return raise(0.5) }
            return .check
        }
        let odds = Double(call) / (pot + Double(call))
        if strength > 0.78, roll() < 0.45 + personality.aggression * 0.45 { return raise(0.75) }
        if strength > odds + 0.06 - personality.looseness * 0.08 { return .call }
        if strength > odds - 0.05, roll() < 0.2 + personality.looseness * 0.3 { return .call }
        if roll() < personality.bluff * 0.07, Double(call) < pot / 2 { return raise(0.75) }
        return .fold
    }
}
