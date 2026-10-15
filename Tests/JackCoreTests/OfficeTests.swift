import CoreGraphics
import JackCore
import Testing

struct OfficeTests {
    @Test(arguments: [0, 1, 3, 12, 20])
    func layoutFitsAndSeparatesDesks(agentCount: Int) {
        let size = CGSize(width: 1100, height: 700)
        let layout = OfficeLayoutEngine.layout(agentCount: agentCount, size: size)

        #expect(layout.size == size)
        #expect(layout.floorY == size.height * 0.38)
        #expect(layout.desks.count == max(3, agentCount))
        #expect(layout.loungeSpots.count >= 6)
        #expect(layout.loungeFrame.minX >= 0 && layout.loungeFrame.maxX <= size.width)
        #expect(layout.loungeFrame.minY >= layout.floorY && layout.loungeFrame.maxY <= size.height)

        for desk in layout.desks {
            #expect(desk.deskFrame.minX >= 0)
            #expect(desk.deskFrame.minY >= layout.floorY)
            #expect(desk.deskFrame.maxX <= size.width * 0.70 + 0.001)
            #expect(desk.deskFrame.maxY <= size.height + 0.001)
            #expect(desk.scale > 0 && desk.scale <= 1)
        }
        for left in layout.desks.indices {
            for right in layout.desks.indices where right > left {
                #expect(!layout.desks[left].deskFrame.intersects(layout.desks[right].deskFrame))
            }
        }
        for spot in layout.loungeSpots {
            #expect(layout.loungeFrame.contains(spot))
        }
        if agentCount > 12 { #expect(layout.desks[0].scale < 1) }
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
