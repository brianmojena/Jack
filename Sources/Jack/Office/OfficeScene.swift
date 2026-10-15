import AppKit
import JackCore
import SwiftUI

/// Palette shared by the office scene and the characters drawn above it.
enum OfficePalette {
    static let midnight = Color(red: 0.035, green: 0.047, blue: 0.10)
    static let wall = Color(red: 0.075, green: 0.082, blue: 0.16)
    static let indigo = Color(red: 0.18, green: 0.19, blue: 0.39)
    static let warmLight = Color(red: 1.0, green: 0.68, blue: 0.34)
    static let neon = Color(red: 0.39, green: 0.83, blue: 0.91)
    static let wood = Color(red: 0.27, green: 0.16, blue: 0.15)
    static let woodLight = Color(red: 0.48, green: 0.29, blue: 0.23)
    static let floor = Color(red: 0.13, green: 0.105, blue: 0.15)

    private static let agentColors: [Color] = [
        Color(red: 0.35, green: 0.78, blue: 0.91), Color(red: 0.77, green: 0.48, blue: 0.94),
        Color(red: 0.98, green: 0.57, blue: 0.40), Color(red: 0.36, green: 0.82, blue: 0.65),
        Color(red: 0.98, green: 0.76, blue: 0.34), Color(red: 0.96, green: 0.48, blue: 0.68),
        Color(red: 0.47, green: 0.61, blue: 0.98), Color(red: 0.69, green: 0.83, blue: 0.42),
        Color(red: 0.34, green: 0.78, blue: 0.78), Color(red: 0.92, green: 0.63, blue: 0.83)
    ]

    static func agentColor(seed: UInt64) -> Color {
        agentColors[Int(seed % UInt64(agentColors.count))]
    }

    static func stateColor(_ s: OfficeAgentState) -> Color {
        switch s {
        case .working: Color(red: 0.28, green: 0.82, blue: 0.67)
        case .thinking: Color(red: 0.69, green: 0.52, blue: 0.96)
        case .waiting: Color(red: 1.0, green: 0.69, blue: 0.31)
        case .blocked: Color(red: 0.96, green: 0.43, blue: 0.29)
        case .idle: Color(red: 0.49, green: 0.58, blue: 0.70)
        case .failed: Color(red: 0.94, green: 0.30, blue: 0.35)
        }
    }
}

struct OfficeSceneView: View {
    let layout: OfficeLayout
    let agentsByDesk: [OfficeAgent?]
    let date: Date
    let animate: Bool

