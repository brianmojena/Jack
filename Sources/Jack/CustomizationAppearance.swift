import AppKit
import Combine
import JackCore
import Observation
import SwiftUI

extension Notification.Name {
    static let jackCustomizationChanged = Notification.Name("Jack.customizationChanged")
}

/// Normal-mode theme state. JackPalette reads this observable value while rendering.
@MainActor
@Observable
final class CustomizationAppearance {
    static let shared = CustomizationAppearance()

    private(set) var theme: CustomizationTheme?
    private(set) var isEnabled = false
    private(set) var revision = 0
    @ObservationIgnored private var observation: AnyCancellable?

    var paletteTheme: CustomizationTheme? {
        guard isEnabled, !UserDefaults.standard.bool(forKey: "lightModeEnabled") else { return nil }
        return theme
    }

    var colorScheme: ColorScheme? {
        guard let appearance = paletteTheme?.appearance else { return nil }
        return switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func connect(to center: CustomizationCenter) {
        observation?.cancel()
        isEnabled = true
        update(center.effectiveTheme)
        observation = center.$revision.sink { [weak self, weak center] _ in
            guard let center else { return }
            Task { @MainActor in self?.update(center.effectiveTheme) }
        }
    }

    func disable() {
        observation?.cancel()
        observation = nil
        isEnabled = false
        update(nil)
    }

    private func update(_ theme: CustomizationTheme?) {
        self.theme = theme
        revision &+= 1
        NotificationCenter.default.post(name: .jackCustomizationChanged, object: self)
    }

    nonisolated static func color(_ hex: String?) -> NSColor? {
        guard let hex else { return nil }
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        let alpha = value.count == 8 ? CGFloat(number & 0xFF) / 255 : 1
        let rgb = value.count == 8 ? number >> 8 : number
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255,
                       alpha: alpha)
    }
}
