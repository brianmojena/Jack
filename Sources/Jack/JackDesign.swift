import AppKit
import JackCore
import SwiftUI

/// Semantic colors that follow the system appearance and accent color.
enum JackPalette {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.white.withAlphaComponent(0.055)))
    static let panelStrong = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.065), dark: NSColor.white.withAlphaComponent(0.085)))
    static let codeBackground = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.black.withAlphaComponent(0.28)))
    static let composer = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let secondaryText = Color(nsColor: .labelColor).opacity(0.86)
    static let red = Color(nsColor: .systemRed)
    static let amber = Color(nsColor: .systemOrange)
    static let green = Color(nsColor: .systemGreen)
    static let blue = Color(nsColor: .systemBlue)
    static let purple = Color(nsColor: .systemPurple)

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension ChatStatus {
    var title: String {
        switch self {
        case .idle: "Listo"
        case .queued: "En cola"
        case .running: "Trabajando"
        case .waiting: "Necesita tu respuesta"
        case .failed: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "checkmark.circle.fill"
        case .queued: "clock.fill"
        case .running: "circle.dotted"
        case .waiting: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: JackPalette.muted
        case .queued: JackPalette.muted
        case .running: JackPalette.accent
        case .waiting: JackPalette.amber
        case .failed: JackPalette.red
        }
    }

    var isActive: Bool { self == .running || self == .waiting || self == .queued }
}

/// Small capsule that shows a conversation's state.
struct StatusPill: View {
    let status: ChatStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .running {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
            } else {
                Image(systemName: status.symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(status.title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Shortens absolute paths: inside the project they become relative, otherwise `~`-prefixed.
func displayPath(_ path: String, project: String) -> String {
    var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = project.hasSuffix("/") ? project : project + "/"
    if value.hasPrefix(root) { value = String(value.dropFirst(root.count)) }
    else if value.hasPrefix(NSHomeDirectory()) { value = "~" + value.dropFirst(NSHomeDirectory().count) }
    return value
}
