import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit

/// El color y la imagen de cada plataforma: el motor de la oficina se escribe una vez con estos nombres y compila igual en la
/// Mac (AppKit) y en el iPhone (UIKit).
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
#else
import UIKit

typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
#endif

extension PlatformColor {
    /// Los componentes en sRGB (0…1), en las dos plataformas.
    var srgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        (usingColorSpace(.sRGB) ?? self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return (red, green, blue, alpha)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension Image {
    /// Una imagen de la plataforma (`NSImage` o `UIImage`).
    init(platformImage image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension View {
    /// Un botón con aspecto de enlace (en el iPhone, sin borde: `.link` es solo de la Mac).
    func officeLinkButton() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
