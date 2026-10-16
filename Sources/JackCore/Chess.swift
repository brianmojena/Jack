import Foundation

// MARK: - Piezas y casillas

public enum ChessColor: String, Sendable, Codable {
    case white, black

    public var opposite: ChessColor { self == .white ? .black : .white }
    /// Cómo se nombra en español, con el artículo («las blancas»).
    public var title: String { self == .white ? "blancas" : "negras" }
}

public enum ChessKind: Int, Sendable, CaseIterable {
    case pawn, knight, bishop, rook, queen, king

    /// La letra en FEN y en SAN (en mayúscula).
    var letter: Character { ["P", "N", "B", "R", "Q", "K"][rawValue] }
    public var title: String { ["peón", "caballo", "alfil", "torre", "dama", "rey"][rawValue] }
}

public struct ChessPiece: Hashable, Sendable {
    public var kind: ChessKind
    public var color: ChessColor

    public init(_ kind: ChessKind, _ color: ChessColor) {
        self.kind = kind
        self.color = color
    }

    init?(fen character: Character) {
        guard let kind = ChessKind.allCases.first(where: { $0.letter == Character(character.uppercased()) }) else { return nil }
        self.init(kind, character.isUppercase ? .white : .black)
    }

    var fen: Character { color == .white ? kind.letter : Character(kind.letter.lowercased()) }
}

/// Una casilla del tablero: 0…63, `rango * 8 + columna`; la 0 es a1 y la 63, h8.
public enum ChessSquare {
    public static func make(file: Int, rank: Int) -> Int { rank * 8 + file }
    public static func file(_ square: Int) -> Int { square & 7 }
    public static func rank(_ square: Int) -> Int { square >> 3 }
    /// «e4».
    public static func name(_ square: Int) -> String {
        String(UnicodeScalar(UInt8(97 + file(square)))) + String(rank(square) + 1)
    }
    public static func parse(_ text: String) -> Int? {
        let chars = Array(text.lowercased())
        guard chars.count == 2, let file = chars[0].asciiValue.map({ Int($0) - 97 }), let rank = chars[1].wholeNumberValue,
              (0..<8).contains(file), (1...8).contains(rank) else { return nil }
        return make(file: file, rank: rank - 1)
    }
}

public struct ChessMove: Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var promotion: ChessKind?

    public init(from: Int, to: Int, promotion: ChessKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// Notación de coordenadas: «e2e4», «e7e8q».
    public var uci: String {
        ChessSquare.name(from) + ChessSquare.name(to) + (promotion.map { String($0.letter).lowercased() } ?? "")
    }
}

/// Qué cambia en el tablero con una jugada, para animarla pieza a pieza.
public struct ChessMoveEffects: Equatable, Sendable {
    /// La pieza que se come y dónde estaba (en la captura al paso no es la casilla de destino).
    public var captured: (piece: ChessPiece, square: Int)?
    /// La torre que se mueve al enrocar.
    public var rook: (from: Int, to: Int)?
    public var promotion: ChessKind?

    public static func == (a: ChessMoveEffects, b: ChessMoveEffects) -> Bool {
        a.captured?.piece == b.captured?.piece && a.captured?.square == b.captured?.square
            && a.rook?.from == b.rook?.from && a.rook?.to == b.rook?.to && a.promotion == b.promotion
    }
}

public enum ChessOutcome: Equatable, Sendable {
    case ongoing
    case checkmate(winner: ChessColor)
    case stalemate
    case fiftyMoves
    case insufficientMaterial
    case repetition

    public var isOver: Bool { self != .ongoing }
    public var winner: ChessColor? {
        if case .checkmate(let winner) = self { return winner }
        return nil
    }

    public var title: String {
        switch self {
        case .ongoing: return "en juego"
        case .checkmate(let winner): return "jaque mate, ganan las \(winner.title)"
        case .stalemate: return "tablas por rey ahogado"
        case .fiftyMoves: return "tablas por la regla de los 50 movimientos"
        case .insufficientMaterial: return "tablas por material insuficiente"
        case .repetition: return "tablas por repetición"
        }
    }
}

