import CoreGraphics
import JackCore
import Testing

struct OfficeTests {
    @Test func navDeskCoordinatesMatchWeb() {
        let expected: [Int: [(CGFloat, CGFloat, CGFloat, CGFloat)]] = [
            1: [(535, 454, 595, 536)],
            3: [(305, 454, 365, 536), (535, 454, 595, 536), (765, 454, 825, 536)],
            6: [(305, 372, 365, 454), (535, 372, 595, 454), (765, 372, 825, 454),
                (305, 537, 365, 619), (535, 537, 595, 619), (765, 537, 825, 619)],
            12: [(190, 290, 250, 372), (420, 290, 480, 372), (650, 290, 710, 372), (880, 290, 940, 372),
                 (190, 455, 250, 537), (420, 455, 480, 537), (650, 455, 710, 537), (880, 455, 940, 537),
                 (190, 620, 250, 702), (420, 620, 480, 702), (650, 620, 710, 702), (880, 620, 940, 702)]
        ]
        for (count, positions) in expected {
            let desks = OfficeNav.deskLayout(count)
            #expect(desks.count == positions.count)
            for (desk, position) in zip(desks, positions) {
                #expect(abs(desk.seat.x - position.0) < 0.001)
                #expect(abs((desk.seat.y - 12) - position.1) < 0.001)
                #expect(abs((desk.deskFrame.midX + 115) - position.2) < 0.001)
                #expect(abs((desk.seat.y - 12 + 82) - position.3) < 0.001)
            }
        }
    }

    @Test func navWorldAndSpotsAreExact() {
        #expect(OfficeNav.world == CGSize(width: 1280, height: 760))
        #expect(OfficeNav.aisleX == 950)
        #expect(OfficeNav.spot(0) == CGPoint(x: 1030, y: 294))
        #expect(OfficeNav.spot(8) == CGPoint(x: 1150, y: 706))
        #expect(OfficeNav.spot(9) == CGPoint(x: 985, y: 540))
        let layout = OfficeNav.layout(agentCount: 3)
        #expect(layout.size == OfficeNav.world)
        #expect(layout.desks == OfficeNav.deskLayout(3))
        #expect(layout.loungeSpots == OfficeNav.spots)
    }

    @Test func buildPathIncludesEndpoints() {
        let desks = OfficeNav.deskLayout(3)
        let from = CGPoint(x: 500, y: 310)
        let to = CGPoint(x: 1105, y: 480)
        let path = OfficeNav.buildPath(from: from, to: to, desks: desks)
        #expect(path.first == from)
        #expect(path.last == to)
    }

    @Test func mapsRuntimeStates() {
        #expect(OfficeStateMapper.state(for: AgentStatus.working) == .working)
        #expect(OfficeStateMapper.state(for: AgentStatus.blocked) == .blocked)
        #expect(OfficeStateMapper.state(for: AgentStatus.done) == .idle)
        #expect(OfficeStateMapper.state(for: ChatStatus.running, lastMessageRole: "reasoning") == .thinking)
        #expect(OfficeStateMapper.state(for: ChatStatus.running, lastMessageRole: "tool") == .working)
        #expect(OfficeStateMapper.state(for: ChatStatus.waiting) == .waiting)
        #expect(OfficeStateMapper.state(for: ChatStatus.failed) == .failed)
        #expect(OfficeStateMapper.state(for: ChatStatus.queued) == .waiting)
    }

    @Test func seedIsStable() {
        #expect(OfficeStateMapper.seed(for: "conversation-1") == OfficeStateMapper.seed(for: "conversation-1"))
        #expect(OfficeStateMapper.seed(for: "conversation-1") != OfficeStateMapper.seed(for: "conversation-2"))
        #expect(OfficeStateMapper.seed(for: "") == 0xcbf29ce484222325)
    }
}
