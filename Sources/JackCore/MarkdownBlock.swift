import Foundation

public enum MarkdownBlock: Equatable {
    public struct Item: Equatable { public var text: String; public var indent: Int }
    public enum ColumnAlignment: Equatable { case left, center, right }
    public struct Table: Equatable {
        public var header: [String]
        public var alignments: [ColumnAlignment]
        public var rows: [[String]]
    }
    case table(Table)
    case paragraph(String)
    case heading(Int, String)
    case list([Item], ordered: Bool)
    case quote(String)
    case code(language: String, code: String)
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
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

        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            index += 1
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
            // A header becomes a table only once its complete delimiter row arrives.
            // This also lets partial tables stay readable while a reply streams.
            if index < lines.count, let header = tableCells(line),
               let alignments = tableAlignments(lines[index]), header.count == alignments.count {
                flushAll()
                index += 1
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]) {
                    rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(Table(header: header, alignments: alignments, rows: rows)))
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

    /// Escaped pipes are cell content, including inside inline code (GFM syntax).
    private static func tableCells(_ source: String) -> [String]? {
        let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var separators = 0
        var endsWithSeparator = false
        for character in line {
            if escaped {
                if character == "|" { cell.append(character) }
                else { cell.append("\\"); cell.append(character) }
                escaped = false
                endsWithSeparator = false
            } else if character == "\\" {
                escaped = true
                endsWithSeparator = false
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                separators += 1
                endsWithSeparator = true
            } else {
                cell.append(character)
                endsWithSeparator = false
            }
        }
        if escaped { cell.append("\\") }
        guard separators > 0 else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.first == "|" { cells.removeFirst() }
        if endsWithSeparator { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignments(_ line: String) -> [ColumnAlignment]? {
        guard let cells = tableCells(line) else { return nil }
        var result: [ColumnAlignment] = []
        for cell in cells {
            var marker = cell[...]
            let left = marker.first == ":"
            let right = marker.last == ":"
            if left { marker = marker.dropFirst() }
            if right, !marker.isEmpty { marker = marker.dropLast() }
            guard !marker.isEmpty, marker.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .right : .left)
        }
        return result
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
