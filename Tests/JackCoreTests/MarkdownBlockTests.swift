import XCTest
@testable import JackCore

final class MarkdownBlockTests: XCTestCase {
    func testChatTableWithInlineFormattingAndSurroundingParagraphs() {
        let blocks = MarkdownBlock.parse("""
        Antes

        | Novedad | Qué notarías al usar Jack | Tecnología |
        |---|---|---|
        | **Ponme al día** | Ver qué quedó pendiente | Apple Intelligence |
        | Stellar | [Contexto](https://example.com) y `código` | Local |

        Después
        """)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.first, .paragraph("Antes"))
        guard case let .table(table) = blocks[1] else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.header, ["Novedad", "Qué notarías al usar Jack", "Tecnología"])
        XCTAssertEqual(table.rows[0], ["**Ponme al día**", "Ver qué quedó pendiente", "Apple Intelligence"])
        XCTAssertEqual(table.rows[1][1], "[Contexto](https://example.com) y `código`")
        XCTAssertEqual(blocks.last, .paragraph("Después"))
    }

    func testOptionalOuterPipesAndColumnAlignment() {
        guard case let .table(table) = MarkdownBlock.parse("A | B | C\n:--- | :---: | ---:\n1 | 2 | 3").first else {
            return XCTFail("Expected a table")
        }
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.rows, [["1", "2", "3"]])
    }

    func testEscapedPipesAndUnevenRows() {
        guard case let .table(table) = MarkdownBlock.parse(#"""
        | A | B |
        | --- | --- |
        | a\|b | `c\|d` |
        | only |
        | 1 | 2 | ignored |
        | | |
        """#).first else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.rows, [["a|b", "`c|d`"], ["only", ""], ["1", "2"], ["", ""]])
    }

    func testStreamingDelimiterAndHeaderOnlyTable() {
        XCTAssertEqual(MarkdownBlock.parse("| A | B |\n|---|"), [.paragraph("| A | B |\n|---|")])
        guard case let .table(table) = MarkdownBlock.parse("| A | B |\n|---|---|").first else {
            return XCTFail("Expected a header-only table")
        }
        XCTAssertTrue(table.rows.isEmpty)
    }

    func testPipesInOrdinaryTextAndCodeAreNotTables() {
        XCTAssertEqual(MarkdownBlock.parse("a | b\nx | y"), [.paragraph("a | b\nx | y")])
        XCTAssertEqual(MarkdownBlock.parse("```md\n| A | B |\n|---|---|\n```"),
                       [.code(language: "md", code: "| A | B |\n|---|---|")])
        XCTAssertEqual(MarkdownBlock.parse("| A | B |\n|---|invalid|"), [.paragraph("| A | B |\n|---|invalid|")])
    }
}
