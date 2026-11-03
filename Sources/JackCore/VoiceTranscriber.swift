import AVFoundation
import Foundation
import Security

/// Voice credentials stay in the user's Keychain; the environment and DEBUG fallback support local setups.
public enum VoiceConfig {
    private static let keychainService = "dev.jack.voice"
    private static let keychainAccount = "groq-api-key"

    public static var apiKey: String {
        let keychain = savedAPIKey()
        let environment = ProcessInfo.processInfo.environment["GROQ_API_KEY"]
        #if DEBUG
        return resolveAPIKey(keychain: keychain, environment: environment, fallback: VoiceKey.value)
        #else
        return resolveAPIKey(keychain: keychain, environment: environment)
        #endif
    }

    /// Pure seam for precedence tests; callers never need to read the keychain to resolve a test value.
    static func resolveAPIKey(keychain: String?, environment: String?, fallback: String? = nil) -> String {
        [keychain, environment, fallback]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    public static func saveAPIKey(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw VoiceCredentialError.emptyKey }
        let query = keychainQuery()
        let update = [kSecValueData as String: Data(value.utf8)] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw VoiceCredentialError.saveFailed }
        } else if status != errSecSuccess {
            throw VoiceCredentialError.saveFailed
        }
    }

    public static func deleteAPIKey() throws {
        let status = SecItemDelete(keychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceCredentialError.deleteFailed
        }
    }

    private static func savedAPIKey() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    public static let model = "whisper-large-v3-turbo"
    public static let language = "es"
    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    /// Groq's free tier takes files up to 25 MB; 16 kHz mono 16-bit audio is 32 KB/s, so this stays far below it.
    public static let maxSeconds: TimeInterval = 600
}

public enum VoiceCredentialError: LocalizedError {
    case emptyKey
    case saveFailed
    case deleteFailed

    public var errorDescription: String? {
        switch self {
        case .emptyKey: "Escribe una API key de Groq antes de guardarla."
        case .saveFailed: "No se pudo guardar la API key de Groq en el llavero."
        case .deleteFailed: "No se pudo borrar la API key de Groq del llavero."
        }
    }
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
        case .missingKey: "Falta la API key de Groq. Guárdala en Ajustes › General."
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
        try await transcribe(file, apiKey: VoiceConfig.apiKey, session: session)
    }

    static func transcribe(_ file: URL, apiKey: String, session: URLSession = .shared) async throws -> String {
        defer { try? FileManager.default.removeItem(at: file) }
        guard !apiKey.isEmpty else { throw VoiceError.missingKey }
        let audio = try Data(contentsOf: file)
        // A header alone is 44 bytes; under half a second there is nothing to transcribe.
        guard audio.count > 16_000 else { throw VoiceError.noSpeech }

        let boundary = "jack-\(UUID().uuidString)"
        var request = URLRequest(url: VoiceConfig.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
