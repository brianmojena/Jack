import Foundation
import JackCore
import RealityKit
import simd

/// Lo que se le pide a un personaje de la oficina.
enum OfficeCommand: Equatable {
    /// No se ve: no hay ningún agente en este puesto.
    case hidden
    /// En su sofá. Con `failed`, hace el gesto de «no» (límite de sesión o error).
    case sofa(failed: Bool)
    /// En su escritorio tecleando. Con `waiting`, teclea despacio mientras espera una respuesta.
    case desk(waiting: Bool)
    /// Sentado a la mesa de ajedrez, en el asiento indicado.
    case chess(OfficeChessSeat)
    /// A ducharse, como en Los Sims; al terminar vuelve a su sofá (`OfficeActor.onShowerDone`).
    case shower
}

/// Qué hace un jugador sentado a la mesa de ajedrez.
enum OfficeChessMood: Equatable {
    case waiting, thinking, moving, won, lost

    var clip: String {
        switch self {
        case .waiting: "chess_idle"
        case .thinking: "chess_think"
        case .moving: "chess_move"
        case .won: "chess_win"
        case .lost: "chess_lose"
        }
    }
}

/// Un personaje de la oficina: un esqueleto de Mixamo con todos sus clips en una sola línea de tiempo,
/// que se recorta por clip, y los recorridos calculados en Blender para ir del sofá al escritorio y volver.
@MainActor final class OfficeActor {
    private enum Phase { case sofa, toDesk, desk, toSofa, toChess, chess, fromChess, toShower, showering, fromShower }

    let index: Int
    let slot: OfficeLayout.Slot
    /// Raíz del personaje en la escena; es lo que se mueve y se pulsa.
    let holder = Entity()
    private var model: Entity
    private let layout: OfficeLayout
    private var timeline: AnimationResource?
    private var resources: [String: AnimationResource] = [:]
    private var controller: AnimationPlaybackController?
    private var playing: String?
    private weak var chair: Entity?
    /// El reflejo del personaje en el espejo: otra copia de su modelo, que repite lo que él hace.
    private(set) var mirrorHolder: Entity?
    private var mirrorModel: Entity?
    private var mirrorController: AnimationPlaybackController?
    private weak var mirrorChair: Entity?
    private var chairBase = SIMD3<Float>.zero
    private let chairDirection: SIMD3<Float>

    private var phase = Phase.sofa
    private var frame = 0.0
    private let toDesk: [OfficePose]
    private let toSofa: [OfficePose]
    private let sofaPose: OfficePose
    private let deskPose: OfficePose
    private let pulledChair: Float

    /// Mientras charla en el sofá, el clip de hablar que le toca: `talk_right` si tiene al compañero a su derecha, `talk_left` si a
    /// su izquierda. Sin charla, `nil`.
    var talkClip: String?

    /// El suelo que ocupan los muebles (x, z de RealityKit) y los límites de la sala, para que al caminar los rodee.
    var walkObstacles: [OfficeChessRoute.Obstacle] = []
    var walkBounds: OfficeChessRoute.Rect?
    /// Los recorridos al escritorio y de vuelta, con el camino calculado entre los muebles (si no, los de Blender).
    private var deskRoutes: (toDesk: OfficeRoutePath, toSofa: OfficeRoutePath)?

    /// La mesa de ajedrez, si la sala la tiene.
    var chess: OfficeChessSet?
    /// Los recorridos del sofá a la mesa y de vuelta, calculados al sentarse.
    private var chessRoute: (toSeat: OfficeRoutePath, toSofa: OfficeRoutePath, seat: OfficeChessSeat)?
    /// Lo que hace sentado a la mesa: pensar, mover, celebrar…
    var chessMood = OfficeChessMood.waiting {
        didSet { if chessMood != oldValue { moodTime = 0 } }
    }
    private var moodTime = 0.0
    /// Ya está sentado a la mesa y listo para jugar.
    var isSeatedAtChess: Bool { phase == .chess }
    /// Ha vuelto a su sofá (o nunca salió de él).
    var isOnSofa: Bool { phase == .sofa }

