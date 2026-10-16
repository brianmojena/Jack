import AppKit
import JackCore
import SwiftUI

/// Lo que se ve en el monitor de un puesto mientras su agente trabaja: la pestaña de Claude con lo último que ha pasado.
/// Es una imagen pequeña y legible de lejos, no la sesión real (esa se abre al usar el PC).
struct OfficeMonitorView: View {
    struct Line: Identifiable {
        enum Kind { case user, assistant, tool, error }
        var id: String
        var kind: Kind
        var text: String
    }

    let title: String
    let model: String
    let status: ChatStatus
    let lines: [Line]
    let size: CGSize

    private var unit: CGFloat { size.height / 540 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14 * unit) {
                HStack(spacing: 10 * unit) {
                    Circle().fill(Color(red: 1, green: 0.55, blue: 0.2)).frame(width: 16 * unit, height: 16 * unit)
                    Text(title).font(.system(size: 26 * unit, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 20 * unit).frame(height: 54 * unit)
                .background(Color(white: 0.14), in: UnevenRoundedRectangle(topLeadingRadius: 14 * unit, topTrailingRadius: 14 * unit))
                Spacer()
                Text(model).font(.system(size: 22 * unit, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            .padding(.horizontal, 24 * unit).padding(.top, 12 * unit)
            .frame(height: 66 * unit).background(Color(white: 0.06))
            VStack(alignment: .leading, spacing: 12 * unit) {
                ForEach(lines) { line in row(line) }
                Spacer(minLength: 0)
                HStack(spacing: 12 * unit) {
                    Text("›").font(.system(size: 30 * unit, weight: .bold, design: .monospaced)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.2))
                    Text(status == .running ? "trabajando…" : status == .waiting ? "esperando tu respuesta" : "listo para el siguiente mensaje")
                        .font(.system(size: 26 * unit, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 18 * unit).padding(.vertical, 14 * unit)
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12 * unit))
            }
            .padding(24 * unit)
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func row(_ line: Line) -> some View {
        switch line.kind {
        case .user:
            Text("› \(line.text)").font(.system(size: 28 * unit, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.4)).lineLimit(2)
        case .assistant:
            Text(line.text).font(.system(size: 28 * unit, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
        case .tool:
            Text("⏺ \(line.text)").font(.system(size: 25 * unit, design: .monospaced)).foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55)).lineLimit(1)
        case .error:
            Text(line.text).font(.system(size: 26 * unit, design: .monospaced)).foregroundStyle(Color(red: 1, green: 0.4, blue: 0.35)).lineLimit(2)
        }
    }

    /// Las últimas líneas de la conversación, resumidas para el monitor.
    static func lines(of conversation: ChatConversation) -> [Line] {
        var found: [Line] = []
        for message in conversation.messages.suffix(14).reversed() {
            let line: Line?
            switch message.role {
            case "user": line = message.text.isEmpty ? nil : Line(id: message.id, kind: .user, text: message.text)
            case "assistant": line = message.text.isEmpty ? nil : Line(id: message.id, kind: .assistant, text: message.text)
            case "tool":
                let tool = ToolPresentation(message: message, projectPath: conversation.projectPath)
                let subject = tool.kind == .command ? tool.subject : (tool.subject as NSString).lastPathComponent
                line = Line(id: message.id, kind: .tool, text: [tool.verb(running: ["running", "inProgress", "pending"].contains(message.status)), subject]
                    .filter { !$0.isEmpty }.joined(separator: " "))
            case "error": line = Line(id: message.id, kind: .error, text: message.text)
            default: line = nil
            }
            if let line { found.append(line) }
            if found.count == 5 { break }
        }
        return found.reversed()
    }

    /// Dibuja el monitor como imagen.
    @MainActor static func image(conversation: ChatConversation, status: ChatStatus, model: String, size: CGSize) -> CGImage? {
        let view = OfficeMonitorView(title: conversation.title, model: model, status: status, lines: lines(of: conversation), size: size)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }
}
