import AppKit
import JackCore
import SwiftUI

/// Block-level Markdown for agent replies: paragraphs, headings, lists, quotes, rules, tables and fenced code.
/// Inline styling (bold, italics, code, links) is delegated to `AttributedString`.
struct MarkdownText: View {
    let text: String
    var fontSize: CGFloat = 13
    var design: Font.Design = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inline(text).font(.system(size: fontSize, design: design)).lineSpacing(2.5)
        case let .heading(level, text):
            inline(text)
                .font(.system(size: level == 1 ? fontSize + 4 : level == 2 ? fontSize + 2 : fontSize + 1, weight: .semibold, design: design))
                .padding(.top, 4)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: fontSize, weight: ordered ? .medium : .bold, design: design).monospacedDigit())
                            .foregroundStyle(JackPalette.muted)
                            .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                        // Beside the bullet the text is offered a single line's height, so it was cut with
                        // "…" in narrow windows instead of wrapping: it takes the height it needs.
                        inline(item.text).font(.system(size: fontSize, design: design)).lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case let .quote(text):
            inline(text)
                .font(.system(size: fontSize, design: design)).foregroundStyle(JackPalette.muted)
                .padding(.leading, 11)
                .overlay(alignment: .leading) { Rectangle().fill(JackPalette.hairline).frame(width: 3) }
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .table(table):
            MarkdownTableView(table: table, fontSize: fontSize, design: design)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let value = try? AttributedString(markdown: text, options: options) { return Text(value) }
        return Text(text)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "código" : language)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(JackPalette.muted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(JackPalette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
    }
}
