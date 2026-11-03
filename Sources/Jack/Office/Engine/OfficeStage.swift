import ImageIO
import CoreGraphics
import Foundation
import Metal
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
    /// La mesa de ajedrez (si el archivo de la sala la trae).
    private(set) var chess: OfficeChessSet?
    /// La ducha (si el archivo de la sala la trae) y quién se está duchando.
    private(set) var shower: OfficeShower?
    /// La cafetera de la mesita, con su vapor animado (viene aparte de la sala, en `OfficeCoffee.usdz`).
    private var coffee: Entity?
    /// La mesita del café (dónde se toma y la taza) y quién se está tomando uno.
    private(set) var coffeeBar: OfficeCoffeeBar?
    @Published private(set) var drinking: Int?
    /// La pizarra de la pared (si la sala la trae) y quién está dibujando en ella.
    private(set) var whiteboard: OfficeWhiteboard?
    @Published private(set) var drawing: Int?
    @Published private(set) var showering: Int?
    /// La luz ambiental de la sala: un entorno sintético cálido, no el cielo (el HDRI solo es fondo).
    private var ambient: EnvironmentResource?
    private var pointLights: [Entity] = []
    /// La luz de lo que se mueve, sin luces en tiempo real: panorámicas HDR de la sala renderizadas en Blender con la misma luz
    /// horneada (`OfficeProbe_<zona>.exr`), cada una con el punto del suelo (x, y de Blender) desde el que se hizo.
    private var probes: [(point: SIMD2<Float>, light: EnvironmentResource)] = []
    /// Una luz por panorámica, para lo que casi no se mueve (sillas, piezas, PC): cada cosa usa la de su zona.
    private var probeLights: [Entity] = []
    /// La luz de cada personaje: la mezcla de las dos panorámicas más cercanas, que se rehace al caminar.
    private var actorLights: [(entity: Entity, pair: SIMD2<Int32>, blend: Float)] = []
    private var probeClock = 0.0
    /// Las sombras de contacto de lo que se mueve (personajes y sillas): la sala horneada no recibe luz, así que no puede
    /// recibir sombras en tiempo real; una mancha suave bajo cada uno, en el suelo, hace de sombra.
    private var contactShadows: [(shadow: Entity, owner: Entity, follows: Bool)] = []
    private var shadowsOn = true
    /// Si los PC de los escritorios tienen su animación en marcha.
    private var pcAnimating = false
    private var mirroredRoom: Entity?
    /// Los cristales de los monitores por puesto: el de la sala y el de su reflejo.
    private var screens: [String: [(entity: Entity, reflected: Bool)]] = [:]
    /// La pantalla de la tele, en la sala y en su reflejo.
    private var tvScreens: [(entity: Entity, reflected: Bool)] = []
    private var tvTexture: TextureResource?
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
            // Lo primero: el resto de ajustes de materiales (paredes, ajedrez, espejo) ya trabaja sobre la luz horneada.
            Self.applyBakedLighting(in: room)
            // El detalle nítido del suelo y el ladrillo (`applyDetail`) queda apagado: su material propio salía negro en la app.
            // Antes del espejo, para que el reflejo copie las paredes y la tele ya cambiadas.
            Self.solidWalls(in: room)
            Self.fixBackWallCorner(in: room)
            enlargePCs(in: room)
            Self.playLoop(room)
            pcAnimating = true
            await prepareWalls(in: room)
            // La mesa de ajedrez: se monta antes del espejo (para que también esté en el reflejo) y antes de que los puestos
            // aparten sus sillas (la de la mesa se copia de la del primer puesto tal como llega).
            if let chessURL = resources.url("OfficeChess", "json"), let chessLayout = try? OfficeChessLayout.load(from: chessURL), let first = layout.slots.first {
                chess = OfficeChessSet(layout: chessLayout, room: room, template: first)
                chess?.reset()
            }
            var made: [OfficeActor] = []
            for (index, slot) in layout.slots.enumerated() {
                guard let url = resources.url(slot.file, "usdz") else { throw OfficeError.missing("\(slot.file).usdz") }
                let model = try await Entity(contentsOf: url)
                let actor = OfficeActor(index: index, slot: slot, layout: layout, model: model)
                actor.attachChair(in: room)
                actor.chess = chess
                actor.walkBounds = (SIMD2(Float(layout.room.min[0]) + 0.5, -Float(layout.room.max[1]) + 0.5), SIMD2(Float(layout.room.max[0]) - 0.5, -Float(layout.room.min[1]) - 0.5))
                world.addChild(actor.holder)
                made.append(actor)
            }
            actors = made
            // Los muebles, con las sillas apartadas (que es como están cuando alguien se levanta).
            let obstacles = walkObstacles(in: room, slots: layout.slots)
            for actor in made { actor.walkObstacles = obstacles }
            shower = OfficeShower(room: room, world: world)
            for actor in made { actor.shower = shower }
            await addCoffee(resources, room: room)
            await addWhiteboard(layout)
            await addLights(resources)
            addGroundingShadows(room)
            for actor in made { addGroundingShadows(actor.holder) }
            if let mirror = layout.mirror { addMirror(mirror, room: room) }
            if let mirroredRoom { chess?.attachMirror(mirroredRoom) }
            if let mirroredRoom { shower?.attachMirror(mirroredRoom) }
            if let coffee, let reflected = mirroredRoom?.parent { mirrorCoffee(coffee, in: reflected) }
            if let reflected = mirroredRoom?.parent { whiteboard?.attachMirror(in: reflected) }
            // Después del espejo: su copia de la sala no debe heredar luces de este mundo.
            assignProbes(room: room, layout: layout)
            addContactShadows(room: room, layout: layout)
            collectScreens(layout: layout, room: room)
            collectTV(room: room)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// El suelo que ocupan los muebles grandes (x, z de RealityKit), para que los personajes los rodeen al caminar.
    private func walkObstacles(in room: Entity, slots: [OfficeLayout.Slot]) -> [OfficeChessRoute.Obstacle] {
        var rects: [OfficeChessRoute.Obstacle] = []
        for name in ["WORKSTATION_01", "WORKSTATION_02", "WORKSTATION_03", "PROP_sofa", "PROP_sofa_big", "CHESS_table_top", "PROP_shower", "PROP_coffee_table", "PROP_floor_lamp",
                     "PROP_meeting_table", "PROP_server_rack", "PROP_plant_big", "PROP_plant_big_2", "PROP_chalkboard"]
            + (1...6).map({ "PROP_meeting_chair_\($0)" }) {
            guard let entity = room.findEntity(named: name) else { continue }
            let bounds = entity.visualBounds(relativeTo: nil)
            guard !bounds.isEmpty else { continue }
            rects.append(((SIMD2(bounds.min.x, bounds.min.z), SIMD2(bounds.max.x, bounds.max.z)), false))
        }
        // Las sillas de los escritorios, ya apartadas.
        for slot in slots {
            guard let chair = room.findEntity(named: slot.chair) else { continue }
            let bounds = chair.visualBounds(relativeTo: nil)
            if !bounds.isEmpty { rects.append(((SIMD2(bounds.min.x, bounds.min.z), SIMD2(bounds.max.x, bounds.max.z)), true)) }
        }
        // Las sillas de la mesa de ajedrez, donde quedan al apartarlas para sentarse.
        rects += (chess?.pulledChairFootprints() ?? []).map { ($0, true) }
        return rects
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

    /// Manda a ducharse al personaje de un puesto (si la ducha está libre). Vuelve solo a su sofá al terminar.
    func startShower(slot index: Int) {
        guard shower != nil, showering == nil, actors.indices.contains(index) else { return }
        showering = index
        actors[index].onShowerDone = { [weak self] in
            if self?.showering == index { self?.showering = nil }
        }
    }

    // MARK: - Cafetera

    /// Pone la cafetera en su marcador de la mesita y deja su vapor subiendo en bucle.
    private func addCoffee(_ resources: Resources, room: Entity) async {
        guard let url = resources.url("OfficeCoffee", "usdz"), let spot = room.findEntity(named: "PROP_coffee_spot"),
              let model = try? await Entity(contentsOf: url) else { return }
        model.name = "office-coffee"
        model.position = spot.position(relativeTo: nil)
        Self.softenSteam(model)
        world.addChild(model)
        Self.playLoop(model)
        coffee = model
        coffeeBar = OfficeCoffeeBar(coffee: model, room: room, world: world)
        for actor in actors { actor.coffee = coffeeBar }
    }

    /// Su gemela en la sala del espejo, con el mismo vapor.
    private func mirrorCoffee(_ coffee: Entity, in reflected: Entity) {
        let copy = coffee.clone(recursive: true)
        Self.flipCulling(copy)
        reflected.addChild(copy)
        Self.playLoop(copy)
        coffeeBar?.attachMirror(copy, in: reflected)
    }

    private static func playLoop(_ entity: Entity) {
        for animation in entity.availableAnimations {
            entity.playAnimation(animation.repeat(duration: .infinity))
        }
    }

    /// El vapor llega opaco (el exportador USD solo guarda la transparencia que viene de una textura): blanco y casi transparente.
    private static func softenSteam(_ entity: Entity, inSteam: Bool = false) {
        let steam = inSteam || entity.name.hasPrefix("COFFEE_steam")
        if steam, var model = entity.components[ModelComponent.self] {
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.3))
            material.faceCulling = .none
            model.materials = Array(repeating: material, count: max(model.materials.count, 1))
            entity.components.set(model)
        }
        for child in entity.children { softenSteam(child, inSteam: steam) }
    }

    /// Manda al personaje de un puesto a tomarse un café (si la mesita está libre). Vuelve solo a su sofá al terminar.
    func startCoffee(slot index: Int) {
        guard coffeeBar != nil, drinking == nil, actors.indices.contains(index) else { return }
        drinking = index
        actors[index].onCoffeeDone = { [weak self] in
            if self?.drinking == index { self?.drinking = nil }
        }
    }

    // MARK: - Pizarra

    /// Cuelga la pizarra de la pared (con las medidas que dejó Blender en el archivo de la sala).
    private func addWhiteboard(_ layout: OfficeLayout) async {
        guard let spec = layout.whiteboard else { return }
        let board = OfficeWhiteboard(layout: spec, world: world)
        await board.prepare()
        whiteboard = board
        for actor in actors { actor.board = board }
    }

    /// Manda al personaje de un puesto a dibujar en la pizarra (si está libre). Se queda dibujando hasta `releaseDrawer()` y
    /// después vuelve solo a su sofá.
    func startDrawing(slot index: Int) {
        guard whiteboard != nil, drawing == nil, actors.indices.contains(index) else { return }
        drawing = index
        actors[index].onDrawDone = { [weak self] in
            if self?.drawing == index { self?.drawing = nil }
        }
    }

    /// Ya está ante la pizarra, con el rotulador en la mano.
    func isDrawing(slot index: Int) -> Bool { actors[safe: index]?.isDrawing == true }

    /// Que baje el rotulador y vuelva al sofá.
    func releaseDrawer() {
        guard let drawing, actors.indices.contains(drawing) else { return }
        actors[drawing].drawingActive = false
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
        if pcAnimating { Self.playLoop(copy) }
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
        glass.baseColor = .init(tint: PlatformColor(red: 0.02, green: 0.025, blue: 0.045, alpha: 1))
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
                    if var unlit = material as? UnlitMaterial { unlit.faceCulling = .back; return unlit }
                    if var custom = material as? CustomMaterial { custom.faceCulling = .back; return custom }
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

    /// La luz horneada con trazado de rayos en Blender (scripts/office_bake_lighting.py): lo horneado llega negro, mate y con
    /// su atlas de luz como emisión. Se dibuja tal cual, sin luces ni tono encima, para que se vea igual que el render; las
    /// luces de la escena quedan para lo que se mueve (personajes, sillas, piezas).
    private static func applyBakedLighting(in room: Entity) {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        func isBaked(_ pbr: PhysicallyBasedMaterial) -> Bool {
            guard pbr.emissiveColor.texture != nil, pbr.baseColor.texture == nil, pbr.roughness.scale > 0.99, pbr.metallic.scale < 0.01 else { return false }
            let base = pbr.baseColor.tint.srgbComponents
            return max(base.red, base.green, base.blue) < 0.01
        }
        for entity in models(under: room) {
            guard var model = entity.components[ModelComponent.self] else { continue }
            var baked = false
            model.materials = model.materials.map { material in
                guard let pbr = material as? PhysicallyBasedMaterial, isBaked(pbr), let atlas = pbr.emissiveColor.texture else { return material }
                baked = true
                var unlit = UnlitMaterial(applyPostProcessToneMap: false)
                unlit.color = .init(tint: .white, texture: atlas)
                return unlit
            }
            if baked { entity.components.set(model) }
        }
    }

    /// El suelo y el ladrillo, nítidos de cerca (ver OfficeDetail.metal): el atlas horneado, por el detalle de su textura original
    /// a resolución completa. Las superficies, la textura y su proyección vienen en `OfficeDetail.json` (lo escribe Blender al
    /// hornear) y el color sin luz del atlas en `OfficeBake_room_albedo.jpg`. Si falta algo, se quedan como las deja
    /// `applyBakedLighting`.
    private func applyDetail(in room: Entity, resources: Resources) async {
        struct Surface: Decodable { let texture: String; let scale: Float; let u: Int; let v: Int }
        guard let url = resources.url("OfficeDetail", "json"), let data = try? Data(contentsOf: url),
              let surfaces = try? JSONDecoder().decode([String: Surface].self, from: data),
              let library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary(),
              let albedoURL = resources.url("OfficeBake_room_albedo", "jpg") else { return }
        let options = TextureResource.CreateOptions(semantic: .color, mipmapsMode: .allocateAndGenerateAll)
        guard let albedo = try? await TextureResource(contentsOf: albedoURL, options: options) else { return }
        let shader = CustomMaterial.SurfaceShader(named: "officeDetail", in: library)
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        for (name, surface) in surfaces {
            let base = (surface.texture as NSString).deletingPathExtension, ext = (surface.texture as NSString).pathExtension
            guard let entity = room.findEntity(named: name), let file = resources.url(base, ext),
                  let detail = try? await TextureResource(contentsOf: file, options: options) else { continue }
            for model in models(under: entity) {
                guard var component = model.components[ModelComponent.self] else { continue }
                component.materials = component.materials.map { current in
                    guard let baked = current as? UnlitMaterial, let atlas = baked.color.texture,
                          var material = try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit) else { return current }
                    material.baseColor = .init(tint: .white, texture: .init(atlas.resource))
                    material.emissiveColor = .init(color: .white, texture: .init(albedo))
                    material.custom = .init(value: SIMD4(surface.scale, Float(surface.u), Float(surface.v), 0), texture: .init(detail))
                    material.faceCulling = baked.faceCulling
                    return material
                }
                model.components.set(component)
            }
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
                if var custom = material as? CustomMaterial { custom.faceCulling = .none; return custom }
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
                if var custom = material as? CustomMaterial { custom.faceCulling = .front; return custom }
                return material
            }
            entity.components.set(model)
        }
        for child in entity.children { flipCulling(child) }
    }

    // MARK: - Tele

    /// Los PC de los escritorios, un poco más grandes, sin separarse de la mesa: crecen desde el centro de su base.
    private func enlargePCs(in room: Entity) {
        for name in ["PROP_pc_gamer_animation", "PROP_pc_gamer_animation_03"] {
            guard let pc = room.findEntity(named: name) else { continue }
            let before = pc.visualBounds(relativeTo: pc.parent)
            pc.scale *= Self.pcScale
            let after = pc.visualBounds(relativeTo: pc.parent)
            pc.position += SIMD3(before.center.x - after.center.x, before.min.y - after.min.y, before.center.z - after.center.z)
        }
    }

    /// Cuánto crecen los PC respecto al modelo.
    private static let pcScale: Float = 1.15

    private func collectTV(room: Entity) {
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        if let screen = room.findEntity(named: "TV_49Zoll_Screen1_0") { tvScreens += models(under: screen).map { ($0, false) } }
        if let screen = mirroredRoom?.findEntity(named: "TV_49Zoll_Screen1_0") { tvScreens += models(under: screen).map { ($0, true) } }
    }

    /// Lo que enseña la tele. La primera imagen crea su textura; las siguientes la sustituyen sin tocar los materiales,
    /// para que el logo animado pueda ir a varios fotogramas por segundo.
    func setTV(image: CGImage) async {
        guard !tvScreens.isEmpty else { return }
        let options = TextureResource.CreateOptions(semantic: .color)
        if let tvTexture {
            try? tvTexture.replace(withImage: image, options: options)
            return
        }
        guard let texture = try? await TextureResource(image: image, options: options) else { return }
        tvTexture = texture
        for (entity, reflected) in tvScreens {
            guard var model = entity.components[ModelComponent.self] else { continue }
            var material = UnlitMaterial(color: .white)
            material.color = .init(tint: .white, texture: .init(texture))
            if reflected { material.faceCulling = .front }
            model.materials = Array(repeating: material, count: max(model.materials.count, 1))
            entity.components.set(model)
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
                var material = UnlitMaterial(color: PlatformColor(white: 0.012, alpha: 1))
                if let texture { material.color = .init(tint: .white, texture: .init(texture)) }
                // En el reflejo se invierte el orden de los vértices (ver `flipCulling`).
                if reflected { material.faceCulling = .front }
                model.materials = Array(repeating: material, count: max(model.materials.count, 1))
                entity.components.set(model)
            }
        }
    }

    /// Si algo de la sala se mueve (alguien camina, se ducha o toma café, juega al ajedrez o se abre la puerta de la ducha);
    /// con todos sentados y nada en marcha, la escena puede dibujarse a menos fotogramas por segundo.
    var isBusy: Bool {
        actors.contains { $0.isActive } || chess?.isBusy == true || shower?.isBusy == true
    }

    func update(deltaTime: Double) {
        for actor in actors { actor.update(deltaTime: min(deltaTime, 0.1)) }
        chess?.update(deltaTime: min(deltaTime, 0.1))
        shower?.update(deltaTime: min(deltaTime, 0.1))
        // La luz y la sombra de lo que se mueve siguen a cada uno diez veces por segundo: de sobra para el paso al que caminan.
        probeClock += deltaTime
        if probeClock >= 0.1 {
            probeClock = 0
            updateActorLights()
            updateContactShadows()
        }
    }

    // MARK: - Gráficos

    /// Las entidades con sombra de contacto, recogidas la primera vez para poder quitarlas y volver a ponerlas.
    private var groundedEntities: [Entity] = []
    private var logos: Entity?
    private var appliedQuality: OfficeQuality?

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
        shadowsOn = quality.shadows
        updateContactShadows()
        // La sala trae su luz horneada y lo que se mueve la toma de las panorámicas: no hay focos que encender ni apagar. Solo
        // la ambiental sintética (el reflejo, o la sala si faltan las panorámicas) sube en la iluminación simple.
        let simple = quality.lights == 1
        for entity in entities where !entity.name.hasPrefix("office-probe") {
            guard let ambient = entity.components[ImageBasedLightComponent.self] else { continue }
            let inMirror = entity.parent?.parent === world
            let exponent: Float = simple ? (inMirror ? 2.2 : 1.8) : (inMirror ? 0.8 : 0.5)
            entity.components.set(ImageBasedLightComponent(source: ambient.source, intensityExponent: exponent))
        }
        if logos == nil { logos = room?.findEntity(named: "PROP_lang_logos") }
        if #available(macOS 27.0, iOS 27.0, *), let logos {
            if quality.neon { logos.components.set(BloomComponent(scope: .hierarchical)) } else { logos.components.remove(BloomComponent.self) }
        }
        // El espejo: sin él no se dibuja la sala reflejada y el cristal pasa a ser un panel oscuro.
        mirrorOn = quality.mirror
        refreshMirror()
        applyMirrorDetail(light: quality.mirror && quality.mirrorLight)
        if let glass = world.findEntity(named: "mirror-glass") as? ModelEntity, var model = glass.model {
            model.materials = model.materials.map { material in
                guard var pbr = material as? PhysicallyBasedMaterial else { return material }
                pbr.blending = .transparent(opacity: quality.mirror ? 0.12 : 0.92)
                return pbr
            }
            glass.model = model
        }
        for actor in actors { actor.freezeIdle = !quality.idleAnimation }
        setPCAnimation(quality.idleAnimation)
    }

    /// Los PC de la sala (y los de su reflejo) se animan igual que los personajes en reposo: con la calidad baja se quedan quietos.
    private func setPCAnimation(_ on: Bool) {
        guard on != pcAnimating, let room else { return }
        pcAnimating = on
        for entity in [room, mirroredRoom].compactMap({ $0 }) {
            if on { Self.playLoop(entity) } else { entity.stopAllAnimations() }
        }
    }

    // MARK: - Espejo

    /// El espejo está encendido en los gráficos, y la cámara lo tiene (o puede tenerlo) a la vista.
    private var mirrorOn = true
    private var mirrorInView = true
    /// Los muebles pequeños de la sala reflejada, que el reflejo ligero no dibuja (se buscan la primera vez que hacen falta).
    private var mirrorSmallProps: [Entity]?
    /// Lo que mide, como mucho, un objeto que el reflejo ligero se salta (en unidades de la escena; un personaje mide unas 6).
    private static let mirrorSmallSize: Float = 1.0

    /// Las cuatro esquinas del cristal del espejo y hacia dónde mira, para saber si la cámara lo ve.
    var mirrorGlass: (corners: [SIMD3<Float>], normal: SIMD3<Float>)? {
        guard let mirror = layout?.mirror else { return nil }
        let center = OfficePose.world(x: mirror.center[0], y: mirror.center[1], z: mirror.center[2])
        let half = SIMD3<Float>(0, Float(mirror.height) / 2, Float(mirror.width) / 2)
        return ([SIMD3(1, 1, 1), SIMD3(1, 1, -1), SIMD3(1, -1, 1), SIMD3(1, -1, -1)].map { center + $0 * half }, SIMD3(1, 0, 0))
    }

    /// Con la cámara de espaldas al espejo o mirando a otro lado, no se dibuja la sala reflejada (no se ve).
    func setMirrorInView(_ visible: Bool) {
        guard visible != mirrorInView else { return }
        mirrorInView = visible
        refreshMirror()
    }

    private func refreshMirror() {
        let enabled = mirrorOn && mirrorInView
        world.children.first { $0.name == "mirror-world" }?.isEnabled = enabled
        world.findEntity(named: "mirror-portal")?.isEnabled = enabled
    }

    /// El reflejo ligero: sin sombras de contacto ni de los focos, sin los halos y el rebote del suelo (solo los rellenos) y sin
    /// los muebles pequeños, que en un espejo apenas se aprecian. Con `light: false` el reflejo queda completo.
    private func applyMirrorDetail(light: Bool) {
        guard let reflected = mirroredRoom?.parent else { return }
        func all(_ entity: Entity) -> [Entity] { [entity] + entity.children.flatMap(all) }
        let entities = all(reflected)
        if light {
            for entity in entities {
                if entity.components.has(GroundingShadowComponent.self) { entity.components.remove(GroundingShadowComponent.self) }
                if entity.components.has(SpotLightComponent.Shadow.self) { entity.components.remove(SpotLightComponent.Shadow.self) }
                if let point = entity.components[PointLightComponent.self], point.attenuationRadius < 40 { entity.isEnabled = false }
            }
        }
        if mirrorSmallProps == nil, light, let room = mirroredRoom {
            mirrorSmallProps = all(room).filter { entity in
                guard entity.components.has(ModelComponent.self) else { return false }
                let bounds = entity.visualBounds(relativeTo: nil)
                return !bounds.isEmpty && max(bounds.extents.x, bounds.extents.y, bounds.extents.z) < Self.mirrorSmallSize
            }
        }
        for entity in mirrorSmallProps ?? [] { entity.isEnabled = !light }
    }

    // MARK: - Luces

    /// La sala ya trae su luz horneada en Blender, y lo que se mueve la toma de las panorámicas (`assignProbes`): no hay luces
    /// en tiempo real. Aquí quedan los logos de neón y la luz ambiental.
    private func addLights(_ resources: Resources) async {
        addNeonLogos()
        await addAmbient(resources)
    }

    /// Los logos de lenguajes de la pared, en neón: cada color de su paleta brilla un poco por sí mismo, y el halo de color
    /// de detrás de cada uno ya viene horneado en la pared.
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
                // Suave, para que el logo se lea nítido: el neón fuerte es el halo de detrás.
                pbr.emissiveIntensity = 0.25
                return pbr
            }
            entity.components.set(model)
        }
        if #available(macOS 27.0, iOS 27.0, *) { logos.components.set(BloomComponent(scope: .hierarchical)) }
    }

    // MARK: - Luz y sombra de lo que se mueve

    /// Las panorámicas de `scripts/office_bake_probes.py`, con el punto del suelo (x, y de Blender) desde el que se hizo cada una.
    private static let probeZones: [(name: String, point: SIMD2<Float>)] = [
        ("pcs", SIMD2(3.3, -1.5)), ("meeting", SIMD2(8.0, -14.0)), ("mac", SIMD2(1.5, -9.0)), ("lounge", SIMD2(-1.0, -0.5)),
        ("sofa", SIMD2(6.0, -17.5)), ("chess", SIMD2(18.8, -15.0)), ("rack", SIMD2(18.0, 0.0)),
    ]
    /// La intensidad de las panorámicas: su luz viene en las unidades de Blender, y así queda a la par de la sala horneada.
    private static let probeExponent: Float = 0.0

    private func loadProbes(_ resources: Resources) async {
        for zone in Self.probeZones {
            guard let url = resources.url("OfficeProbe_\(zone.name)", "exr"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let light = try? await EnvironmentResource(equirectangular: image, withName: "office-probe-\(zone.name)") else { continue }
            probes.append((zone.point, light))
        }
    }

    /// El punto del suelo, en x, y de Blender, donde está una posición de la escena.
    private static func floorPoint(_ position: SIMD3<Float>) -> SIMD2<Float> { SIMD2(position.x, -position.z) }

    private func nearestProbes(to point: SIMD2<Float>) -> (Int, Int, Float) {
        let ranked = probes.indices.sorted { simd_distance(probes[$0].point, point) < simd_distance(probes[$1].point, point) }
        guard ranked.count > 1 else { return (ranked[0], ranked[0], 0) }
        let near = simd_distance(probes[ranked[0]].point, point), far = simd_distance(probes[ranked[1]].point, point)
        return (ranked[0], ranked[1], near + far > 0 ? near / (near + far) : 0)
    }

    /// Cada cosa que no está horneada (sillas, piezas, PC, cafetera, pizarra) toma la panorámica de su zona; cada personaje,
    /// una luz propia que mezcla las dos más cercanas y se rehace al caminar (`updateActorLights`).
    private func assignProbes(room: Entity, layout: OfficeLayout) {
        guard !probes.isEmpty else { return }
        probeLights = probes.enumerated().map { index, probe in
            let entity = Entity()
            entity.name = "office-probe-\(index)"
            entity.components.set(ImageBasedLightComponent(source: .single(probe.light), intensityExponent: Self.probeExponent))
            world.addChild(entity)
            return entity
        }
        func models(under entity: Entity) -> [Entity] {
            (entity.components.has(ModelComponent.self) ? [entity] : []) + entity.children.flatMap(models(under:))
        }
        var lit = models(under: room)
        if let coffee { lit += models(under: coffee) }
        for entity in lit {
            guard let materials = entity.components[ModelComponent.self]?.materials, materials.contains(where: { $0 is PhysicallyBasedMaterial }) else { continue }
            let (nearest, _, _) = nearestProbes(to: Self.floorPoint(entity.visualBounds(relativeTo: nil).center))
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: probeLights[nearest]))
        }
        actorLights = actors.map { actor in
            let entity = Entity()
            entity.name = "office-probe-actor"
            world.addChild(entity)
            actor.holder.components.set(ImageBasedLightReceiverComponent(imageBasedLight: entity))
            return (entity, SIMD2(-1, -1), 0)
        }
        updateActorLights()
    }

    private func updateActorLights() {
        guard !probes.isEmpty else { return }
        for (index, actor) in actors.enumerated() where index < actorLights.count {
            let (near, far, blend) = nearestProbes(to: Self.floorPoint(actor.holder.position(relativeTo: nil)))
            let pair = SIMD2(Int32(near), Int32(far))
            if actorLights[index].pair == pair && abs(actorLights[index].blend - blend) < 0.03 { continue }
            actorLights[index].pair = pair
            actorLights[index].blend = blend
            let source: ImageBasedLightComponent.Source = near == far ? .single(probes[near].light) : .blend(probes[near].light, probes[far].light, blend)
            actorLights[index].entity.components.set(ImageBasedLightComponent(source: source, intensityExponent: Self.probeExponent))
        }
    }

    /// Una mancha suave y oscura en el suelo bajo cada personaje y cada silla: su sombra de contacto.
    private func addContactShadows(room: Entity, layout: OfficeLayout) {
        guard let image = Self.contactShadowImage(),
              let texture = try? TextureResource(image: image, options: .init(semantic: .raw)) else { return }
        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: .init(scale: 0.6, texture: .init(texture)))
        func shadow(width: Float) -> Entity {
            let entity = ModelEntity(mesh: .generatePlane(width: width, depth: width), materials: [material])
            entity.name = "contact-shadow"
            world.addChild(entity)
            return entity
        }
        for actor in actors { contactShadows.append((shadow(width: 2.6), actor.holder, true)) }
        let chairs = layout.slots.map(\.chair) + ["CHESS_chair_white", "CHESS_chair_black"]
        for name in chairs {
            guard let chair = room.findEntity(named: name) else { continue }
            contactShadows.append((shadow(width: 2.4), chair, false))
        }
        updateContactShadows()
    }

    private func updateContactShadows() {
        for (shadow, owner, follows) in contactShadows {
            shadow.isEnabled = shadowsOn && owner.isEnabledInHierarchy
            guard shadow.isEnabled else { continue }
            // Los personajes, por su posición; las sillas, por el centro de lo que ocupan (giran y se apartan).
            let center = follows ? owner.position(relativeTo: nil) : owner.visualBounds(relativeTo: nil).center
            shadow.position = SIMD3(center.x, 0.015, center.z)
        }
    }

    /// Un degradado radial: opaco en el centro y transparente en el borde (en el canal rojo, que es el que usa la opacidad).
    private static func contactShadowImage() -> CGImage? {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) + 0.5) / Float(size) * 2 - 1, dy = (Float(y) + 0.5) / Float(size) * 2 - 1
                let t = max(0, 1 - sqrt(dx * dx + dy * dy))
                let value = UInt8(min(1, t * t * (3 - 2 * t)) * 255)
                let index = (y * size + x) * 4
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value; pixels[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
        await loadProbes(resources)
        addBackdrop()
    }

    /// El color del fondo fuera de las paredes; quien muestra la oficina pone el suyo (en la Mac, el de la barra lateral de Jack).
    static var backdropColor: PlatformColor = .black

    /// El fondo fuera de las paredes: una cúpula lisa de `backdropColor`, que no recibe luz.
    private func addBackdrop() {
        var material = UnlitMaterial(color: Self.backdropColor)
        material.faceCulling = .front
        let dome = ModelEntity(mesh: .generateSphere(radius: 450), materials: [material])
        dome.name = "backdrop"
        world.addChild(dome)
    }

    /// Un entorno equirrectangular pequeño en degradado: arriba la penumbra fría de los paneles de oficina, en el horizonte algo
    /// del rojo de los PC y abajo el rebote del roble del suelo.
    private static func ambientImage() -> CGImage? {
        let width = 64, height = 32
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let top: SIMD3<Float> = [0.36, 0.39, 0.45]
        let horizon: SIMD3<Float> = [0.42, 0.36, 0.37]
        let bottom: SIMD3<Float> = [0.44, 0.32, 0.23]
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
