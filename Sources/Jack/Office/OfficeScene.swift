import AppKit
import JackCore
import SwiftUI

/// Colors translated directly from behaviors.js and office.js.
enum OfficePalette {
    static let ROLE_COLORS: [String: Color] = [
        "Developer": Color(hex: "38bdf8"), "QA": Color(hex: "a3e635"), "DevOps": Color(hex: "fb923c"),
        "Architect": Color(hex: "a78bfa"), "Researcher": Color(hex: "2dd4bf"), "Designer": Color(hex: "f472b6"), "PM": Color(hex: "facc15")
    ]
    static let STATE_COLORS: [String: Color] = ["working": Color(hex: "34d399"), "idle": Color(hex: "94a3b8"), "blocked": Color(hex: "ff5d6c")]
    static let SHIRTS = ["6366f1", "ec4899", "14b8a6", "f59e0b", "8b5cf6", "ef4444", "22c55e", "0ea5e9", "d946ef", "f97316", "84cc16", "06b6d4"].map(Color.init(hex:))
    static let SKINS = ["ffd9b8", "f1c27d", "e0ac69", "c68642", "8d5524", "ffe0c4"].map(Color.init(hex:))
    static let HAIRS = ["2b1d0e", "5a3825", "b5651d", "e6c15a", "1f1f2e", "9b2d30", "c9c9d9"].map(Color.init(hex:))

    static func agentColor(seed: UInt64) -> Color { SHIRTS[Int(seed % UInt64(SHIRTS.count))] }
    static func stateColor(_ s: OfficeAgentState) -> Color {
        switch s {
        case .working, .thinking: STATE_COLORS["working"]!
        case .waiting, .blocked, .failed: STATE_COLORS["blocked"]!
        case .idle: STATE_COLORS["idle"]!
        }
    }
}

struct OfficeSceneView: View {
    let layout: OfficeLayout
    let agentsByDesk: [OfficeAgent?]
    let date: Date
    let animate: Bool

    /// Overscan so the wall and floor keep going past the world edges, like the web's viewBox with `slice`.
    static let overscan = CGSize(width: 700, height: 420)

    var body: some View {
        let m = Self.overscan
        Canvas(opaque: true, colorMode: .nonLinear) { context, _ in
            context.translateBy(x: m.width, y: m.height)
            let time = animate ? date.timeIntervalSinceReferenceDate : 0
            drawRoom(&context, time: time, date: date)
            drawDecor(&context, time: time)
            for slot in layout.desks {
                let agent = agentsByDesk.indices.contains(slot.index) ? agentsByDesk[slot.index] : nil
                drawDesk(&context, slot: slot, agent: agent, time: time)
            }
            drawAmbient(&context, time: time)
        }
        .frame(width: OfficeNav.world.width + m.width * 2, height: OfficeNav.world.height + m.height * 2)
        .frame(width: OfficeNav.world.width, height: OfficeNav.world.height)
        .accessibilityLabel("Oficina de agentes IA")
    }

