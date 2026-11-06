import AppKit
import SwiftUI

/// How CodeOS is drawn: following the Mac's light/dark setting, or fixed by hand from the control center.
enum CodeOSAppearance: String, CaseIterable {
    case system, dark, light

    /// What the window is forced to; nil lets it follow the system, live.
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        }
    }

    var next: CodeOSAppearance {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The label for the control center; when it follows the system it also says what the system is using now.
    func label(resolved: ColorScheme) -> String {
        switch self {
        case .system: "Aspecto: automático (\(resolved == .dark ? "oscuro" : "claro"))"
        case .dark: "Aspecto: oscuro"
        case .light: "Aspecto: claro"
        }
    }
}

extension Color {
    /// A colour that changes with the appearance of the view that draws it, so the same code serves both modes.
    static func codeOSDynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension ShapeStyle where Self == Color {
    /// Text, outlines and translucent fills: white on the dark console, near-black on the light one.
    static var ink: Color { .codeOSDynamic(dark: .white, light: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1)) }
    /// The opposite of `ink`: scrims and the text of buttons that are filled with `ink`.
    static var canvas: Color { .codeOSDynamic(dark: .black, light: .white) }
    /// The window's floor colour.
    static var codeOSFloor: Color { .codeOSDynamic(dark: NSColor(srgbRed: 0.035, green: 0.045, blue: 0.08, alpha: 1), light: NSColor(srgbRed: 0.94, green: 0.945, blue: 0.965, alpha: 1)) }
}
