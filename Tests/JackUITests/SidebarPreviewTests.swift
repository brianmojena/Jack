import AppKit
import XCTest
import SwiftUI
import JackCore
@testable import Jack

final class SidebarPreviewTests: XCTestCase {
    @MainActor func testPreview() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "SidebarVisualPreview")!
        defaults.removePersistentDomain(forName: "SidebarVisualPreview")
        defer { defaults.removePersistentDomain(forName: "SidebarVisualPreview") }
        let rows = ["Jack", "Marketing", "Pixel"].enumerated().flatMap { index, project in
            (0..<2).map { item in
                SidebarRowModel(id: UUID(), title: item == 0 ? "Mejorar interfaz" : "Revisar pruebas", projectName: project,
                                provider: .claude, model: "default", status: .idle, activity: "", unread: false,
                                updatedAt: Date(timeIntervalSinceNow: Double(-index * 60)), canEdit: true)
            }
        }
        let view = JackSidebar(rows: rows, projectPaths: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "/work/" + $0.projectName) }),
                               selectedID: rows.first?.id, onNewConversation: { _ in }, onSelect: { _ in }, onRename: { _ in },
                               onDelete: { _ in }, onSetUnread: { _, _ in }, onSetPinned: { _, _ in }, onSetPending: { _, _ in },
                               onContinueInTerminal: { _ in }, onReloadFromClaude: { _ in }, onOpenInPane: { _ in }, isImprovingChatNames: false, onImproveChatNames: {}, onHide: {}, searchRequest: 0)
            .defaultAppStorage(defaults).environment(\.interfaceStyle, .basic).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 540)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/jack-sidebar-drag-preview.png"))
        window.orderOut(nil)
    }
}