    private func drawRoom(_ c: inout GraphicsContext, time: TimeInterval, date: Date) {
        // SVG wallG, floorG and repeating planks pattern.
        fill(&c, CGRect(x: -900, y: -900, width: 3100, height: 1100), Color(hex: "171a3d"), Color(hex: "232857"), from: CGPoint(x:0,y:-120), to: CGPoint(x:0,y:200))
        rect(&c, CGRect(x: -900, y: 150, width: 3100, height: 52), Color(hex: "13163a").opacity(0.7))
        rect(&c, CGRect(x: -900, y: 196, width: 3100, height: 5), Color(hex: "3a3f85"))
        fill(&c, CGRect(x: -900, y: 200, width: 3100, height: 1400), Color(hex: "2a2e5e"), Color(hex: "171a38"), from: CGPoint(x:0,y:200), to: CGPoint(x:0,y:780))
        for y in stride(from: 200.5, through: 1600, by: 46) {
            line(&c, CGPoint(x: -900, y: y), CGPoint(x: 2200, y: y), Color.black.opacity(0.16), 1)
            line(&c, CGPoint(x: -900, y: y + 1), CGPoint(x: 2200, y: y + 1), Color.white.opacity(0.03), 1)
        }
        for row in 0..<31 {
            let y = CGFloat(200 + row * 46)
            for x in [-900 + (row % 2 == 0 ? 40 : 100), -900 + (row % 2 == 0 ? 100 : 40), -900 + 70] {
                line(&c, CGPoint(x: CGFloat(x), y: y), CGPoint(x: CGFloat(x), y: min(y + 46, 1600)), Color.black.opacity(0.09), 1)
            }
        }
        radial(&c, CGRect(x: -120, y: 160, width: 1040, height: 520), Color(hex: "7aa2ff"), 0.06)
        let hour = Calendar.current.component(.hour, from: date), minute = Calendar.current.component(.minute, from: date)
        let hr = Double(hour) + Double(minute) / 60
        let daylight = clamp((cos(((hr - 13) / 12) * .pi) + 0.15) / 1.15, 0, 1)
        let night = [Color(hex: "080c2a"), Color(hex: "1d2a63")]
        let dusk = [Color(hex: "3b2a73"), Color(hex: "f0875f")]
        let day = [Color(hex: "4f9be0"), Color(hex: "c4e7ff")]
        let sky = daylight < 0.5 ? zip(night, dusk).map { mix($0.0, $0.1, smooth(daylight * 2)) } : zip(dusk, day).map { mix($0.0, $0.1, smooth((daylight - 0.5) * 2)) }
        for i in 0..<3 { drawWindow(&c, x: CGFloat(60 + i * 270), sky: sky, starsAlpha: CGFloat(clamp(1 - daylight * 2.2, 0, 1)), time: time, index: i) }
        drawClock(&c, date: date)
        // Wall art, neon sign, garland, and divider.
        rounded(&c, CGRect(x: 1000, y: 40, width: 56, height: 76), 4, Color(hex: "10133a"), Color(hex: "4a4fa0"), 2)
        ellipse(&c, CGRect(x: 1014, y: 56, width: 28, height: 28), Color(hex: "f472b6").opacity(0.85))
        polygon(&c, [CGPoint(x:1006,y:106),CGPoint(x:1024,y:84),CGPoint(x:1036,y:98),CGPoint(x:1044,y:90),CGPoint(x:1050,y:106)], Color(hex:"38bdf8").opacity(0.85))
        rounded(&c, CGRect(x: 1210, y: 52, width: 52, height: 64), 4, Color(hex: "10133a"), Color(hex: "4a4fa0"), 2)
        for (i, color) in ["a3e635", "facc15", "2dd4bf", "fb923c"].enumerated() { rounded(&c, CGRect(x: 1218, y: CGFloat(62 + i * 12), width: [36,26,32,18][i], height: 5), 2, Color(hex: color)) }
        text(&c, "AGENT OFFICE", at: CGPoint(x: 1130, y: 78), size: 25, color: Color(hex: "ffd1f3"), weight: .heavy, tracking: 3, glow: Color(hex: "ff5fd2"))
        text(&c, "OPEN 24 / 7", at: CGPoint(x: 1130, y: 99), size: 11, color: Color(hex: "7ad7ff"), tracking: 5)
        for i in -1..<9 { drawLights(&c, startX: CGFloat(i * 160), idx: i, time: time) }
        rect(&c, CGRect(x: 944, y: 60, width: 6, height: 140), Color(hex: "0e1130").opacity(0.6))
        // Lounge rug.
        ellipse(&c, CGRect(x: 945, y: 554, width: 330, height: 116), Color(hex: "33306b"))
        strokeEllipse(&c, CGRect(x: 960, y: 562, width: 300, height: 100), Color(hex: "5b57b0"), 2, [3,7])
        ellipse(&c, CGRect(x: 1000, y: 576, width: 220, height: 72), Color(hex: "3d3a82").opacity(0.7))
        text(&c, "L O U N G E", at: CGPoint(x: 1110, y: 278), size: 10, color: Color(hex: "9aa3ec").opacity(0.55), tracking: 2)
    }

    private func drawWindow(_ c: inout GraphicsContext, x: CGFloat, sky: [Color], starsAlpha: CGFloat, time: TimeInterval, index: Int) {
        let frame = CGRect(x: x, y: 50, width: 210, height: 110)
        rounded(&c, CGRect(x: x - 8, y: 42, width: 226, height: 126), 10, Color(hex: "0e1130"), Color(hex: "363b7c"), 2)
        let glass = Path(roundedRect: frame, cornerRadius: 6)
        c.fill(glass, with: .linearGradient(Gradient(colors: sky), startPoint: CGPoint(x: frame.minX, y: frame.minY), endPoint: CGPoint(x: frame.minX, y: frame.maxY)))
        c.drawLayer { layer in
            let clip = Path(roundedRect: frame, cornerRadius: 6); layer.clip(to: clip)
            var rng = JSRandom(seed: UInt32(1000 + index * 77)); var bx: CGFloat = -6
            while bx < 216 {
                let w = 18 + CGFloat(rng.next()) * 26, h = 22 + CGFloat(rng.next()) * 54, y = 110 - h
                rect(&layer, CGRect(x: x + bx, y: 50 + y, width: w, height: h), Color(hex: index % 2 == 1 ? "0c1033" : "0a0e2c"))
                var wy = y + 5
                while wy < 106 {
                    var wx = bx + 4
                    while wx < bx + w - 5 {
                        if rng.next() > 0.62 { rect(&layer, CGRect(x: x + wx, y: 50 + wy, width: 3, height: 4), Color(hex: "ffd27a").opacity(0.45 + Double(rng.next()) * 0.5)) }
                        wx += 7
                    }
                    wy += 8
                }
                bx += w + 2
            }
            // Star coordinates use the same seeded generator after skyline generation.
            for _ in 0..<16 {
                let sx = CGFloat(rng.next()) * 210, sy = CGFloat(rng.next()) * 60
                let radius = (0.6 + rng.next() * 0.9) * 2
                let delay = Double(rng.next()) * 4
                let pulse = 0.25 + 0.18 * (0.5 + 0.5 * sin(time * 2 + delay))
                ellipse(&layer, CGRect(x: x + sx, y: 50 + sy, width: radius, height: radius), Color.white.opacity(starsAlpha * pulse))
            }
            if index == 1 { ellipse(&layer, CGRect(x: x + 149, y: 65, width: 22, height: 22), Color(hex: "f5f0d0")); ellipse(&layer, CGRect(x: x + 154, y: 61, width: 20, height: 20), sky[0]) }
        }
        c.stroke(glass, with: .color(Color(hex: "454a95")), lineWidth: 2)
        line(&c, CGPoint(x: x + 105, y: 50), CGPoint(x: x + 105, y: 160), Color(hex: "0e1130"), 4)
        line(&c, CGPoint(x: x, y: 105), CGPoint(x: x + 210, y: 105), Color(hex: "0e1130"), 4)
        rounded(&c, CGRect(x: x - 12, y: 162, width: 234, height: 8), 3, Color(hex: "2e326c"))
    }

