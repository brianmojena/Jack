import AppKit
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
        func table() -> some View {
            BotTableView(orchestrator: orchestrator, bots: store.bots, store: store, projectPaths: [NSTemporaryDirectory()]) { Text("chat").foregroundStyle(.white) }
        }
        let size = CGSize(width: 1180, height: 760)

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

        orchestrator.setApprovalMode(.autonomous, principal: jack)
        let autonomous = try render(table(), size: size, name: "mesa-4-autonomo")
        XCTAssertGreaterThan(distinctColors(autonomous), 8)
        XCTAssertEqual(orchestrator.approvalMode, .autonomous)
    }
}
