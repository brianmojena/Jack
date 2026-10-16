import AppKit
import Foundation
import RealityKit
import simd

/// La oficina 3D: la sala, sus luces y los personajes de cada puesto.
///
/// No sabe nada de los agentes de Jack; quien la use le pide a cada puesto un `OfficeCommand`.
@MainActor final class OfficeStage: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Dónde están los archivos exportados desde Blender.
    struct Resources {
        var url: (_ name: String, _ ext: String) -> URL?

        static let bundled = Resources { name, ext in Bundle.main.url(forResource: name, withExtension: ext) }
        static func folder(_ folder: URL) -> Resources {
            Resources { name, ext in folder.appendingPathComponent("\(name).\(ext)") }
        }
    }

    @Published private(set) var state = LoadState.idle
    /// De dónde se cargan los modelos de los avatares que se eligen después de abrir la oficina.
    private var resources = Resources.bundled
    let world = Entity()
    private(set) var layout: OfficeLayout?
    private(set) var actors: [OfficeActor] = []
    private(set) var room: Entity?
    /// La luz ambiental de la sala: un entorno sintético cálido, no el cielo (el HDRI solo es fondo).
    private var ambient: EnvironmentResource?
    private var pointLights: [Entity] = []
    private var mirroredRoom: Entity?
    /// Los cristales de los monitores por puesto: el de la sala y el de su reflejo.
    private var screens: [String: [(entity: Entity, reflected: Bool)]] = [:]
    /// La pantalla de la tele, en la sala y en su reflejo.
    private var tvScreens: [(entity: Entity, reflected: Bool)] = []
    /// El letrero de cada puesto en la pared, sobre su escritorio, y dónde queda esa pared.
    private var labels: [String: ModelEntity] = [:]
    private var walls: [Int: SIMD3<Float>] = [:]
    private var wallTries: [Int: Int] = [:]
    /// Las paredes llevan una colisión temporal, solo para encontrar dónde colgar los letreros.
    private var wallColliders: [Entity] = []
    private static let wallGroup = CollisionGroup(rawValue: 1 << 20)

    /// Centro de la sala, hacia donde mira la cámara, en coordenadas de RealityKit.
    var focus: SIMD3<Float> { OfficePose.world(x: 3.2, y: -4.5, z: 2.4) }

    func load(_ resources: Resources = .bundled) async {
        guard state == .idle else { return }
        state = .loading
        self.resources = resources
        do {
            guard let layoutURL = resources.url("OfficeLayout", "json") else { throw OfficeError.missing("OfficeLayout.json") }
            let layout = try OfficeLayout.load(from: layoutURL)
            self.layout = layout
            guard let roomURL = resources.url("OfficeRoom", "usdz") else { throw OfficeError.missing("OfficeRoom.usdz") }
            let room = try await Entity(contentsOf: roomURL)
            self.room = room
            world.addChild(room)
            // Antes del espejo, para que el reflejo copie las paredes y la tele ya cambiadas.
            Self.solidWalls(in: room)
            Self.fixBackWallCorner(in: room)
            enlargeTV(in: room)
            await prepareWalls(in: room)
            var made: [OfficeActor] = []
            for (index, slot) in layout.slots.enumerated() {
                guard let url = resources.url(slot.file, "usdz") else { throw OfficeError.missing("\(slot.file).usdz") }
                let model = try await Entity(contentsOf: url)
                let actor = OfficeActor(index: index, slot: slot, layout: layout, model: model)
                actor.attachChair(in: room)
                world.addChild(actor.holder)
                made.append(actor)
            }
            actors = made
            await addLights(resources)
            addGroundingShadows(room)
            for actor in made { addGroundingShadows(actor.holder) }
            if let mirror = layout.mirror { addMirror(mirror, room: room) }
            collectScreens(layout: layout, room: room)
            collectTV(room: room)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Pone a un puesto el modelo de otro avatar (el archivo `<avatar>.usdz`); el personaje no se mueve ni deja lo que hacía.
    func setAvatar(_ avatar: String, forSlot index: Int) async {
        guard actors.indices.contains(index), let url = resources.url(avatar, "usdz"),
              let model = try? await Entity(contentsOf: url) else { return }
        let actor = actors[index]
        actor.replaceModel(with: model)
        if let reflection = actor.mirrorHolder { Self.flipCulling(reflection) }
        // Las sombras de contacto y de calidad: igual que el modelo al que sustituye.
        if appliedQuality?.shadows != false {
            addGroundingShadows(model)
            if !groundedEntities.isEmpty {
                func collect(_ entity: Entity) -> [Entity] { (entity.components.has(GroundingShadowComponent.self) ? [entity] : []) + entity.children.flatMap(collect) }
                groundedEntities += collect(model)
            }
        }
    }

    func command(_ command: OfficeCommand, forSlot index: Int) {
        guard actors.indices.contains(index) else { return }
        actors[index].command = command
    }

    /// El espejo: detrás de la pared hay una copia de la sala invertida respecto al plano del espejo, con sus personajes,
    /// que solo se ve a través de un portal en el cristal. Un cristal oscuro y casi transparente delante la hace pasar por reflejo.
    private func addMirror(_ mirror: OfficeLayout.Mirror, room: Entity) {
        let center = OfficePose.world(x: mirror.center[0], y: mirror.center[1], z: mirror.center[2])
        let reflected = Entity()
        reflected.name = "mirror-world"
        reflected.position = SIMD3(2 * center.x, 0, 0)
        reflected.scale = SIMD3(-1, 1, 1)
        let copy = room.clone(recursive: true)
        // La pared perforada y el marco quedarían delante del cristal en el reflejo.
        copy.findEntity(named: mirror.wall)?.removeFromParent()
        copy.findEntity(named: mirror.frame)?.removeFromParent()
        Self.flipCulling(copy)
        reflected.addChild(copy)
        mirroredRoom = copy
        // Las luces también se reflejan: sin ellas el reflejo queda a oscuras.
        for light in pointLights {
            let copy = light.clone(recursive: false)
            // En el mundo del portal no llega la luz de la sala: las luces reflejadas valen el triple para que se vea como ella.
            if var component = copy.components[PointLightComponent.self] {
                component.intensity *= 3
                copy.components.set(component)
            }
            reflected.addChild(copy)
        }
        for actor in actors {
            actor.attachMirror(in: reflected, room: copy)
            if let reflection = actor.mirrorHolder { Self.flipCulling(reflection) }
        }
        // La sala reflejada vive en su propio mundo, que solo se ve a través del portal del cristal.
        let portalWorld = Entity()
        portalWorld.name = "mirror-world"
        portalWorld.components.set(WorldComponent())
        if let ambient {
            let light = Entity()
            light.components.set(ImageBasedLightComponent(source: .single(ambient), intensityExponent: 0.8))
            portalWorld.addChild(light)
            reflected.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
        }
        portalWorld.addChild(reflected)
        world.addChild(portalWorld)

        let portal = ModelEntity(mesh: .generatePlane(width: Float(mirror.width), height: Float(mirror.height)), materials: [PortalMaterial()])
        portal.name = "mirror-portal"
        portal.components.set(PortalComponent(target: portalWorld))
        // `generatePlane` mira hacia +z; el cristal mira hacia +x (hacia la sala).
        portal.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        portal.position = center
        world.addChild(portal)

        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: NSColor(red: 0.02, green: 0.025, blue: 0.045, alpha: 1))
        glass.roughness = 0.05
        glass.blending = .transparent(opacity: 0.12)
        let pane = ModelEntity(mesh: .generatePlane(width: Float(mirror.width), height: Float(mirror.height)), materials: [glass])
        pane.name = "mirror-glass"
        // `generatePlane` mira hacia +z; el cristal mira hacia +x (hacia la sala).
        pane.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        pane.position = center + SIMD3(0.004, 0, 0)
        world.addChild(pane)
    }

    /// Las paredes (la sala fusionada y piezas sueltas como la de ladrillo) vienen con una sola cara, la de dentro: vistas
    /// desde fuera eran transparentes. Toda la sala se dibuja por las dos caras.
    /// El rincón de la pared de ladrillo: su caja hueca (`ROOM_merged_0`) tiene una cara de abajo que, vista por las dos caras,
    /// se pintaba con ladrillo encima del suelo, y la cara de ladrillo (`Object_388`) coincidía con el canto de la pared lateral.
    /// La caja vuelve a ocultar sus caras de espaldas (así no se ve su fondo ni su canto de dentro) y el ladrillo se adelanta
    /// dos centésimas hacia la sala.
    private static func fixBackWallCorner(in room: Entity) {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        if let box = room.findEntity(named: "ROOM_merged_0") {
            for entity in models(under: box) {
                guard var model = entity.components[ModelComponent.self] else { continue }
                model.materials = model.materials.map { material in
                    if var pbr = material as? PhysicallyBasedMaterial { pbr.faceCulling = .back; return pbr }
                    return material
                }
                entity.components.set(model)
            }
        }
        if let brick = room.findEntity(named: "Object_388") {
            // Hacia la sala es +z en la escena (en Blender, -y).
            brick.setPosition(brick.position(relativeTo: nil) + SIMD3(0, 0, 0.02), relativeTo: nil)
        }
    }

    private static func solidWalls(in room: Entity) {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        for entity in models(under: room) {
            guard var model = entity.components[ModelComponent.self] else { continue }
            model.materials = model.materials.map { material in
                if var pbr = material as? PhysicallyBasedMaterial { pbr.faceCulling = .none; return pbr }
                if var unlit = material as? UnlitMaterial { unlit.faceCulling = .none; return unlit }
                return material
            }
            entity.components.set(model)
        }
    }

    /// Invertir un eje da vuelta el orden de los vértices de cada triángulo: lo que era la cara de delante pasa a ser la de
    /// atrás. Para que el reflejo no salga del revés, sus materiales ocultan las caras contrarias.
    private static func flipCulling(_ entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                if var pbr = material as? PhysicallyBasedMaterial { pbr.faceCulling = .front; return pbr }
                if var unlit = material as? UnlitMaterial { unlit.faceCulling = .front; return unlit }
                return material
            }
            entity.components.set(model)
        }
        for child in entity.children { flipCulling(child) }
    }

    // MARK: - Tele

    /// La tele de la pared, más grande: crece sobre su propio centro para seguir colgada en el mismo sitio.
    private func enlargeTV(in room: Entity) {
        guard let tv = room.findEntity(named: "PROP_tv_75") else { return }
        let before = tv.visualBounds(relativeTo: tv.parent)
        tv.scale *= 1.5
        let after = tv.visualBounds(relativeTo: tv.parent)
        tv.position += before.center - after.center
    }

    private func collectTV(room: Entity) {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        if let screen = room.findEntity(named: "TV_49Zoll_Screen1_0") { tvScreens += models(under: screen).map { ($0, false) } }
        if let screen = mirroredRoom?.findEntity(named: "TV_49Zoll_Screen1_0") { tvScreens += models(under: screen).map { ($0, true) } }
    }

    /// Lo que enseña la tele.
    func setTV(image: CGImage) {
        guard !tvScreens.isEmpty else { return }
        Task { @MainActor in
            guard let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return }
            for (entity, reflected) in tvScreens {
                guard var model = entity.components[ModelComponent.self] else { continue }
                var material = UnlitMaterial(color: .white)
                material.color = .init(tint: .white, texture: .init(texture))
                if reflected { material.faceCulling = .front }
                model.materials = Array(repeating: material, count: max(model.materials.count, 1))
                entity.components.set(model)
            }
        }
    }

    // MARK: - Letreros

    /// Colisiones exactas de las paredes (la sala viene fusionada en pocas mallas), solo para lanzar rayos contra ellas.
    private func prepareWalls(in room: Entity) async {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        for entity in models(under: room) where entity.name.hasPrefix("ROOM_merged") {
            guard let mesh = entity.components[ModelComponent.self]?.mesh,
                  let shape = try? await ShapeResource.generateStaticMesh(from: mesh) else { continue }
            entity.components.set(CollisionComponent(shapes: [shape], mode: .default, filter: CollisionFilter(group: Self.wallGroup, mask: Self.wallGroup)))
            wallColliders.append(entity)
        }
    }

    /// El punto de la pared detrás del monitor de un puesto, a la altura `height`.
    private func wallPoint(slot index: Int, frame: (center: SIMD3<Float>, facing: SIMD3<Float>, size: SIMD2<Float>), height: Float) -> SIMD3<Float>? {
        if let found = walls[index] { return SIMD3(found.x, height, found.z) }
        let origin = SIMD3(frame.center.x, height, frame.center.z)
        if let hit = world.scene?.raycast(origin: origin, direction: -frame.facing, length: 20, query: .nearest, mask: Self.wallGroup, relativeTo: nil).first {
            walls[index] = hit.position
        } else {
            // La colisión tarda un fotograma en existir; si aun así no hay pared, el letrero queda justo detrás del monitor.
            wallTries[index, default: 0] += 1
            guard wallTries[index, default: 0] > 8 else { return nil }
            walls[index] = frame.center - frame.facing * 0.5
        }
        if let layout, walls.count == layout.slots.count {
            for entity in wallColliders { entity.components.remove(CollisionComponent.self) }
            wallColliders = []
        }
        return walls[index].map { SIMD3($0.x, height, $0.z) }
    }

    /// El letrero con el nombre del chat en la pared sobre el escritorio de un puesto; sin imagen, se quita.
    /// Devuelve `false` si todavía no se pudo colgar (la pared aún no se encontró): hay que volver a pedirlo.
    @discardableResult
    func setLabel(slot index: Int, image: CGImage?) -> Bool {
        guard let layout, layout.slots.indices.contains(index) else { return false }
        let id = layout.slots[index].id
        guard let image else {
            labels[id]?.isEnabled = false
            return true
        }
        guard let frame = screenFrame(slot: index) else { return false }
        let width = min(max(frame.size.x * 0.9, 2.2), 3.6)
        let height = width * Float(image.height) / Float(max(image.width, 1))
        let center = frame.center.y + frame.size.y / 2 + 0.45 + height / 2
        guard let wall = wallPoint(slot: index, frame: frame, height: center) else { return false }
        Task { @MainActor in
            guard let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return }
            var material = UnlitMaterial(color: .white)
            material.color = .init(tint: .white, texture: .init(texture))
            let mesh = MeshResource.generatePlane(width: width, height: height)
            let label = labels[id] ?? ModelEntity()
            label.model = ModelComponent(mesh: mesh, materials: [material])
            label.name = "label-\(id)"
            // `generatePlane` mira hacia +z; el letrero mira hacia la sala, como la pantalla.
            label.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: frame.facing)
            label.position = wall + frame.facing * 0.04
            label.isEnabled = true
            if labels[id] == nil {
                labels[id] = label
                world.addChild(label)
            }
        }
        return true
    }

    // MARK: - Monitores

    /// Busca el cristal de cada monitor (en Blender se llaman SCREEN_<puesto>) y los deja apagados.
    private func collectScreens(layout: OfficeLayout, room: Entity) {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        for slot in layout.slots {
            var found: [(Entity, Bool)] = []
            if let screen = room.findEntity(named: "SCREEN_\(slot.id)") { found += models(under: screen).map { ($0, false) } }
            if let screen = mirroredRoom?.findEntity(named: "SCREEN_\(slot.id)") { found += models(under: screen).map { ($0, true) } }
            screens[slot.id] = found
            setScreen(slot: slot.id, image: nil)
        }
    }

    /// Dónde está la pantalla de un puesto: su centro, hacia dónde mira (hacia la silla, en horizontal) y su ancho y alto.
    func screenFrame(slot index: Int) -> (center: SIMD3<Float>, facing: SIMD3<Float>, size: SIMD2<Float>)? {
        guard let layout, layout.slots.indices.contains(index),
              let screen = room?.findEntity(named: "SCREEN_\(layout.slots[index].id)") else { return nil }
        let bounds = screen.visualBounds(relativeTo: nil)
        guard !bounds.isEmpty else { return nil }
        var facing = OfficePose(layout.slots[index].atDesk).position - bounds.center
        facing.y = 0
        guard simd_length(facing) > 0.001 else { return nil }
        facing = simd_normalize(facing)
        // La pantalla está alineada con la sala: su ancho va por el eje horizontal que no mira hacia la silla.
        let width = abs(facing.x) > abs(facing.z) ? bounds.extents.z : bounds.extents.x
        return (bounds.center, facing, SIMD2(width, bounds.extents.y))
    }

    /// Lo que enseña el monitor de un puesto: una imagen, o apagado (negro) si no hay.
    func setScreen(slot id: String, image: CGImage?) {
        guard let targets = screens[id], !targets.isEmpty else { return }
        Task { @MainActor in
            var texture: TextureResource?
            if let image { texture = try? await TextureResource(image: image, options: .init(semantic: .color)) }
            for (entity, reflected) in targets {
                guard var model = entity.components[ModelComponent.self] else { continue }
                var material = UnlitMaterial(color: NSColor(white: 0.012, alpha: 1))
                if let texture { material.color = .init(tint: .white, texture: .init(texture)) }
                // En el reflejo se invierte el orden de los vértices (ver `flipCulling`).
                if reflected { material.faceCulling = .front }
                model.materials = Array(repeating: material, count: max(model.materials.count, 1))
                entity.components.set(model)
            }
        }
    }

    func update(deltaTime: Double) {
        for actor in actors { actor.update(deltaTime: min(deltaTime, 0.1)) }
    }

    // MARK: - Gráficos

    /// Las entidades con sombra de contacto, recogidas la primera vez para poder quitarlas y volver a ponerlas.
    private var groundedEntities: [Entity] = []
    private var logos: Entity?
    private var appliedQuality: OfficeQuality?
    private var sun: Entity?

    /// La luz de la iluminación simple, como la de una oficina: blanca y pareja, de frente y por arriba, más un relleno suave
    /// por el otro lado para que no queden zonas oscuras; sin sombras. Se crea la primera vez que hace falta.
    private func simpleSun() -> Entity {
        if let sun { return sun }
        let entity = Entity()
        entity.name = "simple-light"
        func light(from offset: SIMD3<Float>, intensity: Float, color: NSColor) -> Entity {
            let light = Entity()
            light.components.set(DirectionalLightComponent(color: color, intensity: intensity, isRealWorldProxy: false))
            light.look(at: focus, from: focus + offset, relativeTo: nil)
            return light
        }
        entity.addChild(light(from: SIMD3(9, 22, 16), intensity: 3200, color: NSColor(red: 1, green: 0.99, blue: 0.96, alpha: 1)))
        entity.addChild(light(from: SIMD3(-14, 14, -10), intensity: 1600, color: NSColor(red: 0.93, green: 0.96, blue: 1, alpha: 1)))
        entity.isEnabled = false
        world.addChild(entity)
        sun = entity
        return entity
    }

    /// Ajusta la escena a los gráficos elegidos. Con `ultra` queda como se montó al cargar.
    func apply(_ quality: OfficeQuality) {
        guard state == .ready, quality != appliedQuality else { return }
        // Con los gráficos de siempre y sin haber tocado nada, no hay nada que cambiar.
        if appliedQuality == nil, quality == .ultra { appliedQuality = quality; return }
        appliedQuality = quality
        func all(_ entity: Entity) -> [Entity] { [entity] + entity.children.flatMap(all) }
        let entities = all(world)
        if groundedEntities.isEmpty { groundedEntities = entities.filter { $0.components.has(GroundingShadowComponent.self) } }
        for entity in groundedEntities {
            if quality.shadows { entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true)) }
            else { entity.components.remove(GroundingShadowComponent.self) }
        }
        // Iluminación simple: sin focos ni puntos de luz, solo luz natural pareja (ambiental más una luz suave sin sombras).
        let simple = quality.lights == 1
        for entity in entities {
            // Los focos son lo principal; luego el relleno y el rebote del suelo; por último, los halos de los logos.
            if entity.components.has(SpotLightComponent.self) {
                entity.isEnabled = !simple
                if quality.shadows { if !entity.components.has(SpotLightComponent.Shadow.self) { entity.components.set(SpotLightComponent.Shadow()) } }
                else { entity.components.remove(SpotLightComponent.Shadow.self) }
            } else if let point = entity.components[PointLightComponent.self] {
                let isGlow = point.attenuationRadius <= 8
                entity.isEnabled = !simple && (quality.lights >= 3 || (quality.lights == 2 && !isGlow))
            } else if let ambient = entity.components[ImageBasedLightComponent.self] {
                // La ambiental de la sala sube en la iluminación simple; la del reflejo, que parte más alta, también.
                let inMirror = entity.parent?.parent === world
                let exponent: Float = simple ? (inMirror ? 2.2 : 1.8) : (inMirror ? 0.8 : 0.5)
                entity.components.set(ImageBasedLightComponent(source: ambient.source, intensityExponent: exponent))
            }
        }
        simpleSun().isEnabled = simple
        if logos == nil { logos = room?.findEntity(named: "PROP_lang_logos") }
        if #available(macOS 27.0, *), let logos {
            if quality.neon { logos.components.set(BloomComponent(scope: .hierarchical)) } else { logos.components.remove(BloomComponent.self) }
        }
        // El espejo: sin él no se dibuja la sala reflejada y el cristal pasa a ser un panel oscuro.
        world.children.first { $0.name == "mirror-world" }?.isEnabled = quality.mirror
        world.findEntity(named: "mirror-portal")?.isEnabled = quality.mirror
        if let glass = world.findEntity(named: "mirror-glass") as? ModelEntity, var model = glass.model {
            model.materials = model.materials.map { material in
                guard var pbr = material as? PhysicallyBasedMaterial else { return material }
                pbr.blending = .transparent(opacity: quality.mirror ? 0.12 : 0.92)
                return pbr
            }
            glass.model = model
        }
        for actor in actors { actor.freezeIdle = !quality.idleAnimation }
    }

    // MARK: - Luces

    /// Las luces de la sala, con el tinte morado y rosa de Blender. Para que parezca luz real, las principales son focos
    /// cenitales que proyectan sombras (las puntuales de RealityKit no las tienen); unas pocas puntuales suaves rellenan.
    private func addLights(_ resources: Resources) async {
        // Un toque de color, sin teñir la sala: cada luz es su color mezclado con blanco (`keep` es cuánto color queda).
        func tint(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, keep: CGFloat = 0.4) -> NSColor {
            NSColor(red: r * keep + (1 - keep), green: g * keep + (1 - keep), blue: b * keep + (1 - keep), alpha: 1)
        }
        // Focos altos y abiertos, para que la luz caiga pareja sin manchas quemadas; un aire cyberpunk: morado en el
        // escritorio de REMY y en el centro, rojo magenta en el de CH31 y rosa delante; los rellenos, violeta azulado.
        let spots: [(SIMD3<Double>, SIMD3<Double>, NSColor, Float)] = [
            (SIMD3(-2.0, -3.5, 12.0), SIMD3(-1.5, 0.5, 0), tint(0.72, 0.5, 1.0, keep: 0.5), 720_000),
            (SIMD3(8.5, -2.0, 12.0), SIMD3(8.5, 0.0, 0), tint(1.0, 0.24, 0.36, keep: 0.55), 720_000),
            (SIMD3(2.0, -11.0, 12.0), SIMD3(1.0, -10.0, 0), tint(1.0, 0.5, 0.78, keep: 0.4), 780_000),
            (SIMD3(3.2, -5.0, 12.5), SIMD3(3.2, -5.5, 0), tint(0.76, 0.6, 1.0, keep: 0.4), 320_000),
        ]
        for (position, target, color, intensity) in spots {
            let entity = Entity()
            var light = SpotLightComponent(color: color, intensity: intensity, innerAngleInDegrees: 28, outerAngleInDegrees: 60, attenuationRadius: 50)
            light.attenuationFalloffExponent = 0.9
            entity.components.set(light)
            entity.components.set(SpotLightComponent.Shadow())
            entity.look(at: OfficePose.world(x: target.x, y: target.y, z: target.z),
                        from: OfficePose.world(x: position.x, y: position.y, z: position.z), relativeTo: nil)
            world.addChild(entity)
            pointLights.append(entity)
        }
        // Relleno suave en las esquinas y el fondo, donde los focos no llegan.
        let fills: [(SIMD3<Double>, NSColor, Float)] = [
            (SIMD3(3.2, 3.0, 9.0), tint(0.55, 0.55, 1.0, keep: 0.4), 340_000),
            (SIMD3(-3.5, -12.0, 7.0), tint(0.5, 0.58, 1.0, keep: 0.4), 500_000),
            (SIMD3(10.5, -12.0, 7.0), tint(1.0, 0.3, 0.55, keep: 0.5), 460_000),
        ]
        for (position, color, intensity) in fills {
            let entity = Entity()
            entity.components.set(PointLightComponent(color: color, intensity: intensity, attenuationRadius: 45))
            entity.position = OfficePose.world(x: position.x, y: position.y, z: position.z)
            world.addChild(entity)
            pointLights.append(entity)
        }
        addNeonLogos()
        // Dentro de una sala no hay sol: en su lugar, la luz que devuelve el suelo de madera, cálida y baja, que ilumina
        // de abajo y de frente piernas, caras y muebles, como el rebote de un render con trazado de rayos. Sin sombras.
        let bounces: [SIMD3<Double>] = [SIMD3(0.5, -3.5, 2.5), SIMD3(6.5, -6.0, 2.5)]
        for position in bounces {
            let entity = Entity()
            entity.components.set(PointLightComponent(color: tint(1.0, 0.64, 0.45, keep: 0.4), intensity: 260_000, attenuationRadius: 30))
            entity.position = OfficePose.world(x: position.x, y: position.y, z: position.z)
            world.addChild(entity)
            pointLights.append(entity)
        }
        await addAmbient(resources)
    }

    /// Los logos de lenguajes de la pared, en neón suave: cada color de su paleta brilla un poco por sí mismo y cada logo deja
    /// en la pared un halo tenue de su color.
    private func addNeonLogos() {
        guard let logos = room?.findEntity(named: "PROP_lang_logos") else { return }
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        for entity in models(under: logos) {
            guard var model = entity.components[ModelComponent.self] else { continue }
            model.materials = model.materials.map { material in
                guard var pbr = material as? PhysicallyBasedMaterial else { return material }
                pbr.emissiveColor = .init(color: pbr.baseColor.tint, texture: pbr.baseColor.texture)
                pbr.emissiveIntensity = 0.45
                return pbr
            }
            entity.components.set(model)
        }
        if #available(macOS 27.0, *) { logos.components.set(BloomComponent(scope: .hierarchical)) }

        let bounds = logos.visualBounds(relativeTo: nil)
        var out = focus - bounds.center
        out.y = 0
        guard simd_length(out) > 0.001 else { return }
        out = simd_normalize(out)
        let up = SIMD3<Float>(0, 1, 0)
        // Mirando la pared desde la sala: a la derecha y hacia arriba.
        let right = simd_normalize(simd_cross(-out, up))
        let width = abs(right.x) * bounds.extents.x + abs(right.z) * bounds.extents.z
        let height = bounds.extents.y
        // Dos filas de tres: Swift, Python, TypeScript; Java, Svelte, Kotlin.
        let colors: [NSColor] = [
            NSColor(red: 1.0, green: 0.36, blue: 0.16, alpha: 1), NSColor(red: 0.95, green: 0.8, blue: 0.25, alpha: 1),
            NSColor(red: 0.2, green: 0.45, blue: 1.0, alpha: 1), NSColor(red: 0.3, green: 0.55, blue: 1.0, alpha: 1),
            NSColor(red: 1.0, green: 0.28, blue: 0.1, alpha: 1), NSColor(red: 0.62, green: 0.3, blue: 1.0, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            let column = Float(index % 3 - 1), row = index < 3 ? Float(0.25) : Float(-0.25)
            let point = bounds.center + right * (column * width / 3) + up * (row * height)
            let glow = Entity()
            // Lejos de la pared y flojo: el halo queda difuso, sin un punto de brillo que se desplace al mover la cámara.
            glow.components.set(PointLightComponent(color: color, intensity: 9_000, attenuationRadius: 5))
            glow.position = point + out * 1.8
            world.addChild(glow)
            pointLights.append(glow)
        }
    }

    /// Sombras de contacto suaves bajo los muebles y los personajes, como la oclusión de un render con luz rebotada.
    private func addGroundingShadows(_ entity: Entity) {
        if entity.components.has(ModelComponent.self) { entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true)) }
        for child in entity.children { addGroundingShadows(child) }
    }

    /// La luz ambiental: sale de un entorno sintético (techo y paredes en penumbra cálida, suelo que devuelve el tono de la
    /// madera) y el entorno del sistema se anula. El fondo fuera de las paredes lo pone la vista, con el color de Jack.
    private func addAmbient(_ resources: Resources) async {
        world.components.set(EnvironmentLightingConfigurationComponent(environmentLightingWeight: 0))
        if let gradient = Self.ambientImage(), let environment = try? await EnvironmentResource(equirectangular: gradient) {
            ambient = environment
            let source = Entity()
            source.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.5))
            world.addChild(source)
            world.components.set(ImageBasedLightReceiverComponent(imageBasedLight: source))
        }
        addBackdrop()
    }

    /// El fondo fuera de las paredes: una cúpula lisa del color de la barra lateral de Jack, que no recibe luz.
    private func addBackdrop() {
        var color = NSColor.black
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { color = JackPalette.chromeColor.usingColorSpace(.sRGB) ?? .black }
        var material = UnlitMaterial(color: color)
        material.faceCulling = .front
        let dome = ModelEntity(mesh: .generateSphere(radius: 450), materials: [material])
        dome.name = "backdrop"
        world.addChild(dome)
    }

    /// Un entorno equirrectangular pequeño en degradado: arriba penumbra neutra, en el horizonte algo más cálido y abajo el
    /// rebote anaranjado de la madera.
    private static func ambientImage() -> CGImage? {
        let width = 64, height = 32
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let top: SIMD3<Float> = [0.42, 0.37, 0.52]
        let horizon: SIMD3<Float> = [0.48, 0.38, 0.47]
        let bottom: SIMD3<Float> = [0.56, 0.37, 0.26]
        for y in 0..<height {
            let t = Float(y) / Float(height - 1)
            let color = t < 0.5 ? top + (horizon - top) * (t / 0.5) : horizon + (bottom - horizon) * ((t - 0.5) / 0.5)
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(min(color.x, 1) * 255)
                pixels[index + 1] = UInt8(min(color.y, 1) * 255)
                pixels[index + 2] = UInt8(min(color.z, 1) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

}

enum OfficeError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Falta \(name) en la app."
        }
    }
}
