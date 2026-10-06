import JackCore
import SwiftUI

/// The answer to a side question (⌥↩ or `!btw`), above the composer until it is closed.
struct AsideView: View {
    @ObservedObject var asides: ChatAsides
    let conversationID: UUID
    let provider: ChatProvider

    var body: some View {
        if let aside = asides.items[conversationID] {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(JackPalette.accent)
                    Text("Al margen").font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.secondaryText)
                    Text(aside.question).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(JackPalette.muted)
                        .help(aside.question)
                    Spacer(minLength: 8)
                    if aside.finished, aside.error == nil {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(aside.answer, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").frame(width: 20, height: 18).contentShape(Rectangle()) }
                        .help("Copiar la respuesta")
                        .accessibilityLabel("Copiar la respuesta")
                    }
                    Button { asides.dismiss(conversationID) } label: {
                        Image(systemName: "xmark").frame(width: 20, height: 18).contentShape(Rectangle())
                    }
                    .help(aside.finished ? "Cerrar (Esc)" : "Cancelar (Esc)")
                    .accessibilityLabel("Cerrar la pregunta al margen")
                }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(JackPalette.muted)

                if let error = aside.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(JackPalette.red)
                        .textSelection(.enabled).lineLimit(6)
                } else if aside.answer.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(provider.title) responde sin interrumpir su trabajo…")
                            .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    }
                } else {
                    ScrollView {
                        MarkdownText(text: aside.answer, fontSize: 12.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(JackPalette.accent.opacity(0.35), lineWidth: 1))
            .frame(maxWidth: MainWindowView.columnWidth).frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.top, 4)
        }
    }
}