    /// La ducha de la sala, si la tiene.
    var shower: OfficeShower?
    /// Se llama al volver de la ducha al sofá (o si no se pudo ir).
    var onShowerDone: (() -> Void)?
    private var showerRoute: (toShower: OfficeRoutePath, openAt: Int, toSofa: OfficeRoutePath, closeAt: Int)?
    private var showerTime = 0.0
    private var mosaic: (real: Entity, reflected: Entity?)?

    /// Con `true` el personaje y su silla se desvanecen, para que no tapen su pantalla cuando la cámara se pone delante.
    var concealed = false
    private var opacity: Float = 1

    var command = OfficeCommand.sofa(failed: false) {
        didSet { if command != oldValue { holder.isEnabled = command != .hidden && opacity > 0; mirrorHolder?.isEnabled = command != .hidden } }
    }

    init(index: Int, slot: OfficeLayout.Slot, layout: OfficeLayout, model: Entity) {
        self.index = index
        self.slot = slot
        self.layout = layout
        self.model = model
        // La línea de tiempo larga es la animación más larga del archivo.
        timeline = model.availableAnimations.max { $0.definition.duration < $1.definition.duration }
        toDesk = slot.toDesk.poses
        toSofa = slot.toSofa.poses
        sofaPose = OfficePose(slot.sofa)
        deskPose = OfficePose(slot.atDesk)
        pulledChair = OfficePose(slot.toDesk.root[0]).chairOffset
        // La dirección de la silla viene en ejes de Blender y se aplica en el espacio local de su puesto.
        chairDirection = SIMD3(Float(slot.chairDir[0]), Float(slot.chairDir[1]), 0)
        holder.name = "agent-\(slot.id)"
        holder.addChild(model)
        apply(sofaPose)
        holder.components.set(OfficeAgentTag(index: index, kind: .agent))
        holder.components.set(CollisionComponent(shapes: [.generateBox(size: [2.4, 5.8, 2.4]).offsetBy(translation: [0, 2.9, 0])]))
        holder.components.set(InputTargetComponent())
    }

    /// La silla que este personaje mueve al sentarse y levantarse, ya dentro de la escena.
    /// Su puesto de trabajo (el padre de la silla) pasa a ser pulsable.
    func attachChair(in room: Entity) {
        guard let found = room.findEntity(named: slot.chair) else { return }
        chair = found
        chairBase = found.position
        setChair(offset: pulledChair)
        if let workstation = found.parent {
            let bounds = workstation.visualBounds(relativeTo: workstation)
            workstation.components.set(OfficeAgentTag(index: index, kind: .desk))
            workstation.components.set(CollisionComponent(shapes: [.generateBox(size: bounds.extents).offsetBy(translation: bounds.center)]))
            workstation.components.set(InputTargetComponent())
        }
    }

    /// Cambia el modelo del personaje por otro (otro avatar) sin moverlo: se queda en su postura y sigue con lo que hacía.
    /// El reflejo del espejo, si lo hay, cambia con él.
    func replaceModel(with newModel: Entity) {
        model.removeFromParent()
        holder.addChild(newModel)
        model = newModel
        timeline = newModel.availableAnimations.max { $0.definition.duration < $1.definition.duration }
        // Los clips y reproductores eran del modelo anterior: se vuelven a crear con el siguiente fotograma.
        resources = [:]
        controller = nil
        mirrorController = nil
        playing = nil
        frozen = false
        idleTime = 0
        if let reflection = mirrorHolder {
            mirrorModel?.removeFromParent()
            let copy = newModel.clone(recursive: true)
            reflection.addChild(copy)
            mirrorModel = copy
        }
        // Si el personaje estaba desvanecido (su pantalla de cerca), el nuevo también.
        if opacity < 1 {
            func dim(_ entity: Entity) {
                entity.components.set(OpacityComponent(opacity: opacity))
                entity.children.forEach(dim)
            }
            dim(newModel)
        }
    }

