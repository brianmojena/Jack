import Foundation
import CoreGraphics
import CoreText

/// El logo de Jack en ASCII animado, para la tele: un núcleo que reparte trabajo a seis agentes (el mismo de la web).
/// Cada fotograma se dibuja con Core Graphics, sin SwiftUI, así que puede generarse fuera del hilo principal.
final class OfficeTVLogo: @unchecked Sendable {
    /// Igual que la vista del uso, para que la tele cambie de imagen sin cambiar de textura.
    static let size = CGSize(width: 1600, height: 900)

    private struct Arm {
        let node: CGPoint
        let armR: Double
        let nodeR: Double
        let back: Bool
        let offset: Double
    }

    private static let hub = CGPoint(x: 512, y: 512)
    private static let center = CGPoint(x: 512, y: 525)
    private static let hubR = 74.0
    private static let accent = CGPoint(x: 512, y: 740)
    private static let accentR = 72.0
    private static let arms = [
        Arm(node: CGPoint(x: 512, y: 290), armR: 21, nodeR: 50, back: true, offset: 0.12),
        Arm(node: CGPoint(x: 704, y: 623), armR: 21, nodeR: 50, back: true, offset: 0.45),
        Arm(node: CGPoint(x: 320, y: 623), armR: 21, nodeR: 50, back: true, offset: 0.78),
        Arm(node: CGPoint(x: 718, y: 393), armR: 29, nodeR: 66, back: false, offset: 0.29),
        Arm(node: CGPoint(x: 306, y: 393), armR: 29, nodeR: 66, back: false, offset: 0.62),
        Arm(node: CGPoint(x: 512, y: 740), armR: 29, nodeR: 0, back: false, offset: 0.95),
    ]
    private static let ramp = Array(" .·:;=+*x#%@")
    private static let glitch = Array("<>/\\{}[]=+*#01$%&?!;~^")
    private static let speed = 0.26

    private typealias RGB = (Double, Double, Double)
    private static let dark: RGB = (58, 64, 84)
    private static let white: RGB = (244, 246, 252)
    private static let ember: RGB = (255, 84, 28)
    private static let gold: RGB = (255, 184, 100)

    private let font: CTFont
    private let rampGlyphs: [CGGlyph]
    private let glitchGlyphs: [CGGlyph]
    private let cw: Double
    private let ch: Double
    private let cols: Int
    private let rows: Int
    private let scale: Double
    private let baseline: Double
    private let caption: CTLine
    private let status: CTLine

    init() {
        let size = Self.size
        let font = PlatformFont.monospacedSystemFont(ofSize: 17, weight: .medium) as CTFont
        self.font = font
        func glyphs(_ chars: [Character]) -> [CGGlyph] {
            chars.map { char in
                var units = Array(String(char).utf16)
                var glyph = [CGGlyph](repeating: 0, count: units.count)
                CTFontGetGlyphsForCharacters(font, &units, &glyph, units.count)
                return glyph[0]
            }
        }
        rampGlyphs = glyphs(Self.ramp)
        glitchGlyphs = glyphs(Self.glitch)
        var glyph = rampGlyphs[rampGlyphs.count - 1]
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        cw = advance.width
        ch = 17 * 1.18
        cols = Int((size.width / cw).rounded(.up))
        rows = Int((size.height / ch).rounded(.up))
        scale = min(size.width, size.height * 1.05) * 0.84 / 600
        baseline = (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2

        let label = PlatformFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        caption = CTLineCreateWithAttributedString(NSAttributedString(string: "jack — 1 hub · 6 agentes", attributes: [
            .font: label, .foregroundColor: PlatformColor(red: 0.36, green: 0.38, blue: 0.47, alpha: 1),
        ]))
        status = CTLineCreateWithAttributedString(NSAttributedString(string: "repartiendo tareas", attributes: [
            .font: label, .foregroundColor: PlatformColor(red: 0.55, green: 0.58, blue: 0.66, alpha: 1),
        ]))
    }

    /// El fotograma del segundo `t` desde que la tele empezó a enseñar el logo; los primeros 1,5 s aparece de arriba abajo.
    func frame(at t: Double) -> CGImage? {
        let width = Int(Self.size.width)
        let height = Int(Self.size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = Self.size.width
        let H = Self.size.height

        context.setFillColor(CGColor(srgbRed: 0.027, green: 0.031, blue: 0.043, alpha: 1))
        context.fill(CGRect(origin: .zero, size: Self.size))
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 1, green: 0.42, blue: 0.17, alpha: 0.16), CGColor(srgbRed: 1, green: 0.42, blue: 0.17, alpha: 0),
        ] as CFArray, locations: [0, 1]) {
            let mid = CGPoint(x: W / 2, y: H / 2)
            context.drawRadialGradient(glow, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: H * 0.62, options: [])
        }

