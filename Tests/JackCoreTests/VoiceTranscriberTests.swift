import XCTest
@testable import JackCore

final class VoiceTranscriberTests: XCTestCase {
    func testCredentialResolutionPrefersKeychainThenEnvironmentThenDebugFallback() {
        XCTAssertEqual(VoiceConfig.resolveAPIKey(keychain: " saved ", environment: "env", fallback: "debug"), "saved")
        XCTAssertEqual(VoiceConfig.resolveAPIKey(keychain: nil, environment: " env ", fallback: "debug"), "env")
        XCTAssertEqual(VoiceConfig.resolveAPIKey(keychain: nil, environment: nil, fallback: " debug "), "debug")
    }

    func testCredentialResolutionIgnoresEmptyValues() {
        XCTAssertEqual(VoiceConfig.resolveAPIKey(keychain: " \n", environment: "", fallback: nil), "")
        XCTAssertEqual(VoiceConfig.resolveAPIKey(keychain: "", environment: " env ", fallback: nil), "env")
    }

    func testBodyCarriesModelLanguageAndAudio() {
        let body = String(decoding: VoiceTranscriber.body(audio: Data("AUDIO".utf8), boundary: "b"), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\n\(VoiceConfig.model)"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\n\(VoiceConfig.language)"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"voice.wav\""))
        XCTAssertTrue(body.contains("AUDIO"))
        XCTAssertTrue(body.hasSuffix("--b--\r\n"))
    }

    func testErrorMessageReadsGroqError() {
        let data = Data(#"{"error":{"message":"rate limit"}}"#.utf8)
        XCTAssertEqual(VoiceTranscriber.errorMessage(data, status: 429), "rate limit")
        XCTAssertEqual(VoiceTranscriber.errorMessage(data, status: 401), "la API key de Groq no es válida")
        XCTAssertEqual(VoiceTranscriber.errorMessage(Data(), status: 500), "HTTP 500")
    }

    func testEmptyAudioIsNoSpeechWithoutReadingUserCredential() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jack-voice-test-\(UUID().uuidString).wav")
        try? Data(count: 44).write(to: file)
        do { _ = try await VoiceTranscriber.transcribe(file, apiKey: "test-key"); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? VoiceError, .noSpeech) }
    }

    func testMissingKeyDoesNotReadUserKeychain() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jack-voice-test-\(UUID().uuidString).wav")
        try? Data(count: 44).write(to: file)
        do { _ = try await VoiceTranscriber.transcribe(file, apiKey: ""); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? VoiceError, .missingKey) }
    }
}
