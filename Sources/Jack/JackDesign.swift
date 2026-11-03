import AppKit
import JackCore
import SwiftUI

/// Colors of Jack's dark, dense workspace look. Every color also has a light variant,
/// so the app still follows the system appearance.
enum JackPalette {
    static var canvasColor: NSColor { themed(\.canvas) ?? adaptive(light: rgb(0xFFFFFF), dark: rgb(0x0E0E0F)) }
    static var chromeColor: NSColor { themed(\.chrome) ?? adaptive(light: rgb(0xF3F3F5), dark: rgb(0x161618)) }
    static var canvas: Color { Color(nsColor: canvasColor) }
    /// Sidebar, tab strips and status bar.
    static var chrome: Color { Color(nsColor: chromeColor) }
    static var selection: Color { Color(nsColor: themed(\.selection) ?? adaptive(light: NSColor.black.withAlphaComponent(0.075), dark: NSColor.white.withAlphaComponent(0.085))) }
    static var panel: Color { Color(nsColor: themed(\.panel) ?? adaptive(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.white.withAlphaComponent(0.05))) }
    static var panelStrong: Color { Color(nsColor: themed(\.panel) ?? adaptive(light: NSColor.black.withAlphaComponent(0.065), dark: NSColor.white.withAlphaComponent(0.08))) }
    static let codeBackground = Color(nsColor: adaptive(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.035)))
    static var composer: Color { canvas }
    static var hairline: Color { Color(nsColor: themed(\.border) ?? adaptive(light: NSColor.black.withAlphaComponent(0.1), dark: NSColor.white.withAlphaComponent(0.085))) }
    /// Scales a corner radius to the theme's `cornerRadius` (8 = unchanged); mods only apply in Normal mode.
    static func radius(_ base: CGFloat) -> CGFloat {
        guard let value = MainActor.assumeIsolated({ CustomizationAppearance.shared.paletteTheme?.cornerRadius }) else { return base }
        return base * CGFloat(value) / 8
    }
    /// Stroke width for borders drawn with `hairline` (1 = unchanged).
    static func borderWidth(_ base: CGFloat = 1) -> CGFloat {
        MainActor.assumeIsolated { CustomizationAppearance.shared.paletteTheme?.borderWidth }.map(CGFloat.init) ?? base
    }
    static var accent: Color { themed(\.accent).map { Color(nsColor: $0) } ?? Color.accentColor }
    static var muted: Color { themed(\.muted).map { Color(nsColor: $0) } ?? Color(nsColor: .secondaryLabelColor) }
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static var primaryText: Color { themed(\.text).map { Color(nsColor: $0) } ?? .primary }
    static var secondaryText: Color { themed(\.text).map { Color(nsColor: $0).opacity(0.86) } ?? Color(nsColor: .labelColor).opacity(0.86) }
    static let red = Color(nsColor: .systemRed)
    static let amber = Color(nsColor: .systemOrange)
    static let green = Color(nsColor: .systemGreen)
    static let blue = Color(nsColor: .systemBlue)
    static let purple = Color(nsColor: .systemPurple)
    /// Neon magenta for chats marked as pending: no other status uses it, so it stands out in the list.
    static let pending = Color(red: 1.0, green: 0.07, blue: 0.72)
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

    private static func themed(_ keyPath: KeyPath<CustomizationTheme, String?>) -> NSColor? {
        MainActor.assumeIsolated {
            CustomizationAppearance.color(CustomizationAppearance.shared.paletteTheme?[keyPath: keyPath])
        }
    }
}

// MARK: - Interface style

/// How Jack's main window is drawn. Basic is the solid, dense workspace; Ice is built from
/// macOS's own Liquid Glass structure. Terminal presents native PTYs instead of chats. Office draws the
/// agents as characters in an animated 2D studio or a 3D office, with access to their chats.
enum InterfaceStyle: String, CaseIterable, Identifiable {
    case basic, ice, terminal, office, office2D, codeos

    static let key = "interfaceStyle"

    var isOffice: Bool { self == .office || self == .office2D }
    var availableInLight: Bool { self != .terminal && !isOffice && self != .codeos }

