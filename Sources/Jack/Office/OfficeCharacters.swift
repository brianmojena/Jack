import JackCore
import SwiftUI

/// Keeps each agent's current destination and deterministic walking route.
/// The view asks for placements at its own TimelineView cadence; this type owns
/// no timers and never advances state while placement(for:now:) is being read.
@MainActor
final class OfficeChoreographer: ObservableObject {
    private struct Motion {
        var start: CGPoint
        var destination: CGPoint
        var route: [CGPoint]
        var startTime: Date
        var duration: TimeInterval
        var pose: OfficePose
        var facingLeft: Bool
        var scale: CGFloat
        var agent: OfficeAgent
        var loungeIndex: Int?
        var loungePose: OfficePose = .standingCoffee
        var nextLoungeChange: Date = .distantFuture
        var celebrationUntil: Date?
        var desiredState: OfficeAgentState
    }

    var reduceMotion = false
    private var motions: [String: Motion] = [:]
    private var order: [String] = []

    func update(agents: [OfficeAgent], layout: OfficeLayout, now: Date) {
        let retained = Set(agents.map(\.id))
        motions = motions.filter { retained.contains($0.key) }
        order = agents.map(\.id)

        for (index, agent) in agents.enumerated() {
            guard let desk = layout.desks[safe: index] else { continue }
            let previous = motions[agent.id]
            let isNew = previous == nil
            var motion = previous ?? Motion(
                start: desk.seat, destination: desk.seat, route: [], startTime: now,
                duration: 0, pose: pose(for: agent.state), facingLeft: false,
                scale: desk.scale, agent: agent, loungeIndex: nil,
                desiredState: agent.state
            )
            motion.agent = agent

            if isNew {
                motion.destination = desk.seat
                motion.start = motion.destination
                motion.pose = pose(for: agent.state)
                motion.scale = desk.scale
                if agent.state == .idle, !layout.loungeSpots.isEmpty {
                    motion.loungePose = loungePose(for: agent.seed, cycle: 0)
                    if let loungeIndex = chooseLoungeSpot(agent: agent, layout: layout, excluding: nil, order: index) {
                        motion.loungeIndex = loungeIndex
                        motion.destination = layout.loungeSpots[loungeIndex]
                        motion.start = motion.destination
                        motion.pose = motion.loungePose
                        motion.nextLoungeChange = now.addingTimeInterval(loungeInterval(seed: agent.seed, cycle: 0))
                    } else {
                        motion.pose = motion.loungePose
                    }
                }
                motion.desiredState = agent.state
                motions[agent.id] = motion
                continue
            }

            let stateChanged = motion.desiredState != agent.state
            motion.scale = desk.scale
            if agent.state == .idle {
                if stateChanged {
                    motion.desiredState = .idle
                    if motion.pose == .seatedTyping || motion.pose == .seatedThinking {
                        motion.pose = .celebrating
                        motion.celebrationUntil = now.addingTimeInterval(0.85)
                        motion.loungeIndex = chooseLoungeSpot(agent: agent, layout: layout, excluding: motion.loungeIndex, order: index)
                    } else if motion.loungeIndex == nil, !layout.loungeSpots.isEmpty {
                        motion.loungeIndex = chooseLoungeSpot(agent: agent, layout: layout, excluding: nil, order: index)
                        motion.loungePose = loungePose(for: agent.seed, cycle: 0)
                        motion.nextLoungeChange = now.addingTimeInterval(loungeInterval(seed: agent.seed, cycle: 0))
                        if motion.loungeIndex == nil { motion.pose = motion.loungePose }
                    }
                }
                if let celebrationUntil = motion.celebrationUntil, now >= celebrationUntil {
                    motion.celebrationUntil = nil
                    if let spotIndex = motion.loungeIndex, layout.loungeSpots.indices.contains(spotIndex) {
                        move(&motion, to: layout.loungeSpots[spotIndex], pose: motion.loungePose, layout: layout, now: now)
                        motion.nextLoungeChange = now.addingTimeInterval(loungeInterval(seed: agent.seed, cycle: 0))
                    } else {
                        motion.pose = motion.loungePose
                    }
                } else if motion.celebrationUntil == nil, isLoungePose(motion.pose), now >= motion.nextLoungeChange,
                          !layout.loungeSpots.isEmpty {
                    let cycle = Int(now.timeIntervalSince1970 / 30)
                    let newIndex = chooseLoungeSpot(agent: agent, layout: layout, excluding: motion.loungeIndex, order: cycle)
                    motion.loungeIndex = newIndex
                    motion.loungePose = loungePose(for: agent.seed, cycle: cycle)
                    if let newIndex, layout.loungeSpots.indices.contains(newIndex) {
                        move(&motion, to: layout.loungeSpots[newIndex], pose: motion.loungePose, layout: layout, now: now)
                    }
                    motion.nextLoungeChange = now.addingTimeInterval(loungeInterval(seed: agent.seed, cycle: cycle))
                } else if motion.celebrationUntil == nil, !isLoungePose(motion.pose), motion.pose != .walking {
                    if let spotIndex = motion.loungeIndex, layout.loungeSpots.indices.contains(spotIndex) {
                        move(&motion, to: layout.loungeSpots[spotIndex], pose: motion.loungePose, layout: layout, now: now)
                    }
                }
            } else {
                motion.celebrationUntil = nil
                motion.desiredState = agent.state
                let targetPose = pose(for: agent.state)
                let atSeat = distance(currentPosition(of: motion, now: now), desk.seat) < 4
                if stateChanged || motion.loungeIndex != nil || (!atSeat && motion.pose != .walking) || (motion.pose != targetPose && motion.pose != .walking) {
                    motion.loungeIndex = nil
                    move(&motion, to: desk.seat, pose: targetPose, layout: layout, now: now)
                } else if motion.pose != .walking {
                    motion.pose = targetPose
                    motion.destination = desk.seat
                }
            }

            // Keep a character visually stable when the window is resized. Its
            // new target is approached from its interpolated position.
            if previous?.scale != desk.scale || previous?.destination != desk.seat && agent.state != .idle {
                if agent.state != .idle {
                    let here = currentPosition(of: motion, now: now)
                    move(&motion, from: here, to: desk.seat, pose: pose(for: agent.state), layout: layout, now: now)
                }
            }
            motions[agent.id] = motion
        }
    }

