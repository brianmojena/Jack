import AppKit
import JackCore
import SwiftUI

/// Native Markdown uses Normal's parser; unchanged message blocks retain their attributed text.
struct LightNativeTranscript: NSViewRepresentable {
    let conversationID: UUID
    let messages: [ChatMessage]
    var isVisible = true

    func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView() }
    func updateNSView(_ view: TranscriptScrollView, context: Context) {
        if isVisible { view.update(id: conversationID, messages: messages) }
    }

    final class TranscriptScrollView: NSScrollView {
        // TextKit 1 supports native NSTextTable cells without an implicit compatibility-mode switch.
        // The composer continues using TextKit 2; neither view needs a SwiftUI tree per Markdown block.
        private let text = NSTextView(usingTextLayoutManager: false)
        private var conversationID: UUID?
        private var messages: [ChatMessage] = []
        private var lengths: [Int] = []
        private var rendered: [String: (message: ChatMessage, text: NSAttributedString)] = [:]

        override init(frame: NSRect) {
            super.init(frame: frame)
            hasVerticalScroller = true
            drawsBackground = false
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.textContainerInset = NSSize(width: 16, height: 14)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel("Conversación Light")
            documentView = text
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(id: UUID, messages next: [ChatMessage]) {
            guard conversationID != id || messages != next, let storage = text.textStorage else { return }
            let changedConversation = conversationID != id
            if changedConversation { rendered.removeAll() }
            let follow = changedConversation || messages.isEmpty || contentView.bounds.maxY >= text.bounds.height - 28
            var prefix = 0
            if !changedConversation {
                while prefix < min(messages.count, next.count), messages[prefix] == next[prefix] { prefix += 1 }
            }
            let offset = changedConversation ? 0 : lengths.prefix(prefix).reduce(0, +)
            let blocks = next.dropFirst(prefix).map { message -> NSAttributedString in
                if let cached = rendered[message.id], cached.message == message { return cached.text }
                let block = LightMarkdown.message(message)
                rendered[message.id] = (message, block)
                return block
            }
            let replacement = NSMutableAttributedString(string: "")
            blocks.forEach { replacement.append($0) }
            // A closing Markdown marker may restyle earlier text in the current message.
            // Replace that message, not the already-rendered conversation before it.
            storage.replaceCharacters(in: NSRange(location: offset, length: storage.length - offset), with: replacement)
            lengths = (changedConversation ? [] : Array(lengths.prefix(prefix))) + blocks.map(\.length)
            let visibleIDs = Set(next.map(\.id))
            rendered = rendered.filter { visibleIDs.contains($0.key) }
            conversationID = id
            messages = next
            if follow { text.scrollRangeToVisible(NSRange(location: storage.length, length: 0)) }
        }
    }
}

/// An AppKit renderer, not another Markdown grammar: blocks and inline syntax are shared with Normal.
enum LightMarkdown {
    private static let bodyFont = NSFont.systemFont(ofSize: 13)

