import AppKit
@testable import Jack
@testable import JackCore
import SwiftUI
import XCTest

@MainActor
final class CustomizationAppearanceTests: XCTestCase {
    func testNestedEquatableViewRendersLiveThemeAndLightResetsToSystemPalette() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-customization-" + UUID().uuidString)
        let center = CustomizationCenter(directory: folder, enabled: true)
        let appearance = CustomizationAppearance.shared
        let defaults = UserDefaults.standard
        let previousLightMode = defaults.object(forKey: "lightModeEnabled")
        defaults.set(false, forKey: "lightModeEnabled")
        defer {
            appearance.disable()
            if let previousLightMode { defaults.set(previousLightMode, forKey: "lightModeEnabled") }
            else { defaults.removeObject(forKey: "lightModeEnabled") }
            center.setEnabled(false)
            try? FileManager.default.removeItem(at: folder)
        }

        try center.save(CustomizationPack(id: "live-theme", name: "Live", theme: .init(canvas: "#E02030"), layout: .init(interface: .basic)))
        try center.setPackEnabled("live-theme", true)
        appearance.connect(to: center)

        let themedView = NestedEquatableTheme().equatable()
            .frame(width: 40, height: 40)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: themedView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        flush(host, in: window)
        defer { window.orderOut(nil) }

        let themedColor = try await renderedCenterPixel(
            host,
            matching: NSColor(srgbRed: 224 / 255, green: 32 / 255, blue: 48 / 255, alpha: 1),
            snapshotPath: "/private/tmp/jack-customization-live-initial.png"
        )
        XCTAssertTrue(themedColor.matches, "A nested Equatable descendant should render the active theme without changing view identity. \(themedColor.diagnostic)")

        try center.save(CustomizationPack(id: "live-theme", name: "Live", theme: .init(canvas: "#1040D0"), layout: .init(interface: .basic)))
        let changedColor = try await renderedCenterPixel(
            host,
            matching: NSColor(srgbRed: 16 / 255, green: 64 / 255, blue: 208 / 255, alpha: 1),
            snapshotPath: "/private/tmp/jack-customization-live-updated.png"
        )
        XCTAssertTrue(changedColor.matches, "Changing the pack should refresh the nested Equatable descendant in place. \(changedColor.diagnostic)")

        defaults.set(true, forKey: "lightModeEnabled")
        appearance.disable()
        center.setEnabled(false)
        XCTAssertNil(appearance.paletteTheme, "Light mode must immediately fall back to the system palette")
        XCTAssertNil(center.effectiveLayout, "Disabling the customization center restores the default layout")
    }

    func testCustomizationEditorRendersEmptyAndPopulatedSnapshots() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-customization-editor-" + UUID().uuidString)
        let center = CustomizationCenter(directory: folder, enabled: true)
        let defaults = UserDefaults.standard
        let previousLightMode = defaults.object(forKey: "lightModeEnabled")
        defaults.set(false, forKey: "lightModeEnabled")
        CustomizationAppearance.shared.disable()
        defer {
            if let previousLightMode { defaults.set(previousLightMode, forKey: "lightModeEnabled") }
            else { defaults.removeObject(forKey: "lightModeEnabled") }
            center.setEnabled(false)
            try? FileManager.default.removeItem(at: folder)
        }

        try await renderEditor(center, to: "/private/tmp/jack-customization-empty.png")

        let pack = CustomizationPack(
            id: "editor-preview", name: "Studio Night", author: "Jack",
            theme: .init(appearance: .dark, canvas: "#151923", chrome: "#202635", panel: "#293246",
                         selection: "#394967", accent: "#78A9FF", text: "#E6ECF5", muted: "#9CAAC0"),
            layout: .init(interface: .basic, sidebarPosition: .right, sidebarWidth: 300, sidebarVisible: true,
                          statusBarVisible: true, workspacePosition: .bottom, workspaceWidth: 560,
                          workspaceHeight: 300, explorerVisible: true),
            commands: [.init(name: "custom-review", title: "Revisar cambios", kind: .prompt, content: "Revisa {{args}}")]
        )
        try center.save(pack)
        try center.setPackEnabled(pack.id, true)
        try await renderEditor(center, to: "/private/tmp/jack-customization-editor.png")
    }

    private func renderEditor(_ center: CustomizationCenter, to path: String) async throws {
        let size = NSSize(width: 720, height: 620)
        let editor = CustomizationSettingsView(center: center)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<8 {
            flush(host, in: window)
            try await Task.sleep(for: .milliseconds(15))
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width), "The snapshot should preserve the editor's 720-point width")
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height), "The snapshot should preserve the editor's 620-point height")
        XCTAssertGreaterThan(nonBackgroundPixelCount(bitmap), 200, "The snapshot should contain rasterized editor controls and text, not only a background")
    }

    private func flush(_ host: NSView, in window: NSWindow) {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.displayIfNeeded()
    }

    private func nonBackgroundPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        guard let background = bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.035
                    || abs(color.greenComponent - background.greenComponent) > 0.035
                    || abs(color.blueComponent - background.blueComponent) > 0.035 {
                    count += 1
                }
            }
        }
        return count
    }

    private func renderedCenterPixel<V: View>(
        _ host: NSHostingView<V>, matching expected: NSColor, snapshotPath: String
    ) async throws -> PixelCheck {
        let expected = try XCTUnwrap(expected.usingColorSpace(.sRGB))
        var lastColor: NSColor?
        var lastBitmap: NSBitmapImageRep?
        for _ in 0..<80 {
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            if let window = host.window { flush(host, in: window) }
            else { host.layoutSubtreeIfNeeded() }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let color = bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB)
            lastColor = color
            lastBitmap = bitmap
            if let color,
               color.redComponent.isClose(to: expected.redComponent),
               color.greenComponent.isClose(to: expected.greenComponent),
               color.blueComponent.isClose(to: expected.blueComponent) {
                try save(bitmap, to: snapshotPath)
                return PixelCheck(matches: true, actual: color, expected: expected, snapshotPath: snapshotPath)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bitmap = try XCTUnwrap(lastBitmap)
        try save(bitmap, to: snapshotPath)
        return PixelCheck(matches: false, actual: lastColor, expected: expected, snapshotPath: snapshotPath)
    }

    private func save(_ bitmap: NSBitmapImageRep, to path: String) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private struct PixelCheck {
        let matches: Bool
        let actual: NSColor?
        let expected: NSColor
        let snapshotPath: String

        var diagnostic: String {
            "Expected \(actualHex(expected)); got \(actual.map(actualHex) ?? "no center pixel"); snapshot: \(snapshotPath)"
        }

        private func actualHex(_ color: NSColor) -> String {
            let color = color.usingColorSpace(.sRGB) ?? color
            return String(
                format: "#%02X%02X%02X (sRGB %.4f, %.4f, %.4f)",
                Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()),
                color.redComponent, color.greenComponent, color.blueComponent
            )
        }
    }
}

private struct NestedEquatableTheme: View, Equatable {
    static func == (_: Self, _: Self) -> Bool { true }
    var body: some View { EquatableThemeLeaf().equatable().frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct EquatableThemeLeaf: View, Equatable {
    static func == (_: Self, _: Self) -> Bool { true }
    var body: some View { JackPalette.canvas }
}

private extension CGFloat {
    func isClose(to other: CGFloat) -> Bool { abs(self - other) < 0.025 }
}