// MARK: - Posición

public struct ChessPosition: Equatable, Sendable {
    public struct Castling: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let whiteKing = Castling(rawValue: 1)
        public static let whiteQueen = Castling(rawValue: 2)
        public static let blackKing = Castling(rawValue: 4)
        public static let blackQueen = Castling(rawValue: 8)
        public static let all: Castling = [.whiteKing, .whiteQueen, .blackKing, .blackQueen]
    }

    public private(set) var board: [ChessPiece?]
    public private(set) var turn: ChessColor
    public private(set) var castling: Castling
    /// La casilla que un peón puede tomar al paso.
    public private(set) var enPassant: Int?
    public private(set) var halfmoveClock: Int
    public private(set) var fullmoveNumber: Int

    public static let start = ChessPosition(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")!

    public init?(fen: String) {
        let parts = fen.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }
        var board = [ChessPiece?](repeating: nil, count: 64)
        let rows = parts[0].split(separator: "/")
        guard rows.count == 8 else { return nil }
        for (index, row) in rows.enumerated() {
            var file = 0
            for character in row {
                if let empty = character.wholeNumberValue {
                    file += empty
                } else if let piece = ChessPiece(fen: character), file < 8 {
                    board[ChessSquare.make(file: file, rank: 7 - index)] = piece
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }
        self.board = board
        turn = parts[1] == "b" ? .black : .white
        var castling = Castling()
        if parts[2].contains("K") { castling.insert(.whiteKing) }
        if parts[2].contains("Q") { castling.insert(.whiteQueen) }
        if parts[2].contains("k") { castling.insert(.blackKing) }
        if parts[2].contains("q") { castling.insert(.blackQueen) }
        self.castling = castling
        enPassant = parts[3] == "-" ? nil : ChessSquare.parse(parts[3])
        halfmoveClock = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        fullmoveNumber = parts.count > 5 ? Int(parts[5]) ?? 1 : 1
    }

    public subscript(square: Int) -> ChessPiece? { board[square] }

    // MARK: FEN

    public var fen: String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = board[ChessSquare.make(file: file, rank: rank)] {
                    if empty > 0 { row += String(empty); empty = 0 }
                    row.append(piece.fen)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        var rights = ""
        if castling.contains(.whiteKing) { rights += "K" }
        if castling.contains(.whiteQueen) { rights += "Q" }
        if castling.contains(.blackKing) { rights += "k" }
        if castling.contains(.blackQueen) { rights += "q" }
        return rows.joined(separator: "/") + " \(turn == .white ? "w" : "b") \(rights.isEmpty ? "-" : rights) "
            + "\(enPassant.map(ChessSquare.name) ?? "-") \(halfmoveClock) \(fullmoveNumber)"
    }

    /// Lo que identifica la posición para detectar repeticiones.
    var repetitionKey: String { fen.split(separator: " ").prefix(4).joined(separator: " ") }

    // MARK: Ataques

    private static let knightSteps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingSteps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let bishopDirections = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    private static let rookDirections = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    private func square(_ square: Int, offset: (Int, Int)) -> Int? {
        let file = ChessSquare.file(square) + offset.0, rank = ChessSquare.rank(square) + offset.1
        return (0..<8).contains(file) && (0..<8).contains(rank) ? ChessSquare.make(file: file, rank: rank) : nil
    }

    /// ¿Ataca alguna pieza de `color` esta casilla?
    func isAttacked(_ target: Int, by color: ChessColor) -> Bool {
        // Peones: atacan en diagonal hacia delante, así que desde la casilla se mira hacia atrás.
        let back = color == .white ? -1 : 1
        for side in [-1, 1] {
            if let from = square(target, offset: (side, back)), board[from] == ChessPiece(.pawn, color) { return true }
        }
        for step in Self.knightSteps {
            if let from = square(target, offset: step), board[from] == ChessPiece(.knight, color) { return true }
        }
        for step in Self.kingSteps {
            if let from = square(target, offset: step), board[from] == ChessPiece(.king, color) { return true }
        }
        for (directions, kinds) in [(Self.bishopDirections, [ChessKind.bishop, .queen]), (Self.rookDirections, [ChessKind.rook, .queen])] {
            for direction in directions {
                var current = target
                while let next = square(current, offset: direction) {
                    current = next
                    if let piece = board[next] {
                        if piece.color == color, kinds.contains(piece.kind) { return true }
                        break
                    }
                }
            }
        }
        return false
    }

    func kingSquare(of color: ChessColor) -> Int? {
        board.firstIndex { $0 == ChessPiece(.king, color) }
    }

    public var isCheck: Bool {
        kingSquare(of: turn).map { isAttacked($0, by: turn.opposite) } ?? false
    }

    // MARK: Jugadas

    private func pseudoLegalMoves() -> [ChessMove] {
        var moves: [ChessMove] = []
        func add(_ from: Int, _ to: Int, promotes: Bool = false) {
            if promotes {
                for kind in [ChessKind.queen, .rook, .bishop, .knight] { moves.append(ChessMove(from: from, to: to, promotion: kind)) }
            } else {
                moves.append(ChessMove(from: from, to: to))
            }
        }
        for from in 0..<64 {
            guard let piece = board[from], piece.color == turn else { continue }
            switch piece.kind {
            case .pawn:
                let forward = turn == .white ? 1 : -1
                let startRank = turn == .white ? 1 : 6, lastRank = turn == .white ? 7 : 0
                if let one = square(from, offset: (0, forward)), board[one] == nil {
                    add(from, one, promotes: ChessSquare.rank(one) == lastRank)
                    if ChessSquare.rank(from) == startRank, let two = square(from, offset: (0, 2 * forward)), board[two] == nil { add(from, two) }
                }
                for side in [-1, 1] {
                    guard let to = square(from, offset: (side, forward)) else { continue }
                    if let target = board[to], target.color != turn {
                        add(from, to, promotes: ChessSquare.rank(to) == lastRank)
                    } else if to == enPassant {
                        add(from, to)
                    }
                }
            case .knight, .king:
                for step in piece.kind == .knight ? Self.knightSteps : Self.kingSteps {
                    guard let to = square(from, offset: step), board[to]?.color != turn else { continue }
                    add(from, to)
                }
            case .bishop, .rook, .queen:
                let directions = piece.kind == .bishop ? Self.bishopDirections : piece.kind == .rook ? Self.rookDirections
                    : Self.bishopDirections + Self.rookDirections
                for direction in directions {
                    var current = from
                    while let to = square(current, offset: direction) {
                        current = to
                        if let target = board[to] {
                            if target.color != turn { add(from, to) }
                            break
                        }
                        add(from, to)
                    }
                }
            }
        }
        moves += castlingMoves()
        return moves
    }

    private func castlingMoves() -> [ChessMove] {
        let rank = turn == .white ? 0 : 7
        let home = ChessSquare.make(file: 4, rank: rank)
        guard board[home] == ChessPiece(.king, turn), !isAttacked(home, by: turn.opposite) else { return [] }
        var moves: [ChessMove] = []
        let kingSide: Castling = turn == .white ? .whiteKing : .blackKing
        let queenSide: Castling = turn == .white ? .whiteQueen : .blackQueen
        func empty(_ files: [Int]) -> Bool { files.allSatisfy { board[ChessSquare.make(file: $0, rank: rank)] == nil } }
        func safe(_ files: [Int]) -> Bool { files.allSatisfy { !isAttacked(ChessSquare.make(file: $0, rank: rank), by: turn.opposite) } }
        if castling.contains(kingSide), board[ChessSquare.make(file: 7, rank: rank)] == ChessPiece(.rook, turn), empty([5, 6]), safe([5, 6]) {
            moves.append(ChessMove(from: home, to: ChessSquare.make(file: 6, rank: rank)))
        }
        if castling.contains(queenSide), board[ChessSquare.make(file: 0, rank: rank)] == ChessPiece(.rook, turn), empty([1, 2, 3]), safe([2, 3]) {
            moves.append(ChessMove(from: home, to: ChessSquare.make(file: 2, rank: rank)))
        }
        return moves
    }

    public func legalMoves() -> [ChessMove] {
        pseudoLegalMoves().filter { move in
            let next = applying(move)
            guard let king = next.kingSquare(of: turn) else { return false }
            return !next.isAttacked(king, by: turn.opposite)
        }
    }

    public func effects(of move: ChessMove) -> ChessMoveEffects {
        var effects = ChessMoveEffects(promotion: move.promotion)
        guard let piece = board[move.from] else { return effects }
        if let target = board[move.to] {
            effects.captured = (target, move.to)
        } else if piece.kind == .pawn, move.to == enPassant, ChessSquare.file(move.from) != ChessSquare.file(move.to) {
            let square = ChessSquare.make(file: ChessSquare.file(move.to), rank: ChessSquare.rank(move.from))
            if let victim = board[square] { effects.captured = (victim, square) }
        }
        if piece.kind == .king, abs(ChessSquare.file(move.to) - ChessSquare.file(move.from)) == 2 {
            let rank = ChessSquare.rank(move.from)
            let kingSide = ChessSquare.file(move.to) == 6
            effects.rook = (ChessSquare.make(file: kingSide ? 7 : 0, rank: rank), ChessSquare.make(file: kingSide ? 5 : 3, rank: rank))
        }
        return effects
    }

    /// La posición tras la jugada (que debe ser legal).
    public func applying(_ move: ChessMove) -> ChessPosition {
        var next = self
        guard let piece = board[move.from] else { return next }
        let effects = effects(of: move)
        if let captured = effects.captured { next.board[captured.square] = nil }
        next.board[move.from] = nil
        next.board[move.to] = move.promotion.map { ChessPiece($0, piece.color) } ?? piece
        if let rook = effects.rook {
            next.board[rook.to] = next.board[rook.from]
            next.board[rook.from] = nil
        }
        // Derechos de enroque: se pierden al mover el rey o la torre, o al comerse una torre en su casilla.
        func lose(at square: Int) {
            switch square {
            case 4: next.castling.subtract([.whiteKing, .whiteQueen])
            case 60: next.castling.subtract([.blackKing, .blackQueen])
            case 0: next.castling.remove(.whiteQueen)
            case 7: next.castling.remove(.whiteKing)
            case 56: next.castling.remove(.blackQueen)
            case 63: next.castling.remove(.blackKing)
            default: break
            }
        }
        lose(at: move.from)
        lose(at: move.to)
        // Al paso solo se anota si algún peón rival puede tomar.
        next.enPassant = nil
        if piece.kind == .pawn, abs(move.to - move.from) == 16 {
            let middle = (move.to + move.from) / 2
            let enemy = ChessPiece(.pawn, piece.color.opposite)
            for side in [-1, 1] {
                if let neighbour = self.square(move.to, offset: (side, 0)), board[neighbour] == enemy { next.enPassant = middle }
            }
        }
        next.halfmoveClock = piece.kind == .pawn || effects.captured != nil ? 0 : halfmoveClock + 1
        if turn == .black { next.fullmoveNumber += 1 }
        next.turn = turn.opposite
        return next
    }

    /// Las jugadas legales cuyo destino y origen coinciden con el texto («e2e4», «e7e8q»; también «e2-e4»).
    public func move(uci text: String) -> ChessMove? {
        let cleaned = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == 4 || cleaned.count == 5, let from = ChessSquare.parse(String(cleaned.prefix(2))),
              let to = ChessSquare.parse(String(cleaned.dropFirst(2).prefix(2))) else { return nil }
        let promotion = cleaned.count == 5 ? ChessKind.allCases.first { Character($0.letter.lowercased()) == cleaned.last } : nil
        let candidates = legalMoves().filter { $0.from == from && $0.to == to }
        if let exact = candidates.first(where: { $0.promotion == promotion }) { return exact }
        // Un peón que llega al final sin decir la pieza corona dama.
        return candidates.count > 1 ? candidates.first { $0.promotion == .queen } : candidates.first
    }

    /// La jugada en notación algebraica, tal como la escribiría un jugador («Nf3», «exd5», «O-O», «e8=Q+»).
    public func san(_ move: ChessMove) -> String {
        guard let piece = board[move.from] else { return move.uci }
        var text: String
        if piece.kind == .king, abs(ChessSquare.file(move.to) - ChessSquare.file(move.from)) == 2 {
            text = ChessSquare.file(move.to) == 6 ? "O-O" : "O-O-O"
        } else {
            let capture = effects(of: move).captured != nil
            if piece.kind == .pawn {
                text = (capture ? String(UnicodeScalar(UInt8(97 + ChessSquare.file(move.from)))) + "x" : "") + ChessSquare.name(move.to)
            } else {
                text = String(piece.kind.letter)
                let rivals = legalMoves().filter { $0.to == move.to && $0.from != move.from && board[$0.from] == piece }
                if !rivals.isEmpty {
                    let sameFile = rivals.contains { ChessSquare.file($0.from) == ChessSquare.file(move.from) }
                    let sameRank = rivals.contains { ChessSquare.rank($0.from) == ChessSquare.rank(move.from) }
                    let name = ChessSquare.name(move.from)
                    if !sameFile { text += String(name.first!) } else if !sameRank { text += String(name.last!) } else { text += name }
                }
                text += (capture ? "x" : "") + ChessSquare.name(move.to)
            }
            if let promotion = move.promotion { text += "=\(promotion.letter)" }
        }
        let next = applying(move)
        if next.isCheck { text += next.legalMoves().isEmpty ? "#" : "+" }
        return text
    }

    // MARK: Final de la partida

    var hasInsufficientMaterial: Bool {
        var minors: [(kind: ChessKind, square: Int)] = []
        for (square, piece) in board.enumerated() {
            guard let piece, piece.kind != .king else { continue }
            if piece.kind == .knight || piece.kind == .bishop { minors.append((piece.kind, square)) } else { return false }
        }
        if minors.count <= 1 { return true }
        // Solo alfiles, todos en casillas del mismo color.
        guard minors.allSatisfy({ $0.kind == .bishop }) else { return false }
        return Set(minors.map { (ChessSquare.file($0.square) + ChessSquare.rank($0.square)) % 2 }).count == 1
    }

    /// El estado de la posición sin contar repeticiones (eso lo sabe `ChessGame`, que tiene el historial).
    public var outcome: ChessOutcome {
        if legalMoves().isEmpty { return isCheck ? .checkmate(winner: turn.opposite) : .stalemate }
        if hasInsufficientMaterial { return .insufficientMaterial }
        if halfmoveClock >= 100 { return .fiftyMoves }
        return .ongoing
    }
}

// MARK: - Partida

/// Una partida: la posición, las jugadas hechas (en SAN) y cómo acabó.
public struct ChessGame: Sendable {
    public private(set) var position = ChessPosition.start
    public private(set) var history: [(move: ChessMove, san: String)] = []
    private var seen: [String: Int] = [ChessPosition.start.repetitionKey: 1]

    public init() {}

    public var outcome: ChessOutcome {
        let base = position.outcome
        if base.isOver { return base }
        return (seen[position.repetitionKey] ?? 0) >= 3 ? .repetition : .ongoing
    }

    public var sanHistory: [String] { history.map(\.san) }

    /// Juega una jugada legal; devuelve sus efectos en el tablero, o `nil` si no es legal.
    @discardableResult
    public mutating func play(_ move: ChessMove) -> ChessMoveEffects? {
        guard position.legalMoves().contains(move) else { return nil }
        let effects = position.effects(of: move)
        history.append((move, position.san(move)))
        position = position.applying(move)
        seen[position.repetitionKey, default: 0] += 1
        return effects
    }

    /// Las jugadas en texto numerado: «1. e4 e5 2. Nf3».
    public var movetext: String {
        var parts: [String] = []
        for (index, entry) in history.enumerated() {
            if index % 2 == 0 { parts.append("\(index / 2 + 1). \(entry.san)") } else { parts.append(entry.san) }
        }
        return parts.joined(separator: " ")
    }
}
