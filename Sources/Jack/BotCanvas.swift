import SwiftUI

/// Jack Bot's look: a node editor on near-black. A faint dot grid, dark rounded cards with a hairline border,
/// thin soft cables, pastel accents. The colors are fixed (not the app theme) because the canvas only works on black.
enum BC {
    static let canvas = Color(red: 0.043, green: 0.043, blue: 0.047)     // #0B0B0C
    static let card = Color(red: 0.102, green: 0.102, blue: 0.110)       // #1A1A1C
    static let field = Color(red: 0.067, green: 0.067, blue: 0.071)      // #111112
    static let bar = Color(red: 0.090, green: 0.090, blue: 0.098)
    static let ink = canvas
    static let line = Color.white
    static let stroke = Color.white.opacity(0.09)
    static let text = Color.white.opacity(0.9)
    static let dim = Color.white.opacity(0.56)
    static let faint = Color.white.opacity(0.36)
    static let hi = Color.white
    // Pastel accents, as in the reference: ports, status pills and glows.
    static let green = Color(red: 0.45, green: 0.93, blue: 0.62)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let warn = red
    static let yellow = Color(red: 1.0, green: 0.86, blue: 0.30)
    static let blue = Color(red: 0.42, green: 0.70, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.50, blue: 0.85)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.40)

    static func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// Only for the tiny counters in the corners.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func code(_ prefix: String, _ index: Int) -> String { "\(prefix)-" + String(format: "%02d", index + 1) }
}

/// A faint dot grid. Drawn in one pass, and the spacing doubles when zooming out so it never turns into thousands of dots.
struct BCDotGrid: View {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var body: some View {
        Canvas { context, size in
            var step = 24 * scale
            while step < 12 { step *= 2 }
            let ox = offset.width.truncatingRemainder(dividingBy: step), oy = offset.height.truncatingRemainder(dividingBy: step)
            var dots = Path()
            var x = ox < 0 ? ox + step : ox
            while x <= size.width {
                var y = oy < 0 ? oy + step : oy
                while y <= size.height { dots.addEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)); y += step }
                x += step
            }
            context.fill(dots, with: .color(.white.opacity(0.075)))
        }
        .allowsHitTesting(false)
    }
}

/// Where the old drawing-sheet grid was: the same name for the background of every Jack Bot screen.
struct BCGrid: View { var body: some View { BCDotGrid() } }

extension View {
    /// A rounded card. `selected` brightens the border.
    func bcBox(marks: Bool = false, selected: Bool = false, fill: Double = 0) -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color(white: 0.145) : BC.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.32 : 0.09), lineWidth: 1))
    }
    /// An inset text field, darker than its card.
    func bcField() -> some View {
        textFieldStyle(.plain).font(BC.sf(12)).foregroundStyle(BC.text).padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BC.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
    func bcEditor(height: CGFloat) -> some View {
        scrollContentBackground(.hidden).font(BC.sf(12)).foregroundStyle(BC.text).padding(6).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BC.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
    /// A dark floating pill, like the ones of the top bar.
    func bcPill(padding: CGFloat = 4) -> some View {
        self.padding(padding).background(Capsule().fill(BC.bar)).overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// A small section title.
struct BCHeader<Trailing: View>: View {
    let number: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title.capitalized(with: .current)).font(BC.sf(11, .semibold)).foregroundStyle(BC.dim)
            Spacer(minLength: 4)
            trailing()
        }
        .lineLimit(1)
    }
}
extension BCHeader where Trailing == EmptyView {
    init(_ number: String, _ title: String) { self.init(number: number, title: title) { EmptyView() } }
}

struct BCButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = prominent ? .white : destructive ? BC.red.opacity(0.12) : Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)
        configuration.label
            .font(BC.sf(11.5, .medium))
            .foregroundStyle(prominent ? Color.black : destructive ? BC.red : BC.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(fill.opacity(prominent && configuration.isPressed ? 0.8 : 1)))
            .overlay(Capsule().strokeBorder(destructive ? BC.red.opacity(0.4) : Color.white.opacity(prominent ? 0 : 0.10), lineWidth: 1))
            .opacity(enabled ? 1 : 0.38).contentShape(Capsule())
    }
}

