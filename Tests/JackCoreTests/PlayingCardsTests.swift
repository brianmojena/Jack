import XCTest
@testable import JackCore

final class PlayingCardsTests: XCTestCase {
    func testDeckHasFiftyTwoDifferentCards() {
        let deck = PlayingCard.deck
        XCTAssertEqual(deck.count, 52)
        XCTAssertEqual(Set(deck).count, 52)
        XCTAssertEqual(Set(deck.map(\.id)).count, 52)
        XCTAssertEqual(deck.filter { $0.suit == .hearts }.count, 13)
    }

    func testRanksAndNames() {
        XCTAssertTrue(CardRank.ace > CardRank.king)
        XCTAssertEqual(CardRank.ten.symbol, "10")
        XCTAssertEqual(CardRank.queen.symbol, "Q")
        XCTAssertTrue(CardRank.jack.isFace && !CardRank.ten.isFace)
        XCTAssertEqual(PlayingCard(.ace, of: .spades).title, "as de picas")
        XCTAssertTrue(CardSuit.diamonds.isRed && !CardSuit.clubs.isRed)
    }
}

final class OfficeCardTalkerTests: XCTestCase {
    @MainActor func testSpeakerGetsSecretAndChatAndStripsItsOwnName() async throws {
        let talker = OfficeCardTalker()
        talker.inspectModel = { StellarModel(id: "ollama/gemma4:31b-cloud", name: OfficeNarrator.modelName, server: StellarServer.builtIn[0], tools: false, contextLength: 8192, isCloud: true) }
        var sent: [StellarMessage] = []
        talker.streamRequest = { _, messages, _ in
            sent = messages
            return AsyncThrowingStream { continuation in continuation.yield(.text("Remy: «Yo no miento, jamás.»")); continuation.finish() }
        }
        let speaker = OfficeCardTalker.Speaker(name: "Remy", profile: "Eres un cocinero.", game: "el Mentiroso", others: ["Ruben", "Lamine"])
        let line = try await talker.comment(on: "Ruben te acusa", as: speaker, secret: "Estás mintiendo.", chat: ["Ruben: ja"], lightMode: false)
        XCTAssertEqual(line, "Yo no miento, jamás.")
        XCTAssertTrue(sent.last?.content.contains("Estás mintiendo.") == true)
        XCTAssertTrue(sent.last?.content.contains("Ruben: ja") == true)
        XCTAssertTrue(sent.first?.content.contains("Eres un cocinero.") == true)
        do {
            _ = try await talker.comment(on: "algo", as: speaker, lightMode: true)
            XCTFail("En Light no se habla")
        } catch is CancellationError {}
    }
}
