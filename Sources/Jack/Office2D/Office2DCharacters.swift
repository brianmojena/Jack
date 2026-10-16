import JackCore
import SwiftUI

/// Deterministic motion for the SVG office translated into world coordinates.
@MainActor
final class Office2DChoreographer: ObservableObject {
    private struct Motion {
        var start: CGPoint
        var destination: CGPoint
        var route: [CGPoint]
        var segmentLengths: [CGFloat]
        var routeLength: CGFloat
        var startTime: Date
        var pose: Office2DPose
        var facingLeft: Bool
        var scale: CGFloat
        var agent: Office2DAgent
        var desiredState: Office2DAgentState
        var celebrationUntil: Date?
        var loungeIndex: Int?
    }

    var reduceMotion = false
    private var motions: [String: Motion] = [:]
    private var desks: [Office2DDeskSlot] = []

    func update(agents: [Office2DAgent], layout: Office2DLayout, now: Date) {
        desks = layout.desks
        let ids = Set(agents.map(\.id))
        motions = motions.filter { ids.contains($0.key) }
        for (index, agent) in agents.enumerated() {
            guard layout.desks.indices.contains(index) else { continue }
            let desk = layout.desks[index]
            guard var motion = motions[agent.id] else {
                let idle = agent.state == .idle
                let spotIndex = idle && !Office2DNav.spots.isEmpty ? Int(agent.seed % UInt64(Office2DNav.spots.count)) : nil
                let destination = spotIndex.map(Office2DNav.spot) ?? desk.seat
                let pose = idle ? loungePose(for: spotIndex ?? 0) : Self.pose(for: agent.state)
                var arrival = Motion(start: destination, destination: destination, route: [], segmentLengths: [], routeLength: 0,
                    startTime: now, pose: pose, facingLeft: false, scale: desk.scale, agent: agent,
                    desiredState: agent.state, celebrationUntil: nil, loungeIndex: spotIndex)
                if !idle && !reduceMotion {
                    arrival.start = CGPoint(x: 1220, y: 706)
                    arrival.destination = arrival.start
                    beginMove(&arrival, to: desk.seat, pose: pose, desks: layout.desks, now: now)
                }
                motions[agent.id] = arrival
                continue
            }
            motion.agent = agent
            motion.scale = desk.scale
            let changed = motion.desiredState != agent.state
            if agent.state == .idle {
                if changed && (motion.desiredState == .working || motion.desiredState == .thinking) {
                    let here = currentPosition(motion, now: now)
                    motion.start = here
                    motion.destination = here
                    motion.pose = .celebrating
                    motion.celebrationUntil = now.addingTimeInterval(1.3)
                } else if changed {
                    motion.celebrationUntil = nil
                    let spots = Office2DNav.spots
                    let spot = spots.isEmpty ? desk.seat : spots[Int(agent.seed % UInt64(spots.count))]
                    motion.loungeIndex = spots.isEmpty ? nil : Int(agent.seed % UInt64(spots.count))
                    beginMove(&motion, to: spot, pose: loungePose(for: motion.loungeIndex ?? 0), desks: layout.desks, now: now)
                }
                if let until = motion.celebrationUntil, now >= until {
                    motion.celebrationUntil = nil
                    let spots = Office2DNav.spots
                    let idx = spots.isEmpty ? nil : Int(agent.seed % UInt64(spots.count))
                    motion.loungeIndex = idx
                    beginMove(&motion, to: idx.map { spots[$0] } ?? desk.seat, pose: loungePose(for: idx ?? 0), desks: layout.desks, now: now)
                }
            } else {
                motion.celebrationUntil = nil
                let target = Self.pose(for: agent.state)
                if changed || distance(motion.destination, desk.seat) > 2 || (motion.pose != target && motion.pose != .walking) {
                    beginMove(&motion, to: desk.seat, pose: target, desks: layout.desks, now: now)
                } else if motion.pose != .walking {
                    motion.pose = target
                }
                motion.loungeIndex = nil
            }
            motion.desiredState = agent.state
            motions[agent.id] = motion
        }
    }

