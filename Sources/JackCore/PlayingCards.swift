import Foundation

public enum CardSuit: Int, CaseIterable, Sendable, Codable {
    case spades, hearts, diamonds, clubs

    public var isRed: Bool { self == .hearts || self == .diamonds }

    public var title: String { ["picas", "corazones", "diamantes", "tréboles"][rawValue] }
}

public enum CardRank: Int, CaseIterable, Sendable, Codable, Comparable {
    case two = 2, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace

    public static func < (a: CardRank, b: CardRank) -> Bool { a.rawValue < b.rawValue }

    /// Lo que se escribe en la esquina de la carta.
    public var symbol: String {
        switch self {
        case .jack: "J"
        case .queen: "Q"
        case .king: "K"
        case .ace: "A"
        default: String(rawValue)
        }
    }

    public var title: String {
        switch self {
        case .jack: "jota"
        case .queen: "reina"
        case .king: "rey"
        case .ace: "as"
        default: String(rawValue)
        }
    }

    public var isFace: Bool { self == .jack || self == .queen || self == .king }
}

/// Una carta de la baraja francesa (52 cartas, sin comodines).
public struct PlayingCard: Hashable, Sendable, Codable, Identifiable {
    public var suit: CardSuit
    public var rank: CardRank

    public init(_ rank: CardRank, of suit: CardSuit) {
        self.rank = rank
        self.suit = suit
    }

    public var id: String { "\(suit.rawValue)-\(rank.rawValue)" }

    /// «as de picas», «7 de corazones»…
    public var title: String { "\(rank.title) de \(suit.title)" }

    /// La baraja completa, ordenada.
    public static var deck: [PlayingCard] {
        CardSuit.allCases.flatMap { suit in CardRank.allCases.map { PlayingCard($0, of: suit) } }
    }
}
