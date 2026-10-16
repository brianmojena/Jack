import Foundation
import simd

/// Un recorrido de un personaje: su pose en cada fotograma y qué clip suena en cada tramo (como `OfficeLayout.Segment`, pero
/// calculado en la app).
struct OfficeRoutePath {
    var poses: [OfficePose]
    var clips: [OfficeLayout.Segment.ClipRange]
}

/// Los recorridos entre el sofá y la mesa de ajedrez.
///
/// Los de Blender solo llegan del sofá al escritorio. Aquí se reaprovechan sus tramos y entre ellos se camina por un
/// camino nuevo: levantarse del sofá (el del propio personaje), caminar rodeando la mesa y sentarse en la silla de la mesa (el
/// movimiento de sentarse del escritorio del puesto de referencia, colocado en el asiento); y al revés.
enum OfficeChessRoute {
    /// De cuánto se aparta el camino de la mesa (la silla y el personaje se mueven dentro de ese margen).
    private static let margin: Float = 0.6

    static func toSeat(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, seat: OfficeChessSeat, table: (center: SIMD2<Float>, half: Float), chairStart: Float, fps: Double) -> OfficeRoutePath? {
        let own = actor.toDesk, reference = template.toDesk
        guard let stand = own.clips.first(where: { $0.clip == "stand_up" }), let sit = reference.clips.first(where: { $0.clip == "sit_down" }),
              stand.to > stand.from, own.root.count >= stand.to, reference.root.count > sit.from else { return nil }
        let referencePoses = reference.poses
        let pulled = referencePoses[0].chairOffset

        // 1. Levantarse del sofá; la silla de la mesa se aparta mientras tanto.
        var poses = Array(own.poses[stand.from..<stand.to])
        for index in poses.indices { poses[index].chairOffset = chairStart + (pulled - chairStart) * smooth(Float(index) / Float(max(poses.count - 1, 1))) }
        var clips = [OfficeLayout.Segment.ClipRange(clip: "stand_up", from: 0, to: poses.count)]

        // 3. Sentarse: el movimiento de sentarse del escritorio, llevado al asiento de la mesa.
        let sitting = reanchor(Array(referencePoses[sit.from...]), reference: referencePoses[referencePoses.count - 1], target: seat.pose)

        // 2. Caminar hasta donde empieza a sentarse, sin atravesar la mesa.
        let start = poses[poses.count - 1]
        var approach = sitting[0]
        approach.chairOffset = pulled
        let steps = walk(from: start, to: approach, seat: seat.pose, table: table, speed: walkSpeed(of: template), pulled: pulled)
        poses += steps
        clips.append(.init(clip: "walk", from: poses.count - steps.count, to: poses.count))
        let sitStart = poses.count
        poses += sitting
        let downEnd = min(sit.to - sit.from, sitting.count)
        clips.append(.init(clip: "sit_down", from: sitStart, to: sitStart + downEnd))
        if downEnd < sitting.count { clips.append(.init(clip: "chess_idle", from: sitStart + downEnd, to: poses.count + 1)) }
        return OfficeRoutePath(poses: poses, clips: clips)
    }

    static func toSofa(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, seat: OfficeChessSeat, table: (center: SIMD2<Float>, half: Float), fps: Double) -> OfficeRoutePath? {
        let own = actor.toSofa, reference = template.toSofa
        guard let walkRange = reference.clips.first(where: { $0.clip == "walk" }), let arrive = own.clips.first(where: { $0.clip == "stand_idle" }),
              walkRange.from > 0, own.root.count > arrive.from else { return nil }
        let referencePoses = reference.poses

        // 1. Apartar la silla y levantarse de la mesa (lo del escritorio, colocado en el asiento).
        var poses = reanchor(Array(referencePoses[0..<walkRange.from]), reference: referencePoses[0], target: seat.pose)
        var clips: [OfficeLayout.Segment.ClipRange] = []
        for range in reference.clips where range.from < walkRange.from {
            let name = range.clip == "type" ? "chess_idle" : range.clip
            clips.append(.init(clip: name, from: range.from, to: min(range.to, walkRange.from)))
        }

        // 2. Caminar hasta donde empieza a sentarse en el sofá.
        let ownPoses = own.poses
        let start = poses[poses.count - 1]
        var goal = ownPoses[arrive.from]
        goal.chairOffset = start.chairOffset
        let steps = walk(from: start, to: goal, seat: seat.pose, table: table, speed: walkSpeed(of: template), pulled: start.chairOffset, leaving: true)
        poses += steps
        clips.append(.init(clip: "walk", from: poses.count - steps.count, to: poses.count))

        // 3. Esperar un momento y sentarse en el sofá, tal como está en Blender.
        let base = poses.count
        let tail = Array(ownPoses[arrive.from...])
        poses += tail
        for range in own.clips where range.to > arrive.from {
            clips.append(.init(clip: range.clip, from: base + max(range.from - arrive.from, 0), to: base + range.to - arrive.from))
        }
        return OfficeRoutePath(poses: poses, clips: clips)
    }