    /// Crea el reflejo del personaje dentro del mundo del espejo, con su silla.
    func attachMirror(in mirrorWorld: Entity, room mirroredRoom: Entity) {
        let copy = model.clone(recursive: true)
        let reflection = Entity()
        reflection.addChild(copy)
        reflection.position = holder.position
        reflection.orientation = holder.orientation
        mirrorWorld.addChild(reflection)
        mirrorHolder = reflection
        mirrorModel = copy
        mirrorChair = mirroredRoom.findEntity(named: slot.chair)
    }

    /// Dónde está el personaje (para anclar el menú que se abre sobre él).
    /// El pecho del personaje: de ahí salen las acciones, como en Los Sims.
    var chestPosition: SIMD3<Float> { holder.position(relativeTo: nil) + SIMD3(0, 3.6, 0) }
    var headPosition: SIMD3<Float> { holder.position(relativeTo: nil) + SIMD3(0, 6.2, 0) }

    // MARK: - Reproducción

    func update(deltaTime: Double) {
        fade(deltaTime)
        guard command != .hidden else { return }
        switch phase {
        case .sofa:
            apply(sofaPose)
            setChair(offset: pulledChair)
            if case .sofa(let failed) = command {
                play(failed ? "no" : (talkClip ?? "idle_sit"))
                updateFreeze(shouldFreeze: freezeIdle && !failed && talkClip == nil, deltaTime: deltaTime)
            }
            if case .desk = command { prepareDeskRoutes(); begin(.toDesk) }
            if case .chess(let seat) = command, startChess(seat) { begin(.toChess) }
            if case .shower = command {
                if startShower() { begin(.toShower) } else { onShowerDone?() }
            }
        case .toDesk:
            if advance(clips: deskRoutes?.toDesk.clips ?? slot.toDesk.clips, poses: deskRoutes?.toDesk.poses ?? toDesk, deltaTime: deltaTime) { phase = .desk }
        case .desk:
            apply(deskPose)
            setChair(offset: deskPose.chairOffset)
            if case .desk(let waiting) = command {
                play("type", speed: waiting ? 0.25 : 1)
            } else {
                prepareDeskRoutes()
                begin(.toSofa)
            }
        case .toSofa:
            if advance(clips: deskRoutes?.toSofa.clips ?? slot.toSofa.clips, poses: deskRoutes?.toSofa.poses ?? toSofa, deltaTime: deltaTime) { phase = .sofa }
        case .toChess:
            guard let route = chessRoute else { phase = .sofa; break }
            if advance(clips: route.toSeat.clips, poses: route.toSeat.poses, deltaTime: deltaTime) { phase = .chess }
        case .chess:
            guard let route = chessRoute, let last = route.toSeat.poses.last else { begin(.sofa); break }
            apply(last)
            if case .chess = command {
                let clip = chessMood.clip
                play(clip)
                moodTime += deltaTime
                // Lo que se hace una vez (mover, celebrar) acaba en la postura de espera.
                if let info = layout.clips[clip], !info.loop, moodTime > info.duration + 0.05 { chessMood = .waiting }
            } else {
                chessMood = .waiting
                begin(.fromChess)
            }
        case .fromChess:
            guard let route = chessRoute else { phase = .sofa; break }
            if advance(clips: route.toSofa.clips, poses: route.toSofa.poses, deltaTime: deltaTime) { phase = .sofa }
        case .toShower:
            guard let route = showerRoute, let shower else { finishShower(); break }
            let before = frame
            let arrived = advance(clips: route.toShower.clips, poses: route.toShower.poses, deltaTime: deltaTime)
            if before < Double(route.openAt), frame >= Double(route.openAt) { shower.openDoor() }
            if arrived {
                // Dentro: se cierra la puerta, cae el agua y el mosaico lo tapa todo menos la cabeza.
                shower.closeDoor()
                shower.setWater(true)
                setMosaic(true)
                showerTime = 0
                phase = .showering
            }
        case .showering:
            guard let shower else { finishShower(); break }
            apply(shower.inside)
            play("stand_idle")
            showerTime += deltaTime
            if showerTime > OfficeShower.duration {
                shower.setWater(false)
                setMosaic(false)
                shower.openDoor()
                begin(.fromShower)
            }
        case .fromShower:
            guard let route = showerRoute, let shower else { finishShower(); break }
            let before = frame
            let arrived = advance(clips: route.toSofa.clips, poses: route.toSofa.poses, deltaTime: deltaTime)
            if before < Double(route.closeAt), frame >= Double(route.closeAt) { shower.closeDoor() }
            if arrived { finishShower() }
        }
    }

