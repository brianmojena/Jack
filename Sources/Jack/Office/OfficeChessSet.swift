import Foundation
import JackCore
import RealityKit
import simd

/// La mesa de ajedrez exportada desde Blender (`Resources/Office/Runtime/OfficeChess.json`), en coordenadas de Blender.
struct OfficeChessLayout: Decodable {
    struct Piece: Decodable {
        let name: String
        let color: String
        let kind: String
        let square: String
    }

    struct Table: Decodable {
        let center: [Double]
        let half: Double
        let top: Double
    }

    struct Seat: Decodable {
        let color: String
        let position: [Double]
        let yaw: Double
    }

    struct Graveyard: Decodable {
        let start: [Double]
        let step: [Double]
    }

    let square: Double
    let squares: [[Double]]
    let pieces: [Piece]
    let table: Table
    let seats: [Seat]
    let graveyards: [String: Graveyard]

    static func load(from url: URL) throws -> OfficeChessLayout {
        try JSONDecoder().decode(OfficeChessLayout.self, from: Data(contentsOf: url))
    }
}

/// Dónde se sienta un jugador y con qué color juega.
struct OfficeChessSeat: Equatable {
    var color: ChessColor
    /// La cadera sentada y hacia dónde mira.
    var pose: OfficePose
}

/// El juego de ajedrez de la sala: las piezas, que se mueven por el tablero con un arco, y las dos sillas de la mesa.
///
/// Las piezas y la mesa vienen en `OfficeRoom.usdz`, así que también existen en la sala del espejo: cada pieza y cada silla
/// tiene su gemela y se mueven a la vez.
@MainActor final class OfficeChessSet {
    final class Piece {
        let color: ChessColor
        let kind: ChessKind
        let real: Entity
        var reflected: Entity?
        let home: Int?
        var square: Int?

        init(color: ChessColor, kind: ChessKind, real: Entity, home: Int?) {
            self.color = color
            self.kind = kind
            self.real = real
            self.home = home
            square = home
        }

        func place(_ position: SIMD3<Float>) {
            real.position = position
            reflected?.position = position
        }

        func scale(_ factor: Float) {
            real.scale = SIMD3(repeating: factor)
            reflected?.scale = SIMD3(repeating: factor)
        }
    }

    final class Chair {
        let color: ChessColor
        let real: Entity
        var reflected: Entity?
        /// Con la silla metida, y hacia dónde se aparta (en el espacio de RealityKit).
        let tucked: SIMD3<Float>
        let pull: SIMD3<Float>

        init(color: ChessColor, real: Entity, tucked: SIMD3<Float>, pull: SIMD3<Float>) {
            self.color = color
            self.real = real
            self.tucked = tucked
            self.pull = pull
        }

        func set(offset: Float) {
            let position = tucked + pull * offset
            real.position = position
            reflected?.position = position
        }
    }

    private enum Step {
        case tween([Tween])
        case action(() -> Void)
    }

    private struct Tween {
        var piece: Piece
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        var arc: Float
        var duration: Float
        /// Para las piezas que aparecen (una coronación): de este tamaño al normal.
        var growsFrom: Float?
    }

    private struct Job {
        var steps: [Step]
        var done: CheckedContinuation<Void, Never>?
    }

    let layout: OfficeChessLayout
    private(set) var seats: [ChessColor: OfficeChessSeat] = [:]
    private(set) var chairs: [ChessColor: Chair] = [:]
    /// El centro de la mesa y su mitad de lado, en el suelo y en el espacio de RealityKit (x, z).
    let tableCenter: SIMD2<Float>
    let tableHalf: Float
    private var pieces: [Piece] = []
    private var extra: [Piece] = []
    private var onSquare: [Int: Piece] = [:]
    private var buried: [ChessColor: Int] = [.white: 0, .black: 0]
    private var jobs: [Job] = []
    private var current: (job: Job, step: Int, elapsed: Float)?
    private var mirrorRoom: Entity?
    var onLand: (() -> Void)?

