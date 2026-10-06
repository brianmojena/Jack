import JackCore
import SwiftUI

/// Messages written while the agent works, above the composer until the agent reads them.
struct WaitingMessagesView: View {
    let messages: [ChatQueuedMessage]
    let provider: ChatProvider
    /// The agent reads them after its current step rather than when its turn ends.
    let readsWhileWorking: Bool
    let onSendNow: () -> Void
    let onEdit: (ChatQueuedMessage) -> Void
    let onRemove: (ChatQueuedMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                Text("En espera").font(.system(size: 11, weight: .semibold))
                Text(readsWhileWorking ? "· \(provider.title) lo leerá al terminar el paso actual" : "· se enviará cuando \(provider.title) termine")
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(JackPalette.muted)
                Spacer(minLength: 8)
                Button(action: onSendNow) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").font(.system(size: 9))
                        Text("Interrumpir y enviar")
                        Text("⌘↩").foregroundStyle(JackPalette.muted)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(JackPalette.accent)
                .help("Detiene el paso en curso para que \(provider.title) lea ya los mensajes en espera (⌘↩)")
            }
            .foregroundStyle(JackPalette.secondaryText)
            ForEach(messages) { message in
                WaitingMessageRow(message: message, onEdit: { onEdit(message) }, onRemove: { onRemove(message) })
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(JackPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct WaitingMessageRow: View {
    let message: ChatQueuedMessage
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("›").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(JackPalette.faint)
            Text(message.text.isEmpty ? "Archivos adjuntos" : message.text)
                .font(.system(size: 12)).lineLimit(2).foregroundStyle(JackPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !message.attachments.isEmpty {
                Label("\(message.attachments.count)", systemImage: "paperclip")
                    .font(.system(size: 10.5)).foregroundStyle(JackPalette.muted)
                    .help(message.attachments.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n"))
            }
            HStack(spacing: 2) {
                Button(action: onEdit) { Image(systemName: "pencil").frame(width: 20, height: 18).contentShape(Rectangle()) }
                    .help("Editar: lo devuelve al cuadro de mensaje")
                    .accessibilityLabel("Editar mensaje en espera")
                Button(action: onRemove) { Image(systemName: "xmark").frame(width: 20, height: 18).contentShape(Rectangle()) }
                    .help("Quitar de la espera")
                    .accessibilityLabel("Quitar mensaje en espera")
            }
            .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(JackPalette.muted)
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