    private func drawClock(_ c: inout GraphicsContext, date: Date) {
        let center = CGPoint(x: 880, y: 92), r: CGFloat = 38
        ellipse(&c, CGRect(x: center.x-r, y: center.y-r, width: 76, height: 76), Color(hex: "0e1130"), Color(hex: "5a62c8"), 3)
        ellipse(&c, CGRect(x: center.x-r, y: center.y-r, width: 76, height: 76), Color(hex: "7aa2ff").opacity(0.16))
        for i in 0..<12 { let a = CGFloat(i) * .pi / 6, len: CGFloat = i % 3 == 0 ? 28 : 25
            line(&c, CGPoint(x:center.x + sin(a)*len,y:center.y-cos(a)*len), CGPoint(x:center.x+sin(a)*33,y:center.y-cos(a)*33), Color(hex:"9aa3ec"), i % 3 == 0 ? 2 : 1.2) }
        let comp = Calendar.current.dateComponents([.hour,.minute,.second], from: date), h = CGFloat((comp.hour ?? 0) % 12), m = CGFloat(comp.minute ?? 0), s = CGFloat(comp.second ?? 0)
        clockHand(&c, center, 17, (h * 30 + m * 0.5) * .pi / 180, Color(hex:"e8ebff"), 3.4)
        clockHand(&c, center, 25, (m * 6 + s * 0.1) * .pi / 180, Color(hex:"e8ebff"), 2.4)
        clockHand(&c, center, 27, s * 6 * .pi / 180, Color(hex:"ff6b8a"), 1.3)
        ellipse(&c, CGRect(x:center.x-2.6,y:center.y-2.6,width:5.2,height:5.2), Color(hex:"ff6b8a"))
    }

    private func drawLights(_ c: inout GraphicsContext, startX: CGFloat, idx: Int, time: TimeInterval) {
        quad(&c, CGPoint(x:startX,y:12), CGPoint(x:startX+80,y:46), CGPoint(x:startX+160,y:12), Color(hex:"2b2f63"), 1.6)
        let colors = ["ffcf6b","ff7eb6","7ad7ff","9dffb0"]
        for (j,t) in [0.2,0.5,0.8].enumerated() { let x = startX + 160*t, y = 12 + 68*t*(1-t)
            let color = Color(hex: colors[((idx + 1) * 3 + j) % 4]); let alpha = 0.72 + 0.2 * sin(time * 2 + Double((idx + 1) * 3 + j) * 0.37)
            ellipse(&c, CGRect(x:x-8,y:y-5,width:16,height:16), color.opacity(0.14 * alpha))
            ellipse(&c, CGRect(x:x-2.8,y:y+0.2,width:5.6,height:5.6), color)
        }
    }

