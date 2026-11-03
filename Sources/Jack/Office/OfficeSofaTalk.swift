import Foundation
#if canImport(JackCore)
import JackCore
#endif

/// Dos personajes del sofá charlan de un tema curioso al azar: cada uno dice su línea (la escribe Gemma como esa persona) en su
/// bocadillo, por turnos, hasta que el usuario los para o se alcanza el límite de la charla.
@MainActor final class OfficeSofaTalk: ObservableObject {
    @Published private(set) var pair: [Int] = []
    /// Lo que dice cada uno en su bocadillo, por puesto.
    @Published private(set) var said: [Int: String] = [:]
    private var task: Task<Void, Never>?
    private let chatter = OfficeChatter()
    /// Cuántas intervenciones dura una charla como máximo (cada una es una petición a Gemma).
    private let limit = 40

    /// Quién es cada uno: cómo se llama y, si su avatar tiene personalidad, cómo es.
    struct Person {
        var name: String
        var profile: String?
        var about: String?
        /// El modelo con que piensa; sin elegir, Gemma.
        var brain: OfficeBrainChoice?
    }

    var isActive: Bool { !pair.isEmpty }

    func involves(_ slot: Int) -> Bool { pair.contains(slot) }

    func start(_ first: Int, _ second: Int, people: [Int: Person], lightMode: @escaping @MainActor () -> Bool) {
        guard !isActive, first != second, let a = people[first], let b = people[second] else { return }
        pair = [first, second]
        said = [:]
        let seed = OfficeChatter.randomSeed()
        task = Task { [weak self] in await self?.run(first: (first, a), second: (second, b), seed: seed, lightMode: lightMode) }
    }

    func stop() {
        task?.cancel()
        task = nil
        pair = []
        said = [:]
    }

    private func run(first: (Int, Person), second: (Int, Person), seed: String, lightMode: @escaping @MainActor () -> Bool) async {
        var transcript: [OfficeChatter.Line] = []
        var speaker = first, listener = second
        var failures = 0
        while transcript.count < limit, !Task.isCancelled {
            let text: String
            do {
                text = try await chatter.line(as: speaker.1.name, persona: speaker.1.profile, with: listener.1.name, otherAbout: listener.1.about,
                                              seed: seed, transcript: transcript, brain: speaker.1.brain, lightMode: lightMode())
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                guard failures < 3 else {
                    said[speaker.0] = "Se me ha ido el hilo… (\(error.localizedDescription))"
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { stop() }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            guard !Task.isCancelled else { return }
            transcript.append(.init(speaker: speaker.1.name, text: text))
            // Habla uno: el bocadillo del otro se recoge.
            said[listener.0] = nil
            said[speaker.0] = text
            // Lo que se tarda en leer; la siguiente intervención se pide mientras tanto.
            let reading = max(3.5, Double(text.count) * 0.06)
            try? await Task.sleep(for: .seconds(reading))
            swap(&speaker, &listener)
        }
        if !Task.isCancelled {
            said = [:]
            stop()
        }
    }
}
