import AVFoundation

/// The console's sounds. They are the real system sound files when the app carries them (`Resources/CodeOS/Sounds`, bundled at build time)
/// or the user has them in `~/Library/Application Support/Jack/CodeOS/Sounds`, one file per cue, named after it. They are not in the
/// repository. Without them it falls back to bell notes synthesised in code. Nothing plays on its own: every sound answers a key press.
@MainActor final class CodeOSSound {
    static let shared = CodeOSSound()

    enum Cue: String, CaseIterable { case enter, move, tab, select, back, launch, panel, panelClose, home, notify }

    private static let rate = 44100.0
    /// C major pentatonic over two octaves.
    private static let scale: [Double] = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.7, 1318.5]
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    private var pool: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var cues: [Cue: AVAudioPCMBuffer] = [:]
    private var notes: [Int: AVAudioPCMBuffer] = [:]
    private var step = 2
    private var running = false
    private var samples: [Cue: AVAudioPCMBuffer?] = [:]
    /// Inside the app first (Jack.app/Contents/Resources/Sounds), then the user's own folder.
    private static let soundsDirectories = [
        Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS/Sounds")
    ].compactMap { $0 }

    private init() {}

    func move(forward: Bool) {
        if let sample = sample(.move) { schedule(sample); return }
        step = min(max(step + (forward ? 1 : -1), 0), Self.scale.count - 1)
        // At either end of the scale it bounces back, so a long walk keeps changing note.
        if step == 0 || step == Self.scale.count - 1 { step = forward ? Self.scale.count - 3 : 2 }
        let index = step
        let buffer = notes[index] ?? { let made = Self.bell(Self.scale[index], format: format); notes[index] = made; return made }()
        schedule(buffer)
    }

    func play(_ cue: Cue) {
        if let sample = sample(cue) { schedule(sample); return }
        let buffer = cues[cue] ?? { let made = Self.synthesize(cue, format: format); cues[cue] = made; return made }()
        schedule(buffer)
    }

    /// The cue's sound file converted to the engine's format, or nil when there is none.
    private func sample(_ cue: Cue) -> AVAudioPCMBuffer? {
        if let cached = samples[cue] { return cached }
        let loaded = Self.load(cue, as: format)
        samples[cue] = .some(loaded)
        return loaded
    }

    private static func load(_ cue: Cue, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        for (directory, ext) in soundsDirectories.flatMap({ directory in ["flac", "wav", "mp3", "m4a", "aiff"].map { (directory, $0) } }) {
            let url = directory.appendingPathComponent("\(cue.rawValue).\(ext)")
            guard let file = try? AVAudioFile(forReading: url),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: input)) != nil,
                  let converter = AVAudioConverter(from: file.processingFormat, to: format) else { continue }
            let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
            var supplied = false
            var failure: NSError?
            converter.convert(to: output, error: &failure) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if failure == nil, output.frameLength > 0 { return output }
        }
        return nil
    }

    /// Starts the engine and decodes every sound file now, so no key press waits for either.
    func prepare() {
        _ = start()
        for cue in Cue.allCases { _ = sample(cue) }
    }

    func stopAll() {
        guard running else { return }
        pool.forEach { $0.stop() }
        engine.stop()
        running = false
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard start() else { return }
        let player = pool[nextPlayer]
        nextPlayer = (nextPlayer + 1) % pool.count
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private func start() -> Bool {
        if running { return true }
        if pool.isEmpty {
            // The system sounds are already finished, so they go straight to the mixer: a reverb only added delay.
            for _ in 0..<8 {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                pool.append(node)
            }
            engine.mainMixerNode.outputVolume = 0.85
        }
        do {
            try engine.start()
            running = true
        } catch {
            return false
        }
        return true
    }

    // MARK: Synthesis

    private static func make(_ format: AVAudioFormat, duration: Double, _ sample: (Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let t = Double(frame) / rate
            // A short attack and tail stop the clicks.
            let edge = min(1, t / 0.003, (duration - t) / 0.02)
            let value = Float(sample(t) * max(edge, 0))
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        return buffer
    }

    /// A struck glass bell: a fundamental with two inharmonic-ish partials that die faster.
    private static func voice(_ freq: Double, _ t: Double, gain: Double = 1) -> Double {
        guard t >= 0 else { return 0 }
        let body = sin(2 * .pi * freq * t) * exp(-t * 6.5)
            + 0.38 * sin(2 * .pi * freq * 2.0 * t) * exp(-t * 11)
            + 0.14 * sin(2 * .pi * freq * 3.01 * t) * exp(-t * 18)
        return gain * body
    }

    private static func bell(_ freq: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        make(format, duration: 0.8) { t in voice(freq, t, gain: 0.3) }
    }

    private static func synthesize(_ cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer {
        switch cue {
        case .move: return bell(783.99, format: format)
        case .enter, .home: return synthesize(.select, format: format)
        case .panelClose: return synthesize(.back, format: format)
        case .notify: return bell(1046.5, format: format)
        case .tab:
            return make(format, duration: 0.7) { t in voice(783.99, t, gain: 0.22) + voice(1046.5, t - 0.07, gain: 0.22) }
        case .select:
            return make(format, duration: 1.1) { t in
                voice(523.25, t, gain: 0.2) + voice(659.25, t - 0.06, gain: 0.2) + voice(783.99, t - 0.12, gain: 0.2) + voice(1046.5, t - 0.18, gain: 0.22)
            }
        case .back:
            return make(format, duration: 0.8) { t in voice(783.99, t, gain: 0.22) + voice(587.33, t - 0.07, gain: 0.22) + voice(523.25, t - 0.14, gain: 0.2) }
        case .panel:
            return make(format, duration: 1.0) { t in
                let sweep = 0.1 * sin(2 * .pi * (220 * t + 700 * t * t)) * pow(sin(.pi * min(t / 0.45, 1)), 2) * (t < 0.45 ? 1 : 0)
                return sweep + voice(659.25, t - 0.12, gain: 0.2) + voice(987.77, t - 0.2, gain: 0.18)
            }
        case .launch:
            return make(format, duration: 1.8) { t in
                let sweep = t < 0.8 ? 0.16 * sin(2 * .pi * (160 * t + 520 * t * t)) * pow(sin(.pi * t / 0.8), 2) : 0
                return sweep + voice(523.25, t - 0.55, gain: 0.2) + voice(659.25, t - 0.6, gain: 0.2) + voice(783.99, t - 0.65, gain: 0.2) + voice(1046.5, t - 0.7, gain: 0.2)
            }
        }
    }
}
