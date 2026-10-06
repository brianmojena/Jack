import AppKit
import JackCore
import SwiftUI

/// Colors of Jack's dark, dense workspace look. Every color also has a light variant,
/// so the app still follows the system appearance.
enum JackPalette {
    static let canvasColor = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x0E0E0F))
    static let chromeColor = adaptive(light: rgb(0xF3F3F5), dark: rgb(0x161618))
    static let canvas = Color(nsColor: canvasColor)
    /// Sidebar, tab strips and status bar.
    static let chrome = Color(nsColor: chromeColor)
    static let selection = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.075), dark: NSColor.white.withAlphaComponent(0.085)))
    static let panel = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.white.withAlphaComponent(0.05)))
    static let panelStrong = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.065), dark: NSColor.white.withAlphaComponent(0.08)))
    static let codeBackground = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.035)))
    static let composer = canvas
    static let hairline = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.1), dark: NSColor.white.withAlphaComponent(0.085)))
    static let accent = Color.accentColor
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let secondaryText = Color(nsColor: .labelColor).opacity(0.86)
    static let red = Color(nsColor: .systemRed)
    static let amber = Color(nsColor: .systemOrange)
    static let green = Color(nsColor: .systemGreen)
    static let blue = Color(nsColor: .systemBlue)
    static let purple = Color(nsColor: .systemPurple)
    static let added = Color(nsColor: adaptive(light: NSColor.systemGreen.withAlphaComponent(0.16), dark: rgb(0x1F4D2B)))
    static let removed = Color(nsColor: adaptive(light: NSColor.systemRed.withAlphaComponent(0.14), dark: rgb(0x5C2324)))

    static func rgb(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Monospaced type used by the transcript, terminal headers and status bar.
extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Compact age of a date: "ahora", "4m", "3h", "2d".
func compactAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "ahora" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
    if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400))d" }
    return date.formatted(.dateTime.day().month(.abbreviated))
}

/// Lets an empty strip drag the window, as the hidden title bar would.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
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

// MARK: - Provider marks

func providerSymbol(_ provider: ChatProvider) -> String {
    switch provider { case .codex: "chevron.left.forwardslash.chevron.right"; case .claude: "asterisk"; case .opencode: "terminal" }
}

func providerColor(_ provider: ChatProvider) -> Color {
    switch provider {
    case .claude: Color(nsColor: JackPalette.rgb(0xD97757))
    case .codex: Color.primary
    case .opencode: Color(nsColor: .systemTeal)
    }
}

/// The provider's symbol in its own color, without a background: used in dense rows.
struct ProviderMark: View {
    let provider: ChatProvider
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: providerSymbol(provider))
            .font(.system(size: size * (provider == .claude ? 0.95 : 0.78), weight: .bold))
            .foregroundStyle(providerColor(provider))
            .frame(width: size, height: size)
            .accessibilityLabel(provider.title)
    }
}

func providerGlyph(_ provider: ChatProvider, size: CGFloat = 25) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(providerColor(provider).opacity(0.14)).frame(width: size, height: size)
        Image(systemName: providerSymbol(provider)).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(providerColor(provider))
    }.accessibilityHidden(true)
}

/// Small state indicator used by sidebar rows and agent tabs.
struct StatusDot: View {
    let status: ChatStatus
    var unread = false

    var body: some View {
        Group {
            switch status {
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.62)
            case .waiting:
                Image(systemName: "hand.raised.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(JackPalette.amber)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(JackPalette.red)
            case .queued:
                Image(systemName: "clock").font(.system(size: 9, weight: .semibold)).foregroundStyle(JackPalette.muted)
            case .idle:
                Circle().fill(unread ? JackPalette.accent : JackPalette.faint.opacity(0.7)).frame(width: unread ? 7 : 5, height: unread ? 7 : 5)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(unread && status == .idle ? "No leído" : status.title)
    }
}