    func placement(for id: String, now: Date) -> OfficePlacement? {
        guard var motion = motions[id] else { return nil }
        if reduceMotion {
            return OfficePlacement(position: motion.destination, pose: motion.pose == .walking ? settledPose(for: motion) : motion.pose,
                                   facingLeft: motion.facingLeft, scale: motion.scale)
        }
        let point = currentPosition(of: motion, now: now)
        if motion.pose == .walking, now.timeIntervalSince(motion.startTime) >= motion.duration {
            motion.start = motion.destination
            motion.route = []
            motion.pose = settledPose(for: motion)
            motion.startTime = now
            motion.duration = 0
            motions[id] = motion
        }
        return OfficePlacement(position: point, pose: motion.pose, facingLeft: motion.facingLeft, scale: motion.scale)
    }

    private func move(_ motion: inout Motion, to point: CGPoint, pose: OfficePose, layout: OfficeLayout, now: Date) {
        move(&motion, from: currentPosition(of: motion, now: now), to: point, pose: pose, layout: layout, now: now)
    }

    private func move(_ motion: inout Motion, from start: CGPoint, to point: CGPoint, pose: OfficePose, layout: OfficeLayout, now: Date) {
        motion.start = start
        motion.destination = point
        motion.startTime = now
        motion.scale = max(0.45, motion.scale)
        motion.pose = start == point ? pose : .walking
        motion.route = start == point ? [] : hallwayRoute(from: start, to: point, layout: layout, scale: motion.scale)
        let points = [start] + motion.route
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        motion.duration = TimeInterval(length / max(20, 90 * motion.scale))
        if let first = motion.route.first { motion.facingLeft = first.x < start.x }
        else { motion.facingLeft = point.x < start.x }
    }

