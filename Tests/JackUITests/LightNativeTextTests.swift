import AppKit
import XCTest
import JackCore
@testable import Jack

/// Exercises text storage without opening a window or controlling the user's computer.
final class LightNativeTextTests: XCTestCase {
    @MainActor func testStreamingAppendsUnicodeAndCorrectionsReplaceTheCurrentBlock() throws {
        let view = LightNativeTranscript.TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let id = UUID()
        let user = ChatMessage(id: "user", role: "user", text: "hola")
        var reply = ChatMessage(id: "reply", role: "assistant", text: "café 🙂")
        view.update(id: id, messages: [user, reply])
        let text = try XCTUnwrap(view.documentView as? NSTextView)
        XCTAssertEqual(text.string, LightTranscript.text(of: user) + LightTranscript.text(of: reply))
        text.setSelectedRange(NSRange(location: 3, length: 4))
        reply.text += " — más texto 👩🏽‍💻"
        view.update(id: id, messages: [user, reply])
        XCTAssertEqual(text.string, LightTranscript.text(of: user) + LightTranscript.text(of: reply))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 3, length: 4), "streaming preserves a selection in previous text")
        reply.text = "Respuesta corregida"
        view.update(id: id, messages: [user, reply])
        XCTAssertEqual(text.string, LightTranscript.text(of: user) + LightTranscript.text(of: reply))
    }
    @MainActor func testAttachmentsPagingAndConversationSwitchReplaceTheRightRanges() throws {
        let view = LightNativeTranscript.TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let id = UUID()
        let old = ChatMessage(id: "old", role: "user", text: "anterior")
        var reply = ChatMessage(id: "reply", role: "assistant", text: "foto", attachments: ["/tmp/imagen.png"])
        view.update(id: id, messages: [reply])
        let text = try XCTUnwrap(view.documentView as? NSTextView)
        reply.text += " recibida"
        view.update(id: id, messages: [reply])
        XCTAssertEqual(text.string, LightTranscript.text(of: reply))
        view.update(id: id, messages: [old, reply])
        XCTAssertEqual(text.string, LightTranscript.text(of: old) + LightTranscript.text(of: reply))
        view.update(id: UUID(), messages: [old])
        XCTAssertEqual(text.string, LightTranscript.text(of: old))
        view.update(id: UUID(), messages: [])
        XCTAssertTrue(text.string.isEmpty)
    }

    @MainActor func testMarkdownUsesNativeStylesAndPreservesLiteralCode() throws {
        let value = LightMarkdown.body("""
        # Título

        **negrita** *cursiva* `inline` [enlace](https://example.com) ~~tachado~~

        - primero
          - anidado

        > cita

        ```swift
        let x = "**literal**"
        ```

        ---
        """)
        let source = value.string as NSString
        func font(_ word: String) throws -> NSFont {
            try XCTUnwrap(value.attribute(.font, at: source.range(of: word).location, effectiveRange: nil) as? NSFont)
        }
        XCTAssertFalse(value.string.contains("# Título"))
        XCTAssertFalse(value.string.contains("**negrita**"))
        XCTAssertTrue(value.string.contains("let x = \"**literal**\""), "fenced code must stay literal")
        XCTAssertEqual(try font("Título").pointSize, 17)
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("negrita")).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("cursiva")).contains(.italicFontMask))
        XCTAssertTrue(try font("inline").isFixedPitch)
        XCTAssertTrue(try font("let x").isFixedPitch)
        XCTAssertEqual(value.attribute(.link, at: source.range(of: "enlace").location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
        XCTAssertEqual(value.attribute(.strikethroughStyle, at: source.range(of: "tachado").location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        let nested = try XCTUnwrap(value.attribute(.paragraphStyle, at: source.range(of: "anidado").location,
                                                 effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(nested.firstLineHeadIndent, 16)
        XCTAssertGreaterThan(nested.headIndent, nested.firstLineHeadIndent)
    }

    @MainActor func testTablesHaveRealCellsWithAlignmentAndInlineFormatting() throws {
        let value = LightMarkdown.body("| Nombre | Valor |\n|:---|---:|\n| **café 🙂** | `42` |\n| a\\|b | |")
        let source = value.string as NSString
        let headerStyle = try XCTUnwrap(value.attribute(.paragraphStyle, at: source.range(of: "Nombre").location,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        let headerCell = try XCTUnwrap(headerStyle.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(headerCell.table.numberOfColumns, 2)
        XCTAssertEqual(headerCell.startingRow, 0)
        let valueStyle = try XCTUnwrap(value.attribute(.paragraphStyle, at: source.range(of: "42").location,
                                                     effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(valueStyle.alignment, .right)
        XCTAssertEqual((valueStyle.textBlocks.first as? NSTextTableBlock)?.startingColumn, 1)
        XCTAssertTrue(value.string.contains("a|b"), "escaped pipes use the same table parser as Normal")
        XCTAssertFalse(value.string.contains("**"))
        XCTAssertFalse(value.string.contains("---"))
        let view = LightNativeTranscript.TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.update(id: UUID(), messages: [ChatMessage(id: "table", role: "assistant", text: "| A | B |\n|---|---|\n| 1 | 2 |")])
        let text = try XCTUnwrap(view.documentView as? NSTextView)
        let container = try XCTUnwrap(text.textContainer)
        try XCTUnwrap(text.layoutManager).ensureLayout(for: container)
        XCTAssertGreaterThan(try XCTUnwrap(text.layoutManager).usedRect(for: container).height, 0)
    }

    @MainActor func testStreamingRestylesClosedMarkdownWithoutChangingEarlierSelection() throws {
        let view = LightNativeTranscript.TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let id = UUID()
        let user = ChatMessage(id: "user", role: "user", text: "**literal** 🙂")
        var reply = ChatMessage(id: "reply", role: "assistant", text: "**café")
        view.update(id: id, messages: [user, reply])
        let text = try XCTUnwrap(view.documentView as? NSTextView)
        let selection = NSRange(location: 3, length: 7)
        text.setSelectedRange(selection)
        reply.text += " 🙂** y [enlace](https://example.com)"
        view.update(id: id, messages: [user, reply])
        XCTAssertEqual(text.string, LightMarkdown.message(user).string + LightMarkdown.message(reply).string)
        XCTAssertTrue(text.string.contains("**literal**"), "user text is not interpreted as Markdown")
        XCTAssertFalse(text.string.contains("**café"))
        XCTAssertEqual(text.selectedRange(), selection)
        reply.text = "## Corregido\n\n```swift\nprint(\"🙂\")"
        view.update(id: id, messages: [user, reply])
        XCTAssertEqual(text.string, LightMarkdown.message(user).string + LightMarkdown.message(reply).string)
        XCTAssertFalse(text.string.contains("https://example.com"))
        XCTAssertTrue(text.string.contains("print(\"🙂\")"))
    }

    @MainActor func testUnchangedLaterMessageKeepsCachedTableWhenEarlierMessageChanges() throws {
        let view = LightNativeTranscript.TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let id = UUID()
        var first = ChatMessage(id: "first", role: "assistant", text: "Primero")
        let table = ChatMessage(id: "table", role: "assistant", text: "| Nombre |\n|---|\n| dato |")
        view.update(id: id, messages: [first, table])
        let text = try XCTUnwrap(view.documentView as? NSTextView)
        func nativeTable() throws -> NSTextTable {
            let storage = try XCTUnwrap(text.textStorage)
            let index = (text.string as NSString).range(of: "Nombre").location
            let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            return try XCTUnwrap((style.textBlocks.first as? NSTextTableBlock)?.table)
        }
        let originalTable = try nativeTable()
        first.text += " corregido"
        view.update(id: id, messages: [first, table])
        XCTAssertTrue(try nativeTable() === originalTable, "unchanged messages are reused, not reparsed")
        view.update(id: UUID(), messages: [first, table])
        XCTAssertFalse(try nativeTable() === originalTable, "conversation switches clear the bounded cache")
    }
}
