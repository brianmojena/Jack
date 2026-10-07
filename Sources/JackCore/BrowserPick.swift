import CoreGraphics
import Foundation

/// An element the user picked in Jack's browser, with what an agent needs to find it in the code.
public struct BrowserPick: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// A CSS path that finds the element on the page.
    public let selector: String
    /// The element's opening tag, such as `<button class="buy">`.
    public let tag: String
    /// Its visible text, shortened.
    public let text: String
    /// Its HTML, shortened.
    public let html: String
    /// The UI component that rendered it, in development builds of React, Vue or Svelte.
    public let component: String?
    /// The component's source file and line, when the framework exposes them.
    public let source: String?
    /// Where it sits in the page's viewport, in CSS pixels.
    public let rect: CGRect
    public let url: String
    /// A picture of the element, attached to the message.
    public var snapshot: String?

    public init(id: UUID = UUID(), selector: String, tag: String, text: String, html: String, component: String?, source: String?,
                rect: CGRect, url: String, snapshot: String? = nil) {
        self.id = id
        self.selector = selector
        self.tag = tag
        self.text = text
        self.html = html
        self.component = component
        self.source = source
        self.rect = rect
        self.url = url
        self.snapshot = snapshot
    }

    /// Reads what the page's picker script posted.
    public init?(message: [String: Any]) {
        guard let selector = message["selector"] as? String, !selector.isEmpty else { return nil }
        func string(_ key: String) -> String? {
            (message[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let rect = message["rect"] as? [String: Any]
        func number(_ key: String) -> CGFloat { CGFloat((rect?[key] as? NSNumber)?.doubleValue ?? 0) }
        self.init(selector: selector, tag: string("tag") ?? "", text: string("text") ?? "", html: string("html") ?? "",
                  component: string("component"), source: string("source"),
                  rect: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                  url: string("url") ?? "")
    }

    /// A short name for the chip over the composer: the component if known, otherwise the tag.
    public var label: String {
        if let component { return "<\(component)>" }
        let name = tag.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.isEmpty ? selector : "<\(name)>"
    }

    /// The user's message with the picked elements described under it, for the agent.
    public static func message(_ text: String, picks: [BrowserPick]) -> String {
        guard !picks.isEmpty else { return text }
        let page = picks.first?.url ?? ""
        var lines = [text.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        lines.append(picks.count == 1 ? "Elemento que seleccioné en el navegador de Jack (\(page)):"
                                      : "Elementos que seleccioné en el navegador de Jack (\(page)):")
        for (index, pick) in picks.enumerated() {
            lines.append("")
            lines.append(picks.count == 1 ? "- \(pick.tag)" : "\(index + 1). \(pick.tag)")
            if let component = pick.component {
                lines.append("  Componente: \(component)" + (pick.source.map { " (\($0))" } ?? ""))
            } else if let source = pick.source {
                lines.append("  Archivo: \(source)")
            }
            lines.append("  Selector: \(pick.selector)")
            if !pick.text.isEmpty { lines.append("  Texto: «\(pick.text)»") }
            lines.append("  Tamaño: \(Int(pick.rect.width))×\(Int(pick.rect.height)) px")
            if !pick.html.isEmpty { lines.append("  HTML: \(pick.html)") }
        }
        if picks.contains(where: { $0.snapshot != nil }) { lines.append(""); lines.append("Adjunto una captura de cada elemento.") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
