import AppKit
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

/// Dónde se sienta un jugador: «white» y «black» son los del ajedrez y «north» el tercer sitio de la mesa de cartas.
struct OfficeChessSeat: Equatable {
    var id: String
    /// La cadera sentada y hacia dónde mira.
    var pose: OfficePose

    var color: ChessColor? { ChessColor(rawValue: id) }
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
        let id: String
        let real: Entity
        var reflected: Entity?
        /// Con la silla metida, y hacia dónde se aparta (en las coordenadas locales de la sala, las de Blender).
        let tucked: SIMD3<Float>
        let pull: SIMD3<Float>

        init(id: String, real: Entity, tucked: SIMD3<Float>, pull: SIMD3<Float>) {
            self.id = id
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
    private(set) var seats: [String: OfficeChessSeat] = [:]
    private(set) var chairs: [String: Chair] = [:]
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
    private weak var realRoom: Entity?
    var onLand: (() -> Void)?

    /// Busca las piezas y las dos sillas de la mesa. `template` es el puesto de referencia (la altura a la que se sienta).
    init?(layout: OfficeChessLayout, room: Entity, template: OfficeLayout.Slot) {
        self.layout = layout
        tableCenter = SIMD2(Float(layout.table.center[0]), Float(-layout.table.center[1]))
        tableHalf = Float(layout.table.half)
        for info in layout.pieces {
            guard let entity = room.findEntity(named: info.name), let color = ChessColor(rawValue: info.color),
                  let kind = Self.kind(info.kind), let home = ChessSquare.parse(info.square) else { return nil }
            pieces.append(Piece(color: color, kind: kind, real: entity, home: home))
        }
        Self.recolor(pieces: pieces, room: room)
        realRoom = room
        let desk = OfficePose(template.atDesk)
        for seat in layout.seats {
            guard ChessColor(rawValue: seat.color) != nil, let chair = room.findEntity(named: "CHESS_chair_\(seat.color)") else { continue }
            let pose = OfficePose(position: OfficePose.world(x: seat.position[0], y: seat.position[1], z: Double(desk.position.y)),
                                  yaw: Float(seat.yaw * .pi / 180), chairOffset: 0)
            seats[seat.color] = OfficeChessSeat(id: seat.color, pose: pose)
            // La silla (de madera, exportada con la mesa) se aparta hacia atrás desde el asiento; sus coordenadas son las
            // locales de Blender.
            let yaw = Float(seat.yaw * .pi / 180)
            let made = Chair(id: seat.color, real: chair, tucked: chair.position, pull: SIMD3(-sin(yaw), cos(yaw), 0))
            made.set(offset: 0)
            chairs[seat.color] = made
        }
        guard seats.count == 2 else { return nil }
        addNorthSeat(desk: desk)
    }

    /// El tercer sitio de la mesa, para las cartas: en el lado «norte», frente al que mira hacia -y (la silla es una copia de la blanca,
    /// girada).
    static let northSeat = "north"

    private func addNorthSeat(desk: OfficePose) {
        guard let white = layout.seats.first(where: { $0.color == "white" }), let base = chairs["white"], let parent = base.real.parent else { return }
        let center = layout.table.center
        let distance = hypot(white.position[0] - center[0], white.position[1] - center[1])
        let spot = [center[0], center[1] + distance]
        seats[Self.northSeat] = OfficeChessSeat(id: Self.northSeat, pose: OfficePose(position: OfficePose.world(x: spot[0], y: spot[1], z: Double(desk.position.y)),
                                                                                  yaw: 0, chairOffset: 0))
        // La silla blanca mira hacia +x; esta, hacia -y: se gira -90° sobre el eje vertical de Blender (z) y se coloca con el mismo
        // desfase respecto a su asiento.
        let chair = base.real.clone(recursive: true)
        chair.name = "CHESS_chair_\(Self.northSeat)"
        parent.addChild(chair)
        let delta = SIMD2(base.tucked.x - Float(white.position[0]), base.tucked.y - Float(white.position[1]))
        let rotated = SIMD2(delta.y, -delta.x)
        let tucked = SIMD3(Float(spot[0]) + rotated.x, Float(spot[1]) + rotated.y, base.tucked.z)
        chair.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1)) * base.real.orientation
        let made = Chair(id: Self.northSeat, real: chair, tucked: tucked, pull: SIMD3(0, 1, 0))
        made.set(offset: 0)
        chairs[Self.northSeat] = made
    }

    /// Los colores del juego, pensados para la luz cálida y fuerte de la sala: con los del modelo las blancas se perdían sobre las
    /// casillas claras y las negras quedaban grises. Marfil luminoso contra madera tostada, y negro profundo contra madera oscura.
    private static let whitePieces = NSColor(red: 0.93, green: 0.90, blue: 0.80, alpha: 1)
    private static let blackPieces = NSColor(red: 0.025, green: 0.025, blue: 0.03, alpha: 1)
    private static let lightSquares = NSColor(red: 0.52, green: 0.37, blue: 0.22, alpha: 1)
    private static let darkSquares = NSColor(red: 0.13, green: 0.075, blue: 0.045, alpha: 1)

    /// Cambia el color de las piezas y de las casillas (antes del espejo, así que sus gemelas lo heredan).
    private static func recolor(pieces: [Piece], room: Entity) {
        for piece in pieces { tint(piece.real, piece.color == .white ? whitePieces : blackPieces, roughness: piece.color == .white ? 0.5 : 0.38) }
        if let light = room.findEntity(named: "CHESS_board_light") { tint(light, lightSquares, roughness: 0.55) }
        if let dark = room.findEntity(named: "CHESS_board_dark") { tint(dark, darkSquares, roughness: 0.55) }
    }

    private static func tint(_ entity: Entity, _ color: NSColor, roughness: Float) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard var pbr = material as? PhysicallyBasedMaterial else { return material }
                pbr.baseColor = .init(tint: color)
                pbr.roughness = .init(floatLiteral: roughness)
                return pbr
            }
            entity.components.set(model)
        }
        for child in entity.children { tint(child, color, roughness: roughness) }
    }

    private static func kind(_ name: String) -> ChessKind? {
        ["pawn": .pawn, "knight": .knight, "bishop": .bishop, "rook": .rook, "queen": .queen, "king": .king][name]
    }

    /// Las gemelas de las piezas y las sillas en la sala del espejo.
    func attachMirror(_ room: Entity) {
        mirrorRoom = room
        for piece in pieces { piece.reflected = room.findEntity(named: piece.real.name) }
        for chair in chairs.values { chair.reflected = room.findEntity(named: chair.real.name) }
        for chair in chairs.values { chair.set(offset: currentOffset[chair.id] ?? 0) }
    }

    private var currentOffset: [String: Float] = [:]

    func offset(of id: String) -> Float { currentOffset[id] ?? 0 }
    func offset(of color: ChessColor) -> Float { offset(of: color.rawValue) }

    /// El suelo que ocupa cada silla de la mesa cuando está apartada (x, z de RealityKit), para que nadie la atraviese.
    func pulledChairFootprints() -> [(min: SIMD2<Float>, max: SIMD2<Float>)] {
        chairs.values.map { chair in
            let bounds = chair.real.visualBounds(relativeTo: nil)
            // La silla se mueve en las coordenadas locales de Blender (x, y, z arriba); en RealityKit, x se queda y y pasa a -z.
            let shift = SIMD2(chair.pull.x, -chair.pull.y) * (1.5 - offset(of: chair.id))
            let moved = (min: SIMD2(bounds.min.x, bounds.min.z) + shift, max: SIMD2(bounds.max.x, bounds.max.z) + shift)
            // Metida o apartada: cubre las dos posiciones (la silla cambia de sitio según se juegue o no).
            return (SIMD2(min(moved.min.x, bounds.min.x), min(moved.min.y, bounds.min.z)), SIMD2(max(moved.max.x, bounds.max.x), max(moved.max.y, bounds.max.z)))
        }
    }

    func setChair(_ id: String, offset: Float) {
        currentOffset[id] = offset
        chairs[id]?.set(offset: offset)
    }

    func setChair(_ color: ChessColor, offset: Float) { setChair(color.rawValue, offset: offset) }

    /// Desliza una silla hasta `target` (0 metida, 1,5 apartada) en vez de saltar; para quien se sienta o se levanta de ella.
    func slideChair(_ color: ChessColor, to target: Float, duration: Double = 0.7) async {
        await slideChair(color.rawValue, to: target, duration: duration)
    }

    func slideChair(_ id: String, to target: Float, duration: Double = 0.7) async {
        let from = offset(of: id)
        let steps = max(1, Int(duration * 60))
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            let t = Float(step) / Float(steps)
            setChair(id, offset: from + (target - from) * t * t * (3 - 2 * t))
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: - Tablero

    /// Muestra u oculta el tablero y todas las piezas (con las cartas, la mesa se queda lisa). También en el espejo.
    func setVisible(_ visible: Bool) {
        for piece in pieces + extra {
            piece.real.isEnabled = visible
            piece.reflected?.isEnabled = visible
        }
        for room in [realRoom, mirrorRoom] {
            for name in ["CHESS_board_light", "CHESS_board_dark", "CHESS_board_frame"] { room?.findEntity(named: name)?.isEnabled = visible }
        }
    }

    /// La altura de la superficie de la mesa en la escena.
    var tableTop: Float { Float(layout.table.top) }

    /// Dónde pone la cámara quien se sienta en `seat` a una mesa de cartas: mirando el centro de la mesa desde su silla y desde arriba.
    func tablePose(for seat: String) -> OfficeCamera.Pose? {
        guard let found = seats[seat] else { return nil }
        var toward = SIMD3(found.pose.position.x - tableCenter.x, 0, found.pose.position.z - tableCenter.y)
        guard simd_length(toward) > 0.001 else { return nil }
        toward = simd_normalize(toward)
        let target = SIMD3(tableCenter.x, tableTop + 0.2, tableCenter.y) - toward * 0.3
        return OfficeCamera.Pose(target: target, azimuth: atan2(toward.x, toward.z), elevation: 0.85, distance: tableHalf * 3.1)
    }

    /// Dónde cae el centro de una casilla en la escena, a la altura de la base de las piezas.
    func worldPosition(of square: Int) -> SIMD3<Float>? {
        guard let parent = pieces.first?.real.parent else { return nil }
        return parent.convert(position: position(of: square), to: nil)
    }

    /// El lado de una casilla, en metros de la escena.
    var squareSize: Float { Float(layout.square) }

    /// Lo que mide de alto una pieza, en metros de la escena (la media de las de la mesa); para pulsarlas por el cuerpo.
    var pieceHeight: Float {
        let heights = pieces.map { $0.real.visualBounds(relativeTo: nil).extents.y }.filter { $0 > 0 }
        return heights.isEmpty ? squareSize : heights.reduce(0, +) / Float(heights.count)
    }

    /// Dónde pone la cámara quien juega con `color`: sentado en su silla, mirando el tablero desde su lado, con el rival al fondo.
    func cameraPose(for color: ChessColor) -> OfficeCamera.Pose? {
        guard let seat = seats[color.rawValue], let first = worldPosition(of: 0), let last = worldPosition(of: 63) else { return nil }
        let center = (first + last) / 2
        var toward = SIMD3(seat.pose.position.x - center.x, 0, seat.pose.position.z - center.z)
        guard simd_length(toward) > 0.001 else { return nil }
        toward = simd_normalize(toward)
        // Un poco más allá del centro y más arriba, para que quepa el rival sentado detrás del tablero.
        let target = center - toward * squareSize * 0.8 + SIMD3(0, squareSize * 1.6, 0)
        return OfficeCamera.Pose(target: target, azimuth: atan2(toward.x, toward.z), elevation: 0.62, distance: squareSize * 17)
    }

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
