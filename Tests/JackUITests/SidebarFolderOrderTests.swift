import XCTest
import JackCore
@testable import Jack

final class SidebarFolderOrderTests: XCTestCase {
    private func row(_ path: String, time: TimeInterval) -> SidebarRowModel {
        SidebarRowModel(id: UUID(), title: path, projectName: path, provider: .claude, model: "default",
                        status: .idle, activity: "", unread: false, updatedAt: Date(timeIntervalSince1970: time), canEdit: true)
    }

    func testManualOrderIgnoresDuplicatesAndMissingProjects() {
        let a = row("Alpha", time: 10), b = row("Beta", time: 20), c = row("Gamma", time: 30)
        let paths = [a.id: "/Alpha", b.id: "/Beta", c.id: "/Gamma"]
        let sections = SidebarSections(rows: [a, b, c], projectPaths: paths,
                                       projectOrder: ["/missing", "/Beta", "/Beta", "/Alpha"])
        XCTAssertEqual(sections.projects.map(\.path), ["/Beta", "/Alpha", "/Gamma"])
        XCTAssertEqual(sections.visibleIDs(collapsed: ["/Alpha"]), [b.id, c.id])
    }

    func testAlphabeticalOrderOverridesManualOrderAndBreaksNameTiesByPath() {
        let a = row("Alpha", time: 10), b = row("Beta", time: 20), a2 = row("Alpha", time: 30)
        let paths = [a.id: "/z/Alpha", b.id: "/Beta", a2.id: "/a/Alpha"]
        let sections = SidebarSections(rows: [b, a, a2], projectPaths: paths,
                                       projectOrder: ["/Beta", "/z/Alpha"], alphabetical: true)
        XCTAssertEqual(sections.projects.map(\.path), ["/a/Alpha", "/z/Alpha", "/Beta"])
        XCTAssertEqual(sections.visibleIDs(collapsed: []), [a2.id, a.id, b.id])
    }

    func testDefaultOrderRemainsMostRecentlyActiveFirst() {
        let a = row("Alpha", time: 10), b = row("Beta", time: 20)
        let sections = SidebarSections(rows: [a, b], projectPaths: [a.id: "/Alpha", b.id: "/Beta"])
        XCTAssertEqual(sections.projects.map(\.path), ["/Beta", "/Alpha"])
    }

    func testDropMovesOnlyExistingProjects() {
        let order = ["/Alpha", "/Beta", "/Gamma"]
        XCTAssertEqual(SidebarSections.movingProject("/Gamma", before: "/Alpha", in: order), ["/Gamma", "/Alpha", "/Beta"])
        XCTAssertNil(SidebarSections.movingProject("foreign", before: "/Alpha", in: order))
        XCTAssertNil(SidebarSections.movingProject("/Beta", before: "missing", in: order))
        XCTAssertNil(SidebarSections.movingProject("/Beta", before: "/Beta", in: order))
    }

    func testDropAfterLastFolderAndBothDirections() {
        let order = ["/Alpha", "/Beta", "/Gamma"]
        XCTAssertEqual(SidebarSections.movingProject("/Alpha", relativeTo: "/Gamma", after: true, in: order),
                       ["/Beta", "/Gamma", "/Alpha"])
        XCTAssertEqual(SidebarSections.movingProject("/Gamma", relativeTo: "/Alpha", after: true, in: order),
                       ["/Alpha", "/Gamma", "/Beta"])
        XCTAssertEqual(SidebarSections.movingProject("/Alpha", relativeTo: "/Beta", after: true, in: order),
                       ["/Beta", "/Alpha", "/Gamma"])
    }

    func testAdjacentNoOpIsRejectedWithoutSavingANewOrder() {
        let order = ["/Alpha", "/Beta", "/Gamma"]
        XCTAssertNil(SidebarSections.movingProject("/Alpha", relativeTo: "/Beta", after: false, in: order))
        XCTAssertNil(SidebarSections.movingProject("/Gamma", relativeTo: "/Beta", after: true, in: order))
    }

    @MainActor func testCancellingADragClearsFeedbackAndKeepsTheOriginalOrder() {
        let order = ["/Alpha", "/Beta", "/Gamma"]
        let state = SidebarFolderDragState()
        state.begin("/Alpha", order: order)
        state.show("/Gamma", after: true)
        XCTAssertEqual(state.order, order, "hovering must not reorder any folders")
        XCTAssertEqual(state.target, .init(path: "/Gamma", after: true))
        state.end()
        XCTAssertNil(state.source)
        XCTAssertNil(state.target)
        XCTAssertTrue(state.order.isEmpty)
    }
}