    private func drawDecor(_ c: inout GraphicsContext, time: TimeInterval) {
        // Coffee bar and espresso machine.
        ellipse(&c, CGRect(x:962,y:252,width:216,height:20), Color.black.opacity(0.3))
        rounded(&c, CGRect(x:980,y:206,width:180,height:56), 5, Color(hex:"2c2960")); rounded(&c, CGRect(x:980,y:196,width:180,height:13), 4, Color(hex:"6b63b0"))
        rounded(&c, CGRect(x:990,y:216,width:76,height:38), 3, Color(hex:"221f4b")); rounded(&c, CGRect(x:1074,y:216,width:76,height:38), 3, Color(hex:"221f4b"))
        for x in [1060.0,1080.0] { ellipse(&c, CGRect(x:x-2.5,y:233.5,width:5,height:5), Color(hex:"9a93e0")) }
        rounded(&c, CGRect(x:1010,y:136,width:46,height:60), 6, Color(hex:"3a3a6e"), Color(hex:"59599f"), 2)
        rounded(&c, CGRect(x:1016,y:144,width:34,height:16), 3, Color(hex:"15183a")); ellipse(&c, CGRect(x:1020,y:150,width:5,height:5), Color(hex:"ff5d6c")); ellipse(&c, CGRect(x:1028,y:150,width:5,height:5), Color(hex:"34d399"))
        rounded(&c, CGRect(x:1024,y:166,width:18,height:22), 3, Color(hex:"15183a")); rounded(&c, CGRect(x:1027,y:182,width:12,height:9), 2, Color(hex:"f4f5ff"))
        steam(&c, x:1032, y:178, time:time); steam(&c, x:1038, y:178, time:time+0.8)
        rounded(&c, CGRect(x:1100,y:170,width:24,height:26), 5, Color(hex:"d4d7ff")); rounded(&c, CGRect(x:1103,y:174,width:18,height:6), 2, Color(hex:"7ad7ff").opacity(0.7))
        rounded(&c, CGRect(x:1130,y:166,width:22,height:30), 3, Color(hex:"c0794c")); quad(&c, CGPoint(x:1134,y:166), CGPoint(x:1141,y:148), CGPoint(x:1148,y:166), Color(hex:"a5613b"), 3)
        // Floor lamp, sofa, coffee table.
        ellipse(&c, CGRect(x:1238,y:396,width:28,height:8), Color.black.opacity(0.3)); rect(&c, CGRect(x:1250,y:320,width:4,height:80), Color(hex:"6a6fb5"))
        polygon(&c,[CGPoint(x:1236,y:322),CGPoint(x:1268,y:322),CGPoint(x:1260,y:296),CGPoint(x:1244,y:296)],Color(hex:"ffd27a")); radial(&c,CGRect(x:1232,y:280,width:40,height:40),Color(hex:"ffb35c"),0.24)
        ellipse(&c, CGRect(x:1032,y:486,width:236,height:28), Color.black.opacity(0.28))
        rounded(&c, CGRect(x:1050,y:418,width:200,height:62), 20, Color(hex:"5a4a95")); rounded(&c, CGRect(x:1062,y:426,width:176,height:50), 14, Color(hex:"6a59ab"))
        rounded(&c, CGRect(x:1052,y:468,width:196,height:34), 14, Color(hex:"7664bb")); rounded(&c,CGRect(x:1038,y:444,width:28,height:60),13,Color(hex:"5a4a95")); rounded(&c,CGRect(x:1234,y:444,width:28,height:60),13,Color(hex:"5a4a95"))
        for x in [1106.0,1150.0,1194.0] { line(&c,CGPoint(x:x,y:470),CGPoint(x:x,y:500),Color(hex:"5a4a95").opacity(0.6),2) }
        rounded(&c,CGRect(x:1062,y:436,width:30,height:26),9,Color(hex:"f472b6"))
        ellipse(&c,CGRect(x:1046,y:620,width:132,height:24),Color.black.opacity(0.3)); rect(&c,CGRect(x:1106,y:604,width:12,height:28),Color(hex:"2a2450"))
        ellipse(&c,CGRect(x:1048,y:587,width:128,height:34),Color(hex:"8a7bd0")); ellipse(&c,CGRect(x:1048,y:584,width:128,height:34),Color(hex:"a496e6"))
        for x in [1086.0,1128.0] { rounded(&c,CGRect(x:x,y:590,width:12,height:11),2,Color(hex:"f4f5ff")) }; steam(&c,x:1092,y:586,time:time); steam(&c,x:1134,y:588,time:time+0.5)
        drawPlant(&c, x:1240,y:560,scale:1.2,tone:Color(hex:"2fbf8a"),time:time)
        drawPlant(&c, x:34,y:238,scale:1.15,tone:Color(hex:"34c58b"),time:time+0.4)
        drawPlant(&c, x:968,y:742,scale:1,tone:Color(hex:"3dd6a0"),time:time+0.8)
        ellipse(&c,CGRect(x:974,y:734,width:52,height:12),Color.black.opacity(0.25)); rounded(&c,CGRect(x:978,y:714,width:44,height:26),6,Color(hex:"2d2a5e")); rounded(&c,CGRect(x:978,y:714,width:44,height:6),3,Color(hex:"4a4590")); rounded(&c,CGRect(x:986,y:722,width:28,height:3),1,Color(hex:"34d399"))
    }

