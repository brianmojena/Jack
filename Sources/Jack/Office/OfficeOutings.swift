import Foundation
import simd

/// Las salidas desde el sofá (a ducharse, a por un café…): levantarse y volver a sentarse son los tramos de Blender del propio
/// personaje, y entre medias se camina rodeando los muebles.
enum OfficeOutingRoute {
    /// Levantarse del sofá y caminar hasta `goal`. La silla del escritorio se queda como está (apartada) todo el paseo.
    static func leave(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, to goal: OfficePose,
                      obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> OfficeRoutePath? {
        let own = actor.toDesk
        guard let stand = own.clips.first(where: { $0.clip == "stand_up" }), stand.to > stand.from, own.root.count >= stand.to else { return nil }
        var poses = Array(own.poses[stand.from..<stand.to])
        var clips = [OfficeLayout.Segment.ClipRange(clip: "stand_up", from: 0, to: poses.count)]
        var goal = goal
        let start = poses[poses.count - 1]
        goal.chairOffset = start.chairOffset
        // Primero, al frente hasta salir del sofá; después, rodeando todos los muebles (también el sofá, que si no se cruza).
        let speed = OfficeChessRoute.walkSpeed(of: template)
        var exit = clear(of: start, obstacles: obstacles)
        exit.yaw = heading(from: start, to: exit) ?? start.yaw
        var steps = exit == start ? [] : OfficeChessRoute.walkAround(from: start, to: exit, obstacles: [], bounds: nil, speed: speed, lead: false)
        steps += OfficeChessRoute.walkAround(from: exit, to: goal, obstacles: obstacles, bounds: bounds, speed: speed, lead: false)
        poses += steps
        clips.append(.init(clip: "walk", from: poses.count - steps.count, to: poses.count))
        return OfficeRoutePath(poses: poses, clips: clips)
    }

    /// Desde `start` (de pie), caminar hasta el sofá y sentarse, tal como al dejar el escritorio.
    static func back(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, from start: OfficePose,
                     obstacles: [OfficeChessRoute.Obstacle], bounds: OfficeChessRoute.Rect?) -> OfficeRoutePath? {
        let own = actor.toSofa
        guard let arrive = own.clips.first(where: { $0.clip == "stand_idle" }), own.root.count > arrive.from else { return nil }
        let ownPoses = own.poses
        var start = start
        let arrival = ownPoses[arrive.from]
        start.chairOffset = arrival.chairOffset
        // Se llega por delante del sofá (rodeándolo) y de ahí, de frente, al sitio donde se sienta.
        let speed = OfficeChessRoute.walkSpeed(of: template)
        var approach = clear(of: arrival, obstacles: obstacles)
        let detour = approach.position != arrival.position
        approach.yaw = heading(from: approach, to: arrival) ?? arrival.yaw  // de cara a su sitio; ahí se gira para sentarse
        var poses = OfficeChessRoute.walkAround(from: start, to: detour ? approach : arrival, obstacles: obstacles, bounds: bounds,
                                                speed: speed, lead: false)
        if detour {
            poses += OfficeChessRoute.walkAround(from: approach, to: arrival, obstacles: [], bounds: nil, speed: speed, lead: false)
        }
        var clips = [OfficeLayout.Segment.ClipRange(clip: "walk", from: 0, to: poses.count)]
        let base = poses.count
        poses += Array(ownPoses[arrive.from...])
        for range in own.clips where range.to > arrive.from {
            clips.append(.init(clip: range.clip, from: base + max(range.from - arrive.from, 0), to: base + range.to - arrive.from))
        }
        return OfficeRoutePath(poses: poses, clips: clips)
    }

    /// El punto más cercano a `pose` ya fuera de los muebles que tiene alrededor (con el margen con que se rodean al caminar): se
    /// sale por el lado más próximo, que en un sofá es por delante. Si no está dentro de ninguno, la misma pose.
    static func clear(of pose: OfficePose, obstacles: [OfficeChessRoute.Obstacle]) -> OfficePose {
        let around = obstacles.map { obstacle -> OfficeChessRoute.Rect in
            let pad = SIMD2<Float>(repeating: obstacle.soft ? 0.4 : 0.9)
            return (obstacle.rect.min - pad, obstacle.rect.max + pad)
        }
        var point = SIMD2(pose.position.x, pose.position.z)
        for _ in 0..<4 {
            guard let rect = around.first(where: { point.x > $0.min.x && point.x < $0.max.x && point.y > $0.min.y && point.y < $0.max.y }) else { break }
            let exits: [(distance: Float, to: SIMD2<Float>)] = [
                (point.x - rect.min.x, SIMD2(rect.min.x - 0.05, point.y)), (rect.max.x - point.x, SIMD2(rect.max.x + 0.05, point.y)),
                (point.y - rect.min.y, SIMD2(point.x, rect.min.y - 0.05)), (rect.max.y - point.y, SIMD2(point.x, rect.max.y + 0.05)),
            ]
            point = exits.min { $0.distance < $1.distance }!.to
        }
        var out = pose
        out.position = SIMD3(point.x, pose.position.y, point.y)
        return out
    }

    /// Hacia dónde se camina para ir de `a` a `b` (`nil` si están en el mismo sitio).
    private static func heading(from a: OfficePose, to b: OfficePose) -> Float? {
        let delta = SIMD2(b.position.x - a.position.x, b.position.z - a.position.z)
        return simd_length(delta) < 0.01 ? nil : atan2(delta.x, delta.y)
    }

    /// `first` y después `second`, con los tramos de `second` desplazados.
    static func join(_ first: OfficeRoutePath, _ second: OfficeRoutePath) -> OfficeRoutePath {
        let base = first.poses.count
        return OfficeRoutePath(poses: first.poses + second.poses,
                               clips: first.clips + second.clips.map { .init(clip: $0.clip, from: $0.from + base, to: $0.to + base) })
    }

    /// Quieto en `pose` durante `seconds`, con `clip`.
    static func hold(_ pose: OfficePose, seconds: Double, fps: Double, clip: String = "stand_idle") -> OfficeRoutePath {
        let count = max(Int(seconds * fps), 1)
        return OfficeRoutePath(poses: Array(repeating: pose, count: count), clips: [.init(clip: clip, from: 0, to: count)])
    }

    /// Caminar en línea recta (sin muebles por medio) de `a` a `b`.
    static func step(from a: OfficePose, to b: OfficePose, template: OfficeLayout.Slot) -> OfficeRoutePath {
        let poses = OfficeChessRoute.walkAround(from: a, to: b, obstacles: [], bounds: nil, speed: OfficeChessRoute.walkSpeed(of: template), lead: false)
        return OfficeRoutePath(poses: poses, clips: [.init(clip: "walk", from: 0, to: poses.count)])
    }
}