        // Inclinación lenta: los brazos de atrás y los de delante se desplazan en sentidos opuestos.
        let tiltX = sin(t * 0.5) * 0.55
        let tiltY = cos(t * 0.37) * 0.4
        let floatY = sin(t * 0.9) * 6
        let par = 26.0
        let back = (x: tiltX * par * 0.9, y: tiltY * par * 0.9 + floatY * 0.6)
        let front = (x: -tiltX * par * 0.45, y: -tiltY * par * 0.45 + floatY)
        let edge = cw / scale * 0.95
        let intro = Self.clamp((t - 0.05) / 1.5)
        let frontier = intro * Double(rows + 6)

        // Por brazo: un paquete viaja del núcleo al agente y después se abre un anillo en el agente.
        struct Packet { let arm: Arm; let x: Double; let y: Double; let travel: Double; let ring: Double }
        let packets = Self.arms.map { arm -> Packet in
            let q = Self.fract(t * Self.speed + arm.offset)
            let travel = q > 0.3 ? Self.ease((q - 0.3) / 0.7) : -1
            return Packet(arm: arm, x: Self.hub.x + (arm.node.x - Self.hub.x) * max(travel, 0),
                          y: Self.hub.y + (arm.node.y - Self.hub.y) * max(travel, 0), travel: travel, ring: q <= 0.3 ? q / 0.3 : -1)
        }
        let hubPulse = packets.reduce(0.0) { max($0, $1.travel >= 0 && $1.travel < 0.15 ? 1 - $1.travel / 0.15 : 0) }
        let tick = floor(t * 14)

        var batches: [Int: (glyphs: [CGGlyph], points: [CGPoint])] = [:]

        for r in 0..<rows {
            if Double(r) > frontier { break }
            let py = Double(r) * ch + ch / 2
            let nearFrontier = frontier - Double(r) < 3 && intro < 1
            for c in 0..<cols {
                let px = Double(c) * cw + cw / 2
                let fx = Self.center.x + (px - front.x - W / 2) / scale
                let fy = Self.center.y + (py - front.y - H / 2) / scale
                let bx = Self.center.x + (px - back.x - W / 2) / scale
                let by = Self.center.y + (py - back.y - H / 2) / scale

                var sdF = Self.circle(fx, fy, Self.hub, Self.hubR)
                var sdB = 1e9
                for arm in Self.arms {
                    if arm.back {
                        sdB = min(sdB, Self.segment(bx, by, Self.hub, arm.node, arm.armR), Self.circle(bx, by, arm.node, arm.nodeR))
                    } else {
                        sdF = min(sdF, Self.segment(fx, fy, Self.hub, arm.node, arm.armR))
                        if arm.nodeR > 0 { sdF = min(sdF, Self.circle(fx, fy, arm.node, arm.nodeR)) }
                    }
                }
                let sdA = Self.circle(fx, fy, Self.accent, Self.accentR)
                let covB = Self.clamp(0.5 - sdB / edge)
                let covF = Self.clamp(0.5 - sdF / edge)
                let covA = Self.clamp(0.5 - sdA / edge)
                let inside = max(covA, covF, covB)

                // Atrás, delante y el agente activo encima de todo.
                var b = covB * (0.42 + 0.14 * Self.clamp(-sdB / 30))
                let shade = 1 - 0.32 * Self.clamp((fy - 330) / 430)
                let tube = 0.72 + 0.28 * Self.clamp(-sdF / 26)
                b = b * (1 - covF) + covF * shade * tube
                var tint = covA
                b = b * (1 - covA) + covA * (0.84 + 0.12 * Self.clamp(-sdA / 40))
                b += covF * hubPulse * 0.25 * Self.clamp(1 - Self.circle(fx, fy, Self.hub, 0) / 140)
                b += (Self.noise(Double(c) * 0.17, Double(r) * 0.29 - t * 0.7) - 0.5) * 0.2 * inside

                for packet in packets {
                    let lx = packet.arm.back ? bx : fx
                    let ly = packet.arm.back ? by : fy
                    let k = packet.arm.back ? 0.55 : 1
                    if packet.travel >= 0 {
                        let g = exp(-((lx - packet.x) * (lx - packet.x) + (ly - packet.y) * (ly - packet.y)) / 900)
                        if g > 0.01 {
                            b += g * 0.55 * k
                            tint = max(tint, g * 0.95 * k)
                        }
                    } else if packet.ring >= 0 {
                        let radius = (packet.arm.nodeR > 0 ? packet.arm.nodeR : Self.accentR) + packet.ring * 110
                        let band = Self.clamp(1 - abs(Self.circle(lx, ly, packet.arm.node, radius)) / 14) * (1 - packet.ring)
                        if band > 0 {
                            b = max(b, band * 0.42 * k)
                            tint = max(tint, band * 0.8)
                        }
                    }
                }

                // Fondo: un campo tenue de puntos que fluye.
                if inside < 0.05 {
                    let n = Self.noise(Double(c) * 0.07 + t * 0.06, Double(r) * 0.12 - t * 0.09)
                    if n > 0.62 { b = max(b, (n - 0.62) * 0.55) }
                }
                if b < 0.04 && !nearFrontier { continue }

                var glyph = rampGlyphs[Int((Self.clamp(b) * Double(rampGlyphs.count - 1)).rounded())]
                var rgb = Self.mix(Self.dark, Self.white, pow(Self.clamp(b), 0.85))
                if tint > 0.01 {
                    rgb = Self.mix(rgb, Self.mix(Self.ember, Self.gold, Self.clamp(Self.clamp(b) * 1.2 - 0.2)), Self.clamp(tint))
                }
                if nearFrontier {
                    glyph = glitchGlyphs[Int(Self.hash(Double(c), Double(r) + tick) * Double(glitchGlyphs.count)) % glitchGlyphs.count]
                    rgb = Self.mix(Self.mix(rgb, Self.white, 0.5), Self.gold, 0.6)
                }
                if glyph == rampGlyphs[0] { continue }

                let key = (Int(rgb.0) >> 3) << 10 | (Int(rgb.1) >> 3) << 5 | Int(rgb.2) >> 3
                let point = CGPoint(x: px - cw / 2, y: H - py - baseline)
                batches[key, default: ([], [])].glyphs.append(glyph)
                batches[key, default: ([], [])].points.append(point)
            }
        }