    private func drawPlant(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, scale: CGFloat, tone: Color, time: TimeInterval) {
        ellipse(&c,CGRect(x:x-22*scale,y:y-4*scale,width:44*scale,height:12*scale),Color.black.opacity(0.3))
        for i in 0..<3 { let sway = animate ? CGFloat(sin(time * (0.8 + Double(i)*0.08) + Double(i)*1.6)) * 2.4 : 0
            var p = Path()
            p.move(to: CGPoint(x:x,y:y-30*scale))
            if i == 0 { p.addCurve(to:CGPoint(x:x-16*scale+sway,y:y-100*scale),control1:CGPoint(x:x-26*scale+sway,y:y-50*scale),control2:CGPoint(x:x-36*scale+sway,y:y-84*scale)); p.addCurve(to:CGPoint(x:x,y:y-30*scale),control1:CGPoint(x:x-8*scale+sway,y:y-70*scale),control2:CGPoint(x:x-4*scale,y:y-50*scale)) }
            if i == 1 { p.addCurve(to:CGPoint(x:x+22*scale+sway,y:y-104*scale),control1:CGPoint(x:x+26*scale+sway,y:y-52*scale),control2:CGPoint(x:x+40*scale+sway,y:y-80*scale)); p.addCurve(to:CGPoint(x:x,y:y-30*scale),control1:CGPoint(x:x+10*scale+sway,y:y-76*scale),control2:CGPoint(x:x+4*scale,y:y-52*scale)) }
            if i == 2 { p.addCurve(to:CGPoint(x:x+2*scale+sway,y:y-118*scale),control1:CGPoint(x:x-6*scale+sway,y:y-60*scale),control2:CGPoint(x:x+4*scale+sway,y:y-92*scale)); p.addCurve(to:CGPoint(x:x,y:y-30*scale),control1:CGPoint(x:x+14*scale+sway,y:y-92*scale),control2:CGPoint(x:x+12*scale,y:y-56*scale)) }
            p.closeSubpath(); c.fill(p,with:.color([tone,mix(tone,Color(hex:"0b6b4d"),0.35),mix(tone,Color(hex:"8cffd0"),0.25)][i]))
        }
        polygon(&c,[CGPoint(x:x-17*scale,y:y-30*scale),CGPoint(x:x+17*scale,y:y-30*scale),CGPoint(x:x+13*scale,y:y),CGPoint(x:x-13*scale,y:y)],Color(hex:"c2653d")); rounded(&c,CGRect(x:x-19*scale,y:y-34*scale,width:38*scale,height:7*scale),3,Color(hex:"d9794f"))
    }

