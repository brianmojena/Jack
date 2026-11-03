import SwiftUI
import UIKit

/// Los colores de Jack que usa la oficina, en el iPhone (en la Mac están en `JackDesign.swift`). La oficina va siempre a oscuras,
/// así que son los del modo oscuro.
enum JackPalette {
    static let canvasColor = rgb(0x0E0E0F)
    static let chromeColor = rgb(0x161618)
    static let canvas = Color(uiColor: canvasColor)
    static let chrome = Color(uiColor: chromeColor)
    static let panel = Color.white.opacity(0.05)
    static let panelStrong = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.085)
    static let accent = Color.accentColor
    static let muted = Color(uiColor: .secondaryLabel)
    static let faint = Color(uiColor: .tertiaryLabel)
    static let red = Color(uiColor: .systemRed)
    static let amber = Color(uiColor: .systemOrange)
    static let green = Color(uiColor: .systemGreen)
    static let blue = Color(uiColor: .systemBlue)

    static func rgb(_ value: Int) -> UIColor {
        UIColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
