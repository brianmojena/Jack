import Foundation

/// A plan from an agent in plan mode, drawn as a flowchart: start, one node per step and end.
/// Built from the plan's Markdown alone, so it needs no model call and works for every provider.
public struct PlanFlow: Equatable {
    public struct Step: Identifiable, Equatable {
        public var id: Int
        public var title: String
        /// Sub-steps and notes under the step.
        public var details: [String]
        /// The section of the plan it belongs to, when the plan has several.
        public var phase: String?
        /// A question: the flow can go two ways, so the node is drawn as a decision.
        public var isDecision: Bool
        /// Files the step names, as `code` in the Markdown.
        public var files: [String]
    }

    public var title: String
    public var steps: [Step]

    /// A flow needs at least two steps; one line is not a flowchart.
    public static let minimumSteps = 2

    public init(title: String, steps: [Step]) { self.title = title; self.steps = steps }

    /// The flow of a plan, or nil when the text has no sequence of steps.
    public static func parse(_ markdown: String) -> PlanFlow? {
        let blocks = MarkdownBlock.parse(markdown)
        var title = ""
        var phase: String?
        var phases = 0
        var numbered: [Step] = []
        var bullets: [Step] = []
        var headings: [Step] = []
        // Nested items belong to the last top-level item, even when the parser split the list in two.
        var lastOrdered: Bool?

        for block in blocks {
            switch block {
            case let .heading(level, text):
                let clean = plain(text)
                if level == 1, title.isEmpty { title = stripPrefix(clean); continue }
                if title.isEmpty, level == 2 { title = stripPrefix(clean) }
                phase = clean; phases += 1
                if level >= 2 { headings.append(Step(id: 0, title: stripPrefix(clean), details: [], phase: nil, isDecision: false, files: [])) }
            case let .list(items, ordered):
                for item in items {
                    if item.indent == 0 {
                        if ordered { numbered.append(step(item.text, phase: phase)) } else { bullets.append(step(item.text, phase: phase)) }
                        lastOrdered = ordered
                    } else if lastOrdered == true, !numbered.isEmpty {
                        numbered[numbered.count - 1].details.append(plain(item.text))
                    } else if lastOrdered == false, !bullets.isEmpty {
                        bullets[bullets.count - 1].details.append(plain(item.text))
                    }
                }
            default:
                continue
            }
        }

        // Numbered steps are the plan's own order; bullets are the next best; sections the last resort.
        var steps = numbered.count >= minimumSteps ? numbered : bullets.count >= minimumSteps ? bullets : headings
        guard steps.count >= minimumSteps else { return nil }
        // Phases that name a single group of steps add nothing.
        if Set(steps.compactMap(\.phase)).count < 2 { for index in steps.indices { steps[index].phase = nil } }
        for index in steps.indices { steps[index].id = index }
        return PlanFlow(title: title.isEmpty ? "Plan" : title, steps: Array(steps.prefix(40)))
    }

    private static func step(_ text: String, phase: String?) -> Step {
        let files = codeSpans(in: text).filter(looksLikeFile)
        let title = plain(text)
        return Step(id: 0, title: title, details: [], phase: phase, isDecision: isDecision(title), files: files)
    }

    private static func isDecision(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasSuffix("?") || lower.hasPrefix("decidir ") || lower.hasPrefix("decide ") || lower.hasPrefix("comprobar si ")
            || lower.hasPrefix("check whether ") || lower.hasPrefix("decide whether ")
    }

    private static func looksLikeFile(_ span: String) -> Bool {
        guard !span.contains(" "), span.count < 120 else { return false }
        let name = span.split(separator: "/").last.map(String.init) ?? span
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return span.contains("/") }
        let ext = name[name.index(after: dot)...]
        return !ext.isEmpty && ext.count <= 6 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func codeSpans(in text: String) -> [String] {
        let parts = text.components(separatedBy: "`")
        return parts.indices.filter { $0 % 2 == 1 }.map { parts[$0] }
    }

