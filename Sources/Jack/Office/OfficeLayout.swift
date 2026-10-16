import Foundation
import simd

/// Descripción de la oficina 3D exportada desde Blender (`Resources/Office/Runtime/OfficeLayout.json`).
///
/// Las coordenadas del archivo son las de Blender (z hacia arriba, en metros); RealityKit usa y hacia arriba,
/// así que cada punto se convierte con `OfficePose`: x→x, z→y, y→-z.
struct OfficeLayout: Decodable {
    struct Clip: Decodable {
        let start: Double
        let duration: Double
        let loop: Bool
    }

    struct Room: Decodable {
        let min: [Double]
        let max: [Double]
        let height: Double
    }

    /// Un recorrido ya calculado: la posición del personaje en cada fotograma y qué clip suena en cada tramo.
    struct Segment: Decodable {
        struct ClipRange: Decodable {
            let clip: String
            let from: Int
            let to: Int
        }

        let frames: Int
        /// `[x, y, z, giro en grados, desplazamiento de la silla]` por fotograma.
        let root: [[Double]]
        let clips: [ClipRange]
    }

    struct Slot: Decodable {
        let id: String
        let name: String
        let file: String
        let chair: String
        /// La pantalla de su escritorio en la sala; es lo que se acerca al abrir el PC.
        let monitor: String?
        let chairDir: [Double]
        let sofa: [Double]
        let atDesk: [Double]
        let atSofa: [Double]
        let toDesk: Segment
        let toSofa: Segment
    }

    /// El espejo de la pared: su cristal y qué piezas de la sala hay que ocultar o quitar para que refleje.
    struct Mirror: Decodable {
        /// La pared que se perforó para el espejo (en el reflejo no debe aparecer).
        let wall: String
        /// El marco del espejo, que en el reflejo sobraría.
        let frame: String
        /// Centro del cristal, ancho y alto, en coordenadas de Blender.
        let center: [Double]
        let width: Double
        let height: Double
    }

    let fps: Double
    let mirror: Mirror?
    let clips: [String: Clip]
    let room: Room
    let slots: [Slot]

    static func load(from url: URL) throws -> OfficeLayout {
        try JSONDecoder().decode(OfficeLayout.self, from: Data(contentsOf: url))
    }
}

/// Posición, giro y silla de un personaje en RealityKit.
struct OfficePose: Equatable {
    var position: SIMD3<Float>
    /// Giro en radianes alrededor del eje y. Con 0, el personaje mira hacia +z.
    var yaw: Float
    /// Cuánto se aleja la silla de su sitio, en metros.
    var chairOffset: Float

    init(position: SIMD3<Float>, yaw: Float, chairOffset: Float) {
        self.position = position
        self.yaw = yaw
        self.chairOffset = chairOffset
    }

    /// `[x, y, z, giro, silla]` de Blender.
    init(_ values: [Double]) {
        position = OfficePose.world(x: values[0], y: values[1], z: values[2])
        yaw = Float(values[3] * .pi / 180)
        chairOffset = values.count > 4 ? Float(values[4]) : 0
    }

    static func world(x: Double, y: Double, z: Double) -> SIMD3<Float> {
        SIMD3(Float(x), Float(z), Float(-y))
    }

    var orientation: simd_quatf { simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) }

    static func mix(_ a: OfficePose, _ b: OfficePose, _ t: Float) -> OfficePose {
        OfficePose(position: a.position + (b.position - a.position) * t,
                   yaw: a.yaw + (b.yaw - a.yaw) * t,
                   chairOffset: a.chairOffset + (b.chairOffset - a.chairOffset) * t)
    }
}

extension OfficeLayout.Segment {
    var poses: [OfficePose] { root.map(OfficePose.init) }
}
