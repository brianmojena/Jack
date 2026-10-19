import XCTest
@testable import JackCore

final class ChessTests: XCTestCase {
    private func perft(_ position: ChessPosition, _ depth: Int) -> Int {
        let moves = position.legalMoves()
        if depth == 1 { return moves.count }
        return moves.reduce(0) { $0 + perft(position.applying($1), depth - 1) }
    }

    func testMoveGenerationMatchesKnownNodeCounts() throws {
        let cases: [(String, [Int])] = [
            ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", [20, 400, 8902]),
            ("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", [48, 2039]),
            ("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812]),
            ("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264]),
            ("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486])
        ]
        for (fen, counts) in cases {
            let position = try XCTUnwrap(ChessPosition(fen: fen))
            XCTAssertEqual(position.fen, fen)
            for (index, count) in counts.enumerated() { XCTAssertEqual(perft(position, index + 1), count, "\(fen) a profundidad \(index + 1)") }
        }
    }

    func testNotationAndOutcomes() throws {
        var game = ChessGame()
        for move in ["f2f3", "e7e5", "g2g4", "d8h4"] { XCTAssertNotNil(game.play(try XCTUnwrap(game.position.move(uci: move)))) }
        XCTAssertEqual(game.movetext, "1. f3 e5 2. g4 Qh4#")
        XCTAssertEqual(game.outcome, .checkmate(winner: .black))

        let castling = try XCTUnwrap(ChessPosition(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        let names = castling.legalMoves().map { castling.san($0) }
        XCTAssertTrue(names.contains("O-O") && names.contains("O-O-O") && names.contains("Rxa8+"))

        let stalemate = try XCTUnwrap(ChessPosition(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
        XCTAssertEqual(stalemate.outcome, .stalemate)
        XCTAssertEqual(try XCTUnwrap(ChessPosition(fen: "8/8/8/4k3/8/8/3K4/8 w - - 0 1")).outcome, .insufficientMaterial)
    }

    func testIllegalMovesAreRejected() {
        var game = ChessGame()
        XCTAssertNil(game.play(ChessMove(from: ChessSquare.parse("e2")!, to: ChessSquare.parse("e5")!)))
        XCTAssertNil(game.position.move(uci: "e7e5"))
        XCTAssertNotNil(game.position.move(uci: "e2-e4"))
    }

    func testEffectsOfSpecialMoves() throws {
        let enPassant = try XCTUnwrap(ChessPosition(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 3"))
        let capture = try XCTUnwrap(enPassant.move(uci: "e5d6"))
        XCTAssertEqual(enPassant.effects(of: capture).captured?.square, ChessSquare.parse("d5"))
        let castling = try XCTUnwrap(ChessPosition(fen: "4k3/8/8/8/8/8/8/4K2R w K - 0 1"))
        let rook = castling.effects(of: try XCTUnwrap(castling.move(uci: "e1g1"))).rook
        XCTAssertEqual(rook?.from, ChessSquare.parse("h1"))
        XCTAssertEqual(rook?.to, ChessSquare.parse("f1"))
    }

    @MainActor func testMasterAnswerIsValidatedAgainstLegalMoves() throws {
        let position = ChessPosition.start
        let legal = position.legalMoves()
        let sans = legal.map { position.san($0) }
        let good = OfficeChessPlayer.parse(#"{"move": "Nf3", "comment": "Desarrollo con tempo."}"#, in: position, legal: legal, sans: sans)
        XCTAssertEqual(good?.0.uci, "g1f3")
        XCTAssertEqual(good?.1, "Desarrollo con tempo.")
        XCTAssertEqual(OfficeChessPlayer.parse(#"```json {"move": "e2e4"} ```"#, in: position, legal: legal, sans: sans)?.0.uci, "e2e4")
        XCTAssertEqual(OfficeChessPlayer.parse(#"{"move": "nf3"}"#, in: position, legal: legal, sans: sans)?.0.uci, "g1f3")
        XCTAssertNil(OfficeChessPlayer.parse(#"{"move": "Qh5"}"#, in: position, legal: legal, sans: sans))
        XCTAssertNil(OfficeChessPlayer.parse("e4", in: position, legal: legal, sans: sans))
    }

    @MainActor func testPlayerAsksAgainAfterAnIllegalMove() async throws {
        let player = OfficeChessPlayer()
        let model = StellarModel(id: "ollama/gemma4:31b-cloud", name: OfficeNarrator.modelName, server: StellarServer.builtIn[0], tools: false, contextLength: 8192, isCloud: true)
        player.inspectModel = { model }
        var requests = 0
        var sawImage = false
        player.streamRequest = { _, messages, _ in
            requests += 1
            sawImage = sawImage || messages.contains { $0.images?.isEmpty == false }
            let answer = requests == 1 ? #"{"move": "Qh5", "comment": "x"}"# : #"{"move": "e4", "comment": "Al centro."}"#
            return AsyncThrowingStream { continuation in continuation.yield(.text(answer)); continuation.finish() }
        }
        let master = try XCTUnwrap(ChessMasters.master(id: "capablanca"))
        let choice = try await player.choose(game: ChessGame(), as: master, against: nil, color: .white, playedBy: "Remy", lightMode: false)
        XCTAssertEqual(choice.san, "e4")
        XCTAssertEqual(choice.comment, "Al centro.")
        XCTAssertFalse(choice.improvised)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(sawImage)
    }

    @MainActor func testPlayerImprovisesWhenTheModelNeverAnswersALegalMove() async throws {
        let player = OfficeChessPlayer()
        let model = StellarModel(id: "ollama/gemma4:31b-cloud", name: OfficeNarrator.modelName, server: StellarServer.builtIn[0], tools: false, contextLength: 8192, isCloud: true)
        player.inspectModel = { model }
        player.streamRequest = { _, _, _ in AsyncThrowingStream { continuation in continuation.yield(.text("no sé")); continuation.finish() } }
        let master = try XCTUnwrap(ChessMasters.master(id: "tal"))
        let choice = try await player.choose(game: ChessGame(), as: master, against: nil, color: .white, playedBy: "Remy", lightMode: false)
        XCTAssertTrue(choice.improvised)
        XCTAssertTrue(ChessPosition.start.legalMoves().contains(choice.move))
    }

    func testBoardImageIsAPNG() throws {
        let data = try XCTUnwrap(ChessBoardImage.png(of: .start))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
