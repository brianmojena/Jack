import AppKit
import RealityKit
import SwiftUI

/// Cámara que orbita la sala: arrastrar la gira, la rueda y el pellizco acercan y alejan.
@MainActor final class OfficeCamera {
    struct Pose {
        var target: SIMD3<Float>
        var azimuth: Float
        var elevation: Float
        var distance: Float
    }

    static let fieldOfView: Float = 38
    private(set) var current: Pose
    private(set) var goal: Pose
    /// La pose de la sala mientras se mira una pantalla de cerca, para volver a ella al salir.
    private var room: Pose?

    /// Si la cámara está delante de una pantalla; mientras tanto no se gira ni se acerca.
    var isFocused: Bool { room != nil }

    init(target: SIMD3<Float>) {
        let pose = Pose(target: target, azimuth: atan2(21, 25), elevation: asin(17 / 36.2), distance: 36.2)
        current = pose
        goal = pose
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        guard room == nil else { return }
        goal.azimuth -= Float(dx) * 0.008
        goal.elevation = min(max(goal.elevation + Float(dy) * 0.006, 0.12), 1.4)
    }

    /// Desplaza la cámara sobre el suelo, como la mano de Blender: `right` hacia la derecha de la vista y `forward` hacia el
    /// fondo, en fracciones de la distancia a la que mira (así el paso es el mismo cerca y lejos).
    func pan(right: Float, forward: Float) {
        guard room == nil else { return }
        let side = SIMD3<Float>(cos(goal.azimuth), 0, -sin(goal.azimuth))
        let ahead = SIMD3<Float>(-sin(goal.azimuth), 0, -cos(goal.azimuth))
        var target = goal.target + (side * right + ahead * forward) * goal.distance
        // Sin salirse de la sala: x de -6 a 12,5 y, en RealityKit, z de -6 a 15,5 (la y de Blender invertida).
        target.x = min(max(target.x, -6), 12.5)
        target.z = min(max(target.z, -6), 15.5)
        goal.target = target
    }

    func zoom(by factor: Float) {
        guard room == nil else { return }
        goal.distance = min(max(goal.distance * factor, 5.5), 70)
    }

    /// Lleva la cámara justo delante de una pantalla, de frente y a su altura, encuadrándola entera con margen para la barra de arriba.
    /// `facing` es hacia dónde mira la pantalla (hacia quien la usa); `size`, su ancho y alto.
    func focus(screen center: SIMD3<Float>, facing: SIMD3<Float>, size: SIMD2<Float>, view: CGSize) {
        let tangent = tan(Self.fieldOfView * .pi / 360)
        let aspect = Float(view.width / max(view.height, 1))
        let distance = max(size.y / 2 / tangent, size.x / 2 / (tangent * aspect)) * 1.16
        if room == nil { room = goal }
        goal = Pose(target: center, azimuth: atan2(facing.x, facing.z), elevation: 0, distance: distance)
    }

    /// Vuelve a la vista de la sala que había antes de mirar la pantalla.
    func leaveFocus() {
        guard let room else { return }
        goal = room
        self.room = nil
    }

    /// Acerca la cámara actual a la meta; con un movimiento que frena al llegar.
    func step(_ deltaTime: Double) {
        let blend = Float(1 - exp(-deltaTime * 5.5))
        var turn = goal.azimuth - current.azimuth
        turn -= (turn / (2 * .pi)).rounded() * 2 * .pi
        current.azimuth += turn * blend
        current.elevation += (goal.elevation - current.elevation) * blend
        current.distance += (goal.distance - current.distance) * blend
        current.target += (goal.target - current.target) * blend
    }

    func place(_ camera: Entity) { Self.place(camera, current) }

    private static func place(_ camera: Entity, _ pose: Pose) {
        camera.look(at: pose.target, from: pose.target + offset(pose), relativeTo: nil)
    }

    private static func offset(_ pose: Pose) -> SIMD3<Float> {
        SIMD3(sin(pose.azimuth) * cos(pose.elevation), sin(pose.elevation), cos(pose.azimuth) * cos(pose.elevation)) * pose.distance
    }

    /// Dónde cae en la vista un punto de la escena ahora mismo; `nil` si queda detrás de la cámara.
    func projectCurrent(_ point: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        project(point, in: size, from: current)?.point
    }

    /// Dónde caerá un punto cuando la cámara llegue a su meta.
    func projectGoal(_ point: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        project(point, in: size, from: goal)?.point
    }

