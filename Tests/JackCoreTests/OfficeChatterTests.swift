import XCTest
@testable import JackCore

@MainActor final class OfficeChatterTests: XCTestCase {
    private func chatter(capturing store: @escaping ([StellarMessage]) -> Void, answer: String = "Pues sí, y encima huele a menta.") -> OfficeChatter {
        let chatter = OfficeChatter()
        let model = StellarModel(id: "ollama/gemma4:31b-cloud", name: OfficeNarrator.modelName, server: StellarServer.builtIn[0], tools: false, contextLength: 8192, isCloud: true)
        chatter.inspectModel = { model }
        chatter.streamRequest = { _, messages, _ in
            store(messages)
            return AsyncThrowingStream { continuation in continuation.yield(.text(answer)); continuation.finish() }
        }
        return chatter
    }

    func testOpeningAsksForACuriousTopic() async throws {
        var sent: [StellarMessage] = []
        let line = try await chatter(capturing: { sent = $0 }).line(as: "Remy", with: "Chica", seed: "un animal con una habilidad rarísima", transcript: [], lightMode: false)
        XCTAssertEqual(line, "Pues sí, y encima huele a menta.")
        XCTAssertEqual(sent.map(\.role), ["system", "user"])
        XCTAssertTrue(sent[1].content.contains("un animal con una habilidad rarísima"))
    }

    func testReplyUsesTheTranscriptFromTheSpeakersPointOfView() async throws {
        var sent: [StellarMessage] = []
        let transcript = [OfficeChatter.Line(speaker: "Remy", text: "¿Sabías lo del ajolote?"), OfficeChatter.Line(speaker: "Chica", text: "Qué dices, cuéntame.")]
        _ = try await chatter(capturing: { sent = $0 }).line(as: "Remy", with: "Chica", seed: "x", transcript: transcript, lightMode: false)
        XCTAssertEqual(sent.map(\.role), ["system", "user", "assistant", "user"])
    }

    func testLightModeNeverCallsTheModel() async {
        do {
            _ = try await chatter(capturing: { _ in XCTFail("no debía llamar al modelo") }).line(as: "A", with: "B", seed: "x", transcript: [], lightMode: true)
            XCTFail("debía cancelarse")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class OfficePersonasTests: XCTestCase {
    func testOnlyTheAddedAvatarsHaveAPersonality() {
        for id in ["DEADPOOL", "LAMINE", "FRANKLIN"] {
            let persona = OfficePersonas.persona(forAvatar: id)
            XCTAssertNotNil(persona, id)
            XCTAssertFalse(persona?.profile.isEmpty ?? true)
        }
        for id in ["REMY", "CH31", "GIRL"] { XCTAssertNil(OfficePersonas.persona(forAvatar: id), id) }
    }

    @MainActor func testPersonalityGoesIntoThePrompt() async throws {
        var sent: [StellarMessage] = []
        let chatter = OfficeChatter()
        let model = StellarModel(id: "ollama/gemma4:31b-cloud", name: OfficeNarrator.modelName, server: StellarServer.builtIn[0], tools: false, contextLength: 8192, isCloud: true)
        chatter.inspectModel = { model }
        chatter.streamRequest = { _, messages, _ in
            sent = messages
            return AsyncThrowingStream { $0.yield(.text("Hola")); $0.finish() }
        }
        let wade = try XCTUnwrap(OfficePersonas.persona(forAvatar: "DEADPOOL"))
        _ = try await chatter.line(as: "Deadpool", persona: wade.profile, with: "Franklin", otherAbout: "Franklin, de GTA V", seed: "x", transcript: [], lightMode: false)
        XCTAssertTrue(sent[0].content.contains("Wade Wilson"))
        XCTAssertTrue(sent[0].content.contains("Franklin, de GTA V"))
    }
}
