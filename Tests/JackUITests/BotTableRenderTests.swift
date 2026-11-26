import AppKit
import Combine
import SwiftUI
import XCTest
import JackCore
@testable import Jack

/// Draws the table with a team and a proposal waiting, to catch a view that crashes or comes out empty.
/// With JACK_SNAPSHOT_DIR set it also writes the pictures there, for a human to look at.
@MainActor final class BotTableRenderTests: XCTestCase {
    private final class IdleDriver: ChatDriver {
        func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws { onEvent(.completed) }
        func respond(approvalID: String, allow: Bool) async throws {}
        func stop() {}
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["JACK_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        return rep
    }

    private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) { for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
        } }
        return seen.count
    }

    func testTheTableDrawsEmptyAndWithATeamAndAProposal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-table-render-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil, driverFactory: { _ in IdleDriver() })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let orchestrator = store.orchestrator
        orchestrator.installedProviders = { [.claude, .codex] }
        func table(_ tab: BotTab = .table) -> some View {
            BotModeView(bots: store.bots, store: store, projectPaths: [NSTemporaryDirectory()], initialTab: tab) { Text("chat").foregroundStyle(.white) }
        }
        let size = CGSize(width: 1440, height: 900)

        let empty = try render(table(), size: size, name: "mesa-1-vacia")
        XCTAssertGreaterThan(distinctColors(empty), 8, "the empty table draws something")

        let jack = orchestrator.ensurePrincipal(projectPath: NSTemporaryDirectory(), choice: .cli(.claude))
        _ = orchestrator.ask("investiga y resume", principal: jack)
        let first = try XCTUnwrap(try? orchestrator.propose(from: jack, rationale: "Dos analistas en paralelo.", specs: [
            BotChildSpec(name: "Ana", instructions: "", task: "Resume el módulo de pagos."),
            BotChildSpec(name: "Beto", instructions: "", task: "Busca pruebas que falten.", provider: "codex"),
        ]).get())
        let proposed = try render(table(), size: size, name: "mesa-2-propuesta")
        XCTAssertGreaterThan(distinctColors(proposed), 8)
        XCTAssertEqual(orchestrator.proposals.first?.state, .pending)

        _ = try XCTUnwrap(try? orchestrator.approve(first.id).get())
        let team = try render(table(), size: size, name: "mesa-3-equipo")
        XCTAssertGreaterThan(distinctColors(team), 8)
        // A child reports: the report node shows it.
        let child = try XCTUnwrap(orchestrator.children(of: jack.id).first)
        XCTAssertNoThrow(try orchestrator.report(from: child, text: "Resumen del módulo de pagos: 3 clases, 12 pruebas, sin cobertura en reembolsos.", blocked: false).get())
        _ = try render(table(), size: size, name: "mesa-3b-informe")

        orchestrator.setApprovalMode(.autonomous, principal: jack)
        let autonomous = try render(table(), size: size, name: "mesa-4-autonomo")
        XCTAssertGreaterThan(distinctColors(autonomous), 8)
        XCTAssertEqual(orchestrator.approvalMode, .autonomous)

        // The busiest table the limits allow: eight bots at once.
        let more = (3...8).map { BotChildSpec(name: "Bot\($0)", instructions: "", task: "Tarea \($0)") }
        XCTAssertNoThrow(try orchestrator.propose(from: jack, rationale: "ocho a la vez", specs: more).get())
        XCTAssertEqual(orchestrator.children(of: jack.id).count, 8)
        let crowded = try render(table(), size: size, name: "mesa-8-ocho-hijos")
        XCTAssertGreaterThan(distinctColors(crowded), 8)
        // The other views share the look.
        for (tab, name) in [(BotTab.agents, "5-agentes"), (.routines, "6-rutinas"), (.channels, "7-canales")] {
            XCTAssertGreaterThan(distinctColors(try render(table(tab), size: size, name: "mesa-" + name)), 6, name)
        }
    }
}