    private func hallwayRoute(from start: CGPoint, to end: CGPoint, layout: OfficeLayout, scale: CGFloat) -> [CGPoint] {
        let lowerLimit = layout.floorY + 32 * scale
        let beyondFeet = max(start.y, end.y) + 18 * scale
        let upperLimit = layout.size.height - 12 * scale
        let corridorY = min(upperLimit, max(lowerLimit, beyondFeet))
        let candidates = [CGPoint(x: start.x, y: corridorY), CGPoint(x: end.x, y: corridorY), end]
        return candidates.enumerated().compactMap { idx, point in
            let prior = idx == 0 ? start : candidates[idx - 1]
            return distance(prior, point) < 1 ? nil : point
        }
    }

    private func currentPosition(of motion: Motion, now: Date) -> CGPoint {
        guard motion.pose == .walking, motion.duration > 0 else { return motion.destination }
        let progress = min(1, max(0, now.timeIntervalSince(motion.startTime) / motion.duration))
        let full = [motion.start] + motion.route
        guard full.count > 1 else { return motion.destination }
        let lengths = zip(full, full.dropFirst()).map { distance($0.0, $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return motion.destination }
        var remaining = CGFloat(progress) * total
        for (index, length) in lengths.enumerated() {
            if remaining <= length || index == lengths.count - 1 {
                let a = full[index], b = full[index + 1]
                let t = length > 0 ? remaining / length : 1
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= length
        }
        return motion.destination
    }

    private func chooseLoungeSpot(agent: OfficeAgent, layout: OfficeLayout, excluding: Int?, order: Int) -> Int? {
        guard !layout.loungeSpots.isEmpty else { return nil }
        let occupied = Set(motions.filter { $0.key != agent.id }.compactMap { $0.value.loungeIndex })
        let free = layout.loungeSpots.indices.filter { !occupied.contains($0) }
        let alternatives = free.filter { $0 != excluding }
        let pool = alternatives.isEmpty ? free : alternatives
        guard !pool.isEmpty else { return nil }
        return pool[deterministicIndex(agent.seed &+ UInt64(bitPattern: Int64(order)), count: pool.count)]
    }
    private func deterministicIndex(_ seed: UInt64, count: Int) -> Int { count > 0 ? Int((seed ^ (seed >> 17) &* 0x9E3779B97F4A7C15) % UInt64(count)) : 0 }
    private func loungePose(for seed: UInt64, cycle: Int) -> OfficePose { ((seed &+ UInt64(bitPattern: Int64(cycle))) & 1) == 0 ? .standingCoffee : .sittingSofa }
    private func loungeInterval(seed: UInt64, cycle: Int) -> TimeInterval { 20 + Double((seed &+ UInt64(bitPattern: Int64(cycle * 13))) % 21) }
    private func isLoungePose(_ pose: OfficePose) -> Bool { pose == .standingCoffee || pose == .sittingSofa }
    private func pose(for state: OfficeAgentState) -> OfficePose {
        switch state { case .working: .seatedTyping; case .thinking: .seatedThinking; case .waiting, .blocked: .raisedHand; case .idle: .standingCoffee; case .failed: .slumped }
    }
    private func settledPose(for motion: Motion) -> OfficePose { motion.desiredState == .idle ? motion.loungePose : pose(for: motion.desiredState) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The character is drawn in an 80 × 120 pt box. Its feet sit at the bottom
/// centre (local point 40, 120); the supplied scene position is that anchor.
/// The frame helper returns the scaled visual hit target in scene coordinates.
struct OfficeCharacterView: View {
    let agent: OfficeAgent
    let placement: OfficePlacement
    let date: Date
    let animate: Bool
    let isSelected: Bool
    let isHovered: Bool

    private var phase: CGFloat { animate ? CGFloat(date.timeIntervalSinceReferenceDate) : 0 }
    private var skin: Color { Self.skinColor(seed: agent.seed) }
    private var hair: Color { Self.hairColor(seed: agent.seed) }
    private var shirt: Color { OfficePalette.agentColor(seed: agent.seed) }
    private var blink: Bool { animate && Int(date.timeIntervalSinceReferenceDate * 3 + Double(agent.seed % 7)) % 37 == 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            characterCanvas
                .frame(width: 80, height: 120)
                .scaleEffect(x: placement.facingLeft ? -1 : 1, y: 1)
                .overlay(alignment: .top) { statusAdornment.offset(y: -14) }
                .overlay(alignment: .top) { activityChip.offset(y: -31) }
                .overlay(alignment: .bottom) { nameTag.offset(y: 21) }
                .overlay { if isSelected { RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.9), lineWidth: 2).shadow(color: .cyan, radius: 8).padding(5) } }
        }
        .frame(width: 80, height: 120, alignment: .bottom)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(agent.state.rawValue)")
    }

    private var characterCanvas: some View {
        Canvas { context, size in
            let t = phase
            let bob: CGFloat = animate && placement.pose == .walking ? sin(t * 9) * 2.2 : (animate && placement.pose == .seatedTyping ? sin(t * 3) * 0.8 : 0)
            let jump: CGFloat = animate && placement.pose == .celebrating ? abs(sin(t * 8)) * 7 : 0
            let skinTone = skin, hairTone = hair, shirtTone = shirt
            func ellipse(_ rect: CGRect, _ color: Color, stroke: Color? = nil, width: CGFloat = 1) {
                let p = Path(ellipseIn: rect); context.fill(p, with: .color(color)); if let stroke { context.stroke(p, with: .color(stroke), lineWidth: width) }
            }
            func roundRect(_ rect: CGRect, _ radius: CGFloat, _ color: Color) { context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color)) }
            let baseY = 119 - bob - jump
            let isSitting = placement.pose == .seatedTyping || placement.pose == .seatedThinking || placement.pose == .raisedHand || placement.pose == .sittingSofa
            let legShift: CGFloat = placement.pose == .walking && animate ? sin(t * 9) * 7 : 0
            // Legs and shoes
            if isSitting {
                var legs = Path(); legs.move(to: CGPoint(x: 34, y: baseY - 22)); legs.addQuadCurve(to: CGPoint(x: 18, y: baseY - 7), control: CGPoint(x: 17, y: baseY - 20)); legs.move(to: CGPoint(x: 47, y: baseY - 22)); legs.addQuadCurve(to: CGPoint(x: 63, y: baseY - 7), control: CGPoint(x: 62, y: baseY - 20))
                context.stroke(legs, with: .color(Color(red: 0.20, green: 0.24, blue: 0.34)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                ellipse(CGRect(x: 8, y: baseY - 11, width: 17, height: 10), .black.opacity(0.74)); ellipse(CGRect(x: 56, y: baseY - 11, width: 17, height: 10), .black.opacity(0.74))
            } else {
                let stride = placement.pose == .walking ? legShift : 0
                var legs = Path(); legs.move(to: CGPoint(x: 34, y: baseY - 25)); legs.addLine(to: CGPoint(x: 31 + stride, y: baseY - 6)); legs.move(to: CGPoint(x: 46, y: baseY - 25)); legs.addLine(to: CGPoint(x: 49 - stride, y: baseY - 6))
                context.stroke(legs, with: .color(Color(red: 0.20, green: 0.24, blue: 0.34)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                ellipse(CGRect(x: 22 + stride, y: baseY - 10, width: 17, height: 9), .black.opacity(0.76)); ellipse(CGRect(x: 42 - stride, y: baseY - 10, width: 17, height: 9), .black.opacity(0.76))
            }
            // Torso
            roundRect(CGRect(x: 25, y: baseY - 54, width: 30, height: 36), 12, shirtTone)
            ellipse(CGRect(x: 24, y: baseY - 55, width: 32, height: 27), shirtTone)
            // Arms follow each action pose.
            var arms = Path()
            switch placement.pose {
            case .raisedHand:
                arms.move(to: CGPoint(x: 27, y: baseY - 47)); arms.addQuadCurve(to: CGPoint(x: 19, y: baseY - 72), control: CGPoint(x: 10, y: baseY - 67)); arms.addLine(to: CGPoint(x: 18, y: baseY - 82))
                arms.move(to: CGPoint(x: 53, y: baseY - 46)); arms.addLine(to: CGPoint(x: 64, y: baseY - 33))
            case .celebrating:
                arms.move(to: CGPoint(x: 27, y: baseY - 47)); arms.addQuadCurve(to: CGPoint(x: 12, y: baseY - 76), control: CGPoint(x: 9, y: baseY - 57)); arms.move(to: CGPoint(x: 53, y: baseY - 47)); arms.addQuadCurve(to: CGPoint(x: 68, y: baseY - 76), control: CGPoint(x: 71, y: baseY - 57))
            case .slumped:
                arms.move(to: CGPoint(x: 27, y: baseY - 44)); arms.addLine(to: CGPoint(x: 19, y: baseY - 25)); arms.move(to: CGPoint(x: 53, y: baseY - 44)); arms.addLine(to: CGPoint(x: 61, y: baseY - 25))
            case .seatedThinking:
                arms.move(to: CGPoint(x: 28, y: baseY - 45)); arms.addLine(to: CGPoint(x: 18, y: baseY - 31)); arms.move(to: CGPoint(x: 52, y: baseY - 46)); arms.addQuadCurve(to: CGPoint(x: 49, y: baseY - 70), control: CGPoint(x: 63, y: baseY - 52))
            case .standingCoffee:
                arms.move(to: CGPoint(x: 27, y: baseY - 46)); arms.addLine(to: CGPoint(x: 20, y: baseY - 26)); arms.move(to: CGPoint(x: 53, y: baseY - 46)); arms.addQuadCurve(to: CGPoint(x: 61, y: baseY - 35), control: CGPoint(x: 68, y: baseY - 43))
            default:
                let swing = placement.pose == .walking && animate ? legShift : (placement.pose == .seatedTyping && animate ? sin(t * 8) * 2 : 0)
                arms.move(to: CGPoint(x: 27, y: baseY - 47)); arms.addLine(to: CGPoint(x: 17 + swing, y: baseY - 33)); arms.move(to: CGPoint(x: 53, y: baseY - 47)); arms.addLine(to: CGPoint(x: 63 - swing, y: baseY - 33))
            }
            context.stroke(arms, with: .color(skinTone), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            // Keyboard for desk poses
            if placement.pose == .seatedTyping || placement.pose == .seatedThinking || placement.pose == .raisedHand {
                roundRect(CGRect(x: 29, y: baseY - 26, width: 23, height: 5), 2, Color.white.opacity(0.76))
                for key in 0..<4 { roundRect(CGRect(x: 32 + CGFloat(key) * 4.5, y: baseY - 25, width: 2, height: 1.2), 0.5, Color.gray.opacity(0.55)) }
            }
            if placement.pose == .standingCoffee {
                roundRect(CGRect(x: 58, y: baseY - 41, width: 11, height: 11), 2, Color(red: 0.92, green: 0.79, blue: 0.62))
                let handle = Path(ellipseIn: CGRect(x: 67, y: baseY - 39, width: 5, height: 6)); context.stroke(handle, with: .color(.white.opacity(0.75)), lineWidth: 1.4)
                if animate {
                    for i in 0..<2 { var steam = Path(); steam.move(to: CGPoint(x: 61 + CGFloat(i * 4), y: baseY - 44)); steam.addCurve(to: CGPoint(x: 62 + CGFloat(i * 4), y: baseY - 50), control1: CGPoint(x: 57 + CGFloat(i * 4), y: baseY - 47), control2: CGPoint(x: 66 + CGFloat(i * 4), y: baseY - 47)); context.stroke(steam, with: .color(.white.opacity(0.55)), lineWidth: 1) }
                }
            }
            // Head, hair and face
            let headY = baseY - 104 + (placement.pose == .slumped ? 7 : 0)
            ellipse(CGRect(x: 17, y: headY, width: 46, height: 45), skinTone, stroke: Color.black.opacity(0.16), width: 1)
            let hairstyle = Int(agent.seed % 4)
            switch hairstyle {
            case 0: ellipse(CGRect(x: 17, y: headY - 5, width: 46, height: 24), hairTone)
            case 1:
                ellipse(CGRect(x: 17, y: headY - 3, width: 46, height: 18), hairTone); ellipse(CGRect(x: 49, y: headY + 4, width: 12, height: 20), hairTone)
            case 2:
                ellipse(CGRect(x: 17, y: headY - 5, width: 20, height: 19), hairTone); ellipse(CGRect(x: 31, y: headY - 8, width: 19, height: 21), hairTone); ellipse(CGRect(x: 43, y: headY - 4, width: 20, height: 19), hairTone)
            default:
                ellipse(CGRect(x: 17, y: headY - 4, width: 46, height: 17), hairTone); var fringe = Path(); fringe.move(to: CGPoint(x: 23, y: headY + 9)); fringe.addQuadCurve(to: CGPoint(x: 51, y: headY + 10), control: CGPoint(x: 37, y: headY + 20)); context.fill(fringe, with: .color(hairTone))
            }
            let eyeY = headY + 22
            if blink {
                var eyes = Path(); eyes.move(to: CGPoint(x: 29, y: eyeY)); eyes.addLine(to: CGPoint(x: 33, y: eyeY)); eyes.move(to: CGPoint(x: 47, y: eyeY)); eyes.addLine(to: CGPoint(x: 51, y: eyeY)); context.stroke(eyes, with: .color(.black.opacity(0.72)), lineWidth: 1.3)
            } else {
                ellipse(CGRect(x: 29, y: eyeY - 1.3, width: 4, height: 5.4), .black.opacity(0.82)); ellipse(CGRect(x: 47, y: eyeY - 1.3, width: 4, height: 5.4), .black.opacity(0.82)); ellipse(CGRect(x: 30, y: eyeY, width: 1.5, height: 1.5), .white); ellipse(CGRect(x: 48, y: eyeY, width: 1.5, height: 1.5), .white)
            }
            ellipse(CGRect(x: 23, y: eyeY + 6, width: 6, height: 3), .pink.opacity(0.40)); ellipse(CGRect(x: 51, y: eyeY + 6, width: 6, height: 3), .pink.opacity(0.40))
            var mouth = Path(); mouth.move(to: CGPoint(x: 37, y: headY + 32)); mouth.addQuadCurve(to: CGPoint(x: 43, y: headY + 32), control: CGPoint(x: 40, y: headY + 36)); context.stroke(mouth, with: .color(.black.opacity(0.55)), lineWidth: 1)
            if placement.pose == .slumped { ellipse(CGRect(x: 22, y: headY + 16, width: 38, height: 27), Color.red.opacity(0.12)) }
            // Small maker-specific accessories.
            switch agent.kind.lowercased() {
            case "claude":
                roundRect(CGRect(x: 12, y: headY + 15, width: 5, height: 15), 2.5, Color(red: 0.36, green: 0.78, blue: 0.91)); roundRect(CGRect(x: 63, y: headY + 15, width: 5, height: 15), 2.5, Color(red: 0.36, green: 0.78, blue: 0.91))
                var band = Path(); band.addArc(center: CGPoint(x: 40, y: headY + 21), radius: 26, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false); context.stroke(band, with: .color(Color(red: 0.36, green: 0.78, blue: 0.91)), lineWidth: 3)
            case "codex":
                let glasses = Path(roundedRect: CGRect(x: 26, y: eyeY - 5, width: 12, height: 10), cornerRadius: 4).union(Path(roundedRect: CGRect(x: 42, y: eyeY - 5, width: 12, height: 10), cornerRadius: 4))
                context.stroke(glasses, with: .color(Color(red: 0.20, green: 0.34, blue: 0.50)), lineWidth: 1.5); var bridge = Path(); bridge.move(to: CGPoint(x: 38, y: eyeY)); bridge.addLine(to: CGPoint(x: 42, y: eyeY)); context.stroke(bridge, with: .color(.black.opacity(0.7)), lineWidth: 1.3)
            case "opencode":
                var cap = Path(); cap.move(to: CGPoint(x: 17, y: headY + 12)); cap.addQuadCurve(to: CGPoint(x: 61, y: headY + 12), control: CGPoint(x: 39, y: headY - 5)); cap.addLine(to: CGPoint(x: 65, y: headY + 14)); cap.addQuadCurve(to: CGPoint(x: 18, y: headY + 16), control: CGPoint(x: 41, y: headY + 22)); cap.closeSubpath(); context.fill(cap, with: .color(Color(red: 0.94, green: 0.67, blue: 0.28)))
            default: break
            }
            if placement.pose == .celebrating && animate {
                for i in 0..<5 {
                    let x = CGFloat((Int(agent.seed % 31) + i * 17) % 74) + 3
                    let y = 9 + CGFloat((i * 13 + Int(t * 12) % 21) % 26)
                    let rect = CGRect(x: x, y: y, width: 3.5, height: 5)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color([.pink, .yellow, .cyan, .mint, .orange][i]))
                }
            }
        }
    }

    private var statusAdornment: some View {
        Group {
            if agent.state == .working {
                Circle().stroke(OfficePalette.stateColor(agent.state).opacity(animate ? 0.45 + 0.35 * sin(phase * 3) : 0.65), lineWidth: 2)
                    .frame(width: 39, height: 17).overlay(Circle().fill(OfficePalette.stateColor(agent.state).opacity(0.7)).frame(width: 4, height: 4))
            } else if agent.state == .waiting || agent.state == .blocked {
                HStack(spacing: 3) {
                    Text("!").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(.white).frame(width: 18, height: 18).background(Circle().fill(OfficePalette.stateColor(agent.state)))
                    Text("Necesita tu respuesta").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                }.padding(.horizontal, 6).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.76))).fixedSize()
            } else if agent.state == .failed {
                Text("×").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 19, height: 19).background(Circle().fill(OfficePalette.stateColor(agent.state)))
            }
        }.fixedSize()
    }

    private var activityChip: some View {
        Group {
            if (agent.state == .working || agent.state == .thinking), let activity = agent.activity, !activity.isEmpty {
                Text(String(activity.prefix(28))).font(.system(size: 8, weight: .medium, design: .rounded)).lineLimit(1).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.75))).overlay(Capsule().stroke(OfficePalette.stateColor(agent.state).opacity(0.7), lineWidth: 0.8))
                    .offset(y: animate ? sin(phase * 2 + Double(agent.seed % 5)) * 1.2 : 0)
            }
        }.fixedSize()
    }

    private var nameTag: some View {
        Group {
            if isHovered || isSelected {
                Text(agent.name).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.78)))
            }
        }.fixedSize()
    }

    /// Scene-space hit target. The bottom midpoint is the character's feet.
    func officeCharacterFrame(for placement: OfficePlacement) -> CGRect {
        CGRect(x: placement.position.x - 40 * placement.scale,
               y: placement.position.y - 120 * placement.scale,
               width: 80 * placement.scale, height: 120 * placement.scale)
    }

    private static func skinColor(seed: UInt64) -> Color {
        let shades: [Color] = [Color(red: 0.98, green: 0.78, blue: 0.62), Color(red: 0.78, green: 0.52, blue: 0.35), Color(red: 0.55, green: 0.34, blue: 0.25), Color(red: 0.92, green: 0.66, blue: 0.49)]
        return shades[Int((seed >> 5) % UInt64(shades.count))]
    }
    private static func hairColor(seed: UInt64) -> Color {
        let shades: [Color] = [Color(red: 0.19, green: 0.13, blue: 0.12), Color(red: 0.42, green: 0.25, blue: 0.13), Color(red: 0.15, green: 0.17, blue: 0.21), Color(red: 0.69, green: 0.39, blue: 0.17)]
        return shades[Int((seed >> 11) % UInt64(shades.count))]
    }
}

#Preview("Office poses") {
    HStack(alignment: .bottom, spacing: 12) {
        let poses: [OfficePose] = [.seatedTyping, .seatedThinking, .raisedHand, .walking, .standingCoffee, .sittingSofa, .celebrating, .slumped]
        ForEach(Array(poses.enumerated()), id: \.offset) { index, pose in
            VStack(spacing: 8) {
                OfficeCharacterView(
                    agent: OfficeAgent(id: "preview-\(index)", name: "\(pose)", kind: ["claude", "codex", "opencode", "other"][index % 4], state: [.working, .thinking, .waiting, .working, .idle, .idle, .working, .failed][index], activity: "Preparando la oficina", seed: UInt64(index * 127 + 41)),
                    placement: OfficePlacement(position: CGPoint(x: 40, y: 120), pose: pose, facingLeft: false, scale: 1),
                    date: Date(), animate: true, isSelected: false, isHovered: true
                )
            }.frame(width: 100, height: 165).background(Color(red: 0.10, green: 0.13, blue: 0.19)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }.padding().background(Color(red: 0.04, green: 0.06, blue: 0.10))
}
