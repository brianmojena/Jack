import XCTest
@testable import JackCore

final class LiarGameTests: XCTestCase {
    private func c(_ rank: CardRank, _ suit: CardSuit = .spades) -> PlayingCard { PlayingCard(rank, of: suit) }

    func testDealsTheWholeDeckBetweenThree() {
        let game = LiarGame(players: 3)
        XCTAssertEqual(game.hands.map(\.count).sorted(), [17, 17, 18])
        XCTAssertEqual(Set(game.hands.flatMap { $0 }).count, 52)
        XCTAssertEqual(game.phase, .playing(turn: 0))
        XCTAssertEqual(game.requiredRank, .ace)
    }

    func testHonestPlayChallengedMakesTheCallerTakeThePile() {
        var game = LiarGame(hands: [[c(.ace), c(.five)], [c(.two)], [c(.three)]])
        XCTAssertTrue(game.play([c(.ace)]))
        XCTAssertEqual(game.phase, .responding(responder: 1))
        let resolution = game.challenge()
        XCTAssertEqual(resolution?.taker, 1)
        XCTAssertEqual(resolution?.wasLie, false)
        XCTAssertEqual(game.hands[1].count, 2)
        XCTAssertTrue(game.pile.isEmpty)
        XCTAssertEqual(game.phase, .playing(turn: 1))
        XCTAssertEqual(game.requiredRank, .two)
    }

    func testLiarCaughtTakesThePile() {
        var game = LiarGame(hands: [[c(.five), c(.six)], [c(.two)], [c(.three)]])
        game.play([c(.five)])
        game.pass()
        XCTAssertEqual(game.phase, .responding(responder: 2))
        let resolution = game.challenge()
        XCTAssertEqual(resolution?.taker, 0)
        XCTAssertEqual(resolution?.wasLie, true)
        XCTAssertEqual(resolution?.caller, 2)
        XCTAssertEqual(game.hands[0].count, 2)
    }

    func testNobodyChallengesAndTheTurnMovesOn() {
        var game = LiarGame(hands: [[c(.ace), c(.five)], [c(.two)], [c(.three)]])
        game.play([c(.ace)])
        game.pass()
        game.pass()
        XCTAssertEqual(game.phase, .playing(turn: 1))
        XCTAssertEqual(game.pile.count, 1)
        XCTAssertEqual(game.requiredRank, .two)
    }

    func testEmptyingTheHandWinsUnlessCaughtLying() {
        var winning = LiarGame(hands: [[c(.ace)], [c(.two)], [c(.three)]])
        winning.play([c(.ace)])
        winning.pass()
        winning.pass()
        XCTAssertEqual(winning.winner, 0)

        var caught = LiarGame(hands: [[c(.five)], [c(.two)], [c(.three)]])
        caught.play([c(.five)])
        caught.challenge()
        XCTAssertNil(caught.winner)
        XCTAssertEqual(caught.hands[0].count, 1)

        var honest = LiarGame(hands: [[c(.ace)], [c(.two)], [c(.three)]])
        honest.play([c(.ace)])
        honest.challenge()
        XCTAssertEqual(honest.winner, 0)
    }

    func testIllegalPlaysAreRejected() {
        var game = LiarGame(hands: [[c(.ace), c(.two)], [c(.three)], [c(.four)]])
        XCTAssertFalse(game.play([]))
        XCTAssertFalse(game.play([c(.king)]))
        XCTAssertFalse(game.play([c(.ace), c(.ace)]))
        XCTAssertNil(game.challenge())
        XCTAssertTrue(game.play([c(.ace), c(.two)]))
        XCTAssertFalse(game.play([c(.three)]))
    }

    func testAIPlaysTheCardsItHasOrBluffsASingleOne() {
        var rng = SystemRandomNumberGenerator()
        let hand = [c(.ace, .spades), c(.ace, .hearts), c(.five), c(.nine)]
        let honest = LiarAI.cards(hand: hand, required: .ace, personality: LiarPersonality(bluff: 0, suspicion: 0.5), using: &rng)
        XCTAssertEqual(Set(honest), [c(.ace, .spades), c(.ace, .hearts)])
        let bluff = LiarAI.cards(hand: hand, required: .king, personality: LiarPersonality(bluff: 0, suspicion: 0.5), using: &rng)
        XCTAssertEqual(bluff.count, 1)
        XCTAssertTrue(hand.contains(bluff[0]))
    }

    func testAIAlwaysChallengesAnImpossibleClaimOrALastCardGamble() {
        var rng = SystemRandomNumberGenerator()
        var game = LiarGame(hands: [[c(.five), c(.six), c(.seven), c(.eight)], [c(.ace, .hearts), c(.ace, .clubs), c(.ace, .diamonds)], [c(.two)]])
        game.play([c(.five), c(.six), c(.seven), c(.eight)])
        // El jugador 1 tiene tres ases y le dicen cuatro: es imposible.
        XCTAssertTrue(LiarAI.shouldChallenge(game: game, me: 1, personality: LiarPersonality(bluff: 0, suspicion: 0), using: &rng))
        // Se queda sin cartas: hay que pararlo.
        XCTAssertTrue(LiarAI.shouldChallenge(game: game, me: 2, personality: LiarPersonality(bluff: 0, suspicion: 0), using: &rng))
    }

    func testHypergeometric() {
        XCTAssertEqual(LiarAI.hypergeometricAtLeast(0, copies: 4, unknown: 40, draws: 10), 1)
        XCTAssertEqual(LiarAI.hypergeometricAtLeast(5, copies: 4, unknown: 40, draws: 10), 0)
        let one = LiarAI.hypergeometricAtLeast(1, copies: 4, unknown: 40, draws: 10)
        XCTAssertGreaterThan(one, 0.6)
        XCTAssertLessThan(one, 0.8)
    }
}
