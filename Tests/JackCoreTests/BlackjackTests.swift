import XCTest
@testable import JackCore

final class BlackjackTests: XCTestCase {
    private func card(_ rank: CardRank, _ suit: CardSuit = .spades) -> PlayingCard { PlayingCard(rank, of: suit) }

    /// El zapato en el orden en que se reparte (jugador, crupier, jugador, crupier, y luego las que se roben).
    private func table(_ order: [CardRank], chips: Int = 500) -> BlackjackTable {
        BlackjackTable(chips: chips, shoe: PlayingCard.deck + order.reversed().map { card($0) })
    }

    func testHandValuesAndSoftAces() {
        XCTAssertEqual(BlackjackHand([card(.ace), card(.six)]).total, 17)
        XCTAssertTrue(BlackjackHand([card(.ace), card(.six)]).isSoft)
        XCTAssertEqual(BlackjackHand([card(.ace), card(.six), card(.king)]).total, 17)
        XCTAssertFalse(BlackjackHand([card(.ace), card(.six), card(.king)]).isSoft)
        XCTAssertEqual(BlackjackHand([card(.ace), card(.ace), card(.nine)]).total, 21)
        XCTAssertTrue(BlackjackHand([card(.ace), card(.king)]).isBlackjack)
        XCTAssertFalse(BlackjackHand([card(.five), card(.six), card(.ten)]).isBlackjack)
        XCTAssertTrue(BlackjackHand([card(.king), card(.queen), card(.five)]).isBust)
    }

    func testBlackjackPaysThreeToTwo() {
        var game = table([.ace, .nine, .king, .eight])
        game.deal(bet: 100)
        XCTAssertEqual(game.outcome, .blackjack)
        XCTAssertEqual(game.chips, 500 + 150)
    }

    func testPlayerBustLosesTheBet() {
        var game = table([.ten, .nine, .six, .eight, .king])
        game.deal(bet: 50)
        XCTAssertEqual(game.phase, .playerTurn)
        game.hit()
        XCTAssertEqual(game.outcome, .bust)
        XCTAssertEqual(game.chips, 450)
    }

    func testDealerDrawsUntilSeventeenAndPlayerWins() {
        // Jugador 10 + 9 = 19; crupier 6 + 5 = 11 y roba un 4 (15) y un 3 (18).
        var game = table([.ten, .six, .nine, .five, .four, .three])
        game.deal(bet: 100)
        game.stand()
        XCTAssertEqual(game.phase, .dealerTurn)
        XCTAssertTrue(game.dealerDraws())
        XCTAssertTrue(game.dealerDraws())
        XCTAssertFalse(game.dealerDraws())
        XCTAssertEqual(game.dealer.total, 18)
        XCTAssertEqual(game.outcome, .win)
        XCTAssertEqual(game.chips, 600)
    }

    func testDoubleDownDoublesTheBetAndDrawsOneCard() {
        // Jugador 5 + 6 = 11 y dobla con un 10 (21); crupier 10 + 7 = 17.
        var game = table([.five, .ten, .six, .seven, .ten])
        game.deal(bet: 100)
        XCTAssertTrue(game.canDouble)
        game.doubleDown()
        XCTAssertEqual(game.player.total, 21)
        XCTAssertEqual(game.phase, .dealerTurn)
        XCTAssertFalse(game.dealerDraws())
        XCTAssertEqual(game.outcome, .win)
        XCTAssertEqual(game.chips, 700)
    }

    func testPushReturnsTheBetAndDealerBlackjackBeatsTwentyOne() {
        var push = table([.ten, .ten, .eight, .eight])
        push.deal(bet: 100)
        push.stand()
        XCTAssertFalse(push.dealerDraws())
        XCTAssertEqual(push.outcome, .push)
        XCTAssertEqual(push.chips, 500)

        var dealerBJ = table([.five, .ace, .six, .king])
        dealerBJ.deal(bet: 100)
        XCTAssertEqual(dealerBJ.outcome, .dealerBlackjack)
        XCTAssertEqual(dealerBJ.chips, 400)
    }

    func testCannotBetMoreThanTheChips() {
        var game = BlackjackTable(chips: 100)
        XCTAssertFalse(game.deal(bet: 200))
        XCTAssertFalse(game.deal(bet: 0))
        XCTAssertTrue(game.deal(bet: 100))
    }

    func testShoeReshufflesWhenLow() {
        var game = BlackjackTable(chips: 1_000_000, decks: 1)
        for _ in 0..<60 {
            game.deal(bet: 10)
            game.stand()
            while game.dealerDraws() {}
        }
        XCTAssertFalse(game.shoe.isEmpty)
    }
}