    var id: String { rawValue }
    var title: String {
        switch self { case .basic: "Basic"; case .ice: "Ice"; case .terminal: "Terminal"; case .office: "Oficina 3D"; case .office2D: "Oficina 2D"; case .codeos: "CodeOS" }
    }
}

extension EnvironmentValues {
    @Entry var interfaceStyle: InterfaceStyle = .basic
    @Entry var jackCustomizationRevision = 0
    /// Colour the Ice glass is tinted with, when a host (CodeOS) wants the chat to take on its project's colour.
    @Entry var jackTint: Color? = nil
    /// CodeOS lists a project's chats in its own pane: no search field in the window toolbar.
    @Entry var jackHidesSidebarSearch = false
}

/// The window's layers. Basic paints each one; Ice leaves them to the system, so the glass
/// sidebar and toolbar sit over the standard window background.
enum JackSurface {
    case chrome, canvas
}

private struct JackSurfaceBackground: ViewModifier {
    let surface: JackSurface
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .basic, .terminal, .office, .office2D, .codeos: content.background(surface == .chrome ? JackPalette.chrome : JackPalette.canvas)
        case .ice: content
        }
    }
}

/// Liquid Glass in Ice (a material before macOS 26); `basic` keeps the solid look.
private struct JackGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let basic: Color
    var interactive = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.jackTint) private var tint

    func body(content: Content) -> some View {
        if style == .basic || style.isOffice || style == .codeos {
            content.background(basic, in: shape)
        } else if #available(macOS 26, *) {
            let glass: Glass = interactive ? .regular.interactive() : .regular
            content.glassEffect(tint.map { glass.tint($0.opacity(0.26)) } ?? glass, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A bar over the edge of a scroll view: in Ice the content scrolls beneath it with the
/// system's scroll edge effect; in Basic it simply sits above or below.
private struct JackEdgeBar<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let bar: Bar
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        if style == .ice, #available(macOS 26, *) {
            content.safeAreaBar(edge: edge, spacing: 0) { bar }
        } else if edge == .top {
            VStack(spacing: 0) { bar; content }
        } else {
            VStack(spacing: 0) { content; bar }
        }
    }
}

extension View {
    func jackSurface(_ surface: JackSurface) -> some View {
        modifier(JackSurfaceBackground(surface: surface))
    }

    func jackGlass<S: InsettableShape>(in shape: S, basic: Color, interactive: Bool = false) -> some View {
        modifier(JackGlassBackground(shape: shape, basic: basic, interactive: interactive))
    }

    func jackEdgeBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder bar: () -> Bar) -> some View {
        modifier(JackEdgeBar(edge: edge, bar: bar()))
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

/// Official provider logos, stored as template vectors in the asset catalog.
func providerLogo(_ provider: ChatProvider) -> String {
    switch provider { case .codex: "ProviderCodex"; case .claude: "ProviderClaude"; case .opencode: "ProviderOpenCode"; case .stellar: "ProviderStellar"; case .antigravity: "ProviderAntigravity"; case .qoder: "ProviderQoder" }
}

/// Fallback when the asset catalog is not bundled (e.g. `swift run`).
func providerSymbol(_ provider: ChatProvider) -> String {
    switch provider { case .codex: "chevron.left.forwardslash.chevron.right"; case .claude: "asterisk"; case .opencode: "terminal"; case .stellar: "sparkle"; case .antigravity: "sparkles"; case .qoder: "q.circle" }
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
    case .antigravity: Color(nsColor: .systemGreen)
    case .qoder: Color(nsColor: .systemPurple)
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
            .background(providerColor(.stellar).opacity(0.14), in: RoundedRectangle(cornerRadius: JackPalette.radius(3), style: .continuous))
            .help("Stellar Code está en beta")
            .accessibilityLabel("Beta")
    }
}

struct SSHBadge: View {
    var body: some View {
        Text("SSH").font(.system(size: 8, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .foregroundStyle(JackPalette.accent)
            .background(JackPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: JackPalette.radius(3), style: .continuous))
            .help("Se ejecuta en otra máquina por SSH")
            .accessibilityLabel("Remoto por SSH")
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