    private func project(_ point: SIMD3<Float>, in size: CGSize, from pose: Pose) -> (point: CGPoint, depth: Float)? {
        let eye = pose.target + Self.offset(pose)
        let forward = simd_normalize(pose.target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let ray = point - eye
        let depth = simd_dot(ray, forward)
        guard depth > 0.05 else { return nil }
        let tangent = tan(Self.fieldOfView * .pi / 360)
        let aspect = Float(size.width / max(size.height, 1))
        let x = simd_dot(ray, right) / (depth * tangent * aspect)
        let y = simd_dot(ray, up) / (depth * tangent)
        return (CGPoint(x: CGFloat((x + 1) / 2) * size.width, y: CGFloat((1 - y) / 2) * size.height), depth)
    }
}

/// La oficina vista desde arriba, como en Los Sims: una cámara que orbita la sala y personajes y escritorios que se pulsan.
struct OfficeSceneView: View {
    @ObservedObject var stage: OfficeStage
    let camera: OfficeCamera
    var resources = OfficeStage.Resources.bundled
    /// Se pulsó un personaje o un escritorio, en el punto dado de esta vista.
    var onPick: (OfficeAgentTag, CGPoint) -> Void = { _, _ in }
    /// Se pulsó en vacío.
    var onPickNothing: () -> Void = {}
    @State private var updates: EventSubscription?
    @State private var lastDrag = CGSize.zero
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.renderingEffects.antialiasing = .multisample4X
            if #available(macOS 26.0, *) { content.renderingEffects.customPostProcessing = .effect(OfficePostProcess()) }
            content.add(stage.world)
            await stage.load(resources)
            let lens = Entity()
            lens.components.set(PerspectiveCameraComponent(near: 0.1, far: 900, fieldOfViewInDegrees: OfficeCamera.fieldOfView))
            camera.place(lens)
            content.add(lens)
            updates = content.subscribe(to: SceneEvents.Update.self) { event in
                stage.update(deltaTime: event.deltaTime)
                camera.step(event.deltaTime)
                camera.place(lens)
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    if let tag = value.entity.components[OfficeAgentTag.self] {
                        onPick(tag, value.location)
                    } else {
                        onPickNothing()
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let dx = value.translation.width - lastDrag.width, dy = value.translation.height - lastDrag.height
                    // Con Mayúsculas, arrastrar desplaza la escena con la mano en vez de girarla.
                    if NSEvent.modifierFlags.contains(.shift) {
                        camera.pan(right: -Float(dx) * 0.0016, forward: Float(dy) * 0.0016)
                    } else {
                        camera.orbit(dx: dx, dy: dy)
                    }
                    lastDrag = value.translation
                }
                .onEnded { _ in lastDrag = .zero }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    camera.zoom(by: Float(lastMagnification / value.magnification))
                    lastMagnification = value.magnification
                }
                .onEnded { _ in lastMagnification = 1 }
        )
        .background(OfficeScrollZoom(onZoom: { camera.zoom(by: $0) }, onPan: { camera.pan(right: $0, forward: $1) }))
        // Los avisos van en el centro de la escena, que ocupa todo el sitio aunque aún no haya cargado.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if case .failed(let message) = stage.state { OfficeStatusLabel(text: message) } }
        .overlay { if stage.state == .loading { OfficeStatusLabel(text: "Cargando la oficina…") } }
    }
}

/// La rueda del ratón (y el desplazamiento con dos dedos) sobre la escena acercan y alejan la cámara; las flechas del
/// teclado la desplazan por la sala (izquierda y derecha a los lados, arriba y abajo hacia el fondo y hacia delante).
private struct OfficeScrollZoom: NSViewRepresentable {
    let onZoom: (Float) -> Void
    let onPan: (Float, Float) -> Void

    func makeNSView(context: Context) -> NSView { MonitorView(onZoom: onZoom, onPan: onPan) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? MonitorView)?.onZoom = onZoom
        (view as? MonitorView)?.onPan = onPan
    }

    private final class MonitorView: NSView {
        var onZoom: (Float) -> Void
        var onPan: (Float, Float) -> Void
        private var monitor: Any?
        private var keys: Any?

        init(onZoom: @escaping (Float) -> Void, onPan: @escaping (Float, Float) -> Void) {
            self.onZoom = onZoom
            self.onPan = onPan
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
            guard window != nil else { return }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Solo en la ventana de la oficina y sin estar escribiendo: en el chat de abajo las flechas mueven el cursor.
                guard let self, event.window === self.window, !(self.window?.firstResponder is NSText),
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                let step: Float = 0.06
                switch event.keyCode {
                case 123: self.onPan(-step, 0)
                case 124: self.onPan(step, 0)
                case 125: self.onPan(0, -step)
                case 126: self.onPan(0, step)
                default: return event
                }
                return nil
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onZoom(Float(exp(-event.scrollingDeltaY * 0.01)))
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keys { NSEvent.removeMonitor(keys) }
        }
    }
}

private struct OfficeStatusLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
    }
}