        for (key, batch) in batches {
            let r = Double((key >> 10) & 31) * 8 / 255
            let g = Double((key >> 5) & 31) * 8 / 255
            let b = Double(key & 31) * 8 / 255
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            CTFontDrawGlyphs(font, batch.glyphs, batch.points, batch.glyphs.count, context)
        }

        // La barra de estado, como la ventana de la web.
        context.textPosition = CGPoint(x: 60, y: 44)
        CTLineDraw(caption, context)
        let statusWidth = CTLineGetTypographicBounds(status, nil, nil, nil)
        let dotX = W - 60 - statusWidth - 26
        context.setFillColor(CGColor(srgbRed: 0.37, green: 0.9, blue: 0.6, alpha: Self.fract(t * 0.7) < 0.5 ? 1 : 0.35))
        context.fillEllipse(in: CGRect(x: dotX, y: 46, width: 13, height: 13))
        context.textPosition = CGPoint(x: W - 60 - statusWidth, y: 44)
        CTLineDraw(status, context)

        return context.makeImage()
    }

    // MARK: - Geometría y ruido

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    private static func fract(_ v: Double) -> Double { v - floor(v) }
    private static func hash(_ i: Double, _ j: Double) -> Double { fract(sin(i * 127.1 + j * 311.7) * 43758.5453) }
    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    private static func noise(_ x: Double, _ y: Double) -> Double {
        let i = floor(x)
        let j = floor(y)
        let u = smooth(x - i)
        let v = smooth(y - j)
        let a = hash(i, j)
        let b = hash(i + 1, j)
        let c = hash(i, j + 1)
        let d = hash(i + 1, j + 1)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    private static func segment(_ px: Double, _ py: Double, _ a: CGPoint, _ b: CGPoint, _ r: Double) -> Double {
        let pax = px - a.x
        let pay = py - a.y
        let bax = b.x - a.x
        let bay = b.y - a.y
        let h = clamp((pax * bax + pay * bay) / (bax * bax + bay * bay))
        let dx = pax - bax * h
        let dy = pay - bay * h
        return (dx * dx + dy * dy).squareRoot() - r
    }

    private static func circle(_ px: Double, _ py: Double, _ c: CGPoint, _ r: Double) -> Double {
        ((px - c.x) * (px - c.x) + (py - c.y) * (py - c.y)).squareRoot() - r
    }
}
