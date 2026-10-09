import AVFoundation
import Foundation

/// Where the voice transcription goes. The key lives in the git-ignored VoiceKey.swift and is built into the app;
/// change it there before distributing the app.
public enum VoiceConfig {
    public static let apiKey = VoiceKey.value
    public static let model = "whisper-large-v3-turbo"
    public static let language = "es"
    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    /// Groq's free tier takes files up to 25 MB; 16 kHz mono 16-bit audio is 32 KB/s, so this stays far below it.
    public static let maxSeconds: TimeInterval = 600
}

public enum VoiceError: LocalizedError, Equatable {
    case microphoneDenied
    case missingKey
    case recordingFailed
    case noSpeech
    case server(String)
    case offline

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Jack no tiene permiso para usar el micrófono. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Micrófono."
        case .missingKey: "Falta la API key de Groq en VoiceConfig."
        case .recordingFailed: "No se pudo iniciar la grabación."
        case .noSpeech: "No se oyó nada."
        case .server(let message): "La transcripción falló: \(message)"
        case .offline: "Sin conexión: la transcripción por voz necesita internet."
        }
    }
}

/// Records the microphone to a temporary 16 kHz mono WAV, which is what Whisper works on.
@MainActor
public final class VoiceRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    public override init() { super.init() }

    public var isRecording: Bool { recorder?.isRecording == true }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jack-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: VoiceConfig.maxSeconds) else { throw VoiceError.recordingFailed }
        self.recorder = recorder
        fileURL = url
    }

    /// Stops and returns the recording, or nil when there is none.
    public func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        defer { fileURL = nil }
        return fileURL
    }

    public func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }
}

public enum VoiceTranscriber {
    /// Sends the audio file to Groq's Whisper and returns the text. The file is deleted afterwards.
    public static func transcribe(_ file: URL, session: URLSession = .shared) async throws -> String {
        defer { try? FileManager.default.removeItem(at: file) }
        guard !VoiceConfig.apiKey.isEmpty else { throw VoiceError.missingKey }
        let audio = try Data(contentsOf: file)
        // A header alone is 44 bytes; under half a second there is nothing to transcribe.
        guard audio.count > 16_000 else { throw VoiceError.noSpeech }

        let boundary = "jack-\(UUID().uuidString)"
        var request = URLRequest(url: VoiceConfig.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(VoiceConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(audio: audio, boundary: boundary)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
            throw VoiceError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw VoiceError.server("respuesta inválida") }
        guard http.statusCode == 200 else { throw VoiceError.server(errorMessage(data, status: http.statusCode)) }
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceError.noSpeech }
        return text
    }

    static func body(audio: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", VoiceConfig.model)
        field("language", VoiceConfig.language)
        field("response_format", "text")
        field("temperature", "0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return status == 401 ? "la API key de Groq no es válida" : message
        }
        return "HTTP \(status)"
    }
}