    private func drawDesk(_ c: inout GraphicsContext, slot: OfficeDeskSlot, agent: OfficeAgent?, time: TimeInterval) {
        let cx = slot.deskFrame.midX, dy = slot.seat.y - 12, status = agent?.state ?? .idle
        let accent = agent.map { deskAccent(for:$0) } ?? Color(hex:"7c8cff")
        ellipse(&c,CGRect(x:cx-128,y:dy+10,width:256,height:52),Color(hex:"05061a").opacity(0.35))
        if status == .working || status == .thinking {
            strokeEllipse(&c,CGRect(x:cx-122,y:dy+9,width:244,height:50),accent,2,[],opacity:1)
        }
        rounded(&c,CGRect(x:cx+37,y:dy-52,width:36,height:54),15,Color(hex:"2a2d5c"),Color(hex:"40447f"),1.5); rounded(&c,CGRect(x:cx+33,y:dy-1,width:44,height:15),7,Color(hex:"33376d"))
        ellipse(&c,CGRect(x:cx-103,y:dy-12,width:156,height:32),accent.opacity(agent == nil ? 0.03 : 0.18))
        rounded(&c,CGRect(x:cx-95,y:dy-12,width:190,height:24),7,Color(hex:"5b5391"),nil,0)
        rect(&c,CGRect(x:cx-95,y:dy-12,width:190,height:2.4),Color(hex:"8d84d6").opacity(0.55))
        rect(&c,CGRect(x:cx-32,y:dy-22,width:14,height:14),Color(hex:"1b1e40")); ellipse(&c,CGRect(x:cx-46,y:dy-12,width:42,height:9),Color(hex:"1b1e40"))
        rounded(&c,CGRect(x:cx-91,y:dy-15,width:10,height:10),2.5,Color(hex:"f4f5ff")); rounded(&c,CGRect(x:cx-91,y:dy-13,width:10,height:2.4),1,accent)
        steam(&c,x:cx-88,y:dy-17,time:time); steam(&c,x:cx-84,y:dy-17,time:time+0.7)
        let monitor = CGRect(x:cx-67,y:dy-82,width:84,height:62)
        rounded(&c,monitor,7,Color(hex:"07091c"),Color(hex: status == .blocked || status == .waiting || status == .failed ? "ff5d6c" : "3a3f7a"),2)
        let screen=CGRect(x:cx-62,y:dy-77,width:74,height:52)
        c.drawLayer { l in
            l.clip(to:Path(roundedRect:screen,cornerRadius:3)); rect(&l,screen,Color(hex:"0a1228"))
            for copy in 0..<2 { for i in 0..<14 {
                var rng=JSRandom(seed:UInt32(900+slot.index*13+i)); let x=CGFloat(3+Int(rng.next()*4)*6); let count=1+Int(rng.next()*3); var cursor=x
                for _ in 0..<count {
                    let w=6+CGFloat(rng.next())*24
                    let palette=[Color(hex:"a9b4ee"),Color(hex:"a9b4ee"),Color(hex:"a9b4ee"),accent,accent,Color(hex:"c792ea"),Color(hex:"7dd3fc"),Color(hex:"fbbf24"),Color(hex:"7ee2a8")]
                    let token=palette[Int(rng.next()*CGFloat(palette.count))]
                    let ink: Color = status == .idle ? Color(hex:"101a31").opacity(0.82) : token
                    rounded(&l,CGRect(x:cx-60+cursor,y:dy-75+CGFloat(copy*14+i)*7,width:w,height:3.2),1.6,ink)
                    cursor += w+3
                }
            }}
            if status == .blocked || status == .waiting || status == .failed {
                rect(&l,screen,Color(hex:"3a0a14")); polygon(&l,[CGPoint(x:cx-25,y:dy-68),CGPoint(x:cx-9,y:dy-40),CGPoint(x:cx-41,y:dy-40)],Color(hex:"ff5d6c")); rect(&l,CGRect(x:cx-26,y:dy-60,width:3,height:10),Color(hex:"3a0a14")); rect(&l,CGRect(x:cx-26,y:dy-47,width:3,height:3),Color(hex:"3a0a14"))
            } else if status == .idle {
                rect(&l,screen,Color(hex:"05071a").opacity(0.72)); text(&l,"z z",at:CGPoint(x:cx-25,y:dy-51),size:14,color:accent.opacity(0.5),weight:.heavy)
            } else {
                rect(&l,screen,accent.opacity(0.82))
                if animate && Int(time*2).isMultiple(of:2) { rect(&l,CGRect(x:cx-34,y:dy-41,width:3,height:6),accent) }
            }
            polygon(&l,[CGPoint(x:cx-62,y:dy-77),CGPoint(x:cx-30,y:dy-77),CGPoint(x:cx-62,y:dy-45)],Color.white.opacity(0.05))
        }
        ellipse(&c,CGRect(x:cx-26.4,y:dy-23.9,width:2.8,height:2.8),agent.map { stateLED($0.state) } ?? Color(hex:"4b5080"))
        rounded(&c,CGRect(x:cx+14,y:dy-78,width:9,height:9),0,Color(hex:"fde68a")); rounded(&c,CGRect(x:cx+17,y:dy-66,width:8,height:8),0,Color(hex:"fbcfe8"))
        rounded(&c,CGRect(x:cx+21,y:dy-5.5,width:50,height:10),2.5,Color(hex:"171a38"),Color(hex:"303670"),1)
        for i in 0..<10 { for row in 0..<2 { rounded(&c,CGRect(x:cx+24+CGFloat(i)*4.5+CGFloat(row),y:dy-3.3+CGFloat(row)*3.5,width:3,height:2.4),0.6,agent != nil && (status == .working || status == .thinking) && animate && Int(time*3+Double(i)).isMultiple(of:2) ? accent : Color(hex:"3a3f7a")) } }
        drawDeskLamp(&c, cx:cx, dy:dy)
        rounded(&c,CGRect(x:cx-95,y:dy+12,width:190,height:25),5,Color(hex:"352f66")); rounded(&c,CGRect(x:cx-95,y:dy+12,width:190,height:3),1.5,Color(hex:"6d64b3").opacity(0.6))
        rounded(&c,CGRect(x:cx-84,y:dy+19,width:72,height:13),3,Color(hex:"201d45")); rounded(&c,CGRect(x:cx-54,y:dy+24,width:12,height:2.5),1,Color(hex:"8d84d6")); rounded(&c,CGRect(x:cx-6,y:dy+19,width:72,height:13),3,Color(hex:"201d45")); rounded(&c,CGRect(x:cx+24,y:dy+24,width:12,height:2.5),1,Color(hex:"8d84d6"))
        rounded(&c,CGRect(x:cx-91,y:dy+37,width:6,height:7),1,Color(hex:"171534")); rounded(&c,CGRect(x:cx+85,y:dy+37,width:6,height:7),1,Color(hex:"171534"))
        let title = agent?.name.count ?? 0 > 22 ? String(agent!.name.prefix(21))+"…" : (agent?.name ?? "Free desk")
        let plateW = CGFloat(title.count)*6.3+30
        rounded(&c,CGRect(x:cx-plateW/2,y:dy+45,width:plateW,height:22),11,Color(hex:"090c24").opacity(0.78),Color.white.opacity(0.12),1)
        ellipse(&c,CGRect(x:cx-plateW/2+8.4,y:dy+52.4,width:7.2,height:7.2),agent.map { stateLED($0.state) } ?? Color(hex:"94a3b8"))
        text(&c,title,at:CGPoint(x:cx+6,y:dy+54.5),size:11,color:Color(hex:"d9defc"),weight:.semibold)
    }

