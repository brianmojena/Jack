import CoreGraphics
import Metal
import RealityKit
import simd

/// La ducha de la sala, como en Los Sims: la puerta de la mampara se abre girando sobre su bisagra, cae agua de la alcachofa y,
/// mientras alguien se ducha, un mosaico de píxeles le tapa todo menos la cabeza.
///
/// La ducha viene en `OfficeRoom.usdz` (ver `scripts/office_add_shower.py`) con la puerta suelta y tres marcadores: dónde se
/// ducha (`PROP_shower_inside`), dónde espera a que se abra (`PROP_shower_wait`) y de dónde cae el agua (`PROP_shower_head`).
/// La puerta también existe en la sala del espejo: se mueven las dos.
@MainActor final class OfficeShower {
    /// Delante de la ducha, mirándola.
    let outside: OfficePose
    /// Dentro, sobre el plato, mirando a la sala.
    let inside: OfficePose
    /// Cuánto dura la ducha, con el agua cayendo.
    static let duration = 9.0
    /// El puesto que la está usando; solo entra uno a la vez.
    var occupant: Int?

    private let door: Entity
    private var reflectedDoor: Entity?
    private let water = Entity()
    private var angle: Float = 0
    private var target: Float = 0
    /// La puerta abierta: girada hacia la sala sobre la bisagra (en Blender, sobre su eje z).
    private static let openAngle: Float = -80 * .pi / 180

    private var mosaics: [Entity] = []
    private var mosaicTexture: TextureResource?
    private var mosaicClock = 0.0

    init?(room: Entity, world: Entity) {
        guard let door = room.findEntity(named: "PROP_shower_door"), let inside = room.findEntity(named: "PROP_shower_inside"),
              let wait = room.findEntity(named: "PROP_shower_wait"), let head = room.findEntity(named: "PROP_shower_head") else { return nil }
        self.door = door
        // yaw 0 mira hacia +z de RealityKit, que es -y de Blender: hacia la sala.
        self.inside = OfficePose(position: inside.position(relativeTo: nil), yaw: 0, chairOffset: 0)
        var waitPoint = wait.position(relativeTo: nil)
        waitPoint.y = 0
        outside = OfficePose(position: waitPoint, yaw: .pi, chairOffset: 0)
        water.name = "shower-water"
        water.position = head.position(relativeTo: nil)
        water.components.set(Self.emitter())
        world.addChild(water)
    }

    /// La gemela de la puerta en la sala del espejo.
    func attachMirror(_ mirroredRoom: Entity) {
        reflectedDoor = mirroredRoom.findEntity(named: door.name)
        reflectedDoor?.orientation = door.orientation
    }

    func openDoor() { target = Self.openAngle }
    func closeDoor() { target = 0 }

    func setWater(_ on: Bool) {
        guard var emitter = water.components[ParticleEmitterComponent.self] else { return }
        emitter.isEmitting = on
        water.components.set(emitter)
    }

    /// La puerta se está abriendo o cerrando.
    var isBusy: Bool { angle != target }

    func update(deltaTime: Double) {
        if angle != target {
            let next = angle + (target - angle) * Float(1 - exp(-deltaTime * 4.5))
            angle = abs(next - target) < 0.002 ? target : next
            let turn = simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
            door.orientation = turn
            reflectedDoor?.orientation = turn
        }
        // El mosaico se mueve: sus colores cambian poco a poco, como el de Los Sims.
        guard !mosaics.isEmpty else { return }
        mosaicClock += deltaTime
        if mosaicClock > 0.15 {
            mosaicClock = 0
            mosaicField.drift()
            if let image = mosaicField.image() { try? mosaicTexture?.replace(withImage: image, options: .init(semantic: .color)) }
        }
    }

    // MARK: - Mosaico