    /// Busca las piezas y crea las dos sillas a partir de la de `template` (la silla del escritorio de ese puesto), con la
    /// misma posición relativa al asiento que tiene su dueño al teclear.
    init?(layout: OfficeChessLayout, room: Entity, template: OfficeLayout.Slot) {
        self.layout = layout
        tableCenter = SIMD2(Float(layout.table.center[0]), Float(-layout.table.center[1]))
        tableHalf = Float(layout.table.half)
        for info in layout.pieces {
            guard let entity = room.findEntity(named: info.name), let color = ChessColor(rawValue: info.color),
                  let kind = Self.kind(info.kind), let home = ChessSquare.parse(info.square) else { return nil }
            pieces.append(Piece(color: color, kind: kind, real: entity, home: home))
        }
        guard let chair = room.findEntity(named: template.chair) else { return nil }
        let desk = OfficePose(template.atDesk)
        let tucked = chair.position(relativeTo: nil)
        let orientation = chair.orientation(relativeTo: nil)
        let scale = chair.scale(relativeTo: nil)
        for seat in layout.seats {
            guard let color = ChessColor(rawValue: seat.color) else { continue }
            let pose = OfficePose(position: OfficePose.world(x: seat.position[0], y: seat.position[1], z: Double(desk.position.y)),
                                  yaw: Float(seat.yaw * .pi / 180), chairOffset: 0)
            seats[color] = OfficeChessSeat(color: color, pose: pose)
            // La silla se coloca respecto al asiento igual que la del escritorio respecto a su dueño.
            let turn = simd_quatf(angle: pose.yaw - desk.yaw, axis: SIMD3(0, 1, 0))
            let copy = chair.clone(recursive: true)
            copy.name = "CHESS_chair_\(color.rawValue)"
            copy.scale = scale
            copy.orientation = turn * orientation
            room.addChild(copy)
            let forward = SIMD3<Float>(sin(pose.yaw), 0, cos(pose.yaw))
            let made = Chair(color: color, real: copy, tucked: pose.position + turn.act(tucked - desk.position), pull: -forward)
            made.set(offset: 0)
            chairs[color] = made
        }
        guard seats.count == 2 else { return nil }
    }

    private static func kind(_ name: String) -> ChessKind? {
        ["pawn": .pawn, "knight": .knight, "bishop": .bishop, "rook": .rook, "queen": .queen, "king": .king][name]
    }

    /// Las gemelas de las piezas y las sillas en la sala del espejo.
    func attachMirror(_ room: Entity) {
        mirrorRoom = room
        for piece in pieces { piece.reflected = room.findEntity(named: piece.real.name) }
        for chair in chairs.values { chair.reflected = room.findEntity(named: chair.real.name) }
        for chair in chairs.values { chair.set(offset: currentOffset[chair.color] ?? 0) }
    }

    private var currentOffset: [ChessColor: Float] = [:]

    func offset(of color: ChessColor) -> Float { currentOffset[color] ?? 0 }

    func setChair(_ color: ChessColor, offset: Float) {
        currentOffset[color] = offset
        chairs[color]?.set(offset: offset)
    }

    // MARK: - Tablero

    /// La posición de una casilla (al nivel de la base de las piezas), en coordenadas locales de la sala.
    func position(of square: Int) -> SIMD3<Float> {
        let point = layout.squares[square]
        return SIMD3(Float(point[0]), Float(point[1]), Float(point[2]))
    }

    private func graveyard(_ color: ChessColor) -> SIMD3<Float> {
        let yard = layout.graveyards[color.rawValue]!
        let index = Float(buried[color] ?? 0)
        return SIMD3(Float(yard.start[0] + yard.step[0] * Double(index)), Float(yard.start[1] + yard.step[1] * Double(index)), Float(yard.start[2]))
    }

    /// Todas las piezas en su casilla de salida (y fuera las coronadas).
    func reset() {
        current?.job.done?.resume()
        current = nil
        for job in jobs { job.done?.resume() }
        jobs = []
        for piece in extra {
            piece.real.removeFromParent()
            piece.reflected?.removeFromParent()
        }
        extra = []
        onSquare = [:]
        buried = [.white: 0, .black: 0]
        for piece in pieces {
            piece.square = piece.home
            piece.real.isEnabled = true
            piece.reflected?.isEnabled = true
            piece.scale(1)
            if let home = piece.home {
                piece.place(position(of: home))
                onSquare[home] = piece
            }
        }
    }

