import JackCore
import SwiftUI

/// A new chat always lets Jack choose its project from the conversation.
struct NewAgentRequest {
    var provider: ChatProvider
    var model: String
    var effort: String
    var firstMessage: String
    /// Runs the agent over SSH instead of locally. Only Claude Code supports it.
    var remote: ChatRemoteEndpoint? = nil
}

/// Before the first message the composer logo chooses the agent. Once sent,
/// the chat uses ContextLogoButton in the same position.
struct NewAgentProviderButton: View {
    @Binding var provider: ChatProvider
    let localModels: [StellarModel]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            providerGlyph(provider, size: 18)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cambiar agente · \(provider.title)")
        .accessibilityLabel("Cambiar agente")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agente").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JackPalette.muted)
                    .padding(.horizontal, 8).padding(.bottom, 6)
                ForEach(ChatProvider.allCases) { option in
                    Button {
                        provider = option
                        showing = false
                    } label: {
                        HStack(spacing: 10) {
                            providerGlyph(option, size: 22)
                            Text(option.title).font(.system(size: 13, weight: .medium))
                            if option.isBeta { BetaBadge() }
                            Spacer(minLength: 12)
                            if option == provider {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(JackPalette.accent)
                            }
                        }
                        .padding(8)
                        .background(option == provider ? JackPalette.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option == .stellar ? "Stellar admite modelos locales y, en Normal, modelos vinculados de Ollama Cloud" : option.title)
                }
            }
            .padding(10).frame(width: 240)
        }
    }
}
