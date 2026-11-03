import XCTest
@testable import JackCore

final class PokerTests: XCTestCase {
    private func hand(_ text: String) -> [PlayingCard] {
        // «As Kh 9d» (valor + inicial del palo en inglés: s, h, d, c).
        text.split(separator: " ").map { token in
            let rankText = String(token.dropLast())
            let rank: CardRank = ["2": .two, "3": .three, "4": .four, "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine, "T": .ten, "J": .jack, "Q": .queen, "K": .king, "A": .ace][rankText]!
            let suit: CardSuit = ["s": .spades, "h": .hearts, "d": .diamonds, "c": .clubs][String(token.last!)]!
            return PlayingCard(rank, of: suit)
        }
    }

    func testHandCategories() {
        XCTAssertEqual(PokerEvaluator.best(of: hand("As Ks Qs Js Ts")).category, .straightFlush)
        XCTAssertEqual(PokerEvaluator.best(of: hand("As Ks Qs Js Ts")).title, "escalera real")
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s 9h 9d 9c 2s")).category, .fourOfAKind)
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s 9h 9d 2c 2s")).category, .fullHouse)
        XCTAssertEqual(PokerEvaluator.best(of: hand("2s 7s 9s Js Ks")).category, .flush)
        XCTAssertEqual(PokerEvaluator.best(of: hand("5s 6h 7d 8c 9s")).category, .straight)
        XCTAssertEqual(PokerEvaluator.best(of: hand("As 2h 3d 4c 5s")).category, .straight)
        XCTAssertEqual(PokerEvaluator.best(of: hand("As 2h 3d 4c 5s")).ranks, [5])
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s 9h 9d 2c 3s")).category, .threeOfAKind)
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s 9h 4d 4c 3s")).category, .twoPair)
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s 9h 4d 5c 3s")).category, .pair)
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s Kh 4d 5c 3s")).category, .highCard)
    }

    func testBestOfSevenAndComparisons() {
        // La mejor de siete cartas: un color escondido entre dos parejas.
        let seven = PokerEvaluator.best(of: hand("As 9s 9h 4s 4d 2s Ks"))
        XCTAssertEqual(seven.category, .flush)
        XCTAssertGreaterThan(PokerEvaluator.best(of: hand("As Ah Kd 2c 3s")), PokerEvaluator.best(of: hand("Ks Kh Ad 2c 3s")))
        XCTAssertGreaterThan(PokerEvaluator.best(of: hand("As Ah Kd 7c 3s")), PokerEvaluator.best(of: hand("Ad Ac Qd 7h 3d")))
        XCTAssertEqual(PokerEvaluator.best(of: hand("As Ah Kd 7c 3s")), PokerEvaluator.best(of: hand("Ad Ac Kh 7h 3d")))
        XCTAssertEqual(PokerEvaluator.best(of: hand("9s 9h 4d 4c 3s")).title, "doble pareja de nueves y cuatros")
    }

    /// Un mazo preparado: las cartas se reparten desde el final.
    private func rigged(holes: [[String]], board: String) -> [PlayingCard] {
        let boardCards = hand(board)
        // Reparto: dos vueltas empezando por la ciega pequeña (orden `order`); aquí cada lista ya va en ese orden.
        var dealt: [PlayingCard] = []
        for round in 0..<2 { for hole in holes { dealt.append(hand(hole[round])[0]) } }
        let used = Set(dealt + boardCards)
        let filler = PlayingCard.deck.filter { !used.contains($0) }
        // Se reparten desde el final: primero las hole, luego el flop (3), turn y river.
        return filler + boardCards.reversed() + dealt.reversed()
    }

    func testHeadsUpBlindsAndFoldGivesThePotToTheOther() {
        var table = PokerTable(stacks: [1000, 1000], dealer: 0)
        XCTAssertTrue(table.startHand())
        // Mano a mano: el botón pone la ciega pequeña y habla primero.
        XCTAssertEqual(table.players[0].bet, 10)
        XCTAssertEqual(table.players[1].bet, 20)
        XCTAssertEqual(table.toAct, 0)
        XCTAssertEqual(table.toCall(0), 10)
        table.apply(.fold)
        XCTAssertEqual(table.result?.winners, [1])
        XCTAssertEqual(table.players[1].stack, 1010)
        XCTAssertEqual(table.players[0].stack, 990)
    }

    func testCheckedDownToShowdownPaysTheBestHand() {
        var table = PokerTable(stacks: [1000, 1000], dealer: 0)
        // Orden de reparto: ciega pequeña (jugador 0) y luego jugador 1.
        let deck = rigged(holes: [["As", "Ah"], ["Kd", "Kc"]], board: "2c 7d 9h Js 3d")
        table.startHand(deck: deck)
        XCTAssertEqual(table.players[0].hole, hand("As Ah"))
        table.apply(.call)
        table.apply(.check)
        XCTAssertEqual(table.street, .flop)
        XCTAssertEqual(table.board.count, 3)
        // Postflop habla primero el que está después del botón.
        XCTAssertEqual(table.toAct, 1)
        for _ in 0..<3 {
            table.apply(.check)
            table.apply(.check)
        }
        XCTAssertEqual(table.board.count, 5)
        XCTAssertEqual(table.result?.winners, [0])
        XCTAssertEqual(table.result?.showdown, true)
        XCTAssertEqual(table.players[0].stack, 1020)
        XCTAssertEqual(table.players[1].stack, 980)
    }

    func testRaiseThenCallAndAllInRunsOutTheBoard() {
        var table = PokerTable(stacks: [500, 500], dealer: 0)
        table.startHand(deck: rigged(holes: [["As", "Ah"], ["Kd", "Kc"]], board: "2c 7d 9h Js 3d"))
        guard let range = table.raiseRange(0) else { return XCTFail("debería poder subir") }
        XCTAssertEqual(range.lowerBound, 40)
        XCTAssertEqual(range.upperBound, 500)
        table.apply(.raise(to: 500))
        XCTAssertEqual(table.toAct, 1)
        table.apply(.call)
        // Los dos están all-in: salen todas las cartas y se resuelve.
        XCTAssertEqual(table.board.count, 5)
        XCTAssertEqual(table.result?.winners, [0])
        XCTAssertEqual(table.players[0].stack, 1000)
        XCTAssertEqual(table.players[1].stack, 0)
        XCTAssertTrue(table.players[1].stack + table.players[1].reserve == 0)
    }

    func testShortStackLimitsTheOthersAndTheExtraComesBack() {
        var table = PokerTable(stacks: [1000, 1000, 100], dealer: 0)
        table.startHand()
        XCTAssertEqual(table.players.map { $0.stack + $0.bet }, [100, 100, 100])
        XCTAssertEqual(table.players.map(\.reserve), [900, 900, 0])
        let total = table.players.reduce(0) { $0 + $1.chips } + table.totalPot
        XCTAssertEqual(total, 2100)
        // Todos se retiran menos uno y las fichas guardadas vuelven en la mano siguiente.
        while table.toAct != nil { table.apply(.fold) }
        XCTAssertTrue(table.isHandOver)
        table.startHand()
        XCTAssertEqual(table.players.reduce(0) { $0 + $1.chips } + table.totalPot, 2100)
    }

    func testThreeHandedBlindsAndOrder() {
        var table = PokerTable(stacks: [1000, 1000, 1000], dealer: 0)
        table.startHand()
        XCTAssertEqual(table.players[1].bet, 10)
        XCTAssertEqual(table.players[2].bet, 20)
        XCTAssertEqual(table.toAct, 0)
        table.apply(.call)
        table.apply(.call)
        // La ciega grande conserva la opción de subir.
        XCTAssertEqual(table.toAct, 2)
        XCTAssertEqual(table.street, .preflop)
        table.apply(.check)
        XCTAssertEqual(table.street, .flop)
        XCTAssertEqual(table.toAct, 1)
    }

    func testBustedPlayersAreSkippedAndGameEnds() {
        var table = PokerTable(stacks: [1000, 0, 1000], dealer: 0)
        XCTAssertEqual(table.alive, [0, 2])
        XCTAssertTrue(table.startHand())
        XCTAssertTrue(table.players[1].folded)
        var lonely = PokerTable(stacks: [1000, 0], dealer: 0)
        XCTAssertFalse(lonely.startHand())
    }

    func testEquityAndAIAreSensible() {
        var rng = SystemRandomNumberGenerator()
        let aces = PokerEquity.estimate(hole: hand("As Ah"), board: [], opponents: 1, trials: 600, using: &rng)
        let trash = PokerEquity.estimate(hole: hand("7s 2h"), board: [], opponents: 1, trials: 600, using: &rng)
        XCTAssertGreaterThan(aces, 0.75)
        XCTAssertLessThan(trash, 0.45)

        // Con póker de ases en la mesa, la IA nunca se retira ante una apuesta.
        var table = PokerTable(stacks: [1000, 1000], dealer: 0)
        table.startHand(deck: rigged(holes: [["As", "Ah"], ["7s", "2h"]], board: "Ad Ac 9h Js 3d"))
        table.apply(.call)
        table.apply(.check)
        table.apply(.check)
        table.apply(.raise(to: 100))
        XCTAssertNotEqual(PokerAI.decide(table: table, seat: 0, personality: .balanced, trials: 200, using: &rng), .fold)
    }
}
