import SwiftUI

/// Jack Bot's look: a technical drawing on black. Fine grid, hairline rules, square corners with crop marks, monospaced labels.
/// The colors are fixed (not the app theme) because the drawing only works on black.
enum BP {
    static let ink = Color(red: 0.016, green: 0.02, blue: 0.028)
    static let line = Color(red: 0.62, green: 0.78, blue: 1.0)
    static let hi = Color(red: 0.42, green: 0.9, blue: 1.0)
    static let warn = Color(red: 1.0, green: 0.42, blue: 0.4)
    static let text = Color(white: 0.93)
    static let dim = line.opacity(0.64)
    static let faint = line.opacity(0.4)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func code(_ prefix: String, _ index: Int) -> String { "\(prefix)-" + String(format: "%02d", index + 1) }
}

/// Graph paper: a faint cell every 20 points and a stronger one every 100. Static, so it only redraws on resize.
struct BPGrid: View {
    var body: some View {
        Canvas { context, size in
            var minor = Path(), major = Path()
            var step = 0
            var x: CGFloat = 0
            while x <= size.width {
                if step % 5 == 0 { major.addRect(CGRect(x: x, y: 0, width: 0, height: size.height)) } else { minor.addRect(CGRect(x: x, y: 0, width: 0, height: size.height)) }
                step += 1; x += 20
            }
            step = 0
            var y: CGFloat = 0
            while y <= size.height {
                if step % 5 == 0 { major.addRect(CGRect(x: 0, y: y, width: size.width, height: 0)) } else { minor.addRect(CGRect(x: 0, y: y, width: size.width, height: 0)) }
                step += 1; y += 20
            }
            context.stroke(minor, with: .color(BP.line.opacity(0.045)), lineWidth: 0.5)
            context.stroke(major, with: .color(BP.line.opacity(0.1)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// The marks at the four corners of a drawing sheet.
struct BPCorners: Shape {
    var length: CGFloat = 9
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, dx) in [(rect.minX, CGFloat(1)), (rect.maxX, -1)] {
            for (y, dy) in [(rect.minY, CGFloat(1)), (rect.maxY, -1)] {
                path.move(to: CGPoint(x: x + dx * length, y: y)); path.addLine(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x, y: y + dy * length))
            }
        }
        return path
    }
}

extension View {
    /// A hairline box. `marks` adds the crop marks; `selected` brightens it.
    func bpBox(marks: Bool = false, selected: Bool = false, fill: Double = 0) -> some View {
        background(BP.line.opacity(selected ? 0.08 : fill))
            .overlay(Rectangle().strokeBorder(BP.line.opacity(selected ? 0.7 : 0.26), lineWidth: 1))
            .overlay { if marks { BPCorners().stroke(BP.hi.opacity(0.9), lineWidth: 1.5) } }
    }
    func bpField() -> some View {
        textFieldStyle(.plain).font(BP.mono(12)).foregroundStyle(BP.text).padding(.horizontal, 8).padding(.vertical, 6)
            .bpBox(fill: 0.04)
    }
    func bpEditor(height: CGFloat) -> some View {
        scrollContentBackground(.hidden).font(BP.mono(12)).foregroundStyle(BP.text).padding(4).frame(height: height).bpBox(fill: 0.04)
    }
}

/// "[01] TITLE ————————": numbers and names a section like a drawing note.
struct BPHeader<Trailing: View>: View {
    let number: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text("[\(number)]").foregroundStyle(BP.hi)
            Text(title).foregroundStyle(BP.dim)
            Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1)
            trailing()
        }
        .font(BP.mono(10, .semibold)).tracking(1.2).lineLimit(1)
    }
}
extension BPHeader where Trailing == EmptyView {
    init(_ number: String, _ title: String) { self.init(number: number, title: title) { EmptyView() } }
}

struct BPButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let tint = destructive ? BP.warn : prominent ? BP.hi : BP.line
        configuration.label
            .font(BP.mono(10.5, .semibold)).tracking(0.8).textCase(.uppercase)
            .foregroundStyle(prominent || destructive ? tint : BP.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.28 : prominent ? 0.14 : 0.04))
            .overlay(Rectangle().strokeBorder(tint.opacity(prominent || destructive ? 0.8 : 0.4), lineWidth: 1))
            .opacity(enabled ? 1 : 0.35).contentShape(Rectangle())
    }
}

/// A small square button for a single symbol.
struct BPIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold)).foregroundStyle(BP.text).frame(width: 24, height: 24)
            .background(BP.line.opacity(configuration.isPressed ? 0.25 : 0.05)).overlay(Rectangle().strokeBorder(BP.line.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct BPToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Rectangle().strokeBorder(BP.line.opacity(0.7), lineWidth: 1).frame(width: 14, height: 14)
                    if configuration.isOn { Rectangle().fill(BP.hi).frame(width: 8, height: 8) }
                }
                configuration.label.font(BP.mono(11.5)).foregroundStyle(BP.text)
            }
        }
        .buttonStyle(.plain).accessibilityValue(configuration.isOn ? "Activado" : "Desactivado")
    }
}

/// A line with end ticks and a label in the middle, like a dimension on a drawing.
struct BPDimension: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(BP.line.opacity(0.4)).frame(width: 1, height: 9)
            Rectangle().fill(BP.line.opacity(0.3)).frame(height: 1)
            Text(text).font(BP.mono(9.5)).foregroundStyle(BP.dim).lineLimit(1).layoutPriority(1)
            Rectangle().fill(BP.line.opacity(0.3)).frame(height: 1)
            Rectangle().fill(BP.line.opacity(0.4)).frame(width: 1, height: 9)
        }
    }
}

/// The frame of every sheet: a titled drawing sheet on the grid.
struct BPSheet<Content: View>: View {
    let figure: String
    let title: String
    let width: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("FIG. \(figure)").foregroundStyle(BP.hi)
                Text(title).foregroundStyle(BP.text)
                Rectangle().fill(BP.line.opacity(0.25)).frame(height: 1)
            }
            .font(BP.mono(11, .semibold)).tracking(1.2).textCase(.uppercase)
            content()
        }
        .tint(BP.hi).toggleStyle(BPToggleStyle()).buttonStyle(BPButtonStyle())
        .padding(20).frame(width: width)
        .background { ZStack { BP.ink; BPGrid() } }
        .overlay(BPCorners(length: 12).stroke(BP.hi.opacity(0.9), lineWidth: 1.5).padding(6))
        .preferredColorScheme(.dark)
    }
}