    private func fade(_ deltaTime: Double) {
        let target: Float = concealed ? 0 : 1
        guard opacity != target else { return }
        let next = opacity + (target - opacity) * Float(1 - exp(-deltaTime * 9))
        opacity = abs(next - target) < 0.01 ? target : next
        for entity in [holder, chair].compactMap({ $0 }) {
            if opacity == 1 { entity.components.remove(OpacityComponent.self) } else { entity.components.set(OpacityComponent(opacity: opacity)) }
        }
        // Del todo transparente, que tampoco reciba toques ni haga sombra.
        holder.isEnabled = command != .hidden && opacity > 0
        chair?.isEnabled = opacity > 0
    }

    /// Con los gráficos bajos, el personaje del sofá se queda quieto en su postura (sin animar el esqueleto).
    var freezeIdle = false
    private var frozen = false
    private var idleTime = 0.0

    private func updateFreeze(shouldFreeze: Bool, deltaTime: Double) {
        if shouldFreeze {
            idleTime += deltaTime
            // Se espera a que la postura esté puesta antes de pararla.
            if idleTime > 1.2, !frozen {
                controller?.pause()
                mirrorController?.pause()
                frozen = true
            }
        } else if frozen {
            controller?.resume()
            mirrorController?.resume()
            frozen = false
            idleTime = 0
        } else {
            idleTime = 0
        }
    }

    private func begin(_ next: Phase) {
        frozen = false
        idleTime = 0
        phase = next
        frame = 0
    }

    /// Avanza el recorrido; devuelve `true` al terminar.
    private func advance(clips: [OfficeLayout.Segment.ClipRange], poses: [OfficePose], deltaTime: Double) -> Bool {
        frame += deltaTime * layout.fps
        let last = poses.count - 1
        let position = min(frame, Double(last))
        let lower = Int(position)
        let upper = min(lower + 1, last)
        apply(OfficePose.mix(poses[lower], poses[upper], Float(position - Double(lower))))
        if let range = clips.first(where: { lower >= $0.from && lower < $0.to }) { play(range.clip) }
        return frame >= Double(last)
    }

    private func apply(_ pose: OfficePose) {
        holder.position = pose.position
        holder.orientation = pose.orientation
        mirrorHolder?.position = pose.position
        mirrorHolder?.orientation = pose.orientation
        setChair(offset: pose.chairOffset)
    }

    /// Calcula, una vez, el camino entre el sofá y el escritorio rodeando los muebles.
    private func prepareDeskRoutes() {
        guard deskRoutes == nil, !walkObstacles.isEmpty, let template = layout.slots.first,
              let toDesk = OfficeChessRoute.toDesk(actor: slot, template: template, obstacles: walkObstacles, bounds: walkBounds),
              let toSofa = OfficeChessRoute.toSofaFromDesk(actor: slot, template: template, obstacles: walkObstacles, bounds: walkBounds) else { return }
        deskRoutes = (toDesk, toSofa)
    }

    /// Prepara los recorridos a la mesa; `false` si no se pueden calcular (entonces se queda en el sofá).
    private func startChess(_ seat: OfficeChessSeat) -> Bool {
        guard let chess, let template = layout.slots.first,
              let toSeat = OfficeChessRoute.toSeat(actor: slot, template: template, seat: seat, table: (chess.tableCenter, chess.tableHalf), obstacles: walkObstacles, bounds: walkBounds, chairStart: chess.offset(of: seat.color), fps: layout.fps),
              let toSofa = OfficeChessRoute.toSofa(actor: slot, template: template, seat: seat, table: (chess.tableCenter, chess.tableHalf), obstacles: walkObstacles, bounds: walkBounds, fps: layout.fps) else { return false }
        chessRoute = (toSeat, toSofa, seat)
        chessMood = .waiting
        return true
    }

