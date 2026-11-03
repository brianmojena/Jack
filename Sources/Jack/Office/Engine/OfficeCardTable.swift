#if canImport(JackCore)
import CoreGraphics
import JackCore
#endif
import RealityKit
import simd

/// Las cartas sobre la mesa de la oficina, en 3D: planos finos con la cara y el dorso (dibujados por `OfficeCardFace`) que se
/// reparten, se voltean y viajan de un sitio a otro, y montones de dorsos con el grosor de las cartas que llevan.
///
/// Todo se coloca con «sitios» (`Spot`): un punto de la mesa y hacia dónde mira la parte de arriba de la carta. Cada sitio se
/// calcula desde un asiento (`seat(...)`), de modo que a cada jugador sus cartas le quedan derechas.
@MainActor final class OfficeCardTable {
    static let size = SIMD2<Float>(0.45, 0.675)
    /// Cuánto separa una carta de otra en una fila.
    static let spacing: Float = 0.52

    struct Spot {
        var position: SIMD3<Float>
        var yaw: Float
    }

    final class Card {
        fileprivate let root = Entity()
        fileprivate let front: ModelEntity
        fileprivate let back: ModelEntity
        fileprivate(set) var faceUp: Bool
        var spot: Spot

        fileprivate init(front: ModelEntity, back: ModelEntity, faceUp: Bool, spot: Spot) {
            self.front = front
            self.back = back
            self.faceUp = faceUp
            self.spot = spot
            root.addChild(front)
            root.addChild(back)
        }
    }

    let root = Entity()
    private let center: SIMD3<Float>
    private let seats: [String: OfficeChessSeat]
    private var textures: [OfficeCardKind: TextureResource] = [:]
    private var cards: [Card] = []
    private var stacks: [String: ModelEntity] = [:]
    private let mesh: MeshResource

    /// `center` es el centro de la superficie de la mesa (x, y de la altura, z) en la escena.
    init(world: Entity, center: SIMD3<Float>, seats: [String: OfficeChessSeat]) {
        self.center = center
        self.seats = seats
        let width = Self.size.x, depth = Self.size.y
        // El plano con la imagen derecha vista desde arriba por quien tiene el borde de arriba de la carta al fondo (hacia -z):
        // la esquina de arriba a la izquierda es (-x, -z).
        var descriptor = MeshDescriptor(name: "card")
        descriptor.positions = MeshBuffer([SIMD3(-width / 2, 0, -depth / 2), SIMD3(width / 2, 0, -depth / 2),
                                           SIMD3(width / 2, 0, depth / 2), SIMD3(-width / 2, 0, depth / 2)])
        descriptor.normals = MeshBuffer(Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
        descriptor.textureCoordinates = MeshBuffer([SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)])
        descriptor.primitives = .triangles([0, 3, 2, 0, 2, 1])
        mesh = (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generatePlane(width: width, depth: depth)
        root.name = "office-cards"
        world.addChild(root)
    }

    /// Quita todas las cartas y los montones de la mesa.
    func clear() {
        for card in cards { card.root.removeFromParent() }
        cards = []
        for stack in stacks.values { stack.removeFromParent() }
        stacks = [:]
    }

    func tearDown() {
        clear()
        root.removeFromParent()
    }

    // MARK: - Sitios

    /// Un punto de la mesa respecto al asiento `id`: `forward` es cuánto se aleja del centro hacia ese asiento y `right`, el
    /// desplazamiento a la derecha de quien se sienta ahí. La carta queda derecha para él.
    func spot(seat id: String, forward: Float, right: Float, lift: Float = 0.012) -> Spot {
        guard let seat = seats[id] else { return Spot(position: center, yaw: 0) }
        let yaw = seat.pose.yaw
        // Hacia dónde mira quien se sienta: de su asiento a la mesa.
        let facing = SIMD2(sin(yaw), cos(yaw))
        let side = SIMD2(-facing.y, facing.x)
        let xz = SIMD2(center.x, center.z) - facing * forward + side * right
        return Spot(position: SIMD3(xz.x, center.y + lift, xz.y), yaw: yaw + .pi)
    }

    /// La fila de `count` cartas delante de un asiento, centrada; `index` es la que se pide.
    func row(seat id: String, index: Int, count: Int, forward: Float = 1.5, spacing: Float = OfficeCardTable.spacing) -> Spot {
        let offset = (Float(index) - Float(count - 1) / 2) * spacing
        return spot(seat: id, forward: forward, right: offset, lift: 0.012 + 0.002 * Float(index))
    }

    /// Un sitio del centro de la mesa visto desde el asiento `viewer` (la fila de las cartas comunes, el montón).
    func middle(viewer id: String, right: Float = 0, forward: Float = 0, lift: Float = 0.012) -> Spot {
        spot(seat: id, forward: forward, right: right, lift: lift)
    }

    // MARK: - Cartas

    private func texture(_ kind: OfficeCardKind) async -> TextureResource? {
        if let cached = textures[kind] { return cached }
        guard let image = OfficeCardImages.image(for: kind), let made = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        textures[kind] = made
        return made
    }

    private func material(_ kind: OfficeCardKind) async -> UnlitMaterial {
        var material = UnlitMaterial(color: .white)
        if let texture = await texture(kind) {
            material.color = .init(tint: .white, texture: .init(texture))
            // Las esquinas redondeadas son transparentes.
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
        }
        return material
    }

    /// Una carta nueva en `spot`. `kind` es lo que enseña al estar boca arriba; si `nil`, solo se ve el dorso (no se sabe qué es).
    @discardableResult
    func place(_ kind: OfficeCardKind?, at spot: Spot, faceUp: Bool) async -> Card {
        let front = ModelEntity(mesh: mesh, materials: [await material(kind ?? .back)])
        front.position.y = 0.002
        let back = ModelEntity(mesh: mesh, materials: [await material(.back)])
        back.position.y = -0.002
        // El dorso mira hacia abajo: se da la vuelta sobre el eje de la carta.
        back.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
        let card = Card(front: front, back: back, faceUp: faceUp, spot: spot)
        card.root.transform = transform(spot, faceUp: faceUp)
        root.addChild(card.root)
        cards.append(card)
        return card
    }

    private func transform(_ spot: Spot, faceUp: Bool) -> Transform {
        let turn = simd_quatf(angle: spot.yaw, axis: SIMD3(0, 1, 0))
        let flip = faceUp ? simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) : simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
        return Transform(scale: .one, rotation: turn * flip, translation: spot.position)
    }

