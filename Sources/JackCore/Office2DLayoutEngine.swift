import CoreGraphics
import Foundation

/// Exact world-space geometry used by `public/nav.js` in InteractiveAgents.
public enum Office2DNav {
    public static let world = CGSize(width: 1280, height: 760)
    public static let aisleX: CGFloat = 950

    private static let colW: CGFloat = 230
    private static let rowH: CGFloat = 165

    public static let spots: [CGPoint] = [
        CGPoint(x: 1030, y: 294), CGPoint(x: 1108, y: 294),
        CGPoint(x: 1105, y: 480), CGPoint(x: 1150, y: 480), CGPoint(x: 1195, y: 480),
        CGPoint(x: 1040, y: 640), CGPoint(x: 1180, y: 640),
        CGPoint(x: 1075, y: 706), CGPoint(x: 1150, y: 706)
    ]

    /// Same formulas and iteration order as `deskLayout(n)` in nav.js.
    public static func deskLayout(_ n: Int) -> [Office2DDeskSlot] {
        guard n > 0 else { return [] }
        let cols = n <= 3 ? max(n, 1) : n <= 4 ? 2 : n <= 6 ? 3 : n <= 12 ? 4 : Int(ceil(Double(n) / 3))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let colW = min(Self.colW, 920 / CGFloat(cols))
        let x0 = 20 + (920 - CGFloat(cols) * colW) / 2 + colW / 2
        let dy0 = 290 + (2 - min(rows - 1, 2)) * 82
        return (0..<n).map { i in
            let col = i % cols, row = i / cols
            let cx = x0 + CGFloat(col) * colW
            let dy = CGFloat(dy0 + row * Int(rowH))
            // deskFrame bounds the original SVG workstation (x=-95...95, y=-82...44).
            return Office2DDeskSlot(index: i,
                                  deskFrame: CGRect(x: cx - 95, y: dy - 82, width: 190, height: 126),
                                  seat: CGPoint(x: cx + 55, y: dy + 12), scale: 1)
        }
    }

    public static func spot(_ i: Int) -> CGPoint {
        if spots.indices.contains(i) { return spots[i] }
        let k = i - spots.count
        return CGPoint(x: 985 + CGFloat((k * 83) % 250), y: 540 + CGFloat((k * 47) % 190))
    }

    /// nav.js routing, with explicit endpoints included for convenient Swift callers.
    public static func buildPath(from: CGPoint, to: CGPoint, desks: [Office2DDeskSlot]) -> [CGPoint] {
        func center(_ desk: Office2DDeskSlot) -> (cx: CGFloat, dy: CGFloat) {
            (desk.deskFrame.midX, desk.seat.y - 12)
        }
        func gapY(_ desk: Office2DDeskSlot) -> CGFloat { center(desk).dy + 82 }
        func nearestGap(_ y: CGFloat) -> CGFloat {
            desks.map(gapY).min(by: { abs($0 - y) < abs($1 - y) }) ?? y
        }
        let sourceDesk = desks.first { abs($0.seat.x - from.x) < 0.001 && abs($0.seat.y - from.y) < 0.001 }
        let destinationDesk = desks.first { abs($0.seat.x - to.x) < 0.001 && abs($0.seat.y - to.y) < 0.001 }
        let inDeskZone = sourceDesk != nil || from.x < aisleX - 12
        let gy = sourceDesk.map(gapY) ?? nearestGap(from.y)
        var points: [CGPoint] = [from]
        if let sourceDesk {
            let cx = center(sourceDesk).cx
            points.append(CGPoint(x: cx + 115, y: sourceDesk.seat.y))
            points.append(CGPoint(x: cx + 115, y: gy))
        } else if inDeskZone { points.append(CGPoint(x: from.x, y: gy)) }
        if let dest = destinationDesk {
            let c = center(dest)
            if inDeskZone {
                points.append(CGPoint(x: c.cx + 115, y: gy))
                points.append(CGPoint(x: c.cx + 115, y: dest.seat.y))
            } else {
                points.append(CGPoint(x: aisleX, y: gapY(dest)))
                points.append(CGPoint(x: c.cx + 115, y: gapY(dest)))
                points.append(CGPoint(x: c.cx + 115, y: dest.seat.y))
            }
            points.append(to)
        } else if to.x < aisleX - 12 {
            let dest = desks.min(by: { hypot($0.seat.x - to.x, $0.seat.y - to.y) < hypot($1.seat.x - to.x, $1.seat.y - to.y) })
            if let dest {
                let c = center(dest)
                if inDeskZone {
                    points.append(CGPoint(x: c.cx + 115, y: gy))
                    points.append(CGPoint(x: c.cx + 115, y: dest.seat.y))
                } else {
                    points.append(CGPoint(x: aisleX, y: gapY(dest)))
                    points.append(CGPoint(x: c.cx + 115, y: gapY(dest)))
                    points.append(CGPoint(x: c.cx + 115, y: dest.seat.y))
                }
                points.append(to)
            } else { points.append(to) }
        } else {
            if inDeskZone { points.append(CGPoint(x: aisleX, y: gy)) }
            points.append(to)
        }
        // Match nav's route vertices while dropping adjacent duplicates.
        return points.enumerated().filter { index, point in index == 0 || point != points[index - 1] }.map(\.element)
    }

    public static func layout(agentCount: Int) -> Office2DLayout {
        Office2DLayout(size: world, desks: deskLayout(agentCount),
                     loungeFrame: CGRect(x: aisleX, y: 200, width: world.width - aisleX, height: 560),
                     loungeSpots: spots, floorY: 200)
    }
}

/// Compatibility entry point for existing callers; Office2D geometry is always in world coordinates.
public enum Office2DLayoutEngine {
    public static func layout(agentCount: Int, size: CGSize) -> Office2DLayout {
        Office2DNav.layout(agentCount: agentCount)
    }
}

/// Pure translations from Jack's runtime statuses to the small set of office poses.
public enum Office2DStateMapper {
    public static func state(for status: AgentStatus) -> Office2DAgentState {
        switch status {
        case .working: .working
        case .blocked: .blocked
        case .done, .idle, .unknown: .idle
        }
    }

    public static func state(for status: ChatStatus, lastMessageRole: String? = nil) -> Office2DAgentState {
        switch status {
        case .idle: .idle
        case .queued, .waiting: .waiting
        case .failed: .failed
        case .running:
            switch lastMessageRole {
            case "reasoning": .thinking
            case "assistant", "tool": .working
            default: .thinking
            }
        }
    }

    /// FNV-1a over UTF-8, stable across launches and processes.
    public static func seed(for id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
