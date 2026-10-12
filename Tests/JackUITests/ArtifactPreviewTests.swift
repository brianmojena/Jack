import AppKit
import SwiftUI
import WebKit
import XCTest
import JackCore
@testable import Jack

final class ArtifactPreviewTests: XCTestCase {
    @MainActor func testInteractiveHTMLBlocksNetworkAndHasNoNativeBridge() async throws {
        _ = NSApplication.shared
        let view = ArtifactWebPreview.configuredView(svg: false)
        let delegate = ArtifactWebPreview.Coordinator()
        view.navigationDelegate = delegate
        view.loadHTMLString(ArtifactWebPreview.document("""
        <button id="increment" onclick="document.getElementById('count').textContent='1'">Incrementar</button><span id="count">0</span>
        <script>window.ready=true;window.violations=[];document.addEventListener('securitypolicyviolation',e=>window.violations.push(e.effectiveDirective));fetch('https://127.0.0.1:9/blocked').catch(()=>{});</script>
        """), baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("window.ready === true")) as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready, "Inline script must run in the local interactive preview")
        let count = try await view.evaluateJavaScript("document.getElementById('increment').click(); document.getElementById('count').textContent")
        XCTAssertEqual(count as? String, "1")
        var blocked = false
        for _ in 0..<40 {
            if (try await view.evaluateJavaScript("window.violations.includes('connect-src')")) as? Bool == true { blocked = true; break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(blocked, "CSP must block requests before they reach the network")
        let bridge = try await view.evaluateJavaScript("typeof window.webkit?.messageHandlers?.jack")
        XCTAssertEqual(bridge as? String, "undefined")
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(ArtifactWebPreview.configuredView(svg: true).configuration.defaultWebpagePreferences.allowsContentJavaScript)
        view.stopLoading()
    }

    @MainActor func testLibraryPanelRendersAtWorkspaceWidth() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jack-artifact-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ArtifactLibrary(directory: directory)
        let conversation = ChatConversation(projectPath: "/project")
        _ = try library.create(title: "Informe de investigación", kind: .markdown,
                               data: Data("# Resultados\n\nEste artefacto puede editarse con cualquier agente.\n\n- Contexto compartido\n- Versiones independientes".utf8), projectPath: conversation.projectPath)
        let panel = ArtifactPanel(library: library, conversation: conversation, openLink: { _ in }, askAgent: { _ in })
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 620)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/jack-artifact-panel.png"))
        XCTAssertEqual(bitmap.pixelsWide, Int(480 * window.backingScaleFactor))
        window.orderOut(nil)
    }
}
