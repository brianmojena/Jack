import XCTest
@testable import JackCore

final class PaneLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testDroppingOnAnEdgeSplitsBesideOrAboveTheTarget() {
        var layout = PaneLayout().opening(a)
        XCTAssertEqual(layout.columns, [[.main], [.agent(a)]])
        layout = layout.placing(.agent(b), at: .agent(a), .top)
        XCTAssertEqual(layout.columns, [[.main], [.agent(b), .agent(a)]])
        layout = layout.placing(.agent(c), at: .main, .left)
        XCTAssertEqual(layout.columns, [[.agent(c)], [.main], [.agent(b), .agent(a)]])
        layout = layout.placing(.agent(c), at: .main, .bottom)
        XCTAssertEqual(layout.columns, [[.main, .agent(c)], [.agent(b), .agent(a)]], "moving the only chat of a column closes the column")
    }

    func testDroppingInTheCenterSwapsOrReplaces() {
        var layout = PaneLayout().opening(a).opening(b)
        layout = layout.placing(.agent(b), at: .agent(a), .center)
        XCTAssertEqual(layout.columns, [[.main], [.agent(b)], [.agent(a)]])
        layout = layout.placing(.agent(c), at: .agent(a), .center)
        XCTAssertEqual(layout.columns, [[.main], [.agent(b)], [.agent(c)]])
    }

    func testPastTheLimitTheOldestAgentCloses() {
        let layout = PaneLayout().opening(a).opening(b).opening(c).placing(.agent(d), at: .agent(c), .bottom)
        XCTAssertEqual(layout.agents, [b, c, d])
    }

    func testSubAgentsOpenUnderTheirParent() {
        let layout = PaneLayout().opening(a).opening(b, under: .agent(a)).opening(c, under: .main)
        XCTAssertEqual(layout.columns, [[.main, .agent(c)], [.agent(a), .agent(b)]])
    }

    func testPromotingAPaneLeavesTheFormerMainAgentInItsPlace() {
        let layout = PaneLayout().opening(a).placing(.agent(b), at: .agent(a), .bottom).replacing(b, with: c)
        XCTAssertEqual(layout.columns, [[.main], [.agent(a), .agent(c)]])
    }

    func testStorageRoundTripsAndDropsMissingAgents() {
        let layout = PaneLayout().opening(a).placing(.agent(b), at: .main, .top)
        XCTAssertEqual(PaneLayout(encoded: layout.encoded), layout)
        XCTAssertEqual(layout.keeping([b]).columns, [[.agent(b), .main]])
        XCTAssertEqual(PaneLayout(encoded: "").columns, [[.main]])
    }

    func testNarrowWindowsKeepTheColumnsNearestTheMainChat() {
        let layout = PaneLayout().opening(a).opening(b).placing(.agent(c), at: .main, .left)
        // [c] [main] [a] [b]
        XCTAssertEqual(layout.visibleColumns(1), [1])
        XCTAssertEqual(layout.visibleColumns(2), [1, 2])
        XCTAssertEqual(layout.visibleColumns(3), [0, 1, 2])
        XCTAssertEqual(layout.visibleColumns(9), [0, 1, 2, 3])
    }
}