    private func drawAmbient(_ c: inout GraphicsContext, time: TimeInterval) {
        radial(&c,CGRect(x:960,y:320,width:300,height:200),Color(hex:"ffb35c"),0.10)
        radial(&c,CGRect(x:1192,y:340,width:120,height:120),Color(hex:"ffb35c"),0.09)
        radial(&c,CGRect(x:990,y:222,width:100,height:80),Color(hex:"ffb35c"),0.11)
        var rng=JSRandom(seed:7)
        for i in 0..<16 { let x=CGFloat(rng.next()*1280), y=220+CGFloat(rng.next()*520), radius=0.8+CGFloat(rng.next())*1.3, duration=9+Double(rng.next())*10, phase=(time+Double(i)*duration/16).truncatingRemainder(dividingBy:duration)/duration
            let alpha = phase < 0.2 ? phase/0.2*0.55 : phase < 0.8 ? 0.55-(phase-0.2)*0.25 : (1-phase)/0.2*0.35
            ellipse(&c,CGRect(x:x,y:y,width:radius*2,height:radius*2),Color(hex:"ffe6b0").opacity(animate ? alpha : 0))
        }
        let vignette=Path(CGRect(x:-Self.overscan.width,y:-Self.overscan.height,width:1280+Self.overscan.width*2,height:760+Self.overscan.height*2)); c.fill(vignette,with:.radialGradient(Gradient(stops:[.init(color:.clear,location:0.5),.init(color:Color(hex:"04051a").opacity(0.6),location:1)]),center:CGPoint(x:640,y:400),startRadius:0,endRadius:960))
    }

