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
    typealias Rect = (min: SIMD2<Float>, max: SIMD2<Float>)
    /// Un mueble del que apartarse. Los «blandos» (las sillas) se esquivan con menos margen y, si con ellos no hay camino, se ignoran.
    typealias Obstacle = (rect: Rect, soft: Bool)

    /// De cuánto se aparta el camino de la mesa (la silla y el personaje se mueven dentro de ese margen).
    private static let margin: Float = 0.6

    static func toSeat(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, seat: OfficeChessSeat, table: (center: SIMD2<Float>, half: Float), obstacles: [Obstacle], bounds: Rect?, chairStart: Float, fps: Double) -> OfficeRoutePath? {
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
        let steps = walk(from: start, to: approach, seat: seat.pose, table: table, obstacles: obstacles, bounds: bounds, speed: walkSpeed(of: template), pulled: pulled)
        poses += steps
        clips.append(.init(clip: "walk", from: poses.count - steps.count, to: poses.count))
        let sitStart = poses.count
        poses += sitting
        let downEnd = min(sit.to - sit.from, sitting.count)
        clips.append(.init(clip: "sit_down", from: sitStart, to: sitStart + downEnd))
        if downEnd < sitting.count { clips.append(.init(clip: "chess_idle", from: sitStart + downEnd, to: poses.count + 1)) }
        return OfficeRoutePath(poses: poses, clips: clips)
    }

    static func toSofa(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, seat: OfficeChessSeat, table: (center: SIMD2<Float>, half: Float), obstacles: [Obstacle], bounds: Rect?, fps: Double) -> OfficeRoutePath? {
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
        let steps = walk(from: start, to: goal, seat: seat.pose, table: table, obstacles: obstacles, bounds: bounds, speed: walkSpeed(of: template), pulled: start.chairOffset, leaving: true)
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

    // MARK: - Del sofá al escritorio y de vuelta

    /// Del sofá al escritorio: levantarse y sentarse son los de Blender; el camino entre los dos se calcula rodeando los muebles
    /// (el de Blender atravesaba algunos).
    static func toDesk(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, obstacles: [Obstacle], bounds: Rect?) -> OfficeRoutePath? {
        let own = actor.toDesk
        guard let stand = own.clips.first(where: { $0.clip == "stand_up" }), let sit = own.clips.first(where: { $0.clip == "sit_down" }),
              stand.to > stand.from, sit.from > stand.to, own.root.count > sit.from else { return nil }
        let poses = own.poses
        var route = Array(poses[stand.from..<stand.to])
        var clips = [OfficeLayout.Segment.ClipRange(clip: "stand_up", from: 0, to: route.count)]
        let steps = walkAround(from: route[route.count - 1], to: poses[sit.from], obstacles: obstacles, bounds: bounds, speed: walkSpeed(of: template))
        route += steps
        clips.append(.init(clip: "walk", from: route.count - steps.count, to: route.count))
        let base = route.count
        route += Array(poses[sit.from...])
        for range in own.clips where range.to > sit.from {
            clips.append(.init(clip: range.clip, from: base + max(range.from - sit.from, 0), to: base + range.to - sit.from))
        }
        return OfficeRoutePath(poses: route, clips: clips)
    }

    /// Del escritorio al sofá, igual: levantarse y sentarse de Blender y, entre medias, un camino que rodea los muebles.
    static func toSofaFromDesk(actor: OfficeLayout.Slot, template: OfficeLayout.Slot, obstacles: [Obstacle], bounds: Rect?) -> OfficeRoutePath? {
        let own = actor.toSofa
        guard let walkRange = own.clips.first(where: { $0.clip == "walk" }), let arrive = own.clips.first(where: { $0.clip == "stand_idle" }),
              walkRange.from > 0, arrive.from > walkRange.from, own.root.count > arrive.from else { return nil }
        let poses = own.poses
        var route = Array(poses[0..<walkRange.from])
        var clips: [OfficeLayout.Segment.ClipRange] = []
        for range in own.clips where range.from < walkRange.from {
            clips.append(.init(clip: range.clip, from: range.from, to: min(range.to, walkRange.from)))
        }
        let steps = walkAround(from: route[route.count - 1], to: poses[arrive.from], obstacles: obstacles, bounds: bounds, speed: walkSpeed(of: template), lead: false)
        route += steps
        clips.append(.init(clip: "walk", from: route.count - steps.count, to: route.count))
        let base = route.count
        route += Array(poses[arrive.from...])
        for range in own.clips where range.to > arrive.from {
            clips.append(.init(clip: range.clip, from: base + max(range.from - arrive.from, 0), to: base + range.to - arrive.from))
        }
        return OfficeRoutePath(poses: route, clips: clips)
    }

    // MARK: - Esquivar muebles

    /// Caminar de `a` a `b` rodeando los obstáculos (menos los que ya contienen la salida o la llegada, que se están dejando o
    /// alcanzando).
    private static func walkAround(from a: OfficePose, to b: OfficePose, obstacles: [Obstacle], bounds: Rect?, speed: Float, lead: Bool = true) -> [OfficePose] {
        let start = ground(a.position), goal = ground(b.position)
        var points = plan(from: start, to: goal, keepClear: [start, goal], extra: [], obstacles: obstacles, bounds: bounds)
        // Un primer paso al frente, para no deslizarse de lado nada más levantarse.
        if lead { points.insert(points[0] + SIMD2(sin(a.yaw), cos(a.yaw)) * 0.7, at: 1) }
        return follow(points, from: a, to: b, speed: speed)
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
    private static func walk(from a: OfficePose, to b: OfficePose, seat: OfficePose, table: (center: SIMD2<Float>, half: Float), obstacles: [Obstacle], bounds: Rect?, speed: Float,
                             pulled: Float, leaving: Bool = false) -> [OfficePose] {
        let forward = SIMD2(sin(seat.yaw), cos(seat.yaw))
        let side = SIMD2(forward.y, -forward.x)
        let rect = (min: table.center - SIMD2(repeating: table.half + margin), max: table.center + SIMD2(repeating: table.half + margin))
        // Del sofá (o al sofá) se entra a la mesa por el lado del asiento por el que se llega.
        let seatPoint = ground(leaving ? a.position : b.position)
        let lateral: Float = simd_dot((leaving ? ground(b.position) : ground(a.position)) - seatPoint, side) >= 0 ? 1 : -1
        let gate = seatPoint - forward * 0.5 + side * lateral * 1.35
        // Además de la mesa, los demás muebles (menos los que contienen la salida, la llegada o la puerta de entrada).
        let start = ground(a.position), goal = ground(b.position)
        var points: [SIMD2<Float>]
        if leaving {
            points = [start, gate] + plan(from: gate, to: goal, keepClear: [start, goal, gate], extra: [rect], obstacles: obstacles, bounds: bounds).dropFirst()
        } else {
            points = plan(from: start, to: gate, keepClear: [start, goal, gate], extra: [rect], obstacles: obstacles, bounds: bounds) + [goal]
        }
        // Un primer paso al frente: así el personaje no se desliza de lado nada más levantarse.
        if !leaving { points.insert(points[0] + SIMD2(sin(a.yaw), cos(a.yaw)) * 0.7, at: 1) }
        return follow(points, from: a, to: b, speed: speed)
    }

    /// Los fotogramas de caminar a velocidad constante por una línea quebrada de `a` a `b` (el giro sigue la dirección con
    /// suavidad y acaba exactamente en el de `b`).
    private static func follow(_ route: [SIMD2<Float>], from a: OfficePose, to b: OfficePose, speed: Float) -> [OfficePose] {
        var points = route
        // Fuera lo repetido.
        var clean: [SIMD2<Float>] = []
        for point in points where clean.last.map({ simd_distance($0, point) > 0.05 }) ?? true { clean.append(point) }
        points = clean
        if points.count < 2 { points = [points.first ?? ground(a.position), ground(b.position) + SIMD2(0.001, 0)] }
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

    /// El camino de `from` a `to` rodeando los muebles: primero con todos (las sillas con poco margen); si así no hay paso, solo con
    /// los grandes; y si tampoco, en línea recta. `keepClear` son los puntos que no pueden quedar dentro de ningún obstáculo (los
    /// muebles que los contienen se dejan fuera). `extra` son obstáculos que siempre cuentan (ya con su margen).
    private static func plan(from: SIMD2<Float>, to: SIMD2<Float>, keepClear: [SIMD2<Float>], extra: [Rect], obstacles: [Obstacle], bounds: Rect?) -> [SIMD2<Float>] {
        func inside(_ rect: Rect, _ p: SIMD2<Float>) -> Bool { p.x > rect.min.x && p.x < rect.max.x && p.y > rect.min.y && p.y < rect.max.y }
        for includeSoft in [true, false] {
            let rects = obstacles.filter { includeSoft || !$0.soft }.map { obstacle -> Rect in
                let pad = SIMD2<Float>(repeating: obstacle.soft ? 0.15 : margin)
                return (obstacle.rect.min - pad, obstacle.rect.max + pad)
            }.filter { rect in !keepClear.contains { inside(rect, $0) } } + extra
            if let path = shortestPath(from: from, to: to, avoiding: rects, within: bounds) { return path }
        }
        return [from, to]
    }

    /// La ruta más corta de `a` a `b` sin cruzar ninguno de los rectángulos (se prueban sus esquinas, algo apartadas, como puntos
    /// de paso). `within` deja fuera los puntos de paso que caerían fuera de la sala.
    private static func shortestPath(from a: SIMD2<Float>, to b: SIMD2<Float>, avoiding rects: [Rect], within bounds: Rect? = nil) -> [SIMD2<Float>]? {
        let pad: Float = 0.25
        var nodes = [a, b]
        for rect in rects {
            for corner in [SIMD2(rect.min.x - pad, rect.min.y - pad), SIMD2(rect.max.x + pad, rect.min.y - pad),
                           SIMD2(rect.max.x + pad, rect.max.y + pad), SIMD2(rect.min.x - pad, rect.max.y + pad)] {
                if let bounds, corner.x < bounds.min.x || corner.y < bounds.min.y || corner.x > bounds.max.x || corner.y > bounds.max.y { continue }
                // Un punto dentro de otro obstáculo no sirve.
                if rects.contains(where: { corner.x > $0.min.x && corner.x < $0.max.x && corner.y > $0.min.y && corner.y < $0.max.y }) { continue }
                nodes.append(corner)
            }
        }
        var best = [Float](repeating: .greatestFiniteMagnitude, count: nodes.count)
        var previous = [Int?](repeating: nil, count: nodes.count)
        var done = Set<Int>()
        best[0] = 0
        while let current = (0..<nodes.count).filter({ !done.contains($0) && best[$0] < .greatestFiniteMagnitude }).min(by: { best[$0] < best[$1] }) {
            done.insert(current)
            if current == 1 { break }
            for next in 0..<nodes.count where !done.contains(next) && !rects.contains(where: { crosses(nodes[current], nodes[next], rect: $0) }) {
                let cost = best[current] + simd_distance(nodes[current], nodes[next])
                if cost < best[next] { best[next] = cost; previous[next] = current }
            }
        }
        guard previous[1] != nil || a == b else { return nil }
        var path = [1]
        while let before = previous[path[0]] { path.insert(before, at: 0) }
        return path.map { nodes[$0] }
    }

    /// ¿Atraviesa el segmento el interior del rectángulo?
    private static func crosses(_ p: SIMD2<Float>, _ q: SIMD2<Float>, rect: Rect) -> Bool {
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