    var isBusy: Bool { current != nil || !jobs.isEmpty }

    /// Mueve la pieza de `move` (con lo que come, el enroque o la coronación) y vuelve cuando la última pieza se posa.
    /// Hay que llamarla antes de jugar la jugada en la partida: `effects` es lo que hace sobre la posición anterior.
    func play(_ move: ChessMove, effects: ChessMoveEffects) async {
        guard let piece = onSquare[move.from] else { return }
        var steps: [Step] = []
        if let captured = effects.captured, let victim = onSquare[captured.square] {
            let target = graveyard(victim.color)
            buried[victim.color, default: 0] += 1
            onSquare[captured.square] = nil
            victim.square = nil
            steps.append(.tween([Tween(piece: victim, from: position(of: captured.square), to: target, arc: 0.55, duration: 0.5)]))
        }
        onSquare[move.from] = nil
        onSquare[move.to] = piece
        piece.square = move.to
        steps.append(.tween([Tween(piece: piece, from: position(of: move.from), to: position(of: move.to), arc: 0.5, duration: 0.75)]))
        steps.append(.action({ [weak self] in self?.onLand?() }))
        if let rook = effects.rook, let mover = onSquare[rook.from] {
            onSquare[rook.from] = nil
            onSquare[rook.to] = mover
            mover.square = rook.to
            steps.append(.tween([Tween(piece: mover, from: position(of: rook.from), to: position(of: rook.to), arc: 0.4, duration: 0.55)]))
        }
        if let kind = effects.promotion, let crowned = promotion(of: piece, to: kind) {
            steps.append(.action({ [weak self] in
                piece.real.isEnabled = false
                piece.reflected?.isEnabled = false
                self?.onSquare[move.to] = crowned
            }))
            steps.append(.tween([Tween(piece: crowned, from: position(of: move.to), to: position(of: move.to), arc: 0.0, duration: 0.3, growsFrom: 0.05)]))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            jobs.append(Job(steps: steps, done: continuation))
        }
    }

    /// La pieza nueva de una coronación: una copia de otra del mismo tipo y color (o de la dama, si ya no queda ninguna).
    private func promotion(of pawn: Piece, to kind: ChessKind) -> Piece? {
        let model = (pieces + extra).first { $0.color == pawn.color && $0.kind == kind } ?? (pieces + extra).first { $0.color == pawn.color && $0.kind == .queen }
        guard let model, let parent = model.real.parent else { return nil }
        let copy = model.real.clone(recursive: true)
        copy.name = "CHESS_extra_\(extra.count)"
        copy.isEnabled = true
        parent.addChild(copy)
        let piece = Piece(color: pawn.color, kind: kind, real: copy, home: nil)
        if let reflectedParent = model.reflected?.parent {
            let twin = model.reflected!.clone(recursive: true)
            twin.isEnabled = true
            reflectedParent.addChild(twin)
            piece.reflected = twin
        }
        piece.scale(0.05)
        extra.append(piece)
        return piece
    }

    // MARK: - Animación

    func update(deltaTime: Double) {
        if current == nil, !jobs.isEmpty { current = (jobs.removeFirst(), 0, 0) }
        guard let running = current else { return }
        var elapsed = running.elapsed + Float(deltaTime)
        var index = running.step
        while index < running.job.steps.count {
            switch running.job.steps[index] {
            case .action(let action):
                action()
                index += 1
                elapsed = 0
            case .tween(let tweens):
                let length = tweens.map(\.duration).max() ?? 0
                for tween in tweens {
                    let t = min(1, elapsed / max(tween.duration, 0.001))
                    let eased = t * t * (3 - 2 * t)
                    var position = tween.from + (tween.to - tween.from) * eased
                    position.z += tween.arc * sin(.pi * t)
                    tween.piece.place(position)
                    if let start = tween.growsFrom { tween.piece.scale(start + (1 - start) * eased) }
                }
                if elapsed >= length {
                    index += 1
                    elapsed = 0
                } else {
                    current = (running.job, index, elapsed)
                    return
                }
            }
        }
        running.job.done?.resume()
        current = nil
    }
}
