import AppKit
import JackCore
import SwiftUI

/// Leading inset that aligns agent activity with the text column of agent replies.
let chatActivityInset: CGFloat = 33

struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    let provider: ChatProvider
    let projectPath: String
    let isStreaming: Bool
    var topSpacing: CGFloat = 0

    var body: some View {
        content.padding(.top, topSpacing)
    }

    @ViewBuilder private var content: some View {
        switch message.role {
        case "tool": ToolActivityRow(message: message, projectPath: projectPath).padding(.leading, chatActivityInset)
        case "error": errorMessage
        case "user": userMessage
        case "reasoning":
            // Providers often emit empty reasoning blocks; only show them while the agent is thinking.
            if isStreaming || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReasoningRow(text: message.text, isStreaming: isStreaming).padding(.leading, chatActivityInset)
            }
        default: assistantMessage
        }
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if let files = message.attachments, !files.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(files, id: \.self) { AttachmentChip(path: $0) }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            .frame(maxWidth: 600, alignment: .trailing)
        }
        .contextMenu { copyButton(message.text) }
    }

    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            providerGlyph(provider, size: 23)
            VStack(alignment: .leading, spacing: 6) {
                Text(provider.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.muted)
                if message.text.isEmpty, isStreaming {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownText(text: message.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { copyButton(message.text) }
    }

    private var errorMessage: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JackPalette.red)
            Text(message.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(JackPalette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(JackPalette.red.opacity(0.25), lineWidth: 0.5))
        .padding(.leading, chatActivityInset)
    }

    private func copyButton(_ text: String) -> some View {
        Button("Copiar", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

// MARK: - Reasoning

private struct ReasoningRow: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isLong: Bool { trimmed.count > 260 || trimmed.filter { $0 == "\n" }.count > 3 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(JackPalette.faint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                if trimmed.isEmpty {
                    Text("Pensando…")
                        .font(.system(size: 12)).italic().foregroundStyle(JackPalette.faint)
                } else {
                    Text(trimmed)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(JackPalette.muted)
                        .lineLimit(expanded ? nil : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLong {
                        Button(expanded ? "Mostrar menos" : "Mostrar más") {
                            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Razonamiento")
    }
}

// MARK: - Tools

struct ToolPresentation {
    enum Kind { case command, read, edit, search, web, agent, delegate, todo, mcp, other }

    let kind: Kind
    let title: String
    let subject: String
    let input: [String: Any]
    let output: String
    let exitCode: Int?

    var symbol: String {
        switch kind {
        case .command: "terminal"
        case .read: "doc.text"
        case .edit: "pencil.line"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .delegate: "arrow.triangle.branch"
        case .todo: "checklist"
        case .mcp: "puzzlepiece.extension"
        case .other: "wrench.and.screwdriver"
        }
    }

    func verb(running: Bool) -> String {
        switch kind {
        case .command: running ? "Ejecutando" : "Ejecutó"
        case .read: running ? "Leyendo" : "Leyó"
        case .edit: running ? "Editando" : "Editó"
        case .search: running ? "Buscando" : "Buscó"
        case .web: running ? "Consultando" : "Consultó"
        case .agent: "Subagente"
        case .delegate:
            switch title {
            case "create_agent": running ? "Delegando a" : "Delegó a"
            case "wait_for_agents": running ? "Esperando a" : "Esperó a"
            case "send_message": running ? "Escribiendo a" : "Escribió a"
            case "get_agent_result": running ? "Leyendo resultado de" : "Leyó resultado de"
            case "stop_agent": running ? "Deteniendo" : "Detuvo"
            default: running ? "Revisando" : "Revisó"
            }
        case .todo: "Tareas"
        case .mcp, .other: title
        }
    }

    init(message: ChatMessage, projectPath: String) {
        let (input, rest) = Self.splitLeadingJSON(message.detail)
        let name = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        var output = rest
        var subject = ""
        var exitCode: Int?

        func string(_ keys: String...) -> String? {
            for key in keys { if let value = input[key] as? String, !value.isEmpty { return value } }
            return nil
        }
        let path = string("file_path", "filePath", "path", "notebook_path")
        let hasEdit = input["old_string"] != nil || input["oldString"] != nil || input["new_string"] != nil || input["content"] != nil || input["edits"] != nil || input["patchText"] != nil

        let kind: Kind
        let delegateAction = Self.delegateAction(lower)
        if delegateAction != nil {
            kind = .delegate
        } else if lower.hasPrefix("mcp") {
            kind = .mcp
        } else if lower == "ejecutar comando" || ["bash", "shell", "exec", "exec_command", "local_shell"].contains(lower) || input["command"] is String {
            kind = .command
        } else if lower == "editar archivos" || ["edit", "multiedit", "write", "patch", "apply_patch", "notebookedit"].contains(lower) || (path != nil && hasEdit) {
            kind = .edit
        } else if ["read", "view", "cat"].contains(lower) || path != nil {
            kind = .read
        } else if ["grep", "glob", "search", "find", "list", "ls", "codesearch"].contains(lower) || input["pattern"] != nil {
            kind = .search
        } else if lower == "buscar en la web" || ["webfetch", "websearch", "fetch"].contains(lower) || input["url"] != nil {
            kind = .web
        } else if ["task", "agent"].contains(lower) {
            kind = .agent
        } else if lower.hasPrefix("todo") {
            kind = .todo
        } else {
            kind = .other
        }

        switch kind {
        case .command:
            if let command = string("command", "cmd") {
                subject = command
            } else if message.text != "Ejecutar comando", input.isEmpty {
                subject = name
            } else {
                // Codex: "command\nCarpeta: …\noutput\nSalida: N"
                var lines = rest.components(separatedBy: "\n")
                subject = lines.isEmpty ? "" : lines.removeFirst()
                if lines.first?.hasPrefix("Carpeta: ") == true { lines.removeFirst() }
                if let last = lines.last, last.hasPrefix("Salida: ") { exitCode = Int(last.dropFirst(8)); lines.removeLast() }
                output = lines.joined(separator: "\n")
            }
        case .edit:
            if let path { subject = displayPath(path, project: projectPath) }
            else {
                let paths = rest.components(separatedBy: "\n").compactMap { line -> String? in
                    guard let range = line.range(of: ": /") ?? line.range(of: ": ~") else { return nil }
                    let prefix = line[..<range.lowerBound]
                    guard ["add", "delete", "update", "change", "modify", "create"].contains(prefix.lowercased()) else { return nil }
                    return displayPath(String(line[line.index(range.lowerBound, offsetBy: 2)...]), project: projectPath)
                }
                subject = paths.isEmpty ? (name == "Editar archivos" ? "" : displayPath(name, project: projectPath)) : paths.joined(separator: ", ")
            }
        case .read:
            subject = path.map { displayPath($0, project: projectPath) } ?? displayPath(name, project: projectPath)
        case .search:
            subject = [string("pattern", "query"), string("path").map { "en " + displayPath($0, project: projectPath) }].compactMap { $0 }.joined(separator: " ")
        case .web:
            subject = string("url", "query") ?? ""
        case .agent:
            subject = string("description", "prompt") ?? ""
        case .todo:
            subject = ""
        case .delegate:
            switch delegateAction ?? "" {
            case "create_agent":
                let provider = (input["provider"] as? String).flatMap(ChatProvider.init(rawValue:))?.title ?? "un agente"
                subject = [provider, string("title")].compactMap { $0 }.joined(separator: ": ")
            case "wait_for_agents":
                let count = (input["agent_ids"] as? [Any])?.count ?? 0
                subject = count == 1 ? "1 agente" : count > 1 ? "\(count) agentes" : "sus agentes"
            case "list_agents": subject = "sus agentes"
            default: subject = string("agent_id") ?? ""
            }
        case .mcp:
            subject = ""
        case .other:
            subject = string("description", "title") ?? ""
        }

        self.kind = kind
        self.title = kind == .delegate ? delegateAction ?? name : kind == .mcp ? name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ") : name
        self.subject = subject.components(separatedBy: "\n").first ?? subject
        self.input = input
        self.output = output.trimmingCharacters(in: .newlines)
        self.exitCode = exitCode
    }

    /// Jack's own delegation tools, as Claude/Codex (`mcp__jack__x`) and OpenCode (`jack_x`) name them.
    static func delegateAction(_ name: String) -> String? {
        let actions: Set<String> = ["create_agent", "send_message", "wait_for_agents", "get_agent_result", "list_agents", "stop_agent"]
        for prefix in ["mcp__jack__", "jack_"] where name.hasPrefix(prefix) {
            let action = String(name.dropFirst(prefix.count))
            if actions.contains(action) { return action }
        }
        return nil
    }

    /// Splits a detail string that starts with a JSON object into the decoded object and the remaining text.
    static func splitLeadingJSON(_ detail: String) -> ([String: Any], String) {
        let trimmed = detail.drop { $0.isWhitespace }
        guard trimmed.first == "{" else { return ([:], detail) }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        for index in trimmed.indices {
            let character = trimmed[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        guard let end,
              let data = String(trimmed[...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([:], detail) }
        return (object, String(trimmed[trimmed.index(after: end)...]))
    }
}

struct ToolActivityRow: View {
    let message: ChatMessage
    private let presentation: ToolPresentation
    private let diffLines: [DiffLine]
    @State private var expanded: Bool?

    init(message: ChatMessage, projectPath: String) {
        self.message = message
        let presentation = ToolPresentation(message: message, projectPath: projectPath)
        self.presentation = presentation
        self.diffLines = Self.diffLines(for: presentation)
    }

    private var running: Bool { ["running", "inProgress", "pending"].contains(message.status) }
    private var failed: Bool { message.status == "failed" || (presentation.exitCode.map { $0 != 0 } ?? false) }
    private var defaultExpanded: Bool { failed || (presentation.kind == .edit && !diffLines.isEmpty) }
    private var isExpanded: Bool { expanded ?? defaultExpanded }

    var body: some View {
        let tool = presentation
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(JackPalette.faint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: tool.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(failed ? JackPalette.red : JackPalette.muted)
                        .frame(width: 16)
                    Text(tool.verb(running: running))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(JackPalette.secondaryText)
                    if !tool.subject.isEmpty {
                        Text(tool.subject)
                            .font(.system(size: 11.5, design: tool.kind == .command || tool.kind == .read || tool.kind == .edit ? .monospaced : .default))
                            .foregroundStyle(JackPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    statusView
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent(tool)
                    .padding(.leading, 39)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        if running {
            ProgressView().controlSize(.mini)
        } else if failed {
            Label(presentation.exitCode.map { "Código \($0)" } ?? statusTitle, systemImage: "xmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(JackPalette.red)
        } else if message.status == "declined" || message.status == "interrupted" {
            Label(statusTitle, systemImage: "minus.circle.fill").font(.system(size: 11)).foregroundStyle(JackPalette.amber)
        } else if message.status == "completed" {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(JackPalette.green.opacity(0.85))
                .help("Completado")
        } else if !message.status.isEmpty {
            Text(statusTitle).font(.system(size: 11)).foregroundStyle(JackPalette.muted)
        }
    }

    private var statusTitle: String {
        switch message.status {
        case "running", "inProgress", "pending": "En curso"
        case "completed": "Completado"
        case "failed": "Error"
        case "declined": "Rechazado"
        case "interrupted": "Detenido"
        default: message.status
        }
    }

    // MARK: Expanded content

    private static func diffLines(for tool: ToolPresentation) -> [DiffLine] {
        let input = tool.input
        if let old = (input["old_string"] ?? input["oldString"]) as? String, let new = (input["new_string"] ?? input["newString"]) as? String {
            return old.components(separatedBy: "\n").map { DiffLine(kind: .removed, text: $0) } + new.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) }
        }
        if let edits = input["edits"] as? [[String: Any]] {
            return edits.flatMap { edit -> [DiffLine] in
                let old = (edit["old_string"] ?? edit["oldString"]) as? String ?? ""
                let new = (edit["new_string"] ?? edit["newString"]) as? String ?? ""
                return old.components(separatedBy: "\n").map { DiffLine(kind: .removed, text: $0) } + new.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) } + [DiffLine(kind: .context, text: "")]
            }
        }
        if let content = input["content"] as? String, tool.kind == .edit {
            return content.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) }
        }
        let source = (input["patchText"] as? String) ?? (tool.kind == .edit ? tool.output : "")
        guard source.contains("\n+") || source.contains("\n-") || source.hasPrefix("@@") else { return [] }
        return source.components(separatedBy: "\n").map { line in
            if line.hasPrefix("+++") || line.hasPrefix("---") { return DiffLine(kind: .header, text: line) }
            if line.hasPrefix("@@") { return DiffLine(kind: .header, text: line) }
            if line.hasPrefix("+") { return DiffLine(kind: .added, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return DiffLine(kind: .removed, text: String(line.dropFirst())) }
            if line.hasPrefix(" ") { return DiffLine(kind: .context, text: String(line.dropFirst())) }
            return DiffLine(kind: .header, text: line)
        }
    }

    @ViewBuilder private func expandedContent(_ tool: ToolPresentation) -> some View {
        let diff = diffLines
        VStack(alignment: .leading, spacing: 6) {
            if !diff.isEmpty {
                DiffView(lines: diff)
            }
            if tool.kind == .command {
                OutputBox(text: (tool.subject.isEmpty ? "" : "$ \(fullCommand(tool))\n") + tool.output)
            } else if diff.isEmpty || (tool.kind != .edit && !tool.output.isEmpty) {
                let text = tool.output.isEmpty ? prettyInput(tool.input) : tool.output
                if !text.isEmpty { OutputBox(text: text) }
                else { Text("Sin salida").font(.system(size: 11)).foregroundStyle(JackPalette.faint) }
            }
        }
    }

    private func fullCommand(_ tool: ToolPresentation) -> String {
        (tool.input["command"] as? String) ?? tool.subject
    }

    private func prettyInput(_ input: [String: Any]) -> String {
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct DiffLine {
    enum Kind { case added, removed, context, header }
    let kind: Kind
    let text: String
}

/// Number of lines shown before a block collapses behind "Mostrar más"; short overflows are shown whole.
private let collapsedLineLimit = 14
private func collapses(_ count: Int) -> Bool { count > collapsedLineLimit + 4 }

/// Diff without an inner scroll view: wheel events always reach the chat.
private struct DiffView: View {
    let lines: [DiffLine]
    @State private var showAll = false

    var body: some View {
        let visible = showAll || !collapses(lines.count) ? lines.prefix(1_500) : lines.prefix(collapsedLineLimit)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(marker(line.kind)).foregroundStyle(color(line.kind)).frame(width: 10)
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(line.kind == .header ? JackPalette.muted : Color.primary.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
                .background(background(line.kind))
            }
            if collapses(lines.count) {
                ExpandLinesButton(hidden: min(lines.count, 1_500) - collapsedLineLimit, expanded: $showAll)
            }
        }
        .padding(.vertical, 5)
        .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button("Copiar diff", systemImage: "doc.on.doc") {
                let text = lines.map { marker($0.kind).trimmingCharacters(in: .whitespaces) + $0.text }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind { case .added: "+"; case .removed: "−"; case .context, .header: " " }
    }
    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .added: JackPalette.green; case .removed: JackPalette.red; case .context, .header: JackPalette.faint }
    }
    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .added: JackPalette.green.opacity(0.11); case .removed: JackPalette.red.opacity(0.10); case .context, .header: .clear }
    }
}

/// Tool output as a single selectable text, truncated instead of scrolled.
private struct OutputBox: View {
    let text: String
    @State private var showAll = false

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        let lines = self.lines
        let visible = showAll || !collapses(lines.count) ? text : lines.prefix(collapsedLineLimit).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 0) {
            Text(visible)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(1.5)
                .foregroundStyle(JackPalette.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
            if collapses(lines.count) {
                ExpandLinesButton(hidden: lines.count - collapsedLineLimit, expanded: $showAll)
                    .padding(.bottom, 4)
            }
        }
        .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
    }
}

private struct ExpandLinesButton: View {
    let hidden: Int
    @Binding var expanded: Bool

    var body: some View {
        Button(expanded ? "Mostrar menos" : hidden == 1 ? "Mostrar 1 línea más" : "Mostrar \(hidden) líneas más") { expanded.toggle() }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .padding(.horizontal, 9).padding(.top, 4)
    }
}
