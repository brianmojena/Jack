import XCTest
@testable import JackCore

@MainActor final class OfficeBrainTests: XCTestCase {
    override func tearDown() async throws {
        // Las pruebas cambian cómo se consulta a los modelos: se vuelve a lo de siempre.
        OfficeBrain.askCLI = { provider, model, system, prompt in try await ChatAsideService.oneShot(provider: provider, model: model, system: system, prompt: prompt) }
    }

    private func text(_ stream: AsyncThrowingStream<StellarChunk, Error>) async throws -> String {
        var output = ""
        for try await chunk in stream { if case .text(let piece) = chunk { output += piece } }
        return output
    }

    func testSingleUserMessageIsPassedAsIs() {
        let (system, prompt) = OfficeBrain.flatten([StellarMessage(role: "system", content: "Eres Ana."), StellarMessage(role: "system", content: "Equipo: nadie."),
                                                    StellarMessage(role: "user", content: "Hola")])
        XCTAssertEqual(system, "Eres Ana.\n\nEquipo: nadie.")
        XCTAssertEqual(prompt, "Hola")
    }

    func testConversationIsFlattenedIntoTurns() {
        let (_, prompt) = OfficeBrain.flatten([StellarMessage(role: "system", content: "x"), StellarMessage(role: "user", content: "Buenas"),
                                               StellarMessage(role: "assistant", content: "Qué tal"), StellarMessage(role: "user", content: "Bien")])
        XCTAssertTrue(prompt.hasPrefix("Interlocutor: Buenas\n\nTú: Qué tal\n\nInterlocutor: Bien"))
        XCTAssertTrue(prompt.hasSuffix("solo con tu siguiente intervención."))
    }

    func testCLIProvidersAnswerThroughTheirCLI() async throws {
        var asked: [(ChatProvider, String, String, String)] = []
        OfficeBrain.askCLI = { provider, model, system, prompt in
            asked.append((provider, model, system, prompt))
            return "Respuesta de \(provider.rawValue)"
        }
        for provider in [ChatProvider.claude, .codex, .opencode] {
            let stream = try OfficeBrain.stream([StellarMessage(role: "system", content: "Instrucciones"), StellarMessage(role: "user", content: "Pregunta")],
                                                choice: OfficeBrainChoice(provider: provider, model: "m"))
            let answer = try await text(stream)
            XCTAssertEqual(answer, "Respuesta de \(provider.rawValue)")
        }
        XCTAssertEqual(asked.map(\.0), [.claude, .codex, .opencode])
        XCTAssertEqual(asked[0].2, "Instrucciones")
        XCTAssertEqual(asked[0].3, "Pregunta")
    }

    func testCLIFailureReachesTheCaller() async {
        OfficeBrain.askCLI = { _, _, _, _ in throw StellarError.message("sin conexión") }
        do {
            _ = try await text(try OfficeBrain.stream([StellarMessage(role: "user", content: "x")], choice: OfficeBrainChoice(provider: .claude, model: "sonnet")))
            XCTFail("Tenía que fallar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sin conexión"))
        }
    }

    func testUnknownStellarModelIsRejected() {
        XCTAssertThrowsError(try OfficeBrain.stream([StellarMessage(role: "user", content: "x")], choice: OfficeBrainChoice(provider: .stellar, model: "noexiste/modelo")))
    }

    func testChoiceRoundTripsAndHasATitle() throws {
        let choice = OfficeBrainChoice(provider: .claude, model: "sonnet")
        let decoded = try JSONDecoder().decode(OfficeBrainChoice.self, from: JSONEncoder().encode(choice))
        XCTAssertEqual(decoded, choice)
        XCTAssertEqual(choice.title, "Claude Code · sonnet")
        XCTAssertEqual(OfficeBrainChoice(provider: .codex, model: "").title, "Codex")
    }
}