    // MARK: - Piezas del recorrido

    /// Lo que se mueve el personaje por fotograma al caminar (metros de la escena), medido en el tramo de caminar de Blender.
    private static func walkSpeed(of slot: OfficeLayout.Slot) -> Float {
        let poses = slot.toDesk.poses
        guard let range = slot.toDesk.clips.first(where: { $0.clip == "walk" }), range.to - range.from > 4 else { return 0.17 }
        var steps: [Float] = []
        for index in (range.from + 1)..<range.to {
            let delta = poses[index].position - poses[index - 1].position
            steps.append(simd_length(SIMD2(delta.x, delta.z)))
        }
        return max(steps.sorted()[steps.count / 2], 0.08)
    }

    /// Los fotogramas de `poses` llevados de `reference` (un asiento de otro sitio) a `target`: giran y se desplazan juntos.
    private static func reanchor(_ poses: [OfficePose], reference: OfficePose, target: OfficePose) -> [OfficePose] {
        let delta = target.yaw - reference.yaw
        let turn = simd_quatf(angle: delta, axis: SIMD3(0, 1, 0))
        return poses.map { pose in
            OfficePose(position: target.position + turn.act(pose.position - reference.position), yaw: pose.yaw + delta, chairOffset: pose.chairOffset)
        }
    }

