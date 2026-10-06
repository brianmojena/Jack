import AppKit
import SwiftUI

/// Block-level Markdown for agent replies: paragraphs, headings, lists, quotes, rules and fenced code.
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
                        inline(item.text).font(.system(size: fontSize, design: design)).lineSpacing(2.5)
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

enum MarkdownBlock: Equatable {
    struct Item: Equatable { var text: String; var indent: Int }
    case paragraph(String)
    case heading(Int, String)
    case list([Item], ordered: Bool)
    case quote(String)
    case code(language: String, code: String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [Item] = []
        var ordered = false
        var fence: (language: String, lines: [String])?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items, ordered: ordered)); items = [] }
        }
        func flushAll() { flushParagraph(); flushQuote(); flushList() }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = fence {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(rawLine)
                    fence = open
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                fence = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if line.isEmpty { flushAll(); continue }
            if line == "---" || line == "***" || line == "___" { flushAll(); blocks.append(.rule); continue }
            if let heading = headingLevel(line) {
                flushAll()
                blocks.append(.heading(heading, String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if let bullet = bulletText(line) {
                flushParagraph(); flushQuote()
                if !items.isEmpty, ordered { flushList() }
                ordered = false
                items.append(Item(text: bullet, indent: min(indent, 3)))
                continue
            }
            if let number = orderedText(line) {
                flushParagraph(); flushQuote()
                if !items.isEmpty, !ordered { flushList() }
                ordered = true
                items.append(Item(text: number, indent: min(indent, 3)))
                continue
            }
            if !items.isEmpty, indent > 0 {
                items[items.count - 1].text += " " + line
                continue
            }
            flushQuote(); flushList()
            paragraph.append(line)
        }
        if let open = fence { blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            var text = String(line.dropFirst(2))
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑︎ " + text.dropFirst(4) }
            return text
        }
        return nil
    }

    private static func orderedText(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