    var body: some View {
        Canvas(opaque: true, colorMode: .linear) { context, canvasSize in
            let bounds = CGRect(origin: .zero, size: layout.size == .zero ? canvasSize : layout.size)
            let time = animate ? date.timeIntervalSinceReferenceDate : 0
            drawRoom(in: &context, bounds: bounds, floorY: layout.floorY, date: date, time: time)
            for (index, slot) in layout.desks.enumerated() {
                let agent = index < agentsByDesk.count ? agentsByDesk[index] : nil
                drawDesk(slot, agent: agent, in: &context, time: time)
            }
            drawLounge(layout.loungeFrame, in: &context, time: time)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .accessibilityLabel("Oficina nocturna de Jack")
    }

    private func drawRoom(in ctx: inout GraphicsContext, bounds: CGRect, floorY: CGFloat, date: Date, time: TimeInterval) {
        let hour = Calendar.current.component(.hour, from: date)
        let daylight: CGFloat = hour >= 7 && hour < 17 ? 1 : (hour >= 17 && hour < 20 ? 0.5 : 0)
        let skyTop = mix(OfficePalette.midnight, Color(red: 0.16, green: 0.22, blue: 0.34), daylight)
        let skyBottom = mix(OfficePalette.wall, Color(red: 0.35, green: 0.28, blue: 0.30), daylight)
        let wallRect = CGRect(x: 0, y: 0, width: bounds.width, height: floorY)
        ctx.fill(Path(wallRect), with: .linearGradient(Gradient(colors: [skyTop, skyBottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: floorY)))

        // Soft architectural panels and a low warm horizon.
        for i in 0..<6 {
            let x = bounds.width * CGFloat(i) / 6
            var seam = Path(); seam.move(to: CGPoint(x: x, y: 0)); seam.addLine(to: CGPoint(x: x, y: floorY))
            ctx.stroke(seam, with: .color(.white.opacity(0.025)), lineWidth: 1)
        }
        ctx.fill(Path(ellipseIn: CGRect(x: bounds.width * 0.12, y: floorY * 0.58, width: bounds.width * 0.76, height: floorY * 0.45)), with: .radialGradient(Gradient(colors: [OfficePalette.warmLight.opacity(0.09), .clear]), center: CGPoint(x: bounds.midX, y: floorY * 0.78), startRadius: 2, endRadius: bounds.width * 0.48))

        drawWindow(at: CGRect(x: bounds.width * 0.045, y: floorY * 0.12, width: bounds.width * 0.27, height: floorY * 0.61), in: &ctx, time: time, offset: 0)
        drawWindow(at: CGRect(x: bounds.width * 0.685, y: floorY * 0.12, width: bounds.width * 0.27, height: floorY * 0.61), in: &ctx, time: time, offset: 2.7)
        drawClock(in: &ctx, center: CGPoint(x: bounds.midX, y: floorY * 0.27), date: date)
        drawNeonSign(in: &ctx, center: CGPoint(x: bounds.midX, y: floorY * 0.58), width: min(100, bounds.width * 0.16))
        drawPendant(at: CGPoint(x: bounds.width * 0.36, y: floorY * 0.04), drop: floorY * 0.31, in: &ctx)
        drawPendant(at: CGPoint(x: bounds.width * 0.64, y: floorY * 0.04), drop: floorY * 0.31, in: &ctx)
        drawPlant(at: CGPoint(x: bounds.width * 0.035, y: floorY + 5), scale: 0.9, time: time, in: &ctx)
        drawPlant(at: CGPoint(x: bounds.width * 0.96, y: floorY + 8), scale: 0.78, time: time + 1.3, in: &ctx)

        // Floor plane with perspective boards and a vignette at the room edges.
        let floorRect = CGRect(x: 0, y: floorY, width: bounds.width, height: max(0, bounds.height - floorY))
        ctx.fill(Path(floorRect), with: .linearGradient(Gradient(colors: [OfficePalette.floor, Color(red: 0.105, green: 0.075, blue: 0.12)]), startPoint: CGPoint(x: 0, y: floorY), endPoint: CGPoint(x: 0, y: bounds.maxY)))
        var horizon = Path(); horizon.move(to: CGPoint(x: 0, y: floorY)); horizon.addLine(to: CGPoint(x: bounds.maxX, y: floorY))
        ctx.stroke(horizon, with: .color(OfficePalette.warmLight.opacity(0.22)), lineWidth: 1)
        for row in 1...6 {
            let p = CGFloat(row) / 6
            let y = floorY + (bounds.height - floorY) * p * p
            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: bounds.maxX, y: y))
            ctx.stroke(line, with: .color(OfficePalette.woodLight.opacity(0.13 * p)), lineWidth: 1)
        }
        for i in -1...7 {
            let x = bounds.width * CGFloat(i) / 6
            var plank = Path(); plank.move(to: CGPoint(x: bounds.midX + (x - bounds.midX) * 0.16, y: floorY)); plank.addLine(to: CGPoint(x: x, y: bounds.maxY))
            ctx.stroke(plank, with: .color(OfficePalette.woodLight.opacity(0.11)), lineWidth: 1)
        }
        ctx.fill(Path(bounds), with: .radialGradient(Gradient(colors: [.clear, Color.black.opacity(0.22)]), center: CGPoint(x: bounds.midX, y: bounds.midY), startRadius: bounds.width * 0.28, endRadius: bounds.width * 0.78))
    }