/// A small rounded square for a single symbol.
struct BCIconButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(active ? Color.black : BC.text).frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? Color.white : Color.white.opacity(configuration.isPressed ? 0.16 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(active ? 0 : 0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct BCToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 1).frame(width: 15, height: 15)
                    if configuration.isOn { RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.white).frame(width: 9, height: 9) }
                }
                configuration.label.font(BC.sf(12)).foregroundStyle(BC.text)
            }
        }
        .buttonStyle(.plain).accessibilityValue(configuration.isOn ? "Activado" : "Desactivado")
    }
}

/// A caption between two hairlines.
struct BCDimension: View {
    let text: String
    var body: some View {
        Text(text).font(BC.sf(10)).foregroundStyle(BC.dim).lineLimit(1)
    }
}

/// The frame of every sheet: a titled dark card on the dot grid.
struct BCSheet<Content: View>: View {
    let figure: String
    let title: String
    let width: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(BC.sf(14, .semibold)).foregroundStyle(BC.text)
            content()
        }
        .tint(.white).toggleStyle(BCToggleStyle()).buttonStyle(BCButtonStyle())
        .padding(20).frame(width: width)
        .background { ZStack { BC.canvas; BCDotGrid() } }
        .preferredColorScheme(.dark)
    }
}

/// A colored label stuck to a node, like the name tags of the reference. Dark text on a pastel pill.
struct BCStatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(BC.sf(9.5, .semibold)).foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color)).lineLimit(1).fixedSize()
    }
}

/// The coordinates every node and cable share. Ports sit at fixed heights so a cable only needs the node's position.
enum BCLayout {
    static let headerHeight: CGFloat = 38
    static func portY(_ index: Int) -> CGFloat { headerHeight + 11 + CGFloat(index) * 22 }
}

/// A node: header with a colored dot, a title and an optional status pill; the content goes below, in fields.
struct BCNode<Content: View>: View {
    let title: String
    var dot: Color = .white
    var width: CGFloat
    var pill: (String, Color)? = nil
    var accent: Color? = nil          // active/selected: a colored glow along the bottom edge, like the yellow of the reference
    var selected = false
    var dimmed = false
    /// Dragging the header moves the node; tapping it selects it. Both in the canvas's own coordinate space.
    var onDrag: ((DragGesture.Value) -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    static var canvasSpace: String { "bc-screen" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(BC.sf(12, .medium)).foregroundStyle(BC.text).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14).frame(height: BCLayout.headerHeight).contentShape(Rectangle())
            .onTapGesture { onSelect?() }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.canvasSpace))
                .onChanged { onDrag?($0) }.onEnded { _ in onDragEnd?() })
            content().padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BC.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.28 : 0.09), lineWidth: 1))
        .overlay(alignment: .bottom) {
            if let accent {
                Capsule().fill(LinearGradient(colors: [accent.opacity(0), accent, accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2).padding(.horizontal, 18).shadow(color: accent.opacity(0.8), radius: 5)
            }
        }
        .overlay(alignment: .topTrailing) { if let pill { BCStatusPill(text: pill.0, color: pill.1).offset(x: -10, y: -11) } }
        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
        .opacity(dimmed ? 0.5 : 1)
    }
}

/// A colored dot on a card's edge with its label inside, like the model/positive/negative ports of the reference.
struct BCPort: View {
    enum Side { case input, output }
    let label: String
    let color: Color
    let side: Side
    var body: some View {
        HStack(spacing: 6) {
            if side == .input { Circle().fill(color).frame(width: 7, height: 7).offset(x: -16) }
            Text(label).font(BC.sf(10.5)).foregroundStyle(BC.dim)
            if side == .output { Circle().fill(color).frame(width: 7, height: 7).offset(x: 16) }
        }
        .frame(height: 22).frame(maxWidth: .infinity, alignment: side == .input ? .leading : .trailing)
    }
}
