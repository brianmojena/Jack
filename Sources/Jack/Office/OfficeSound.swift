import AVFoundation
import Foundation

/// Los sonidos de la oficina: «tics» secos y cortos sintetizados al abrir un menú, al pasar el ratón, al elegir una acción y al volver atrás. No lleva ningún archivo de audio.
@MainActor enum OfficeSound {
    case open, hover, select, back

    private static var players: [OfficeSound: AVAudioPlayer] = [:]

    func play() {
        if Self.players[self] == nil { Self.players[self] = try? AVAudioPlayer(data: wave) }
        guard let player = Self.players[self] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Notas (frecuencia en Hz, duración en s) de cada sonido.
    private var notes: [(from: Double, to: Double, duration: Double)] {
        switch self {
        case .open: [(2100, 1900, 0.022)]
        case .hover: [(3000, 3000, 0.008)]
        case .select: [(1500, 1300, 0.03)]
        case .back: [(1000, 800, 0.03)]
        }
    }

    private var volume: Double { self == .hover ? 0.08 : 0.35 }

    /// Un WAV de 16 bits con las notas, cada una con ataque rápido y caída suave.
    private var wave: Data {
        let rate = 44_100.0
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.duration * rate)
            var phase = 0.0
            for index in 0..<count {
                let t = Double(index) / Double(count)
                let frequency = note.from + (note.to - note.from) * t
                phase += 2 * .pi * frequency / rate
                let envelope = min(1, Double(index) / (0.0006 * rate)) * pow(1 - t, 3.5)
                // Un golpe seco y corto: un «tic».
                let value = (sin(phase) + 0.5 * sin(2.7 * phase)) / 1.5 * envelope * volume
                samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
