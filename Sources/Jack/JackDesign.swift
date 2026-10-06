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

// MARK: - Interface style

/// How Jack's main window is drawn. Basic is the solid, dense workspace; Ice lets the desktop
/// show through the window and turns the composer, tabs and buttons into Liquid Glass.
enum InterfaceStyle: String, CaseIterable, Identifiable {
    case basic, ice

    static let key = "interfaceStyle"

    var id: String { rawValue }
    var title: String {
        switch self { case .basic: "Basic"; case .ice: "Ice" }
    }
}

extension EnvironmentValues {
    @Entry var interfaceStyle: InterfaceStyle = .basic
}

/// The window's layers. In Basic each one is a solid color; in Ice the window is frosted glass,
/// the chrome is that glass as is and the content keeps a tint so text stays legible.
enum JackSurface {
    case window, chrome, canvas
}

private struct JackSurfaceBackground: ViewModifier {
    let surface: JackSurface
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        content.background {
            switch (style, surface) {
            case (.basic, .chrome): JackPalette.chrome
            case (.basic, _): JackPalette.canvas
            case (.ice, .window): WindowGlass()
            case (.ice, .chrome): Color.clear
            case (.ice, .canvas): JackPalette.iceCanvas
            }
        }
    }
}

/// A Liquid Glass shape in Ice (a material before macOS 26); `basic` keeps the current look.
private struct JackGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let basic: Color
    var tint: Color?
    var interactive = false
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        if style == .basic {
            content.background(basic, in: shape)
        } else if #available(macOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(tint ?? .clear, in: shape).background(.ultraThinMaterial, in: shape)
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

extension View {
    func jackSurface(_ surface: JackSurface) -> some View {
        modifier(JackSurfaceBackground(surface: surface))
    }

    func jackGlass<S: InsettableShape>(in shape: S, basic: Color, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(JackGlassBackground(shape: shape, basic: basic, tint: tint, interactive: interactive))
    }
}

/// The desktop, blurred, behind the whole window.
private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension JackPalette {
    /// Content over Ice's glass: translucent enough to feel the desktop, opaque enough to read.
    static let iceCanvas = Color(nsColor: adaptive(light: NSColor.white.withAlphaComponent(0.55), dark: rgb(0x0E0E0F).withAlphaComponent(0.55)))
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

/// Official provider logos, stored as template vectors in the asset catalog.
func providerLogo(_ provider: ChatProvider) -> String {
    switch provider { case .codex: "ProviderCodex"; case .claude: "ProviderClaude"; case .opencode: "ProviderOpenCode"; case .stellar: "ProviderStellar" }
}

/// Fallback when the asset catalog is not bundled (e.g. `swift run`).
func providerSymbol(_ provider: ChatProvider) -> String {
    switch provider { case .codex: "chevron.left.forwardslash.chevron.right"; case .claude: "asterisk"; case .opencode: "terminal"; case .stellar: "sparkle" }
}

/// The provider's logo at `size` points, falling back to its SF Symbol.
private struct ProviderLogo: View {
    let provider: ChatProvider
    let size: CGFloat
    let symbolScale: CGFloat

    var body: some View {
        if NSImage(named: providerLogo(provider)) != nil {
            Image(providerLogo(provider)).resizable().renderingMode(.template).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: providerSymbol(provider)).font(.system(size: size * symbolScale, weight: .bold))
        }
    }
}

func providerColor(_ provider: ChatProvider) -> Color {
    switch provider {
    case .claude: Color(nsColor: JackPalette.rgb(0xD97757))
    case .codex: Color.primary
    case .opencode: Color(nsColor: .systemTeal)
    case .stellar: Color(nsColor: .systemIndigo)
    }
}

/// The provider's symbol in its own color, without a background: used in dense rows.
struct ProviderMark: View {
    let provider: ChatProvider
    var size: CGFloat = 12

    var body: some View {
        ProviderLogo(provider: provider, size: size, symbolScale: provider == .claude ? 0.95 : 0.78)
            .foregroundStyle(providerColor(provider))
            .frame(width: size, height: size)
            .accessibilityLabel(provider.title)
    }
}

/// "Beta" next to Stellar Code's name while it is being built.
struct BetaBadge: View {
    var body: some View {
        Text("BETA").font(.system(size: 8, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .foregroundStyle(providerColor(.stellar))
            .background(providerColor(.stellar).opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .help("Stellar Code está en beta")
            .accessibilityLabel("Beta")
    }
}

func providerGlyph(_ provider: ChatProvider, size: CGFloat = 25) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(providerColor(provider).opacity(0.14)).frame(width: size, height: size)
        ProviderLogo(provider: provider, size: size * 0.6, symbolScale: 0.75).foregroundStyle(providerColor(provider))
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