    /// Prepara los recorridos a la ducha y de vuelta; `false` si no hay ducha, está ocupada o no se pueden calcular.
    private func startShower() -> Bool {
        guard let shower, shower.occupant == nil || shower.occupant == index, let template = layout.slots.first,
              let there = OfficeShowerRoute.toShower(actor: slot, template: template, shower: shower, fps: layout.fps, obstacles: walkObstacles, bounds: walkBounds),
              let back = OfficeShowerRoute.toSofa(actor: slot, template: template, shower: shower, fps: layout.fps, obstacles: walkObstacles, bounds: walkBounds) else { return false }
        shower.occupant = index
        showerRoute = (there.path, there.openAt, back.path, back.closeAt)
        return true
    }

    private func finishShower() {
        setMosaic(false)
        if let shower, shower.occupant == index {
            shower.setWater(false)
            shower.closeDoor()
            shower.occupant = nil
        }
        showerRoute = nil
        phase = .sofa
        onShowerDone?()
    }

    /// El mosaico de Los Sims, colgado del personaje y de su reflejo.
    private func setMosaic(_ on: Bool) {
        if on, mosaic == nil, let shower, let panel = shower.makeMosaic() {
            holder.addChild(panel)
            let copy = mirrorHolder.map { reflection -> Entity in
                let copy = panel.clone(recursive: true)
                reflection.addChild(copy)
                return copy
            }
            mosaic = (panel, copy)
        } else if !on, let current = mosaic {
            shower?.removeMosaic(current.real)
            current.reflected?.removeFromParent()
            mosaic = nil
        }
    }

    private func setChair(offset: Float) {
        if phase == .toChess || phase == .chess || phase == .fromChess, let seat = chessRoute?.seat {
            chess?.setChair(seat.color, offset: offset)
            return
        }
        chair?.position = chairBase + chairDirection * offset
        mirrorChair?.position = chairBase + chairDirection * offset
    }

    private func play(_ clip: String, speed: Float = 1) {
        if playing == clip {
            // Un clip en bucle que se haya parado (o quedado en pausa sin que toque) se pone en marcha otra vez: así al caminar
            // las piernas nunca se quedan quietas mientras el personaje se desplaza.
            let stalled = controller.map { ($0.isComplete || $0.isStopped || ($0.isPaused && !frozen)) } ?? false
            if stalled, layout.clips[clip]?.loop == true {
                playing = nil
            } else {
                controller?.speed = speed
                mirrorController?.speed = speed
                return
            }
        }
        guard let resource = resource(for: clip) else { return }
        controller = model.playAnimation(resource, transitionDuration: 0.25, startsPaused: false)
        controller?.speed = speed
        mirrorController = mirrorModel?.playAnimation(resource, transitionDuration: 0.25, startsPaused: false)
        mirrorController?.speed = speed
        playing = clip
    }

    private func resource(for clip: String) -> AnimationResource? {
        if let cached = resources[clip] { return cached }
        guard let timeline, let info = layout.clips[clip] else { return nil }
        let view = AnimationView(source: timeline.definition, name: clip, repeatMode: info.loop ? .repeat : .none,
                                 trimStart: info.start, trimDuration: info.duration)
        guard var resource = try? AnimationResource.generate(with: view) else { return nil }
        // El modo de repetición de la vista recortada no repite (el clip de caminar acababa tras una zancada y las piernas se
        // quedaban quietas mientras el personaje seguía desplazándose): se repite el recurso entero.
        if info.loop { resource = resource.repeat(duration: .infinity) }
        resources[clip] = resource
        return resource
    }
}

/// Qué se ha pulsado en la escena: el personaje de un puesto o su escritorio.
struct OfficeAgentTag: Component {
    enum Kind { case agent, desk }
    var index: Int
    var kind: Kind
}
