import CoreGraphics
import Foundation

/// Geometry and stable mappings used by the native Office scene.
public enum OfficeLayoutEngine {
    /// Places at least three visible desks, keeping the work area on the left and the lounge on the right.
    public static func layout(agentCount: Int, size: CGSize) -> OfficeLayout {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let floorY = height * 0.38
        let floorHeight = height - floorY
        let workWidth = width * 0.70
        let count = max(3, agentCount)

        let columns: Int
        if count <= 12 {
            columns = min(4, count)
        } else {
            let aspect = workWidth / max(floorHeight, 1)
            columns = min(count, max(5, Int(ceil(sqrt(Double(count) * Double(max(aspect, 0.1)))))))
        }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let baseWidth: CGFloat = 150
        let baseHeight: CGFloat = 90
        let horizontalGap: CGFloat = 16
        let verticalGap: CGFloat = 24
        let cellWidth = baseWidth + horizontalGap
        let cellHeight = baseHeight + verticalGap

        let widthScale = (workWidth - horizontalGap) / CGFloat(columns * Int(cellWidth) - Int(horizontalGap))
        let heightScale = (floorHeight - verticalGap) / CGFloat(rows * Int(cellHeight) - Int(verticalGap))
        let scale = max(0.01, min(1, widthScale, heightScale))
        let gridWidth = CGFloat(columns) * cellWidth * scale - horizontalGap * scale
        let gridHeight = CGFloat(rows) * cellHeight * scale - verticalGap * scale
        let left = max(0, (workWidth - gridWidth) / 2)
        let top = floorY + max(0, (floorHeight - gridHeight) / 2)

        let desks = (0..<count).map { index -> OfficeDeskSlot in
            let column = index % columns
            let row = index / columns
            let x = left + CGFloat(column) * cellWidth * scale
            let y = top + CGFloat(row) * cellHeight * scale
            let frame = CGRect(x: x, y: y, width: baseWidth * scale, height: baseHeight * scale)
            return OfficeDeskSlot(index: index, deskFrame: frame,
                                  seat: CGPoint(x: frame.midX, y: frame.maxY + 5 * scale), scale: scale)
        }

        let lounge = CGRect(x: workWidth, y: floorY, width: width - workWidth, height: floorHeight)
        let loungeSpots = (0..<8).map { index -> CGPoint in
            let column = index % 2
            let row = index / 2
            return CGPoint(x: lounge.minX + lounge.width * (column == 0 ? 0.34 : 0.72),
                           y: floorY + floorHeight * (0.20 + CGFloat(row) * 0.19))
        }
        return OfficeLayout(size: size, desks: desks, loungeFrame: lounge,
                            loungeSpots: loungeSpots, floorY: floorY)
    }
}

/// Pure translations from Jack's runtime statuses to the small set of office poses.
public enum OfficeStateMapper {
    public static func state(for status: AgentStatus) -> OfficeAgentState {
        switch status {
        case .working: .working
        case .blocked: .blocked
        case .done, .idle, .unknown: .idle
        }
    }

    public static func state(for status: ChatStatus, lastMessageRole: String? = nil) -> OfficeAgentState {
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
