import JackCore
import SwiftUI

/// Rows share column widths and grow vertically as cell text wraps.
struct MarkdownTableView: View {
    let table: MarkdownBlock.Table
    let fontSize: CGFloat
    let design: Font.Design
    @State private var availableWidth: CGFloat = 0

    private var widths: [CGFloat] {
        let weights = table.header.indices.map { column in
            let longest = ([table.header] + table.rows).map { $0[column].count }.max() ?? 0
            return sqrt(CGFloat(min(max(longest, 12), 120)))
        }
        let minimum: CGFloat = 120
        let extra = max(0, availableWidth - minimum * CGFloat(weights.count))
        let total = weights.reduce(0, +)
        return weights.map { minimum + extra * $0 / total }
    }

    var body: some View {
        let columns = widths
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                row(table.header, widths: columns, header: true)
                ForEach(table.rows.indices, id: \.self) { index in
                    Divider()
                    row(table.rows[index], widths: columns, header: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : JackPalette.panel.opacity(0.45))
                }
            }
            .background(JackPalette.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func row(_ cells: [String], widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(table.header.indices, id: \.self) { column in
                let alignment = table.alignments[column]
                cell(cells[column])
                    .font(.system(size: fontSize, weight: header ? .semibold : .regular, design: design))
                    .lineSpacing(2.5)
                    .multilineTextAlignment(alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                    .frame(width: widths[column] - 20, alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
        }
        .background(header ? JackPalette.panel : Color.clear)
    }

    private func cell(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
    }
}