/// The canvas math, and the property that keeps panning cheap: moving the viewport does not invalidate the table.
@MainActor final class BotCanvasModelTests: XCTestCase {
    func testZoomKeepsThePointUnderTheCursorFixed() {
        let model = BotCanvasModel()
        model.viewSize = CGSize(width: 1000, height: 700)
        model.pan(CGSize(width: 120, height: -40))
        let cursor = CGPoint(x: 300, y: 200)
        let before = CGPoint(x: (cursor.x - model.offset.width) / model.scale, y: (cursor.y - model.offset.height) / model.scale)
        model.zoom(by: 1.6, at: cursor)
        let after = CGPoint(x: (cursor.x - model.offset.width) / model.scale, y: (cursor.y - model.offset.height) / model.scale)
        XCTAssertEqual(before.x, after.x, accuracy: 0.001); XCTAssertEqual(before.y, after.y, accuracy: 0.001)
        XCTAssertEqual(model.scale, 1.6, accuracy: 0.0001)
    }

    func testZoomIsClamped() {
        let model = BotCanvasModel()
        model.viewSize = CGSize(width: 800, height: 600)
        for _ in 0..<40 { model.zoom(by: 1.5) }
        XCTAssertEqual(model.scale, BotCanvasModel.range.upperBound)
        for _ in 0..<80 { model.zoom(by: 1 / 1.5) }
        XCTAssertEqual(model.scale, BotCanvasModel.range.lowerBound)
    }

    func testFitPutsEveryNodeInsideTheView() {
        let model = BotCanvasModel()
        model.viewSize = CGSize(width: 1440, height: 900)
        let rects = [CGRect(x: 40, y: 190, width: 300, height: 360), CGRect(x: 850, y: 20, width: 250, height: 190), CGRect(x: 850, y: 1520, width: 250, height: 190), CGRect(x: 1190, y: 120, width: 380, height: 400)]
        model.fit(rects)
        for rect in rects {
            let mapped = CGRect(x: rect.minX * model.scale + model.offset.width, y: rect.minY * model.scale + model.offset.height, width: rect.width * model.scale, height: rect.height * model.scale)
            XCTAssertTrue(CGRect(x: 0, y: 80, width: 1440, height: 670).contains(mapped), "\(mapped)")
        }
        XCTAssertLessThanOrEqual(model.scale, 1.1)
    }

    func testDraggingANodeFollowsTheFingerAtAnyZoomAndStaysInMemory() {
        let model = BotCanvasModel()
        model.viewSize = CGSize(width: 1000, height: 700)
        model.zoom(by: 2, at: .zero)
        model.drag("jack", from: CGPoint(x: 40, y: 190), translation: CGSize(width: 100, height: 50))
        XCTAssertEqual(model.positions["jack"], CGPoint(x: 90, y: 215), "100 screen points are 50 node units at 2x")
        model.drag("jack", from: CGPoint(x: 999, y: 999), translation: CGSize(width: 200, height: 100))
        XCTAssertEqual(model.positions["jack"], CGPoint(x: 140, y: 240), "the start is kept for the whole gesture")
        model.endDrag("jack")
        model.resetLayout()
        XCTAssertTrue(model.positions.isEmpty)
    }

    func testPanAndZoomDoNotInvalidateTheTableButMovingANodeDoes() {
        let model = BotCanvasModel()
        model.viewSize = CGSize(width: 1000, height: 700)
        var tableInvalidations = 0, viewportInvalidations = 0
        let a = model.objectWillChange.sink { tableInvalidations += 1 }
        let b = model.viewport.objectWillChange.sink { viewportInvalidations += 1 }
        for _ in 0..<60 { model.pan(CGSize(width: 3, height: 1)); model.zoom(by: 1.01) }
        XCTAssertEqual(tableInvalidations, 0, "panning must not rebuild the nodes")
        XCTAssertGreaterThan(viewportInvalidations, 0, "only the dot grid, the cables and the transform redraw")
        model.drag("jack", from: .zero, translation: CGSize(width: 5, height: 5))
        XCTAssertGreaterThan(tableInvalidations, 0)
        withExtendedLifetime((a, b)) {}
    }
}
