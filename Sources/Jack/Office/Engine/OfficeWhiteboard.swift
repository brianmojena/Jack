import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(JackCore)
import JackCore
#endif
import RealityKit
import simd

/// La pizarra de tiza de pie junto a la pared del espejo, pasada la mesita del café. El caballete viene en la sala (`PROP_chalkboard`
/// en Office.blend, con su luz horneada); aquí solo está la superficie donde se enseña el dibujo, pegada a su cara verde: una
/// imagen transparente con trazos de tiza que se va sustituyendo mientras alguien dibuja. Delante tiene el sitio donde se para
/// quien dibuja. En el espejo hay una gemela que comparte las mismas texturas.
@MainActor final class OfficeWhiteboard {
    /// Donde se para quien dibuja: de cara a la pizarra, con la mano derecha ante su centro.
    let spot: OfficePose
    /// El puesto que está dibujando; solo cabe uno ante la pizarra.
    var occupant: Int?

    private let layout: OfficeLayout.Whiteboard
    /// El dibujo (los colores de la tiza) y su máscara (dónde hay tiza: el resto deja ver la pizarra).
    private var texture: TextureResource?
    private var mask: TextureResource?
    private let world: Entity
    private var boards: [Entity] = []
    private var surfaces: [(entity: ModelEntity, reflected: Bool)] = []

    /// Resolución de la textura de la superficie (el alto sale de la proporción de la pizarra).
    private static let textureWidth = 1600
    /// Cuánta de la superficie se deja en blanco alrededor del dibujo (en píxeles de la textura).
    private static let margin: CGFloat = 70

    init(layout: OfficeLayout.Whiteboard, world: Entity) {
        self.layout = layout
        self.world = world
        spot = OfficePose(layout.stand)
        boards = [build(reflected: false)]
        world.addChild(boards[0])
    }

    private var textureHeight: Int { Int((Double(Self.textureWidth) * layout.height / layout.width).rounded()) }

    /// La gemela de la pizarra en la sala del espejo (dentro de `reflectedWorld`).
    func attachMirror(in reflectedWorld: Entity) {
        let copy = build(reflected: true)
        reflectedWorld.addChild(copy)
        boards.append(copy)
    }

    /// Crea las texturas de la superficie, sin nada dibujado, y se las pone a las pizarras.
    func prepare() async {
        guard texture == nil, let chalk = Self.render(svg: nil, width: Self.textureWidth, height: textureHeight),
              let color = try? await TextureResource(image: chalk.color, options: .init(semantic: .color)),
              let opacity = try? await TextureResource(image: chalk.mask, options: .init(semantic: .raw)) else { return }
        texture = color
        mask = opacity
        for (entity, reflected) in surfaces { entity.model?.materials = [surfaceMaterial(reflected: reflected)] }
    }

    /// Borra la pizarra.
    func clear() {
        show(Self.render(svg: nil, width: Self.textureWidth, height: textureHeight))
    }

    #if os(macOS)
    // Dibujar un SVG o pintar con un programa es cosa de la Mac (los genera Gemma y los rasteriza AppKit); el iPhone recibe los
    // dibujos ya hechos imagen y los enseña con `show(painting:)`.

    /// Enseña el dibujo poco a poco, como si se estuviera haciendo: cada paso añade formas al anterior, repartidos en `seconds`.
    func reveal(_ sketch: OfficeSketch, over seconds: Double) async {
        let steps = min(max(sketch.shapeCount, 1), 28)
        var frames: [Chalk] = []
        for svg in sketch.progressive(steps: steps) {
            if let image = Self.render(svg: svg, width: Self.textureWidth, height: textureHeight) { frames.append(image) }
            await Task.yield()
        }
        guard !frames.isEmpty else { return }
        let pause = seconds / Double(frames.count)
        for frame in frames {
            guard !Task.isCancelled else { return }
            show(frame)
            try? await Task.sleep(for: .seconds(pause))
        }
    }

    /// Un cuadro pintado por un programa, tal como lo dibujó (entero y centrado, pegado sobre la pizarra).
    func show(painting: CGImage) {
        show(Self.render(width: Self.textureWidth, height: textureHeight) { context, area in
            context.draw(painting, in: Self.fit(CGSize(width: painting.width, height: painting.height), in: area))
        })
    }