    func placement(for id: String, now: Date) -> Office2DPlacement? {
        guard var motion = motions[id] else { return nil }
        if let until = motion.celebrationUntil, now >= until || reduceMotion {
            motion.celebrationUntil = nil
            let index = motion.loungeIndex ?? Int(motion.agent.seed % UInt64(Office2DNav.spots.count))
            motion.loungeIndex = index
            beginMove(&motion, to: Office2DNav.spot(index), pose: loungePose(for: index), desks: desks, now: now)
            motions[id] = motion
        }
        if reduceMotion {
            return Office2DPlacement(position: motion.destination, pose: settledPose(motion),
                                     facingLeft: motion.facingLeft, scale: motion.scale)
        }
        let point = currentPosition(motion, now: now)
        let ahead = currentPosition(motion, now: now.addingTimeInterval(0.05))
        if abs(ahead.x - point.x) > 0.01 { motion.facingLeft = ahead.x < point.x }
        if motion.pose == .walking, now.timeIntervalSince(motion.startTime) >= motion.routeLength / 150 {
            motion.start = motion.destination; motion.route = []; motion.segmentLengths = []; motion.routeLength = 0
            motion.pose = settledPose(motion); motion.startTime = now
        }
        motions[id] = motion
        return Office2DPlacement(position: point, pose: motion.pose, facingLeft: motion.facingLeft, scale: motion.scale)
    }

    /// A visual break only: it never pauses or sends an instruction to an agent.
    func visitLounge(agentID: String, spot: Int, now: Date) {
        guard var motion = motions[agentID], motion.desiredState == .idle else { return }
        objectWillChange.send()
        motion.celebrationUntil = nil
        motion.loungeIndex = spot
        beginMove(&motion, to: Office2DNav.spot(spot), pose: loungePose(for: spot), desks: desks, now: now)
        motions[agentID] = motion
    }

    func greet(agentID: String, now: Date) {
        guard var motion = motions[agentID], motion.desiredState == .idle else { return }
        objectWillChange.send()
        motion.start = currentPosition(motion, now: now)
        motion.destination = motion.start
        motion.pose = .celebrating
        motion.celebrationUntil = now.addingTimeInterval(1.3)
        motions[agentID] = motion
    }

    private func beginMove(_ motion: inout Motion, to point: CGPoint, pose: Office2DPose, desks: [Office2DDeskSlot], now: Date) {
        let from = currentPosition(motion, now: now)
        motion.start = from; motion.destination = point; motion.startTime = now
        motion.pose = distance(from, point) < 1 ? pose : .walking
        motion.route = motion.pose == .walking ? Office2DNav.buildPath(from: from, to: point, desks: desks) : []
        motion.route = motion.route.filter { distance($0, from) > 0.5 }
        if let last = motion.route.last, distance(last, point) > 0.5 { motion.route.append(point) }
        if motion.route.isEmpty && motion.pose == .walking { motion.route = [point] }
        let points = [from] + motion.route
        motion.segmentLengths = zip(points, points.dropFirst()).map { distance($0, $1) }
        motion.routeLength = motion.segmentLengths.reduce(0, +)
        if let first = motion.route.first { motion.facingLeft = first.x < from.x }
    }

    private func currentPosition(_ motion: Motion, now: Date) -> CGPoint {
        guard motion.pose == .walking, motion.routeLength > 0 else { return motion.destination }
        var remaining = min(motion.routeLength, max(0, now.timeIntervalSince(motion.startTime) * 150))
        if remaining >= motion.routeLength { return motion.destination }
        let points = [motion.start] + motion.route
        for (i, length) in motion.segmentLengths.enumerated() {
            if remaining <= length || i == motion.segmentLengths.count - 1 {
                let t = length > 0 ? remaining / length : 1
                return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * t,
                               y: points[i].y + (points[i + 1].y - points[i].y) * t)
            }
            remaining -= length
        }
        return motion.destination
    }
    private func settledPose(_ motion: Motion) -> Office2DPose { motion.desiredState == .idle ? loungePose(for: motion.loungeIndex ?? 0) : Self.pose(for: motion.desiredState) }
    private func loungePose(for i: Int) -> Office2DPose { i < 2 ? .standingCoffee : .sittingSofa }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func pose(for state: Office2DAgentState) -> Office2DPose {
        switch state {
        case .working: .seatedTyping
        case .thinking: .seatedThinking
        case .waiting, .blocked: .raisedHand
        case .failed: .slumped
        case .idle: .standingCoffee
        }
    }
}

struct Office2DCharacterView: View {
    let agent: Office2DAgent
    let placement: Office2DPlacement
    let date: Date
    let animate: Bool
    let isSelected: Bool
    let isHovered: Bool