    /// El censor de Los Sims: un panel opaco de bloques difuminados color piel que tapa del suelo al cuello. Gira para mirar
    /// siempre a la cámara y va por delante del cuerpo (si estuviera en su centro, el pecho y los brazos lo atravesarían).
    /// Se cuelga del personaje.
    func makeMosaic() -> Entity? {
        if mosaicTexture == nil, let image = mosaicField.image() {
            mosaicTexture = try? TextureResource(image: image, options: .init(semantic: .color))
        }
        guard let mosaicTexture else { return nil }
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .nearest
        sampler.magFilter = .nearest
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(mosaicTexture, sampler: .init(sampler)))
        // Opaco: los bloques del contorno que faltan se recortan, sin transparencias que dejen ver lo de detrás.
        material.opacityThreshold = 0.5
        material.faceCulling = .none
        let panel = ModelEntity(mesh: .generatePlane(width: 3.6, height: 5.0), materials: [material])
        panel.position = SIMD3(0, 0, 1.8)
        let pivot = Entity()
        pivot.name = "shower-mosaic"
        pivot.position = SIMD3(0, 2.6, 0)
        pivot.components.set(BillboardComponent())
        pivot.addChild(panel)
        mosaics.append(pivot)
        return pivot
    }

    func removeMosaic(_ pivot: Entity) {
        pivot.removeFromParent()
        mosaics.removeAll { $0 === pivot }
    }

    private var mosaicField = MosaicField()

    /// Los colores del mosaico: una rejilla gruesa de tonos de piel (luces y sombras de un cuerpo borroso) que se reparte,
    /// suavizada, entre bloques más pequeños.
    private struct MosaicField {
        static let coarse = (columns: 4, rows: 7)
        static let blocks = (columns: 12, rows: 17)
        static let block = 6
        var colors: [SIMD3<Double>] = (0..<(coarse.columns * coarse.rows)).map { _ in MosaicField.skin() }
        /// Qué bloques del contorno faltan; cambian de vez en cuando.
        var outline: [Bool] = MosaicField.randomOutline()

        static func skin() -> SIMD3<Double> {
            let light = Double.random(in: -0.16...0.1)
            return SIMD3(0.86 + light, 0.65 + light * 1.1, 0.52 + light * 1.2)
        }

        static func randomOutline() -> [Bool] {
            (0..<(blocks.columns * blocks.rows)).map { _ in Double.random(in: 0...1) < 0.5 }
        }

        mutating func drift() {
            for index in colors.indices where Double.random(in: 0...1) < 0.35 {
                colors[index] = colors[index] * 0.6 + Self.skin() * 0.4
            }
            if Double.random(in: 0...1) < 0.3 { outline = Self.randomOutline() }
        }

        func color(atColumn x: Double, row y: Double) -> SIMD3<Double> {
            let gx = min(max(x * Double(Self.coarse.columns - 1), 0), Double(Self.coarse.columns - 1))
            let gy = min(max(y * Double(Self.coarse.rows - 1), 0), Double(Self.coarse.rows - 1))
            let x0 = Int(gx), y0 = Int(gy)
            let x1 = min(x0 + 1, Self.coarse.columns - 1), y1 = min(y0 + 1, Self.coarse.rows - 1)
            let fx = gx - Double(x0), fy = gy - Double(y0)
            func at(_ x: Int, _ y: Int) -> SIMD3<Double> { colors[y * Self.coarse.columns + x] }
            let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
            let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
            return top * (1 - fy) + bottom * fy
        }

        /// El contorno es un rectángulo de esquinas redondeadas; solo los bloques del borde exterior pueden faltar, así que el
        /// interior (más grande que el cuerpo) siempre tapa.
        func image() -> CGImage? {
            let (columns, rows) = Self.blocks
            let width = columns * Self.block, height = rows * Self.block
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            for row in 0..<rows {
                for column in 0..<columns {
                    let fromSide = min(column, columns - 1 - column), fromEnd = min(row, rows - 1 - row)
                    let corner = fromSide + fromEnd < 2
                    let border = fromSide == 0 || fromEnd == 0
                    if corner || (border && outline[row * columns + column]) { continue }
                    let color = color(atColumn: (Double(column) + 0.5) / Double(columns), row: (Double(row) + 0.5) / Double(rows))
                    context.setFillColor(CGColor(srgbRed: min(color.x, 1), green: min(color.y, 1), blue: min(color.z, 1), alpha: 1))
                    // CGContext empieza abajo: la fila 0 de la imagen es la de arriba.
                    context.fill(CGRect(x: column * Self.block, y: (rows - 1 - row) * Self.block, width: Self.block, height: Self.block))
                }
            }
            return context.makeImage()
        }
    }

    // MARK: - Agua

    private static func emitter() -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .plane
        emitter.emitterShapeSize = SIMD3(0.9, 0, 0.9)
        emitter.birthLocation = .volume
        emitter.birthDirection = .world
        emitter.emissionDirection = SIMD3(0, -1, 0)
        emitter.speed = 7
        emitter.speedVariation = 1
        emitter.mainEmitter.birthRate = 900
        emitter.mainEmitter.lifeSpan = 0.7
        emitter.mainEmitter.size = 0.06
        emitter.mainEmitter.stretchFactor = 6
        emitter.mainEmitter.acceleration = SIMD3(0, -9, 0)
        emitter.mainEmitter.color = .constant(.single(PlatformColor(red: 0.78, green: 0.9, blue: 1, alpha: 0.75)))
        emitter.isEmitting = false
        return emitter
    }
}

/// Los recorridos para ducharse: salir del sofá, esperar a que se abra la puerta, entrar; y al revés.
enum OfficeShowerRoute {
    /// Cuánto se espera delante de la ducha a que la puerta se abra (y dentro, al salir).
    private static let doorWait = 0.9

    /// Del sofá a la ducha. `openAt` es el fotograma en que llega delante (ahí se abre la puerta).
    static func toShower(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, shower: OfficeShower, fps: Double,
                         obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> (path: OfficeRoutePath, openAt: Int)? {
        guard let leave = OfficeOutingRoute.leave(actor: actor, template: template, to: shower.outside, obstacles: obstacles, bounds: bounds),
              let outside = leave.poses.last else { return nil }
        var inside = shower.inside
        inside.chairOffset = outside.chairOffset
        let path = OfficeOutingRoute.join(OfficeOutingRoute.join(leave, OfficeOutingRoute.hold(outside, seconds: doorWait, fps: fps)),
                                          OfficeOutingRoute.step(from: outside, to: inside, template: template))
        return (path, leave.poses.count)
    }

    /// De la ducha al sofá. `closeAt` es el fotograma en que ya está fuera (ahí se cierra la puerta).
    static func toSofa(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, shower: OfficeShower, fps: Double,
                       obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> (path: OfficeRoutePath, closeAt: Int)? {
        var outside = shower.outside
        outside.yaw = 0  // al salir, de espaldas a la ducha
        guard let back = OfficeOutingRoute.back(actor: actor, template: template, from: outside, obstacles: obstacles, bounds: bounds),
              let first = back.poses.first else { return nil }
        var inside = shower.inside
        inside.chairOffset = first.chairOffset
        outside.chairOffset = first.chairOffset
        let out = OfficeOutingRoute.join(OfficeOutingRoute.hold(inside, seconds: doorWait, fps: fps),
                                         OfficeOutingRoute.step(from: inside, to: outside, template: template))
        return (OfficeOutingRoute.join(out, back), out.poses.count)
    }
}