    private static func smooth(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private static func ground(_ position: SIMD3<Float>) -> SIMD2<Float> { SIMD2(position.x, position.z) }

    /// El camino caminando de `a` a `b`. Termina con una aproximación por el lado del asiento (para no atravesar la silla
    /// apartada) y rodea la mesa si hace falta. Los fotogramas van a una velocidad constante.
    private static func walk(from a: OfficePose, to b: OfficePose, seat: OfficePose, table: (center: SIMD2<Float>, half: Float), speed: Float,
                             pulled: Float, leaving: Bool = false) -> [OfficePose] {
        let forward = SIMD2(sin(seat.yaw), cos(seat.yaw))
        let side = SIMD2(forward.y, -forward.x)
        let rect = (min: table.center - SIMD2(repeating: table.half + margin), max: table.center + SIMD2(repeating: table.half + margin))
        // Del sofá (o al sofá) se entra a la mesa por el lado del asiento por el que se llega.
        let seatPoint = ground(leaving ? a.position : b.position)
        let lateral: Float = simd_dot((leaving ? ground(b.position) : ground(a.position)) - seatPoint, side) >= 0 ? 1 : -1
        let gate = seatPoint - forward * 0.5 + side * lateral * 1.35
        var points: [SIMD2<Float>]
        if leaving {
            points = [ground(a.position), gate] + shortestPath(from: gate, to: ground(b.position), avoiding: rect).dropFirst()
        } else {
            points = shortestPath(from: ground(a.position), to: gate, avoiding: rect) + [ground(b.position)]
        }
        // Un primer paso al frente: así el personaje no se desliza de lado nada más levantarse.
        if !leaving { points.insert(points[0] + SIMD2(sin(a.yaw), cos(a.yaw)) * 0.7, at: 1) }
        // Fuera lo repetido.
        var clean: [SIMD2<Float>] = []
        for point in points where clean.last.map({ simd_distance($0, point) > 0.05 }) ?? true { clean.append(point) }
        points = clean
        var lengths: [Float] = [0]
        for index in 1..<points.count { lengths.append(lengths[index - 1] + simd_distance(points[index], points[index - 1])) }
        let total = lengths[lengths.count - 1]
        let count = max(Int((total / speed).rounded(.up)), 2)

        func point(at distance: Float) -> SIMD2<Float> {
            let d = min(max(distance, 0), total)
            var index = 1
            while index < lengths.count - 1, lengths[index] < d { index += 1 }
            let span = max(lengths[index] - lengths[index - 1], 0.0001)
            return points[index - 1] + (points[index] - points[index - 1]) * ((d - lengths[index - 1]) / span)
        }

        var yaw = a.yaw
        var result: [OfficePose] = []
        for step in 1...count {
            let distance = total * Float(step) / Float(count)
            let here = point(at: distance)
            let ahead = point(at: distance + 0.9)
            var direction = ahead - here
            if simd_length(direction) < 0.01 { direction = SIMD2(sin(b.yaw), cos(b.yaw)) }
            let wanted = atan2(direction.x, direction.y)
            var delta = wanted - yaw
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            yaw += min(max(delta, -0.14), 0.14)
            // Al final, el giro del asiento (o del sofá) exacto.
            let remaining = Float(count - step) / 14
            var shown = yaw
            if remaining < 1 {
                var toGoal = b.yaw - yaw
                while toGoal > .pi { toGoal -= 2 * .pi }
                while toGoal < -.pi { toGoal += 2 * .pi }
                shown = yaw + toGoal * smooth(1 - remaining)
            }
            let t = Float(step) / Float(count)
            let height = a.position.y + (b.position.y - a.position.y) * t
            result.append(OfficePose(position: SIMD3(here.x, height, here.y), yaw: shown, chairOffset: a.chairOffset + (b.chairOffset - a.chairOffset) * t))
        }
        return result
    }

    /// La ruta más corta de `a` a `b` sin cruzar el rectángulo (el mapa es un rectángulo y pocas esquinas: basta con probar).
    private static func shortestPath(from a: SIMD2<Float>, to b: SIMD2<Float>, avoiding rect: (min: SIMD2<Float>, max: SIMD2<Float>)) -> [SIMD2<Float>] {
        let pad: Float = 0.25
        let corners = [SIMD2(rect.min.x - pad, rect.min.y - pad), SIMD2(rect.max.x + pad, rect.min.y - pad),
                       SIMD2(rect.max.x + pad, rect.max.y + pad), SIMD2(rect.min.x - pad, rect.max.y + pad)]
        let nodes = [a, b] + corners
        var best = [Float](repeating: .greatestFiniteMagnitude, count: nodes.count)
        var previous = [Int?](repeating: nil, count: nodes.count)
        var done = Set<Int>()
        best[0] = 0
        while let current = (0..<nodes.count).filter({ !done.contains($0) && best[$0] < .greatestFiniteMagnitude }).min(by: { best[$0] < best[$1] }) {
            done.insert(current)
            if current == 1 { break }
            for next in 0..<nodes.count where !done.contains(next) && !crosses(nodes[current], nodes[next], rect: rect) {
                let cost = best[current] + simd_distance(nodes[current], nodes[next])
                if cost < best[next] { best[next] = cost; previous[next] = current }
            }
        }
        guard previous[1] != nil || a == b else { return [a, b] }
        var path = [1]
        while let before = previous[path[0]] { path.insert(before, at: 0) }
        return path.map { nodes[$0] }
    }

    /// ¿Atraviesa el segmento el interior del rectángulo?
    private static func crosses(_ p: SIMD2<Float>, _ q: SIMD2<Float>, rect: (min: SIMD2<Float>, max: SIMD2<Float>)) -> Bool {
        var enter: Float = 0, leave: Float = 1
        let d = q - p
        for axis in 0..<2 {
            if abs(d[axis]) < 1e-6 {
                if p[axis] <= rect.min[axis] || p[axis] >= rect.max[axis] { return false }
            } else {
                var t0 = (rect.min[axis] - p[axis]) / d[axis], t1 = (rect.max[axis] - p[axis]) / d[axis]
                if t0 > t1 { swap(&t0, &t1) }
                enter = max(enter, t0)
                leave = min(leave, t1)
                if enter >= leave - 1e-4 { return false }
            }
        }
        return enter < leave - 1e-4
    }
}