    private var t: Double { animate ? date.timeIntervalSinceReferenceDate : 0 }
    private var motionEnabled: Bool { animate && placement.pose != .walking }
    private var role: String { Self.role(for: agent.kind) }
    private var accent: Color { Office2DPalette.ROLE_COLORS[role] ?? Office2DPalette.ROLE_COLORS["Developer"]! }
    private var shirt: Color { Office2DPalette.SHIRTS[Int(agent.seed % UInt64(Office2DPalette.SHIRTS.count))] }
    private var skin: Color { Office2DPalette.SKINS[Int((agent.seed % 7) % UInt64(Office2DPalette.SKINS.count))] }
    private var hair: Color { Office2DPalette.HAIRS[Int((agent.seed >> 3) % UInt64(Office2DPalette.HAIRS.count))] }
    private var hairStyle: Int { Int((agent.seed >> 7) % 3) }
    private var seedPhase: Double { Double(agent.seed % 1000) }
    private var activityTool: (String, Color)? {
        guard let activity = agent.activity?.lowercased(), !activity.isEmpty else { return nil }
        let tools: [(String, [String], String)] = [
            ("Edit", ["edit", "editing", "editando"], "fbbf24"),
            ("Bash", ["bash", "shell", "terminal", "running command", "ejecutando"], "34d399"),
            ("Read", ["read", "reading", "leyendo"], "38bdf8"),
            ("Grep", ["grep", "search", "buscar", "buscando"], "a78bfa"),
            ("Write", ["write", "writing", "escribiendo"], "f472b6"),
            ("Test", ["test", "testing", "prueba"], "a3e635"),
            ("Web", ["browse", "web", "browsing", "navegando"], "60a5fa")
        ]
        guard let match = tools.first(where: { $0.1.contains(where: { activity.contains($0) }) }) else { return nil }
        return (match.0, Color(hex: match.2))
    }
    private var shortActivity: String {
        let value = agent.activity?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return agent.state == .idle ? "De descanso" : "Trabajando" }
        return value.count > 24 ? String(value.prefix(23)) + "…" : value
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.translateBy(x: size.width / 2, y: 120)
                context.scaleBy(x: placement.facingLeft ? -1 : 1, y: 1)
                drawCharacter(&context)
            }
            .frame(width: 80, height: 120)
            .overlay(alignment: .top) {
                if needsDeskRowAvoidance {
                    VStack(spacing: 3) {
                        if let activityTool, isWorking { toolChip(activityTool) }
                        bubble
                    }
                    .fixedSize()
                    .offset(x: 110, y: 12)
                    .zIndex(10)
                } else {
                    HStack(spacing: 5) {
                        if let activityTool, isWorking { toolChip(activityTool) }
                        bubble
                    }
                    .fixedSize()
                    .layoutPriority(1)
                    .offset(y: -15 + CGFloat(isSelected ? -6 : 0))
                    .zIndex(10)
                }
            }
            if placement.pose == .walking, animate { walkingSparkles }
            if placement.pose == .celebrating, animate {
                Canvas { context, _ in
                    for i in 0..<14 {
                        let phase = (t * 0.9 + Double(i) / 14).truncatingRemainder(dividingBy: 1)
                        let x = 40 + sin(Double(i) * 2.4) * phase * 70
                        let y = 15 - sin(phase * .pi) * 45 + phase * 60
                        context.fill(Path(CGRect(x: x, y: y, width: 3, height: 5)),
                                     with: .color([Color.mint, .pink, .yellow, .cyan][i % 4].opacity(1 - phase)))
                    }
                }.allowsHitTesting(false)
            }
            if isSelected { selectionMark }
            if isHovered || isSelected { nameTag.offset(x: 40, y: 118) }
        }
        .frame(width: 80, height: 120)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(agent.state.rawValue)")
    }

    private func drawCharacter(_ ctx: inout GraphicsContext) {
        let walking = placement.pose == .walking
        let desk = placement.pose == .seatedTyping || placement.pose == .seatedThinking || placement.pose == .raisedHand
        let sofa = placement.pose == .sittingSofa
        let blocked = agent.state == .waiting || agent.state == .blocked || agent.state == .failed
        let phase = t * 18.75
        let sw = sin(phase)
        let bob: CGFloat = walking ? -abs(sin(phase)) * 2.6 : desk ? CGFloat(sin(t * 2 + seedPhase)) * 0.6 : sofa ? CGFloat(sin(t * 1.3 + seedPhase)) * 0.6 : CGFloat(sin(t * 1.6 + seedPhase)) * 0.8
        let shift: CGFloat = desk ? 20 : sofa ? 16 : 0
        let hop: CGFloat = placement.pose == .celebrating && animate ? -abs(sin(t * 9)) * 7 : 0
        let S = shift + bob + hop
        let hipY = -34 + shift + bob * 0.5
        let fL: CGPoint = walking ? CGPoint(x: -8 + sw * 11, y: -max(0, -cos(phase)) * 5) : CGPoint(x: -8, y: 0)
        let fR: CGPoint = walking ? CGPoint(x: 8 - sw * 11, y: -max(0, cos(phase)) * 5) : CGPoint(x: 8, y: 0)
        let hL: CGPoint
        let hR: CGPoint
        var look: CGFloat = 0
        var tilt: CGFloat = 0
        var mood = "smile"
        var cup = false
        var sweat = false
        if walking {
            hL = CGPoint(x: -15 + sin(-sw * 0.75) * 25, y: -58 + S + bob + cos(-sw * 0.75) * 25)
            hR = CGPoint(x: 15 + sin(sw * 0.75) * 25, y: -58 + S + bob + cos(sw * 0.75) * 25)
            look = sw < 0 ? -2.2 : 2.2; tilt = CGFloat(sw) * 3
        } else if desk {
            hL = CGPoint(x: -9 + sin(t * 15 + seedPhase) * 1.3, y: -12 + sin(t * 21 + seedPhase) * 2)
            if blocked {
                hR = CGPoint(x: 28 + sin(t * 9) * 6, y: -78); look = CGFloat(sin(t * 2.5)) * 3
                tilt = CGFloat(sin(t * 7)) * 3; mood = "frown"; sweat = true
            } else {
                hR = CGPoint(x: 9 + sin(t * 18 + seedPhase) * 1.3, y: -12 + sin(t * 24 + seedPhase) * 2)
                look = -3; tilt = CGFloat(sin(t * 1.6 + seedPhase)) * 1.6
                mood = agent.state == .working ? "flat" : "calm"
            }
        } else if placement.pose == .slumped {
            hL = CGPoint(x: -17, y: -25); hR = CGPoint(x: 17, y: -25)
            tilt = 12; mood = "frown"; sweat = true
        } else if sofa {
            hL = CGPoint(x: -13, y: -22 + sin(t * 1.3) * 0.5); hR = CGPoint(x: 13, y: -22)
            cup = agent.seed & 1 == 1; mood = "smile"; look = sin(t * 0.5 + seedPhase) > 0.5 ? 2.5 : 0
        } else if placement.pose == .standingCoffee {
            cup = true
            let s = (t + seedPhase * 7).truncatingRemainder(dividingBy: 6) / 6
            let up = s < 0.3 ? sin((s / 0.3) * .pi) : 0
            hL = CGPoint(x: -17, y: -36); hR = CGPoint(x: CGFloat(17 - 8 * up), y: CGFloat(-44 + up * (-70 + S + bob + 44)))
            tilt = CGFloat(-3 * up); look = CGFloat(placement.facingLeft ? -2 : 2); mood = "smile"
        } else if placement.pose == .celebrating {
            let k = sin(t * 14)
            hL = CGPoint(x: -26, y: -92 + k * 4); hR = CGPoint(x: 26, y: -92 - k * 4)
        } else {
            hL = CGPoint(x: -17, y: -37); hR = CGPoint(x: 17, y: -37 + sin(t * 1.5) * 0.8)
            look = placement.facingLeft ? -2 : 2
        }

        ellipse(&ctx, CGRect(x: -21, y: -5, width: 42, height: 12), .black.opacity(desk ? 0 : 0.32))
        if !desk || sofa {
            line(&ctx, CGPoint(x: -8, y: hipY), CGPoint(x: fL.x, y: fL.y - 2), color: Self.pants, width: 11)
            line(&ctx, CGPoint(x: 8, y: hipY), CGPoint(x: fR.x, y: fR.y - 2), color: Self.pants, width: 11)
            ellipse(&ctx, CGRect(x: fL.x - 9, y: fL.y - 4, width: 16, height: 8), Color(red: 0.914, green: 0.925, blue: 1))
            ellipse(&ctx, CGRect(x: fR.x - 7, y: fR.y - 4, width: 16, height: 8), Color(red: 0.914, green: 0.925, blue: 1))
        }
        let torso = Path(roundedRect: CGRect(x: -15.5, y: -66 + S, width: 31, height: 38), cornerRadius: 14)
        ctx.fill(torso, with: .color(shirt))
        var seam = Path(); seam.move(to: CGPoint(x: -15, y: -52 + S)); seam.addQuadCurve(to: CGPoint(x: 15, y: -52 + S), control: CGPoint(x: 0, y: -44 + S))
        ctx.stroke(seam, with: .color(.white.opacity(0.18)), lineWidth: 2)
        if role == "PM" { var tie = Path(); tie.move(to: CGPoint(x: 0, y: -62 + S)); tie.addLines([CGPoint(x: 4, y: -56 + S), CGPoint(x: 2, y: -42 + S), CGPoint(x: 0, y: -39 + S), CGPoint(x: -2, y: -42 + S), CGPoint(x: -4, y: -56 + S)]); tie.closeSubpath(); ctx.fill(tie, with: .color(accent)) }
        line(&ctx, CGPoint(x: -14, y: -58 + S), hL, color: shirt, width: 9.5)
        line(&ctx, CGPoint(x: 14, y: -58 + S), hR, color: shirt, width: 9.5)
        ellipse(&ctx, CGRect(x: hL.x - 4.6, y: hL.y - 4.6, width: 9.2, height: 9.2), skin)
        ellipse(&ctx, CGRect(x: hR.x - 4.6, y: hR.y - 4.6, width: 9.2, height: 9.2), skin)
        if cup {
            let r = CGRect(x: hR.x - 2.5, y: hR.y - 6, width: 11, height: 10)
            ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(Color(red: 0.957, green: 0.961, blue: 1)))
            ctx.fill(Path(CGRect(x: r.minX, y: r.minY + 2, width: r.width, height: 2.5)), with: .color(accent))
            if animate { for i in 0..<2 { var steam = Path(); steam.move(to: CGPoint(x: r.minX + 3.5 + CGFloat(i) * 4.5, y: r.minY - 3)); steam.addQuadCurve(to: CGPoint(x: r.minX + 3.5 + CGFloat(i) * 4.5, y: r.minY - 10), control: CGPoint(x: r.minX + CGFloat(i) * 4.5, y: r.minY - 6)); ctx.stroke(steam, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round)) } }
        }
        drawHead(&ctx, S: S, tilt: tilt, look: look, mood: mood, sweat: sweat)
    }

    private func drawHead(_ ctx: inout GraphicsContext, S: CGFloat, tilt: CGFloat, look: CGFloat, mood: String, sweat: Bool) {
        ctx.translateBy(x: 0, y: -82 + S); ctx.rotate(by: .degrees(Double(tilt)))
        if hairStyle == 2 { ctx.fill(Path(roundedRect: CGRect(x: -19.5, y: -6, width: 39, height: 25), cornerRadius: 11), with: .color(hair)) }
        ellipse(&ctx, CGRect(x: -21.8, y: -0.8, width: 7.6, height: 7.6), skin)
        ellipse(&ctx, CGRect(x: 14.2, y: -0.8, width: 7.6, height: 7.6), skin)
        ellipse(&ctx, CGRect(x: -18.4, y: -18.4, width: 36.8, height: 36.8), skin)
        let hairPath = svgPath("M-18.6 0 A18.6 18.6 0 0 1 18.6 0 C14 -9 4 -11 -3 -8 C-9 -6 -15 -5 -18.6 0 Z")
        ctx.fill(hairPath, with: .color(hair))
        if hairStyle == 1 { ctx.fill(svgPath("M-3 -17 Q0 -27 6 -22 Q2 -20 3 -16 Z"), with: .color(hair)) }
        ellipse(&ctx, CGRect(x: -13.8, y: 4.7, width: 6.6, height: 6.6), Color(red: 1, green: 0.478, blue: 0.576).opacity(0.3))
        ellipse(&ctx, CGRect(x: 7.2, y: 4.7, width: 6.6, height: 6.6), Color(red: 1, green: 0.478, blue: 0.576).opacity(0.3))
        let blink = animate && Int((t * 2 + seedPhase).truncatingRemainder(dividingBy: 57)) == 0
        for x in [-6.8, 6.8] {
            if blink { var p = Path(); p.move(to: CGPoint(x: x - 2.7 + look, y: 1.5)); p.addLine(to: CGPoint(x: x + 2.7 + look, y: 1.5)); ctx.stroke(p, with: .color(Color(red: 0.102, green: 0.106, blue: 0.2)), lineWidth: 1.8) }
            else {
                ellipse(&ctx, CGRect(x: x - 2.7 + look, y: -1.9, width: 5.4, height: 6.8), Color(red: 0.102, green: 0.106, blue: 0.2))
                ellipse(&ctx, CGRect(x: x - 0.05 + look, y: -0.05, width: 1.9, height: 1.9), .white)
            }
        }
        let mouth = svgPath(mood == "flat" ? "M-3 8.5 L3 8.5" : mood == "calm" ? "M-3.5 8 Q0 9.8 3.5 8" : mood == "frown" ? "M-4.5 10.5 Q0 5.5 4.5 10.5" : "M-4.5 6.5 Q0 11 4.5 6.5")
        ctx.stroke(mouth, with: .color(Color(red: 0.29, green: 0.141, blue: 0.2)), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
        if sweat { ctx.fill(svgPath("M17 -7 q-4.5 6.5 0 9 q4.5 -2.5 0 -9z"), with: .color(Color(red: 0.49, green: 0.827, blue: 0.988).opacity(0.7 + 0.3 * sin(t * 6)))) }
        drawAccessory(&ctx)
    }

    private func drawAccessory(_ ctx: inout GraphicsContext) {
        switch role {
        case "Developer":
            var band = Path(); band.addArc(center: .zero, radius: 19, startAngle: .degrees(181), endAngle: .degrees(359), clockwise: false)
            ctx.stroke(band, with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)), lineWidth: 4)
            for x: CGFloat in [-20, 20] { ctx.fill(Path(roundedRect: CGRect(x: x - 4, y: -6, width: 8, height: 15), cornerRadius: 4), with: .color(accent)) }
        case "DevOps":
            ctx.fill(svgPath("M-20 -3 A20 20 0 0 1 20 -3 Z"), with: .color(Color(red: 0.98, green: 0.737, blue: 0.082)))
            ctx.fill(Path(roundedRect: CGRect(x: -24, y: -6, width: 48, height: 5.5), cornerRadius: 2.7), with: .color(Color(red: 0.918, green: 0.702, blue: 0.035)))
            ctx.fill(Path(roundedRect: CGRect(x: -3.5, y: -21, width: 7, height: 12), cornerRadius: 2), with: .color(Color(red: 0.918, green: 0.702, blue: 0.035)))
        case "QA", "Architect":
            drawGlasses(&ctx)
            if role == "Architect" { ctx.rotate(by: .degrees(25)); ctx.fill(Path(roundedRect: CGRect(x: 15, y: -16, width: 3.4, height: 15), cornerRadius: 1), with: .color(accent)) }
            else { antenna(&ctx) }
        case "Researcher":
            for x: CGFloat in [-7, 7] { ctx.stroke(Path(ellipseIn: CGRect(x: x - 6.6, y: -5.1, width: 13.2, height: 13.2)), with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)), lineWidth: 1.8) }
        case "Designer":
            ctx.rotate(by: .degrees(-9)); ellipse(&ctx, CGRect(x: -18, y: -22.5, width: 42, height: 17), Color(red: 0.882, green: 0.114, blue: 0.282)); ellipse(&ctx, CGRect(x: -11, y: -25.5, width: 28, height: 8), Color(red: 0.984, green: 0.443, blue: 0.522).opacity(0.55)); ellipse(&ctx, CGRect(x: 0.6, y: -25.4, width: 4.8, height: 4.8), Color(red: 0.745, green: 0.071, blue: 0.235))
        case "PM":
            var loop = Path(); loop.move(to: CGPoint(x: 18.5, y: 2)); loop.addQuadCurve(to: CGPoint(x: 8, y: 13), control: CGPoint(x: 21, y: 15)); ctx.stroke(loop, with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)), lineWidth: 2); ellipse(&ctx, CGRect(x: 5.4, y: 10.4, width: 5.2, height: 5.2), accent); ctx.fill(Path(roundedRect: CGRect(x: 16, y: -3, width: 5, height: 9), cornerRadius: 2.5), with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)))
        default: break
        }
    }
    private func drawGlasses(_ ctx: inout GraphicsContext) {
        for x: CGFloat in [-13, 2] { ctx.stroke(Path(roundedRect: CGRect(x: x, y: -3.5, width: 11, height: 9), cornerRadius: 2.5), with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)), lineWidth: 1.8) }
        var bridge = Path(); bridge.move(to: CGPoint(x: -2, y: 0.5)); bridge.addLine(to: CGPoint(x: 2, y: 0.5)); ctx.stroke(bridge, with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)), lineWidth: 1.8)
    }
    private func antenna(_ ctx: inout GraphicsContext) {
        let a = animate ? sin(t * 5 + seedPhase) * 8 : 0
        ctx.rotate(by: .degrees(a)); var p = Path(); p.move(to: CGPoint(x: 0, y: -17)); p.addLine(to: CGPoint(x: 5, y: -29)); ctx.stroke(p, with: .color(Color(red: 0.114, green: 0.129, blue: 0.278)), lineWidth: 2); ellipse(&ctx, CGRect(x: 1.2, y: -34.8, width: 7.6, height: 7.6), accent)
    }

    private var bubble: some View {
        let blocked = isBlocked
        let label = blocked ? (needsDeskRowAvoidance ? "Te necesita" : "Necesita tu respuesta") : placement.pose == .celebrating ? "Done" : shortActivity
        let color = blocked ? Color(hex: "ff5d6c") : agent.state == .idle ? Color(hex: "94a3b8") : Color(hex: "34d399")
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: "e8ebff")).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10).frame(height: 22)
        .background(Color(red: 0.035, green: 0.047, blue: 0.141).opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(blocked ? color.opacity(0.75 + 0.2 * sin(t * 6)) : .white.opacity(0.16), lineWidth: 1))
        .overlay(alignment: .bottom) {
            Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 10, y: 0)); p.addLine(to: CGPoint(x: 5, y: 6)); p.closeSubpath() }
                .fill(Color(red: 0.035, green: 0.047, blue: 0.141).opacity(0.92))
                .frame(width: 10, height: 6).offset(y: 5)
        }
        .fixedSize().shadow(color: isSelected ? accent.opacity(0.4) : .clear, radius: 5)
    }
    private var isBlocked: Bool { agent.state == .waiting || agent.state == .blocked || agent.state == .failed }
    private var isWorking: Bool { agent.state == .working || agent.state == .thinking }
    private var needsDeskRowAvoidance: Bool {
        guard placement.pose == .seatedTyping || placement.pose == .seatedThinking || placement.pose == .raisedHand else { return false }
        return [467, 549, 632].contains { abs(placement.position.y - CGFloat($0)) < 0.5 }
    }
    private func toolChip(_ tool: (String, Color)) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tool.1).frame(width: 6, height: 6)
            Text(tool.0).font(.system(size: 11, weight: .bold)).foregroundStyle(tool.1).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(Color(red: 0.031, green: 0.043, blue: 0.133).opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(tool.1, lineWidth: 1.3))
        .fixedSize()
    }
    private var nameTag: some View { Text(agent.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3).background(Color.black.opacity(0.78), in: Capsule()).fixedSize() }
    private var selectionMark: some View {
        ZStack {
            Ellipse().stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5])).frame(width: 60, height: 18).offset(y: 2)
            Path { p in p.move(to: CGPoint(x: 33, y: -28)); p.addLine(to: CGPoint(x: 47, y: -28)); p.addLine(to: CGPoint(x: 40, y: -18)); p.closeSubpath() }.fill(accent)
        }.frame(width: 80, height: 120).shadow(color: accent.opacity(0.7), radius: 7)
    }
    private var walkingSparkles: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(accent.opacity(0.7)).frame(width: 2.5, height: 2.5).offset(x: CGFloat((i * 13) % 24) - 12, y: -CGFloat((i * 17) % 30) - 10)
            }
        }.frame(width: 80, height: 120)
    }

    private func ellipse(_ ctx: inout GraphicsContext, _ rect: CGRect, _ color: Color) { ctx.fill(Path(ellipseIn: rect), with: .color(color)) }
    private func line(_ ctx: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, color: Color, width: CGFloat) { var p = Path(); p.move(to: a); p.addLine(to: b); ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)) }
    private func svgPath(_ data: String) -> Path { // SVG snippets above use only move/line/curve and arcs; common paths are explicit here.
        if data.hasPrefix("M-18.6") { var p = Path(); p.move(to: CGPoint(x: -18.6, y: 0)); p.addCurve(to: CGPoint(x: 18.6, y: 0), control1: CGPoint(x: -18.6, y: -10.3), control2: CGPoint(x: 18.6, y: -10.3)); p.addCurve(to: CGPoint(x: -3, y: -8), control1: CGPoint(x: 14, y: -9), control2: CGPoint(x: 4, y: -11)); p.addCurve(to: CGPoint(x: -18.6, y: 0), control1: CGPoint(x: -9, y: -6), control2: CGPoint(x: -15, y: -5)); p.closeSubpath(); return p }
        if data.hasPrefix("M-3 -17") { var p = Path(); p.move(to: CGPoint(x: -3, y: -17)); p.addQuadCurve(to: CGPoint(x: 6, y: -22), control: CGPoint(x: 0, y: -27)); p.addQuadCurve(to: CGPoint(x: 3, y: -16), control: CGPoint(x: 2, y: -20)); p.closeSubpath(); return p }
        if data.hasPrefix("M-4.5 6.5") { var p = Path(); p.move(to: CGPoint(x: -4.5, y: 6.5)); p.addQuadCurve(to: CGPoint(x: 4.5, y: 6.5), control: CGPoint(x: 0, y: 11)); return p }
        if data.hasPrefix("M-3.5 8") { var p = Path(); p.move(to: CGPoint(x: -3.5, y: 8)); p.addQuadCurve(to: CGPoint(x: 3.5, y: 8), control: CGPoint(x: 0, y: 9.8)); return p }
        if data.hasPrefix("M-4.5 10.5") { var p = Path(); p.move(to: CGPoint(x: -4.5, y: 10.5)); p.addQuadCurve(to: CGPoint(x: 4.5, y: 10.5), control: CGPoint(x: 0, y: 5.5)); return p }
        if data.hasPrefix("M-3 8.5") { var p = Path(); p.move(to: CGPoint(x: -3, y: 8.5)); p.addLine(to: CGPoint(x: 3, y: 8.5)); return p }
        if data.hasPrefix("M17 -7") { var p = Path(); p.move(to: CGPoint(x: 17, y: -7)); p.addQuadCurve(to: CGPoint(x: 17, y: 2), control: CGPoint(x: 12.5, y: -0.5)); p.addQuadCurve(to: CGPoint(x: 17, y: -7), control: CGPoint(x: 21.5, y: -0.5)); p.closeSubpath(); return p }
        if data.hasPrefix("M-20 -3") { var p = Path(); p.move(to: CGPoint(x: -20, y: -3)); p.addArc(center: .zero, radius: 20, startAngle: .degrees(189), endAngle: .degrees(-9), clockwise: false); p.closeSubpath(); return p }
        return Path()
    }

    private static let pants = Color(hex: "272b52")
    private static func role(for type: String) -> String {
        let type = type.lowercased()
        let exact: [String: String] = ["claude": "Developer", "codex": "Architect", "opencode": "DevOps", "gemini": "Researcher", "aider": "QA", "cursor-agent": "Designer", "amp": "PM", "goose": "DevOps"]
        if let role = exact[type] { return role }
        let roles = ["Developer", "QA", "DevOps", "Architect", "Researcher", "Designer", "PM"]
        var hash: UInt32 = 0
        for byte in type.utf16 { hash = (hash &* 31 &+ UInt32(byte)) }
        return roles[Int(hash % UInt32(roles.count))]
    }
}

