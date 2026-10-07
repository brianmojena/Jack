import JackCore
import SwiftUI

/// One-line live summary of what the agent is doing, shown above the composer.
struct AgentActivityView: View {
    let conversation: ChatConversation
    let status: ChatStatus
    let tokens: ChatTokenUsage?
    let projectPath: String
    /// The agent's model is choosing the project folder before starting.
    var locating = false
    private var activity: ChatMessage? { conversation.messages.last.flatMap { $0.role == "user" ? nil : $0 } }

    private var title: String {
        if locating { return "Buscando la carpeta del proyecto" }
        if status == .queued { return "En cola, esperando un espacio libre" }
        if status == .waiting { return "Esperando tu respuesta" }
        guard let activity else { return "Preparando respuesta" }
        if activity.role == "reasoning" { return "Pensando" }
        if activity.role == "assistant" { return "Escribiendo respuesta" }
        if activity.role == "tool", ["running", "inProgress", "pending"].contains(activity.status) {
            let tool = ToolPresentation(message: activity, projectPath: projectPath)
            return [tool.verb(running: true), tool.subject].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return "Preparando el siguiente paso"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            line
            let tasks = AgentTask.list(in: conversation.messages)
            if !tasks.isEmpty, tasks.contains(where: { $0.status != "completed" }) {
                AgentTaskList(tasks: tasks).padding(.leading, 26)
            }
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            if status == .waiting {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(JackPalette.amber)
            } else if status == .queued {
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(JackPalette.muted)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JackPalette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let tokens, case let total = tokens.input + tokens.output, total > 0 {
                Text("\(total.formatted(.number.notation(.compactName))) tokens")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(JackPalette.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// An item of the task list Claude Code keeps with TaskCreate and TaskUpdate (or TodoWrite).
struct AgentTask: Equatable {
    let id: String
    let subject: String
    var status: String

    /// The list as the latest calls left it; only recent messages are read, so it costs little while streaming.
    static func list(in messages: [ChatMessage]) -> [AgentTask] {
        var tasks: [AgentTask] = []
        for message in messages.suffix(600) where message.role == "tool" {
            // Claude uses TaskCreate/TaskUpdate/TodoWrite; OpenCode reports `todowrite` in lowercase.
            let name = message.text.lowercased()
            guard name.hasPrefix("task") || name == "todowrite" || name == "todo" else { continue }
            let (input, rest) = ToolPresentation.splitLeadingJSON(message.detail)
            switch name {
            case "taskcreate":
                guard let subject = input["subject"] as? String else { continue }
                let number = rest.range(of: #"#(\d+)"#, options: .regularExpression).map { String(rest[$0].dropFirst()) } ?? "\(tasks.count + 1)"
                tasks.removeAll { $0.id == number }
                tasks.append(AgentTask(id: number, subject: subject, status: "pending"))
            case "taskupdate":
                guard let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init),
                      let index = tasks.firstIndex(where: { $0.id == id }) else { continue }
                if let status = input["status"] as? String {
                    if status == "deleted" { tasks.remove(at: index) } else { tasks[index].status = status }
                }
            case "todowrite", "todo":
                guard let todos = input["todos"] as? [[String: Any]] else { continue }
                tasks = todos.enumerated().compactMap { index, todo in
                    (todo["content"] as? String).map { AgentTask(id: "\(index + 1)", subject: $0, status: todo["status"] as? String ?? "pending") }
                }
            default: continue
            }
        }
        return tasks
    }
}

private struct AgentTaskList: View {
    let tasks: [AgentTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visible, id: \.id) { task in
                HStack(spacing: 6) {
                    Image(systemName: symbol(task.status))
                        .font(.system(size: 10))
                        .foregroundStyle(task.status == "in_progress" ? JackPalette.accent : task.status == "completed" ? JackPalette.green : JackPalette.faint)
                        .frame(width: 12)
                    Text(task.subject)
                        .font(.system(size: 11, weight: task.status == "in_progress" ? .medium : .regular))
                        .strikethrough(task.status == "completed", color: JackPalette.faint)
                        .foregroundStyle(task.status == "completed" ? JackPalette.faint : task.status == "in_progress" ? Color.primary : JackPalette.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            if tasks.count > visible.count {
                Text("y \(tasks.count - visible.count) más").font(.system(size: 10.5)).foregroundStyle(JackPalette.faint).padding(.leading, 18)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tareas: \(tasks.filter { $0.status == "completed" }.count) de \(tasks.count) hechas")
    }

    /// The task in progress and its neighbours, at most six.
    private var visible: [AgentTask] {
        guard tasks.count > 6 else { return tasks }
        let current = tasks.firstIndex { $0.status == "in_progress" } ?? tasks.firstIndex { $0.status != "completed" } ?? 0
        let start = max(0, min(current - 1, tasks.count - 6))
        return Array(tasks[start..<start + 6])
    }

    private func symbol(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.square.fill"
        case "in_progress": "square.lefthalf.filled"
        default: "square"
        }
    }
}