    private func drawWindow(at rect: CGRect, in ctx: inout GraphicsContext, time: TimeInterval, offset: Double) {
        let radius: CGFloat = 7
        let outer = Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: radius + 3)
        ctx.fill(outer, with: .color(Color(red: 0.16, green: 0.19, blue: 0.30)))
        let glass = Path(roundedRect: rect, cornerRadius: radius)
        ctx.fill(glass, with: .linearGradient(Gradient(colors: [Color(red: 0.035, green: 0.07, blue: 0.16), Color(red: 0.10, green: 0.13, blue: 0.23)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        ctx.drawLayer { layer in
            layer.clip(to: glass)
            let cityBase = rect.maxY * 0.89
            let buildingCount = 11
            for i in 0..<buildingCount {
                let seed = i * 37 + (offset == 0 ? 0 : 17)
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(buildingCount)
                let width = rect.width / CGFloat(buildingCount) * 0.8
                let height = rect.height * (0.16 + CGFloat((seed * 13) % 38) / 100)
                let building = CGRect(x: x, y: cityBase - height, width: width, height: height + rect.height * 0.14)
                layer.fill(Path(building), with: .color(Color(red: 0.07, green: 0.09, blue: 0.16)))
                for row in 0..<max(2, Int(height / 10)) {
                    for col in 0..<2 {
                        let hash = (seed * 31 + row * 17 + col * 13) % 11
                        guard hash < 4 else { continue }
                        let pulse = 0.62 + 0.25 * sin(time * 0.22 + Double(seed + row * 9 + col))
                        let light = CGRect(x: x + 2 + CGFloat(col) * (width * 0.42), y: cityBase - height + 5 + CGFloat(row) * 8, width: max(1.5, width * 0.19), height: 2.2)
                        layer.fill(Path(light), with: .color((hash == 0 ? OfficePalette.neon : OfficePalette.warmLight).opacity(pulse)))
                    }
                }
            }
            // Deterministic stars, slowly breathing without per-frame random generation.
            for i in 0..<24 {
                let fx = CGFloat((i * 47 + 13) % 97) / 100
                let fy = CGFloat((i * 29 + 7) % 59) / 100
                let r: CGFloat = i % 7 == 0 ? 1.2 : 0.65
                let alpha = 0.25 + 0.18 * (0.5 + 0.5 * sin(time * 0.18 + Double(i) * 1.7))
                let star = CGRect(x: rect.minX + fx * rect.width, y: rect.minY + fy * rect.height * 0.65, width: r * 2, height: r * 2)
                layer.fill(Path(ellipseIn: star), with: .color(Color.white.opacity(alpha)))
            }
        }
        var mullion = Path(); mullion.move(to: CGPoint(x: rect.midX, y: rect.minY)); mullion.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        mullion.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.68)); mullion.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.68))
        ctx.stroke(mullion, with: .color(Color(red: 0.28, green: 0.31, blue: 0.43)), lineWidth: 3)
        ctx.stroke(Path(roundedRect: rect, cornerRadius: radius), with: .color(Color.white.opacity(0.12)), lineWidth: 1)
    }

    private func drawClock(in ctx: inout GraphicsContext, center: CGPoint, date: Date) {
        let radius: CGFloat = 22
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius - 3, y: center.y - radius - 3, width: (radius + 3) * 2, height: (radius + 3) * 2)), with: .color(Color.black.opacity(0.22)))
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(Color(red: 0.12, green: 0.14, blue: 0.23)))
        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(OfficePalette.warmLight.opacity(0.55)), lineWidth: 1.2)
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = CGFloat(components.hour ?? 0) + CGFloat(components.minute ?? 0) / 60
        let minute = CGFloat(components.minute ?? 0) + CGFloat(components.second ?? 0) / 60
        hand(ctx: &ctx, center: center, length: radius * 0.46, angle: hour / 12 * 2 * .pi, color: .white.opacity(0.85), width: 2)
        hand(ctx: &ctx, center: center, length: radius * 0.68, angle: minute / 60 * 2 * .pi, color: OfficePalette.warmLight, width: 1.3)
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(OfficePalette.warmLight))
    }

    private func drawNeonSign(in ctx: inout GraphicsContext, center: CGPoint, width: CGFloat) {
        let rect = CGRect(x: center.x - width / 2, y: center.y - 12, width: width, height: 25)
        ctx.fill(Path(roundedRect: rect.insetBy(dx: -5, dy: -4), cornerRadius: 7), with: .color(Color.black.opacity(0.25)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(OfficePalette.neon.opacity(0.4)), lineWidth: 1)
        text("JACK", at: center, size: 15, color: OfficePalette.neon, weight: .bold, ctx: &ctx, glow: true)
    }

    private func drawPendant(at point: CGPoint, drop: CGFloat, in ctx: inout GraphicsContext) {
        var wire = Path(); wire.move(to: point); wire.addLine(to: CGPoint(x: point.x, y: point.y + drop - 4))
        ctx.stroke(wire, with: .color(Color.black.opacity(0.55)), lineWidth: 1)
        let shade = CGRect(x: point.x - 12, y: point.y + drop - 8, width: 24, height: 13)
        ctx.fill(Path(ellipseIn: CGRect(x: point.x - 50, y: point.y + drop - 4, width: 100, height: 58)), with: .radialGradient(Gradient(colors: [OfficePalette.warmLight.opacity(0.16), .clear]), center: CGPoint(x: point.x, y: point.y + drop), startRadius: 1, endRadius: 52))
        ctx.fill(Path(roundedRect: shade, cornerRadius: 5), with: .color(Color(red: 0.28, green: 0.23, blue: 0.24)))
        ctx.fill(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y + drop - 1, width: 14, height: 3)), with: .color(OfficePalette.warmLight.opacity(0.9)))
    }

    private func drawDesk(_ slot: OfficeDeskSlot, agent: OfficeAgent?, in ctx: inout GraphicsContext, time: TimeInterval) {
        let f = slot.deskFrame
        guard f.width > 0 && f.height > 0 else { return }
        let s = max(0.35, slot.scale)
        let topY = f.maxY - f.height * 0.31
        let top = CGRect(x: f.minX, y: topY, width: f.width, height: max(5, f.height * 0.1))
        let shadow = CGRect(x: f.minX + f.width * 0.04, y: top.maxY + 2, width: f.width * 0.92, height: f.height * 0.12)
        ctx.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.30)))
        // Back legs and chair are behind the seat/person position.
        let chairW = f.width * 0.22
        let chairRect = CGRect(x: slot.seat.x - chairW / 2, y: topY + f.height * 0.12, width: chairW, height: f.height * 0.23)
        ctx.fill(Path(roundedRect: chairRect, cornerRadius: 7 * s), with: .color(Color(red: 0.10, green: 0.12, blue: 0.20)))
        ctx.stroke(Path(roundedRect: chairRect, cornerRadius: 7 * s), with: .color(Color.white.opacity(0.09)), lineWidth: 1)
        var legs = Path()
        legs.move(to: CGPoint(x: top.minX + top.width * 0.1, y: top.maxY)); legs.addLine(to: CGPoint(x: top.minX + top.width * 0.14, y: f.maxY))
        legs.move(to: CGPoint(x: top.maxX - top.width * 0.1, y: top.maxY)); legs.addLine(to: CGPoint(x: top.maxX - top.width * 0.14, y: f.maxY))
        ctx.stroke(legs, with: .color(OfficePalette.wood.opacity(0.9)), lineWidth: max(2, 3 * s))
        ctx.fill(Path(top), with: .linearGradient(Gradient(colors: [OfficePalette.woodLight, OfficePalette.wood]), startPoint: top.origin, endPoint: CGPoint(x: top.minX, y: top.maxY)))
        let lip = CGRect(x: top.minX, y: top.maxY - 1, width: top.width, height: max(2, top.height * 0.28))
        ctx.fill(Path(lip), with: .color(Color(red: 0.22, green: 0.13, blue: 0.14)))
        ctx.stroke(Path(CGRect(x: top.minX, y: top.minY, width: top.width, height: top.height)), with: .color(Color(red: 0.74, green: 0.48, blue: 0.34).opacity(0.38)), lineWidth: 0.8)

        let monitorW = f.width * 0.36
        let screen = CGRect(x: f.midX - monitorW / 2, y: f.minY + f.height * 0.04, width: monitorW, height: f.height * 0.21)
        drawMonitor(screen, agent: agent, time: time, scale: s, in: &ctx)
        let stand = CGRect(x: screen.midX - screen.width * 0.11, y: screen.maxY, width: screen.width * 0.22, height: max(3, top.minY - screen.maxY))
        ctx.fill(Path(stand), with: .color(Color(red: 0.18, green: 0.19, blue: 0.25)))
        let foot = CGRect(x: screen.midX - screen.width * 0.22, y: top.minY - 2, width: screen.width * 0.44, height: 3)
        ctx.fill(Path(roundedRect: foot, cornerRadius: 1.5), with: .color(Color(red: 0.21, green: 0.22, blue: 0.28)))

        let keyboard = CGRect(x: f.midX - f.width * 0.14, y: top.minY + top.height * 0.12, width: f.width * 0.28, height: max(3, top.height * 0.22))
        ctx.fill(Path(roundedRect: keyboard, cornerRadius: 2), with: .color(Color(red: 0.10, green: 0.12, blue: 0.17)))
        for key in 0..<9 {
            let x = keyboard.minX + keyboard.width * CGFloat(key) / 9 + 1
            var keyline = Path(); keyline.move(to: CGPoint(x: x, y: keyboard.minY + 1)); keyline.addLine(to: CGPoint(x: x, y: keyboard.maxY - 1))
            ctx.stroke(keyline, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
        }
        drawCoffee(at: CGPoint(x: top.minX + top.width * 0.16, y: top.minY + top.height * 0.3), size: max(5, f.width * 0.055), in: &ctx)
        drawDeskLamp(at: CGPoint(x: top.maxX - top.width * 0.15, y: top.minY), scale: s, in: &ctx)
        if let agent {
            let plate = CGRect(x: top.midX - f.width * 0.18, y: top.maxY - 0.5, width: f.width * 0.36, height: max(7, top.height * 0.8))
            ctx.fill(Path(roundedRect: plate, cornerRadius: 2), with: .color(Color(red: 0.13, green: 0.16, blue: 0.23)))
            text(agent.name.uppercased(), at: CGPoint(x: plate.midX, y: plate.midY), size: min(7, max(4.5, plate.height * 0.54)), color: OfficePalette.agentColor(seed: agent.seed).opacity(0.95), weight: .semibold, ctx: &ctx)
        }
    }

    private func drawMonitor(_ rect: CGRect, agent: OfficeAgent?, time: TimeInterval, scale: CGFloat, in ctx: inout GraphicsContext) {
        let casing = Path(roundedRect: rect.insetBy(dx: -3 * scale, dy: -3 * scale), cornerRadius: 5 * scale)
        ctx.fill(casing, with: .color(Color(red: 0.075, green: 0.09, blue: 0.14)))
        ctx.stroke(casing, with: .color(Color.white.opacity(0.13)), lineWidth: 0.8)
        let screen = rect.insetBy(dx: 2 * scale, dy: 2 * scale)
        let screenPath = Path(roundedRect: screen, cornerRadius: 2.5 * scale)
        guard let agent else { ctx.fill(screenPath, with: .color(Color(red: 0.025, green: 0.034, blue: 0.06))); return }
        let accent = OfficePalette.agentColor(seed: agent.seed)
        let bg = Path(roundedRect: screen, cornerRadius: 2.5 * scale)
        ctx.fill(bg, with: .color(Color(red: 0.025, green: 0.04, blue: 0.08)))
        ctx.drawLayer { layer in
            layer.clip(to: screenPath)
            switch agent.state {
        case .working:
            for row in 0..<7 {
                let offset = CGFloat((Double(row) * 2.3 + time * 8).truncatingRemainder(dividingBy: 12))
                let y = screen.maxY - offset - CGFloat(row % 3) * 3
                let widths: [CGFloat] = [0.54, 0.75, 0.42, 0.64, 0.32, 0.7, 0.48]
                let line = CGRect(x: screen.minX + 3 * scale, y: y, width: screen.width * widths[row], height: max(0.7, 1 * scale))
                layer.fill(Path(roundedRect: line, cornerRadius: 0.5), with: .color([accent, OfficePalette.neon, OfficePalette.stateColor(.thinking)].map { $0.opacity(0.75) }[row % 3]))
            }
            let blink = sin(time * 4) > 0
            if blink { layer.fill(Path(CGRect(x: screen.minX + 3, y: screen.maxY - 3, width: 2, height: 2)), with: .color(accent)) }
        case .thinking:
            let pulse = 0.7 + 0.3 * sin(time * 2.6)
            for i in 0..<5 {
                let angle = Double(i) * 2 * .pi / 5 + time * 0.4
                let center = CGPoint(x: screen.midX + cos(angle) * screen.width * 0.22, y: screen.midY + sin(angle) * screen.height * 0.23)
                let size = CGFloat(2 + (i % 2)) * scale * pulse
                layer.fill(Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)), with: .color(accent.opacity(0.9)))
            }
            layer.stroke(Path(ellipseIn: screen.insetBy(dx: screen.width * 0.26, dy: screen.height * 0.2)), with: .color(accent.opacity(0.25 + 0.25 * pulse)), lineWidth: 1)
        case .waiting, .blocked:
            layer.fill(Path(screen), with: .color(OfficePalette.stateColor(agent.state).opacity(0.10)))
            text("!", at: CGPoint(x: screen.midX, y: screen.midY + 0.5), size: min(screen.height * 0.78, 18), color: OfficePalette.stateColor(agent.state), weight: .bold, ctx: &layer, glow: true)
        case .failed:
            layer.fill(Path(screen), with: .color(Color(red: 0.22, green: 0.035, blue: 0.06).opacity(0.8)))
            text("×", at: CGPoint(x: screen.midX, y: screen.midY), size: min(screen.height * 0.8, 17), color: OfficePalette.stateColor(.failed).opacity(0.85), weight: .medium, ctx: &layer)
        case .idle:
            for i in 0..<7 {
                let x = screen.minX + screen.width * CGFloat((i * 17 + 8) % 91) / 100
                let y = screen.minY + screen.height * CGFloat((i * 29 + 11) % 81) / 100
                layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(accent.opacity(0.36)))
            }
        }
        }
        ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - 1, y: rect.maxY - 1.7, width: 2, height: 2)), with: .color(accent.opacity(0.7)))
    }

    private func drawCoffee(at point: CGPoint, size: CGFloat, in ctx: inout GraphicsContext) {
        let cup = CGRect(x: point.x - size / 2, y: point.y - size * 0.35, width: size * 0.78, height: size * 0.62)
        ctx.fill(Path(roundedRect: cup, cornerRadius: 2), with: .color(Color(red: 0.78, green: 0.75, blue: 0.68)))
        ctx.fill(Path(ellipseIn: CGRect(x: cup.minX + 1, y: cup.minY, width: cup.width - 2, height: 2)), with: .color(Color(red: 0.20, green: 0.12, blue: 0.10)))
        var handle = Path(); handle.addEllipse(in: CGRect(x: cup.maxX - 1, y: cup.midY - size * 0.13, width: size * 0.28, height: size * 0.3))
        ctx.stroke(handle, with: .color(Color(red: 0.78, green: 0.75, blue: 0.68)), lineWidth: 1.2)
    }

    private func drawDeskLamp(at point: CGPoint, scale: CGFloat, in ctx: inout GraphicsContext) {
        let glow = CGRect(x: point.x - 25 * scale, y: point.y - 34 * scale, width: 50 * scale, height: 39 * scale)
        ctx.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [OfficePalette.warmLight.opacity(0.15), .clear]), center: CGPoint(x: point.x, y: point.y - 15 * scale), startRadius: 1, endRadius: 28 * scale))
        var stem = Path(); stem.move(to: point); stem.addLine(to: CGPoint(x: point.x + 1 * scale, y: point.y - 18 * scale)); stem.addLine(to: CGPoint(x: point.x + 10 * scale, y: point.y - 27 * scale))
        ctx.stroke(stem, with: .color(Color(red: 0.18, green: 0.20, blue: 0.25)), lineWidth: 2 * scale)
        let shade = CGRect(x: point.x + 4 * scale, y: point.y - 32 * scale, width: 14 * scale, height: 8 * scale)
        ctx.fill(Path(roundedRect: shade, cornerRadius: 3 * scale), with: .color(Color(red: 0.30, green: 0.28, blue: 0.31)))
        ctx.fill(Path(ellipseIn: CGRect(x: shade.minX + 3, y: shade.maxY - 1, width: 8 * scale, height: 2)), with: .color(OfficePalette.warmLight.opacity(0.9)))
    }

    private func drawLounge(_ frame: CGRect, in ctx: inout GraphicsContext, time: TimeInterval) {
        guard frame.width > 0 && frame.height > 0 else { return }
        let rug = CGRect(x: frame.minX + frame.width * 0.04, y: frame.maxY - frame.height * 0.14, width: frame.width * 0.92, height: frame.height * 0.13)
        ctx.fill(Path(ellipseIn: rug), with: .color(Color(red: 0.25, green: 0.18, blue: 0.28).opacity(0.8)))
        ctx.stroke(Path(ellipseIn: rug.insetBy(dx: 5, dy: 2)), with: .color(OfficePalette.neon.opacity(0.16)), lineWidth: 1)
        let sofa = CGRect(x: frame.minX + frame.width * 0.10, y: frame.minY + frame.height * 0.44, width: frame.width * 0.53, height: frame.height * 0.34)
        ctx.fill(Path(roundedRect: sofa.offsetBy(dx: 0, dy: 4), cornerRadius: 9), with: .color(.black.opacity(0.24)))
        ctx.fill(Path(roundedRect: sofa, cornerRadius: 9), with: .linearGradient(Gradient(colors: [Color(red: 0.24, green: 0.23, blue: 0.39), Color(red: 0.15, green: 0.16, blue: 0.29)]), startPoint: sofa.origin, endPoint: CGPoint(x: sofa.minX, y: sofa.maxY)))
        ctx.fill(Path(roundedRect: CGRect(x: sofa.minX - 4, y: sofa.minY + sofa.height * 0.44, width: 12, height: sofa.height * 0.52), cornerRadius: 6), with: .color(Color(red: 0.20, green: 0.20, blue: 0.34)))
        ctx.fill(Path(roundedRect: CGRect(x: sofa.maxX - 8, y: sofa.minY + sofa.height * 0.44, width: 12, height: sofa.height * 0.52), cornerRadius: 6), with: .color(Color(red: 0.20, green: 0.20, blue: 0.34)))
        let cushion = CGRect(x: sofa.minX + sofa.width * 0.12, y: sofa.minY + sofa.height * 0.10, width: sofa.width * 0.34, height: sofa.height * 0.52)
        ctx.fill(Path(roundedRect: cushion, cornerRadius: 6), with: .color(Color(red: 0.32, green: 0.30, blue: 0.48)))
        ctx.fill(Path(roundedRect: cushion.offsetBy(dx: cushion.width * 0.95, dy: 0), cornerRadius: 6), with: .color(Color(red: 0.27, green: 0.28, blue: 0.44)))

        let table = CGRect(x: frame.minX + frame.width * 0.20, y: frame.minY + frame.height * 0.80, width: frame.width * 0.39, height: frame.height * 0.055)
        ctx.fill(Path(roundedRect: table, cornerRadius: 3), with: .color(OfficePalette.woodLight))
        var tableLegs = Path(); tableLegs.move(to: CGPoint(x: table.minX + 5, y: table.maxY)); tableLegs.addLine(to: CGPoint(x: table.minX + 7, y: frame.maxY - frame.height * 0.04)); tableLegs.move(to: CGPoint(x: table.maxX - 5, y: table.maxY)); tableLegs.addLine(to: CGPoint(x: table.maxX - 7, y: frame.maxY - frame.height * 0.04))
        ctx.stroke(tableLegs, with: .color(OfficePalette.wood), lineWidth: 2)
        drawCoffee(at: CGPoint(x: table.midX, y: table.minY), size: max(7, frame.width * 0.045), in: &ctx)

        let machine = CGRect(x: frame.minX + frame.width * 0.70, y: frame.minY + frame.height * 0.46, width: frame.width * 0.20, height: frame.height * 0.34)
        ctx.fill(Path(roundedRect: machine, cornerRadius: 5), with: .linearGradient(Gradient(colors: [Color(red: 0.18, green: 0.21, blue: 0.29), Color(red: 0.08, green: 0.10, blue: 0.16)]), startPoint: machine.origin, endPoint: CGPoint(x: machine.maxX, y: machine.maxY)))
        let brew = CGRect(x: machine.minX + machine.width * 0.17, y: machine.minY + machine.height * 0.15, width: machine.width * 0.66, height: machine.height * 0.28)
        ctx.fill(Path(roundedRect: brew, cornerRadius: 3), with: .color(Color(red: 0.035, green: 0.05, blue: 0.085)))
        ctx.fill(Path(ellipseIn: CGRect(x: brew.midX - 2, y: brew.midY - 2, width: 4, height: 4)), with: .color(OfficePalette.neon.opacity(0.75)))
        for i in 0..<3 {
            let x = brew.midX + CGFloat(i - 1) * 4
            let phase = time * 1.5 + Double(i) * 1.4
            let rise = CGFloat((sin(phase) + 1) * 0.5) * 8
            var vapor = Path(); vapor.move(to: CGPoint(x: x, y: brew.maxY + 1 - rise)); vapor.addCurve(to: CGPoint(x: x + 2, y: brew.maxY - 7 - rise), control1: CGPoint(x: x - 3, y: brew.maxY - 2 - rise), control2: CGPoint(x: x + 5, y: brew.maxY - 5 - rise))
            ctx.stroke(vapor, with: .color(Color.white.opacity(0.16)), lineWidth: 1)
        }
        drawPlant(at: CGPoint(x: frame.maxX - frame.width * 0.02, y: frame.maxY - frame.height * 0.10), scale: 1.2, time: time + 0.8, in: &ctx)
    }

    private func drawPlant(at base: CGPoint, scale: CGFloat, time: TimeInterval, in ctx: inout GraphicsContext) {
        let sway = CGFloat(sin(time * 0.52)) * 2.2 * scale
        let pot = CGRect(x: base.x - 11 * scale, y: base.y - 13 * scale, width: 22 * scale, height: 14 * scale)
        ctx.fill(Path(roundedRect: pot, cornerRadius: 3 * scale), with: .color(Color(red: 0.34, green: 0.21, blue: 0.20)))
        ctx.fill(Path(roundedRect: CGRect(x: pot.minX - 2, y: pot.minY - 2, width: pot.width + 4, height: 4 * scale), cornerRadius: 2), with: .color(Color(red: 0.48, green: 0.30, blue: 0.25)))
        for i in 0..<7 {
            let side: CGFloat = i.isMultiple(of: 2) ? -1 : 1
            let height = CGFloat(17 + (i * 7) % 12) * scale
            let root = CGPoint(x: base.x + CGFloat(i - 3) * 2.2 * scale, y: pot.minY + 1)
            let tip = CGPoint(x: root.x + side * CGFloat(7 + i % 3) * scale + sway, y: root.y - height)
            var leaf = Path(); leaf.move(to: root); leaf.addQuadCurve(to: tip, control: CGPoint(x: root.x + side * 3 * scale + sway * 0.5, y: root.y - height * 0.62))
            ctx.stroke(leaf, with: .color(Color(red: 0.23, green: 0.49, blue: 0.39).opacity(0.95)), lineWidth: 2.1 * scale)
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 3 * scale, y: tip.y - 2 * scale, width: 6 * scale, height: 3 * scale).offsetBy(dx: side * 1.2 * scale, dy: 0)), with: .color(Color(red: 0.28, green: 0.58, blue: 0.45)))
        }
    }

    private func hand(ctx: inout GraphicsContext, center: CGPoint, length: CGFloat, angle: CGFloat, color: Color, width: CGFloat) {
        var path = Path(); path.move(to: center); path.addLine(to: CGPoint(x: center.x + sin(angle) * length, y: center.y - cos(angle) * length))
        ctx.stroke(path, with: .color(color), lineWidth: width)
    }

    private func text(_ value: String, at point: CGPoint, size: CGFloat, color: Color, weight: Font.Weight = .regular, ctx: inout GraphicsContext, glow: Bool = false) {
        let resolved = ctx.resolve(Text(value).font(.system(size: size, weight: weight, design: .rounded)).foregroundColor(color))
        if glow { ctx.drawLayer { layer in layer.addFilter(.blur(radius: 5)); layer.draw(resolved, at: point) } }
        ctx.draw(resolved, at: point)
    }

    private func mix(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        let t = min(1, max(0, t))
        return Color(red: component(a, 0) * (1 - t) + component(b, 0) * t, green: component(a, 1) * (1 - t) + component(b, 1) * t, blue: component(a, 2) * (1 - t) + component(b, 2) * t)
    }

    private func component(_ color: Color, _ index: Int) -> CGFloat {
        #if os(macOS)
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        let values = [ns.redComponent, ns.greenComponent, ns.blueComponent]
        return values[index]
        #else
        return 0
        #endif
    }
}