    /// Empieza a llevar la carta a otro sitio (y a voltearla si hace falta) y vuelve enseguida: varias a la vez.
    func slide(_ card: Card, to spot: Spot, faceUp: Bool? = nil, duration: Double = 0.45) {
        let target = faceUp ?? card.faceUp
        card.spot = spot
        card.faceUp = target
        card.root.move(to: transform(spot, faceUp: target), relativeTo: root, duration: duration, timingFunction: .easeInOut)
    }

    /// Lleva la carta a otro sitio en `duration` segundos; vuelve cuando llega.
    func move(_ card: Card, to spot: Spot, faceUp: Bool? = nil, duration: Double = 0.45) async {
        slide(card, to: spot, faceUp: faceUp, duration: duration)
        try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
    }

    /// Cambia lo que enseña al estar boca arriba (para destapar una carta que se jugó oculta).
    func reveal(_ card: Card, as kind: OfficeCardKind) async {
        card.front.model?.materials = [await material(kind)]
    }

    func remove(_ card: Card) {
        card.root.removeFromParent()
        cards.removeAll { $0 === card }
    }

    // MARK: - Montones

    /// Un montón de dorsos con el grosor de `count` cartas; sin cartas, desaparece. `id` lo identifica para ir actualizándolo.
    func setStack(_ id: String, count: Int, at spot: Spot) async {
        guard count > 0 else {
            stacks[id]?.isEnabled = false
            return
        }
        let height = min(0.2, max(0.006, 0.0045 * Float(count)))
        let stack: ModelEntity
        if let existing = stacks[id] {
            stack = existing
        } else {
            stack = ModelEntity()
            stacks[id] = stack
            root.addChild(stack)
            let top = ModelEntity(mesh: mesh, materials: [await material(.back)])
            top.name = "top"
            stack.addChild(top)
        }
        stack.isEnabled = true
        // Los bordes son marfil, como el canto de las cartas.
        stack.model = ModelComponent(mesh: .generateBox(size: SIMD3(Self.size.x * 0.99, height, Self.size.y * 0.99), cornerRadius: 0.01),
                                     materials: [SimpleMaterial(color: PlatformColor(red: 0.9, green: 0.87, blue: 0.78, alpha: 1), roughness: 0.7, isMetallic: false)])
        stack.findEntity(named: "top")?.position.y = height / 2 + 0.002
        stack.position = SIMD3(spot.position.x, center.y + height / 2 + 0.004, spot.position.z)
        stack.orientation = simd_quatf(angle: spot.yaw, axis: SIMD3(0, 1, 0))
    }
}
