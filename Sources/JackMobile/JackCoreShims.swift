import Foundation

// Lo poco de la Mac que la oficina compartida usa y vive en archivos que el iPhone no compila (los agentes y Stellar Code).

extension ChatStatus {
    var title: String {
        switch self {
        case .idle: "Listo"
        case .queued: "En cola"
        case .running: "Trabajando"
        case .waiting: "Necesita tu respuesta"
        case .failed: "Error"
        }
    }

    var isActive: Bool { self == .running || self == .waiting || self == .queued }
}

enum StellarTools {
    static func prefixUTF8(_ value: String, bytes: Int) -> String {
        var result = ""
        for character in value {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}
