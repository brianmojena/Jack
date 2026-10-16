import AppKit
import JackCore
import SwiftUI
import XCTest
@testable import Jack

final class Office2DInteractionTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000)

    private func agent(_ state: Office2DAgentState, id: String = "agent") -> Office2DAgent {
        Office2DAgent(id: id, name: "Codex", kind: "codex", state: state, activity: nil, seed: 0)
    }

    @MainActor func testWalkAdvancesContinuouslyAndSurvivesStreamingUpdates() throws {
        let motion = Office2DChoreographer()
        let layout = Office2DNav.layout(agentCount: 3)
        motion.update(agents: [agent(.working)], layout: layout, now: epoch)
        let first = try XCTUnwrap(motion.placement(for: "agent", now: epoch))
        let next = try XCTUnwrap(motion.placement(for: "agent", now: epoch.addingTimeInterval(0.5)))
        XCTAssertEqual(first.pose, .walking)
        XCTAssertGreaterThan(hypot(next.position.x - first.position.x, next.position.y - first.position.y), 20,
                             "A route must advance more than the old one-pixel clamp")
        motion.update(agents: [agent(.working)], layout: layout, now: epoch.addingTimeInterval(0.5))
        let afterUpdate = try XCTUnwrap(motion.placement(for: "agent", now: epoch.addingTimeInterval(0.5)))
        XCTAssertEqual(next.position, afterUpdate.position, "Streaming must not reset a walk")
        let arrived = try XCTUnwrap(motion.placement(for: "agent", now: epoch.addingTimeInterval(30)))
        XCTAssertEqual(arrived.position, layout.desks[0].seat)
        XCTAssertEqual(arrived.pose, .seatedTyping)
    }

    @MainActor func testCompletionCelebratesThenWalksToLoungeWithoutAnotherStoreUpdate() throws {
        let motion = Office2DChoreographer()
        let layout = Office2DNav.layout(agentCount: 3)
        motion.reduceMotion = true
        motion.update(agents: [agent(.thinking)], layout: layout, now: epoch)
        motion.reduceMotion = false
        motion.update(agents: [agent(.idle)], layout: layout, now: epoch)
        XCTAssertEqual(motion.placement(for: "agent", now: epoch)?.pose, .celebrating)
        XCTAssertEqual(motion.placement(for: "agent", now: epoch.addingTimeInterval(2))?.pose, .walking)
        let resting = try XCTUnwrap(motion.placement(for: "agent", now: epoch.addingTimeInterval(32)))
        XCTAssertEqual(resting.position, Office2DNav.spot(0))
        XCTAssertEqual(resting.pose, .standingCoffee)
    }

    @MainActor func testReducedMotionSettlesImmediatelyAndLoungeActionsIgnoreBusyAgents() throws {
        let motion = Office2DChoreographer()
        let layout = Office2DNav.layout(agentCount: 3)
        motion.reduceMotion = true
        motion.update(agents: [agent(.thinking)], layout: layout, now: epoch)
        XCTAssertEqual(motion.placement(for: "agent", now: epoch)?.pose, .seatedThinking)
        motion.visitLounge(agentID: "agent", spot: 3, now: epoch)
        XCTAssertEqual(motion.placement(for: "agent", now: epoch)?.position, layout.desks[0].seat)
        motion.update(agents: [agent(.idle)], layout: layout, now: epoch)
        motion.visitLounge(agentID: "agent", spot: 3, now: epoch)
        XCTAssertEqual(motion.placement(for: "agent", now: epoch)?.position, Office2DNav.spot(3))
        XCTAssertEqual(motion.placement(for: "agent", now: epoch)?.pose, .sittingSofa)
        motion.update(agents: [], layout: layout, now: epoch)
        XCTAssertNil(motion.placement(for: "agent", now: epoch))
    }

    func testLightOnlyOffersItsExistingInterfaces() {
        XCTAssertEqual(InterfaceStyle.allCases.filter(\.availableInLight), [.basic, .ice])
        XCTAssertFalse(InterfaceStyle.office2D.availableInLight)
        XCTAssertTrue(InterfaceStyle.office.isOffice)
        XCTAssertTrue(InterfaceStyle.office2D.isOffice)
        XCTAssertEqual(InterfaceStyle(rawValue: "office"), .office, "Existing 3D preferences remain valid")
    }

    @MainActor func testRealStoreRetainsCompletedAgentsAndRendersAtCompactAndWideSizes() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-office2d-" + UUID().uuidString)
        let suite = "Office2DTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "delegationEnabled")
        defaults.set(false, forKey: "office2DAnimations")
        defaults.set(InterfaceStyle.office2D.rawValue, forKey: InterfaceStyle.key)
        var drivers: [PreviewDriver] = []
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: defaults, driverFactory: { _ in
            let driver = PreviewDriver()
            drivers.append(driver)
            return driver
        }, commandLoader: { _, _ in [] })
        defer {
            store.shutdown()
            drivers.forEach { $0.stop() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = Office2DViewModel(store: store, onOpen: { _ in })
        XCTAssertTrue(model.agents.isEmpty)
        let view = Office2DView(store: store, batterySaver: BatterySaver(), onOpen: { _ in })
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        try snapshot(host, size: CGSize(width: 1100, height: 720), name: "empty")

        var ids: [UUID] = []
        for (provider, title) in [(ChatProvider.codex, "Construir la interfaz"), (.claude, "Revisar los cambios"), (.opencode, "Preparar las pruebas")] {
            let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: provider, title: title))
            ids.append(id)
            store.send("Vista de prueba", to: id)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.agents.count, 3)
        let stableOrder = model.agents.map(\.id)
        drivers.last?.event?(.approval(ChatApproval(id: "approval", title: "Ejecutar pruebas", detail: "Confirmar")))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.agents.contains { $0.state == .waiting })
        try snapshot(host, size: CGSize(width: 1100, height: 720), name: "wide")
        window.setContentSize(NSSize(width: 636, height: 580))
        try await Task.sleep(for: .milliseconds(100))
        try snapshot(host, size: CGSize(width: 636, height: 580), name: "compact")
        host.rootView = Office2DView(store: store, batterySaver: BatterySaver(), sidebarVisible: false, onOpen: { _ in })
            .defaultAppStorage(defaults)
        try await Task.sleep(for: .milliseconds(100))
        try snapshot(host, size: CGSize(width: 636, height: 580), name: "no-sidebar")
        drivers.first?.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.agents.map(\.id), stableOrder)
        XCTAssertTrue(model.agents.contains { $0.state == .idle }, "Completed agents remain to celebrate and rest")
        let newcomer = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex, title: "Otro agente"))
        store.send("Vista de prueba", to: newcomer)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(Array(model.agents.prefix(3).map(\.id)), stableOrder, "An arrival must not move existing desks")
        XCTAssertEqual(model.agents.last?.id, newcomer.uuidString)
        store.remove(ids[0])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.agents.contains { $0.id == ids[0].uuidString })
    }

    @MainActor private func snapshot<V: View>(_ host: NSHostingView<V>, size: CGSize, name: String) throws {
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/jack-office2d-\(name).png"))
        XCTAssertGreaterThan(data.count, 10_000, "The scene must actually render")
    }
}

@MainActor private final class PreviewDriver: ChatDriver {
    var event: (@MainActor (ChatEvent) -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    func run(conversation: ChatConversation, prompt: String, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        event = onEvent
        onEvent(.tool(id: "read", title: "Read", detail: "Sources/Jack/Office2D/Office2DView.swift", status: "running"))
        await withCheckedContinuation { continuation = $0 }
    }
    func respond(approvalID: String, allow: Bool) async throws {}
    func stop() { continuation?.resume(); continuation = nil }
}
