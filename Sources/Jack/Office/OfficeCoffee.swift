import Foundation
import RealityKit
import simd

/// La mesita del café: dónde se pone quien va a tomarse uno y la taza que coge. La taza (la del capuchino, sin el plato ni la
/// cucharilla) desaparece de la mesa mientras la lleva en la mano izquierda y vuelve a su sitio al terminar. En el espejo pasa
/// lo mismo con la gemela.
@MainActor final class OfficeCoffeeBar {
    /// Delante de la mesita, mirándola.
    let spot: OfficePose
    /// El puesto que está tomando café; solo cabe uno delante de la mesita.
    var occupant: Int?

    /// La taza y su café, dentro de `OfficeCoffee.usdz`.
    private static let cupParts = ["COFFEE_Line272", "COFFEE_Circle239"]
    /// Del centro de la taza a la muñeca, a lo largo de la mano (hacia los dedos), en unidades de la escena.
    private static let grip: Float = 0.3

    private let world: Entity
    private let cup: [Entity]
    private let cupCenter: SIMD3<Float>
    private var reflectedCup: [Entity] = []
    private weak var reflectedWorld: Entity?
    private var held: Entity?
    private var heldReflection: Entity?

    init?(coffee: Entity, room: Entity, world: Entity) {
        let parts = Self.cupParts.compactMap { coffee.findEntity(named: $0) }
        guard !parts.isEmpty, let table = room.findEntity(named: "PROP_coffee_table") else { return nil }
        let tableBounds = table.visualBounds(relativeTo: nil)
        let cupBounds = parts.map { $0.visualBounds(relativeTo: nil) }.reduce(parts[0].visualBounds(relativeTo: nil)) { $0.union($1) }
        self.world = world
        cup = parts
        cupCenter = cupBounds.center
        // La mesita está contra la pared del espejo (-x): se espera delante de su canto, a la altura de la taza, mirando a -x.
        spot = OfficePose(position: SIMD3(tableBounds.max.x + 1.3, 0, cupBounds.center.z), yaw: -.pi / 2, chairOffset: 0)
    }

    /// La gemela de la cafetera en la sala del espejo (dentro de `reflectedWorld`).
    func attachMirror(_ coffee: Entity, in reflectedWorld: Entity) {
        reflectedCup = Self.cupParts.compactMap { coffee.findEntity(named: $0) }
        self.reflectedWorld = reflectedWorld
    }

    /// Coge la taza: la de la mesa se esconde y una copia pasa a seguir la mano.
    func takeCup() {
        guard held == nil else { return }
        held = copy(cup, into: world)
        if let reflectedWorld, !reflectedCup.isEmpty { heldReflection = copy(reflectedCup, into: reflectedWorld) }
        for part in cup + reflectedCup { part.isEnabled = false }
    }

    /// La taza, a la mano: `hand` es la articulación de la mano izquierda en la escena.
    func follow(hand: simd_float4x4?) {
        guard let held, let hand else { return }
        let wrist = SIMD3(hand.columns.3.x, hand.columns.3.y, hand.columns.3.z)
        let along = simd_normalize(SIMD3(hand.columns.1.x, hand.columns.1.y, hand.columns.1.z))
        let offset = wrist + along * Self.grip - cupCenter
        held.position = offset
        heldReflection?.position = offset
    }

    /// Deja la taza en su sitio de la mesa.
    func returnCup() {
        held?.removeFromParent()
        heldReflection?.removeFromParent()
        held = nil
        heldReflection = nil
        for part in cup + reflectedCup { part.isEnabled = true }
    }

    /// Copias de las piezas, en el mismo sitio que las originales, dentro de un grupo colgado en el origen de `parent`: mover el
    /// grupo mueve la taza tal cual estaba (mismo tamaño y giro).
    private func copy(_ parts: [Entity], into parent: Entity) -> Entity {
        let group = Entity()
        group.name = "coffee-cup-held"
        parent.addChild(group)
        for part in parts {
            let placed = part.transformMatrix(relativeTo: parent)
            let copy = part.clone(recursive: true)
            copy.isEnabled = true
            group.addChild(copy)
            copy.setTransformMatrix(placed, relativeTo: group)
        }
        return group
    }
}

/// Los recorridos para tomar café: del sofá a la mesita y, al terminar, de vuelta.
enum OfficeCoffeeRoute {
    static func toBar(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, bar: OfficeCoffeeBar,
                      obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> OfficeRoutePath? {
        OfficeOutingRoute.leave(actor: actor, template: template, to: bar.spot, obstacles: obstacles, bounds: bounds)
    }

    static func toSofa(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, bar: OfficeCoffeeBar,
                       obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> OfficeRoutePath? {
        OfficeOutingRoute.back(actor: actor, template: template, from: bar.spot, obstacles: obstacles, bounds: bounds)
    }
}