#Preview("Oficina") {
    let size = CGSize(width: 960, height: 620)
    let desks = (0..<4).map { i in
        let x = CGFloat(i % 2) * 320 + 110
        let y = CGFloat(i / 2) * 190 + 275
        return OfficeDeskSlot(index: i, deskFrame: CGRect(x: x, y: y, width: 250, height: 160), seat: CGPoint(x: x + 125, y: y + 145), scale: 0.82)
    }
    let layout = OfficeLayout(size: size, desks: desks, loungeFrame: CGRect(x: 725, y: 345, width: 210, height: 210), loungeSpots: [], floorY: 190)
    let agents: [OfficeAgent?] = [
        OfficeAgent(id: "codex", name: "Codex", kind: "codex", state: .working, activity: "Editando escena", seed: 8),
        OfficeAgent(id: "claude", name: "Claude", kind: "claude", state: .thinking, activity: "Razonando", seed: 14),
        OfficeAgent(id: "opencode", name: "OpenCode", kind: "opencode", state: .waiting, activity: "Esperando", seed: 29),
        OfficeAgent(id: "review", name: "Review", kind: "codex", state: .idle, activity: nil, seed: 42)
    ]
    OfficeSceneView(layout: layout, agentsByDesk: agents, date: .now, animate: true)
        .frame(width: size.width, height: size.height)
}