    /// Lo que va pintando el programa de un cuadro, de 0 a 1 en `seconds`: cada fotograma se pide a `runner` en cuanto se acaba de
    /// enseñar el anterior, así que si pintarlo cuesta más de lo que toca, simplemente va más despacio.
    func reveal(_ program: OfficeCanvasProgram, with runner: OfficeCanvasRunner, over seconds: Double) async {
        let steps = 28
        let pause = seconds / Double(steps)
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            let started = Date()
            guard let painting = try? await runner.frame(progress: Double(step) / Double(steps)) else { return }
            guard !Task.isCancelled else { return }
            show(painting: painting)
            let spent = Date().timeIntervalSince(started)
            if spent < pause { try? await Task.sleep(for: .seconds(pause - spent)) }
        }
    }
    #endif

    private func show(_ chalk: Chalk?) {
        guard let chalk, let texture, let mask else { return }
        try? texture.replace(withImage: chalk.color, options: .init(semantic: .color))
        try? mask.replace(withImage: chalk.mask, options: .init(semantic: .raw))
    }

    // MARK: - Modelo

    private func surfaceMaterial(reflected: Bool) -> UnlitMaterial {
        var material = UnlitMaterial(color: .clear)
        if let texture, let mask {
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: .init(scale: 0.92, texture: .init(mask)))
        } else {
            material.blending = .transparent(opacity: .init(scale: 0))
        }
        // En el reflejo se invierte el orden de los vértices (ver `OfficeStage.flipCulling`).
        if reflected { material.faceCulling = .front }
        return material
    }

    /// La superficie del dibujo, pegada a la cara de la pizarra. Mira hacia +x (hacia la sala), que en Blender es también +x.
    private func build(reflected: Bool) -> Entity {
        let group = Entity()
        group.name = reflected ? "office-whiteboard-mirror" : "office-whiteboard"
        group.position = OfficePose.world(x: layout.center[0], y: layout.center[1], z: layout.center[2])
        let surface = ModelEntity(mesh: .generatePlane(width: Float(layout.width), height: Float(layout.height)), materials: [surfaceMaterial(reflected: reflected)])
        surface.name = "whiteboard-surface"
        // `generatePlane` mira hacia +z; la superficie mira hacia +x (hacia la sala).
        surface.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        surface.position = SIMD3(Float(layout.depth) / 2 + 0.006, 0, 0)
        group.addChild(surface)
        surfaces.append((surface, reflected))
        return group
    }

    // MARK: - Imagen

    /// El mayor rectángulo con la proporción de `size` que cabe centrado en `area`.
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// Lo que se ve en la pizarra: el color de la tiza y la máscara de dónde la hay (blanco opaco, negro transparente).
    struct Chalk {
        let color: CGImage
        let mask: CGImage
    }

    /// La superficie con su dibujo (o vacía): el SVG, centrado y entero, en tiza.
    static func render(svg: String?, width: Int, height: Int) -> Chalk? {
        render(width: width, height: height) { context, area in
            #if os(macOS)
            guard let svg, let image = NSImage(data: Data(svg.utf8)), image.size.width > 0, image.size.height > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: fit(image.size, in: area))
            NSGraphicsContext.restoreGraphicsState()
            #endif
        }
    }

    /// `draw` sobre un fondo transparente, en el área de dibujo (sin los márgenes), convertido en tiza: cada color se aclara
    /// hacia el blanco para que se lea sobre el verde oscuro, y lo transparente deja ver la pizarra.
    static func render(width: Int, height: Int, draw: (CGContext, CGRect) -> Void) -> Chalk? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(rect)
        draw(context, rect.insetBy(dx: margin, dy: margin))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var color = [UInt8](repeating: 0, count: width * height * 4)
        var mask = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let alpha = Float(pixels[index * 4 + 3]) / 255
            let opacity = UInt8(alpha * 255)
            mask[index * 4] = opacity; mask[index * 4 + 1] = opacity; mask[index * 4 + 2] = opacity; mask[index * 4 + 3] = 255
            color[index * 4 + 3] = 255
            guard alpha > 0 else { continue }
            for channel in 0..<3 {
                // Sin premultiplicar y a medio camino del blanco: tiza de colores.
                let value = min(1, Float(pixels[index * 4 + channel]) / 255 / alpha)
                color[index * 4 + channel] = UInt8((value * 0.55 + 0.45) * 255)
            }
        }
        func image(_ bytes: [UInt8]) -> CGImage? {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                           shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let colorImage = image(color), let maskImage = image(mask) else { return nil }
        return Chalk(color: colorImage, mask: maskImage)
    }
}

/// Los recorridos para dibujar: del sofá a la pizarra y, al terminar, de vuelta.
enum OfficeBoardRoute {
    static func toBoard(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, board: OfficeWhiteboard,
                        obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> OfficeRoutePath? {
        OfficeOutingRoute.leave(actor: actor, template: template, to: board.spot, obstacles: obstacles, bounds: bounds)
    }

    static func toSofa(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, board: OfficeWhiteboard,
                       obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> OfficeRoutePath? {
        OfficeOutingRoute.back(actor: actor, template: template, from: board.spot, obstacles: obstacles, bounds: bounds)
    }
}