    private func stateLED(_ state: OfficeAgentState) -> Color { state == .working || state == .thinking ? Color(hex:"34d399") : state == .idle ? Color(hex:"fbbf24") : Color(hex:"ff5d6c") }
    private func deskAccent(for agent: OfficeAgent) -> Color {
        let role: String
        switch agent.kind.lowercased() {
        case "claude": role = "Developer"
        case "codex": role = "Architect"
        case "opencode", "goose": role = "DevOps"
        case "gemini": role = "Researcher"
        case "aider": role = "QA"
        case "cursor-agent": role = "Designer"
        case "amp": role = "PM"
        default: return OfficePalette.agentColor(seed: agent.seed)
        }
        return OfficePalette.ROLE_COLORS[role] ?? OfficePalette.agentColor(seed: agent.seed)
    }
    private func drawDeskLamp(_ c: inout GraphicsContext,cx:CGFloat,dy:CGFloat) {
        let cone=Path { p in p.move(to:CGPoint(x:cx+76,y:dy-48)); p.addLine(to:CGPoint(x:cx+98,y:dy-48)); p.addLine(to:CGPoint(x:cx+124,y:dy+6)); p.addLine(to:CGPoint(x:cx+54,y:dy+6)); p.closeSubpath() }
        c.fill(cone,with:.linearGradient(Gradient(stops:[.init(color:Color(hex:"ffd27a").opacity(0.5),location:0),.init(color:Color(hex:"ffd27a").opacity(0),location:1)]),startPoint:CGPoint(x:cx+87,y:dy-48),endPoint:CGPoint(x:cx+87,y:dy+6)))
        ellipse(&c,CGRect(x:cx+82,y:dy-4,width:18,height:5.2),Color(hex:"1b1e40"))
        var stand=Path(); stand.move(to:CGPoint(x:cx+91,y:dy-3)); stand.addLine(to:CGPoint(x:cx+93,y:dy-32)); stand.addLine(to:CGPoint(x:cx+84,y:dy-52)); c.stroke(stand,with:.color(Color(hex:"7a80c8")),style:StrokeStyle(lineWidth:2.6,lineCap:.round))
        polygon(&c,[CGPoint(x:cx+74,y:dy-58),CGPoint(x:cx+96,y:dy-58),CGPoint(x:cx+100,y:dy-47),CGPoint(x:cx+70,y:dy-47)],Color(hex:"e0aa55"))
    }
    private func steam(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, time: TimeInterval) {
        let dy = animate ? CGFloat(sin(time*2+x))*3 : 0
        quad(&c,CGPoint(x:x-2,y:y),CGPoint(x:x-5,y:y-5+dy),CGPoint(x:x-2,y:y-10+dy),Color.white.opacity(0.45),1.3)
        quad(&c,CGPoint(x:x+4,y:y),CGPoint(x:x+1,y:y-5+dy),CGPoint(x:x+4,y:y-10+dy),Color.white.opacity(0.4),1.3)
    }
    private func clockHand(_ c: inout GraphicsContext, _ center: CGPoint, _ length: CGFloat, _ angle: CGFloat, _ color: Color, _ width: CGFloat) { line(&c,center,CGPoint(x:center.x+sin(angle)*length,y:center.y-cos(angle)*length),color,width) }
    private func rect(_ c: inout GraphicsContext,_ r:CGRect,_ color:Color) { c.fill(Path(r),with:.color(color)) }
    private func rounded(_ c: inout GraphicsContext,_ r:CGRect,_ radius:CGFloat,_ color:Color,_ stroke:Color?=nil,_ lineWidth:CGFloat=1) { let p=Path(roundedRect:r,cornerRadius:radius); c.fill(p,with:.color(color)); if let stroke { c.stroke(p,with:.color(stroke),lineWidth:lineWidth) } }
    private func ellipse(_ c: inout GraphicsContext,_ r:CGRect,_ color:Color,_ stroke:Color?=nil,_ lineWidth:CGFloat=1) { let p=Path(ellipseIn:r); c.fill(p,with:.color(color)); if let stroke { c.stroke(p,with:.color(stroke),lineWidth:lineWidth) } }
    private func radial(_ c: inout GraphicsContext,_ r:CGRect,_ color:Color,_ opacity:Double) {
        let gradient=Gradient(stops:[.init(color:color.opacity(opacity),location:0),.init(color:color.opacity(0),location:1)])
        c.fill(Path(ellipseIn:r),with:.radialGradient(gradient,center:CGPoint(x:r.midX,y:r.midY),startRadius:0,endRadius:max(r.width,r.height)/2))
    }
    private func strokeEllipse(_ c: inout GraphicsContext,_ r:CGRect,_ color:Color,_ width:CGFloat,_ dash:[CGFloat]=[],opacity:CGFloat=1) { c.stroke(Path(ellipseIn:r),with:.color(color.opacity(opacity)),style:StrokeStyle(lineWidth:width,dash:dash)) }
    private func line(_ c: inout GraphicsContext,_ a:CGPoint,_ b:CGPoint,_ color:Color,_ width:CGFloat) { var p=Path(); p.move(to:a); p.addLine(to:b); c.stroke(p,with:.color(color),lineWidth:width) }
    private func quad(_ c: inout GraphicsContext,_ a:CGPoint,_ b:CGPoint,_ d:CGPoint,_ color:Color,_ width:CGFloat) { var p=Path(); p.move(to:a); p.addQuadCurve(to:d,control:b); c.stroke(p,with:.color(color),lineWidth:width) }
    private func polygon(_ c: inout GraphicsContext,_ points:[CGPoint],_ color:Color) { guard let first=points.first else{return}; var p=Path(); p.move(to:first); points.dropFirst().forEach{p.addLine(to:$0)}; p.closeSubpath(); c.fill(p,with:.color(color)) }
    private func fill(_ c: inout GraphicsContext,_ r:CGRect,_ a:Color,_ b:Color,from:CGPoint,to:CGPoint) { c.fill(Path(r),with:.linearGradient(Gradient(colors:[a,b]),startPoint:from,endPoint:to)) }
    private func text(_ c: inout GraphicsContext,_ value:String,at:CGPoint,size:CGFloat,color:Color,weight:Font.Weight = .regular,tracking:CGFloat=0,glow:Color?=nil) { let resolved=c.resolve(Text(value).font(.system(size:size,weight:weight,design:.rounded)).tracking(tracking).foregroundColor(color)); if let glow { c.drawLayer{l in l.addFilter(.blur(radius:4)); l.draw(c.resolve(Text(value).font(.system(size:size,weight:weight,design:.rounded)).tracking(tracking).foregroundColor(glow.opacity(0.8))),at:at)} }; c.draw(resolved,at:at) }
    private func mix(_ a:Color,_ b:Color,_ t:CGFloat)->Color { let aa=NSColor(a).usingColorSpace(.deviceRGB) ?? .white, bb=NSColor(b).usingColorSpace(.deviceRGB) ?? .white; return Color(red:aa.redComponent*(1-t)+bb.redComponent*t,green:aa.greenComponent*(1-t)+bb.greenComponent*t,blue:aa.blueComponent*(1-t)+bb.blueComponent*t) }
    private func smooth(_ t:CGFloat)->CGFloat { t*t*(3-2*t) }
    private func clamp<T:Comparable>(_ v:T,_ a:T,_ b:T)->T { min(b,max(a,v)) }
}

private struct JSRandom {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> CGFloat {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return CGFloat((t ^ (t >> 14)))/4_294_967_296
    }
}

private extension Color {
    init(hex: String) {
        let n=UInt64(hex,radix:16) ?? 0
        self.init(.sRGB,red:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,opacity:1)
    }
}