    /// Markdown emphasis, links and code marks removed, for labels.
    static func plain(_ text: String) -> String {
        var result = text
        // [label](url) → label
        while let open = result.range(of: "["), let mid = result.range(of: "](", range: open.upperBound..<result.endIndex),
              let close = result.range(of: ")", range: mid.upperBound..<result.endIndex) {
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: result[open.upperBound..<mid.lowerBound])
        }
        for mark in ["**", "__", "`", "*"] { result = result.replacingOccurrences(of: mark, with: "") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Plan: x" and "Paso 1: x" heads read better as "x".
    private static func stripPrefix(_ text: String) -> String {
        for prefix in ["Plan:", "Plan de implementación:", "Plan —", "Plan -"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // MARK: Mermaid

    /// The flow as a Mermaid `flowchart TD`, to paste in docs, issues or a Markdown file.
    public var mermaid: String {
        func label(_ text: String) -> String {
            let clean = text.replacingOccurrences(of: "\"", with: "'")
            return clean.count > 80 ? String(clean.prefix(79)) + "…" : clean
        }
        var lines = ["flowchart TD", "    start([\"\(label(title))\"])"]
        var previous = "start"
        var arrow = "-->"
        for step in steps {
            let node = "s\(step.id + 1)"
            lines.append(step.isDecision ? "    \(node){\"\(label(step.title))\"}" : "    \(node)[\"\(step.id + 1). \(label(step.title))\"]")
            lines.append("    \(previous) \(arrow) \(node)")
            previous = node
            arrow = step.isDecision ? "-->|sí|" : "-->"
        }
        lines.append("    done([\"Listo\"])")
        lines.append("    \(previous) --> done")
        return lines.joined(separator: "\n")
    }
}

/// A plan an agent has put forward, with an identity that stays the same while the plan streams in.
public struct PlanOffer: Equatable {
    public var key: String
    public var markdown: String
}

/// Finds the plan an agent has put forward in a conversation.
public enum PlanSource {
    /// The latest plan of the current turn, if there is one: Claude's `ExitPlanMode` tool call, or, for
    /// agents that plan in plain text, the reply to the last message while the conversation is in plan mode.
    public static func latest(in messages: [ChatMessage], mode: String?) -> PlanOffer? {
        for message in messages.reversed() {
            if message.role == "user" { break }
            if message.role == "tool", message.text.lowercased() == "exitplanmode", let plan = plan(inDetail: message.detail) {
                return PlanOffer(key: message.id, markdown: plan)
            }
        }
        guard mode == "plan" else { return nil }
        var reply: [String] = []
        var turn = ""
        for message in messages.reversed() {
            if message.role == "user" { turn = message.id; break }
            if message.role == "assistant", !message.text.isEmpty { reply.insert(message.text, at: 0) }
        }
        let text = reply.joined(separator: "\n\n")
        return text.isEmpty ? nil : PlanOffer(key: "text-" + turn, markdown: text)
    }

    /// `{"plan": "…"}` at the start of a tool's detail.
    static func plan(inDetail detail: String) -> String? {
        let trimmed = detail.drop { $0.isWhitespace }
        guard trimmed.first == "{" else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in trimmed.indices {
            let character = trimmed[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    guard let data = String(trimmed[...index]).data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let plan = object["plan"] as? String, !plan.isEmpty else { return nil }
                    return plan
                }
            }
        }
        return nil
    }
}

public extension ChatStore {
    /// The plan the agent is putting forward, from the plan it is waiting for approval on or from its transcript.
    /// A plan in plain text counts once the turn is over, so questions and partial replies do not draw a flowchart.
    func plan(for id: UUID) -> PlanOffer? {
        if let approval = approvals[id]?.first(where: \.isPlan), !approval.detail.isEmpty {
            return PlanOffer(key: approval.id, markdown: approval.detail)
        }
        guard let conversation = conversations.first(where: { $0.id == id }) else { return nil }
        let offer = PlanSource.latest(in: conversation.messages, mode: conversation.mode)
        if let offer, offer.key.hasPrefix("text-"), statuses[id] == .running || statuses[id] == .queued { return nil }
        return offer
    }
}
