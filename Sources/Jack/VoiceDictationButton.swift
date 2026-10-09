import JackCore
import SwiftUI

/// One dictation at a time: a tap on the microphone starts recording and the next one stops it and transcribes.
@MainActor
final class VoiceDictation: ObservableObject {
    enum Phase: Equatable { case idle, recording(UUID), transcribing(UUID) }

    @Published private(set) var phase = Phase.idle
    @Published var errorMessage: String?
    private let recorder = VoiceRecorder()
    private var autoStop: Task<Void, Never>?

    func phase(for id: UUID) -> Phase {
        switch phase {
        case .recording(id): .recording(id)
        case .transcribing(id): .transcribing(id)
        default: .idle
        }
    }

    /// Starts when idle; stops and hands the text to `insert` when it was recording this conversation.
    func toggle(for id: UUID, insert: @escaping (String) -> Void) {
        switch phase {
        case .idle: Task { await start(for: id, insert: insert) }
        case .recording(id): finish(id, insert: insert)
        default: break
        }
    }

    func cancel() {
        autoStop?.cancel()
        recorder.cancel()
        phase = .idle
    }

    private func start(for id: UUID, insert: @escaping (String) -> Void) async {
        errorMessage = nil
        guard await VoiceRecorder.requestAccess() else { errorMessage = VoiceError.microphoneDenied.errorDescription; return }
        do { try recorder.start() } catch {
            errorMessage = (error as? VoiceError ?? .recordingFailed).errorDescription
            return
        }
        phase = .recording(id)
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VoiceConfig.maxSeconds))
            guard !Task.isCancelled else { return }
            self?.finish(id, insert: insert)
        }
    }

    private func finish(_ id: UUID, insert: @escaping (String) -> Void) {
        autoStop?.cancel()
        guard let file = recorder.stop() else { phase = .idle; return }
        phase = .transcribing(id)
        Task {
            defer { phase = .idle }
            do { insert(try await VoiceTranscriber.transcribe(file)) }
            catch {
                JackLog.write("voice: \(error.localizedDescription)")
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The composer's microphone: tap to dictate, tap again to stop and drop the text into the message.
struct VoiceDictationButton: View {
    @ObservedObject var dictation: VoiceDictation
    let conversationID: UUID
    let insert: (String) -> Void
    let report: (String) -> Void

    var body: some View {
        let phase = dictation.phase(for: conversationID)
        Button { dictation.toggle(for: conversationID, insert: insert) } label: {
            Group {
                switch phase {
                case .idle: Image(systemName: "mic").foregroundStyle(JackPalette.muted)
                case .recording: Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                case .transcribing: ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only the chat that is recording can stop it; while one dictates or transcribes, the others wait.
        .disabled(!isRecording(phase) && dictation.phase != .idle)
        .help(isRecording(phase) ? "Detener y transcribir" : "Dictar con la voz (un toque para empezar, otro para parar)")
        .accessibilityLabel(isRecording(phase) ? "Detener dictado" : "Dictar")
        .onChange(of: dictation.errorMessage) { _, message in
            if let message, dictation.phase(for: conversationID) == .idle { report(message) }
        }
    }

    private func isRecording(_ phase: VoiceDictation.Phase) -> Bool {
        if case .recording = phase { return true }
        return false
    }
}
