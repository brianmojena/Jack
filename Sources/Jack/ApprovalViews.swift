import JackCore
import SwiftUI

/// A request from the agent that waits for the user: a permission, a plan to approve or questions.
/// Tool requests are previewed the way the transcript shows that tool: a command, or the diff of an edit.
struct ApprovalCard: View {
    let approval: ChatApproval
    let provider: ChatProvider
    let projectPath: String
    /// The agent reads a message typed in the chat as the reason for rejecting.
    let repliesInChat: Bool
    /// Off while the composer holds a message, so ⌘↩ sends it instead of answering here.
    var shortcutsEnabled = true
    let onRespond: (_ choice: String, _ message: String?) -> Void
    let onAnswer: ([String: String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Spacer()
            }
            if !approval.questions.isEmpty {
                ChatQuestionForm(approval: approval, shortcutsEnabled: shortcutsEnabled, onAnswer: onAnswer)
            } else if approval.isPlan {
                ScrollView { PlanBox(text: approval.detail) }
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
                planButtons
            } else {
                Text(approval.title).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                preview
                permissionButtons
            }
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Ice: floats as glass over the transcript, which scrolls beneath the composer.
        .jackGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), basic: .clear)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var symbol: String {
        if !approval.questions.isEmpty { return "questionmark.bubble.fill" }
        return approval.isPlan ? "list.bullet.clipboard.fill" : "hand.raised.fill"
    }
    private var tint: Color { approval.isPlan ? JackPalette.blue : JackPalette.amber }
    private var heading: String {
        if !approval.questions.isEmpty { return "\(provider.title) tiene preguntas" }
        return approval.isPlan ? "\(provider.title) propone un plan" : "\(provider.title) necesita tu permiso"
    }

    @ViewBuilder private var preview: some View {
        if let tool = approval.tool {
            let presentation = ToolPresentation(message: ChatMessage(role: "tool", text: tool, detail: approval.detail), projectPath: projectPath)
            let diff = ToolActivityRow.diffLines(for: presentation)
            if !diff.isEmpty {
                if !presentation.subject.isEmpty {
                    Text(presentation.subject).font(.system(size: 11, design: .monospaced)).foregroundStyle(JackPalette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                DiffView(lines: diff)
            } else if presentation.kind == .command, let command = presentation.input["command"] as? String {
                if let reason = presentation.input["description"] as? String, !reason.isEmpty {
                    Text(reason).font(.system(size: 12)).foregroundStyle(JackPalette.secondaryText)
                }
                OutputBox(text: "$ " + command)
            } else {
                OutputBox(text: Self.readable(presentation.input, fallback: approval.detail))
            }
        } else if !approval.detail.isEmpty {
            OutputBox(text: approval.detail.count > 4_000 ? approval.detail.prefix(4_000) + "\n…" : approval.detail)
        }
    }

    private var permissionButtons: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                if repliesInChat {
                    Text("O escribe en el chat qué debe hacer en su lugar")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Button("Rechazar") { onRespond("deny", nil) }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Rechazar (Esc)")
                Button("Permitir") { onRespond("allow", nil) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help("Permitir una vez (⌘↩)")
            }
            ForEach(approval.choices) { choice in
                Button { onRespond(choice.id, nil) } label: {
                    Text(choice.title).lineLimit(1).truncationMode(.middle)
                }
                .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return, modifiers: [.command, .option]) : nil)
                .help("\(choice.title) (⌥⌘↩)")
            }
        }
        .controlSize(.regular)
    }

    private var planButtons: some View {
        HStack(spacing: 8) {
            if repliesInChat {
                Text("O escribe en el chat qué cambiar")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ForEach(Array(approval.choices.reversed())) { choice in
                switch choice.id {
                case "deny":
                    Button(choice.title) { onRespond(choice.id, nil) }
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("\(choice.title) (Esc)")
                case "plan.acceptEdits":
                    Button(choice.title) { onRespond(choice.id, nil) }
                        .buttonStyle(.borderedProminent).tint(JackPalette.blue)
                        .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .help("\(choice.title) (⌘↩)")
                default:
                    Button(choice.title) { onRespond(choice.id, nil) }
                        .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return, modifiers: [.command, .option]) : nil)
                        .help("\(choice.title) (⌥⌘↩)")
                }
            }
        }
        .controlSize(.regular)
    }

    /// A tool's input as `key: value` lines, which read better than JSON for most tools.
    private static func readable(_ input: [String: Any], fallback: String) -> String {
        guard !input.isEmpty else { return fallback }
        return input.keys.sorted().map { key in
            let value = input[key].map { $0 as? String ?? String(describing: $0) } ?? ""
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }
}

struct ChatQuestionForm: View {
    let approval: ChatApproval
    var shortcutsEnabled = true
    let onAnswer: ([String: String]) -> Void
    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(approval.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !question.header.isEmpty {
                            Text(question.header.uppercased())
                                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(JackPalette.panelStrong, in: Capsule())
                                .foregroundStyle(JackPalette.muted)
                        }
                        Text(question.question).font(.system(size: 12.5, weight: .medium))
                    }
                    if let options = question.options, !options.isEmpty {
                        ForEach(options, id: \.label) { option in
                            optionRow(option, question: question)
                        }
                    }
                    let binding = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                    if question.isSecret == true {
                        SecureField("Respuesta", text: binding).textFieldStyle(.roundedBorder)
                    } else {
                        TextField(question.options?.isEmpty == false ? "Otra respuesta" : "Escribe tu respuesta", text: binding)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Enviar respuestas") { onAnswer(finalAnswers) }
                    .buttonStyle(.borderedProminent).tint(JackPalette.accent)
                    .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(approval.questions.contains { (finalAnswers[$0.id] ?? "").isEmpty })
                    .help("Enviar respuestas (⌘↩)")
            }
        }
    }

    private func optionRow(_ option: ChatInputOption, question: ChatInputQuestion) -> some View {
        let multiple = question.multiSelect == true
        let chosen = multiple ? selections[question.id, default: []].contains(option.label) : answers[question.id] == option.label
        return Button {
            if multiple {
                if chosen { selections[question.id, default: []].remove(option.label) } else { selections[question.id, default: []].insert(option.label) }
            } else {
                answers[question.id] = option.label
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multiple ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(chosen ? JackPalette.accent : JackPalette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).fontWeight(.medium)
                    if !option.description.isEmpty, option.description != option.label {
                        Text(option.description).foregroundStyle(JackPalette.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(chosen ? JackPalette.accent.opacity(0.1) : JackPalette.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Chosen options, in their order, followed by anything typed.
    private var finalAnswers: [String: String] {
        var result: [String: String] = [:]
        for question in approval.questions {
            let typed = (answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if question.multiSelect == true {
                let chosen = (question.options ?? []).map(\.label).filter { selections[question.id, default: []].contains($0) }
                result[question.id] = (chosen + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
            } else {
                result[question.id] = typed
            }
        }
        return result
    }
}