    static func message(_ message: ChatMessage) -> NSAttributedString {
        let heading: String
        switch message.role {
        case "user": heading = "Tú"
        case "jack": heading = "Jack"
        case "error": heading = "Error"
        default: heading = "Agente"
        }
        let result = NSMutableAttributedString(string: heading + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: message.role == "error" ? NSColor.systemRed : NSColor.secondaryLabelColor
        ])
        // User messages stay literal, as in Normal: pasted Markdown/code isn't rewritten.
        if message.role == "assistant" {
            result.append(body(message.text))
        } else {
            result.append(NSAttributedString(string: message.text + "\n\n", attributes: attributes()))
        }
        if let files = message.attachments, !files.isEmpty {
            result.deleteCharacters(in: NSRange(location: result.length - 2, length: 2))
            result.append(NSAttributedString(string: "\n" + files.map { "Adjunto: " + $0 }.joined(separator: "\n") + "\n\n",
                                             attributes: attributes()))
        }
        return result
    }

    static func body(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in MarkdownBlock.parse(source) {
            switch block {
            case let .paragraph(text):
                result.append(inline(text)); result.append(newlines())
            case let .heading(level, text):
                let size: CGFloat = level == 1 ? 17 : level == 2 ? 15 : 14
                result.append(inline(text, font: .systemFont(ofSize: size, weight: .semibold)))
                result.append(newlines())
            case let .list(items, ordered):
                for (index, item) in items.enumerated() {
                    let style = paragraph()
                    style.firstLineHeadIndent = CGFloat(item.indent) * 16
                    style.headIndent = style.firstLineHeadIndent + 22
                    style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                    let line = NSMutableAttributedString(string: ordered ? "\(index + 1).\t" : "•\t", attributes: attributes(style: style))
                    line.append(inline(item.text, style: style))
                    line.append(NSAttributedString(string: "\n", attributes: attributes(style: style)))
                    result.append(line)
                }
                result.append(newlines(1))
            case let .quote(text):
                let style = paragraph(); style.firstLineHeadIndent = 12; style.headIndent = 12
                let quote = inline(text, style: style)
                quote.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: quote.length))
                result.append(quote); result.append(newlines())
            case let .code(language, code):
                if !language.isEmpty {
                    result.append(NSAttributedString(string: language + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
                var attrs = attributes(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
                result.append(NSAttributedString(string: code + "\n", attributes: attrs))
                result.append(newlines(1))
            case let .table(table):
                result.append(renderTable(table)); result.append(newlines(1))
            case .rule:
                result.append(NSAttributedString(string: "────────────────────────\n\n", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.separatorColor
                ]))
            }
        }
        if result.length == 0 { result.append(newlines()) }
        return result
    }

    private static func inline(_ source: String, font: NSFont = bodyFont,
                               style: NSParagraphStyle? = nil) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSMutableAttributedString(string: source, attributes: attributes(font: font, style: style))
        }
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attrs = attributes(font: font, style: style)
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            attrs[.font] = runFont
            if intent.contains(.code) { attrs[.backgroundColor] = NSColor.quaternaryLabelColor }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link; attrs[.foregroundColor] = NSColor.linkColor }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return result
    }

    private static func renderTable(_ source: MarkdownBlock.Table) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = source.header.count
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let result = NSMutableAttributedString(string: "")
        for (row, cells) in ([source.header] + source.rows).enumerated() {
            for column in source.header.indices {
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.backgroundColor = row == 0 ? .controlBackgroundColor : .textBackgroundColor
                cell.verticalAlignment = .top
                let style = paragraph()
                style.textBlocks = [cell]
                let alignment = source.alignments[column]
                style.alignment = alignment == .right ? .right : alignment == .center ? .center : .left
                let font = row == 0 ? NSFont.systemFont(ofSize: 13, weight: .semibold) : bodyFont
                result.append(inline(cells[column], font: font, style: style))
                result.append(NSAttributedString(string: "\n", attributes: attributes(font: font, style: style)))
            }
        }
        return result
    }

    private static func paragraph() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        return style
    }
    private static func attributes(font: NSFont = bodyFont, style: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style ?? paragraph()]
    }
    private static func newlines(_ count: Int = 2) -> NSAttributedString {
        NSAttributedString(string: String(repeating: "\n", count: count), attributes: attributes())
    }
}

struct LightNativeComposer: NSViewRepresentable {
    @Binding var text: String
    let conversationID: UUID
    let focusRequest: Int
    let onSend: (String, Bool) -> Void
    let onAside: (String) -> Void
    let onStop: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = ComposerTextView(usingTextLayoutManager: true)
        editor.delegate = context.coordinator
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.writingToolsBehavior = .none
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Mensaje")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        let changed = context.coordinator.conversationID != conversationID
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: changed ? length : min(selection.location, length), length: 0))
        }
        if changed {
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.send = onSend
        editor.aside = onAside
        editor.stop = onStop
        if changed || context.coordinator.focusRequest != focusRequest {
            context.coordinator.conversationID = conversationID
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LightNativeComposer
        var conversationID: UUID?
        var focusRequest = -1
        init(_ parent: LightNativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }

    final class ComposerTextView: NSTextView {
        var send: ((String, Bool) -> Void)?
        var aside: ((String) -> Void)?
        var stop: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76) {
                if event.modifierFlags.contains(.shift) { super.keyDown(with: event); return }
                if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) { aside?(string) }
                else { send?(string, event.modifierFlags.contains(.command)) }
                return
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "." { stop?(); return }
            super.keyDown(with: event)
        }
    }
}

/// Reports occlusion/minimization via native notifications, with no repeating task.
struct LightWindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.removeObservers() }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }
        private func report() {
            guard let window else { return }
            onChange?(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }
        func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