private extension Color {
    init(hex: String) {
        let n = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255, opacity: 1)
    }
}

func office2DCharacterFrame(for placement: Office2DPlacement) -> CGRect {
    CGRect(x: placement.position.x - 40 * placement.scale, y: placement.position.y - 120 * placement.scale,
           width: 80 * placement.scale, height: 120 * placement.scale)
}

#Preview("Office2D characters") {
    HStack(alignment: .bottom, spacing: 12) {
        ForEach(Array([Office2DAgentState.working, .thinking, .blocked, .idle].enumerated()), id: \.offset) { index, state in
            let agent = Office2DAgent(id: "preview-\(index)", name: ["Claude", "Codex", "OpenCode", "Gemini"][index], kind: ["claude", "codex", "opencode", "gemini"][index], state: state, activity: "Editando Office2DCharacters.swift", seed: UInt64(index * 127 + 41))
            Office2DCharacterView(agent: agent, placement: Office2DPlacement(position: CGPoint(x: 40, y: 120), pose: state == .blocked ? .raisedHand : state == .idle ? .standingCoffee : .seatedTyping, facingLeft: false, scale: 1), date: Date(), animate: true, isSelected: false, isHovered: true)
                .frame(width: 80, height: 140).background(Color(hex: "171a2c"))
        }
    }.padding().background(Color(hex: "080b19"))
}
