import AppKit
import SwiftUI

/// Two panes side by side; one has a fixed, user-resizable width and can be hidden.
/// The panes are passed as values, so dragging the divider only re-lays out the split
/// instead of re-running the window's body, and hiding a pane keeps the other one's identity.
struct PaneSplit<Leading: View, Trailing: View>: View {
    enum Side { case leading, trailing }

    let side: Side
    let visible: Bool
    let range: ClosedRange<CGFloat>
    /// Space always left to the flexible pane.
    let flexibleMinimum: CGFloat
    let leading: Leading
    let trailing: Trailing
    @AppStorage private var storedWidth: Double
    @State private var dragStart: CGFloat?
    @State private var liveWidth: CGFloat?

    init(_ side: Side, visible: Bool = true, widthKey: String, defaultWidth: CGFloat, range: ClosedRange<CGFloat>,
         flexibleMinimum: CGFloat = 360, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.side = side
        self.visible = visible
        self.range = range
        self.flexibleMinimum = flexibleMinimum
        self.leading = leading()
        self.trailing = trailing()
        _storedWidth = AppStorage(wrappedValue: Double(defaultWidth), widthKey)
    }

    var body: some View {
        // A single-pass layout instead of a GeometryReader: measuring first and placing later left
        // the chat's bottom-anchored lazy list without rows until the user scrolled.
        SplitLayout(paneOnLeading: side == .leading, paneWidth: liveWidth ?? CGFloat(storedWidth), range: range, flexibleMinimum: flexibleMinimum) {
            if side == .leading {
                if visible { leading; divider }
                trailing
            } else {
                leading
                if visible { divider; trailing }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(JackPalette.hairline).frame(width: 1)
            .overlay {
                // A wider invisible grip than the 1-point line.
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? min(max(CGFloat(storedWidth), range.lowerBound), range.upperBound)
                                if dragStart == nil { dragStart = start }
                                let delta = side == .leading ? value.translation.width : -value.translation.width
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { liveWidth = (start + delta).rounded() }
                            }
                            .onEnded { _ in
                                if let liveWidth { storedWidth = Double(min(max(liveWidth, range.lowerBound), range.upperBound)) }
                                liveWidth = nil
                                dragStart = nil
                            }
                    )
            }
            .zIndex(1)
    }
}

/// Lays out `[pane, divider, flexible]` (or the mirror) when the pane is shown, or just the flexible view.
private struct SplitLayout: Layout {
    let paneOnLeading: Bool
    let paneWidth: CGFloat
    let range: ClosedRange<CGFloat>
    let flexibleMinimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else {
            for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
            return
        }
        let wanted = min(max(paneWidth, range.lowerBound), range.upperBound)
        let pane = max(0, min(wanted, bounds.width - flexibleMinimum - 1)).rounded()
        let flexible = max(0, bounds.width - pane - 1)
        let widths = paneOnLeading ? [pane, 1, flexible] : [flexible, 1, pane]
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}
