import JackCore
import SwiftUI

/// The provider logo in the composer; a ring around it fills with the context
/// window and a click opens the detailed context panel.
struct ContextLogoButton: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let busy: Bool
    @State private var showing = false

    var body: some View {
        let usage = conversation.contextUsage
        Button { showing.toggle() } label: {
            ZStack {
                providerGlyph(conversation.provider, size: 18)
                if let fraction = usage?.fraction {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .trim(from: 0, to: fraction)
                        .stroke(ContextPanel.tint(fraction), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(usage?.fraction.map { "Contexto: \(Int(($0 * 100).rounded())) % usado" } ?? "Ver ventana de contexto")
        .accessibilityLabel("Ventana de contexto")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ContextPanel(store: store, conversation: conversation, busy: busy) { showing = false }
        }
    }
}

struct ContextPanel: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let busy: Bool
    let dismiss: () -> Void

    private var usage: ChatContextUsage? { conversation.contextUsage }
    private var tokens: ChatTokenUsage? { store.tokenUsage[conversation.id] ?? conversation.tokenUsage }
    private var canCompact: Bool {
        conversation.provider != .opencode || (store.commands(for: conversation) ?? []).contains { $0.name == "compact" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                providerGlyph(conversation.provider, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ventana de contexto").font(.headline)
                    Text("\(conversation.provider.title) · \(modelTitle)")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted).lineLimit(1)
                }
            }
            if let usage { summary(usage) } else {
                Text("Aún no hay datos. Aparecerán cuando el agente responda a su primer mensaje.")
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tokens, tokens.input + tokens.output + tokens.cached + tokens.reasoning > 0 {
                Divider()
                breakdown(tokens)
            }
            if canCompact {
                Divider()
                HStack(alignment: .center, spacing: 10) {
                    Text("Compactar resume la conversación para liberar espacio.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Compactar") {
                        if store.selectedID != conversation.id { store.select(conversation.id) }
                        store.send("/compact")
                        dismiss()
                    }
                    .disabled(busy || usage == nil)
                    .help(busy ? "Espera a que el agente termine" : "Enviar /compact al agente")
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func summary(_ usage: ChatContextUsage) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(JackPalette.panelStrong, lineWidth: 7)
                Circle().trim(from: 0, to: usage.fraction ?? 0)
                    .stroke(Self.tint(usage.fraction ?? 0), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(usage.fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text(usage.fraction == nil ? "sin límite" : "% usado")
                        .font(.system(size: 9)).foregroundStyle(JackPalette.muted)
                }
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 6) {
                stat("Usado", usage.used.formatted() + " tokens")
                if let window = usage.window {
                    stat("Libre", max(0, window - usage.used).formatted() + " tokens")
                    stat("Ventana", window.formatted() + " tokens")
                } else {
                    Text("El agente no ha informado del tamaño de la ventana.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = usage.fraction, fraction >= 0.7 {
                    Label(fraction >= 0.9 ? "Casi lleno: compacta pronto" : "Empieza a llenarse", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Self.tint(fraction))
                }
            }
        }
    }

    private func breakdown(_ tokens: ChatTokenUsage) -> some View {
        let rows: [(String, Int, Color)] = [
            ("Entrada", tokens.input, JackPalette.accent),
            ("En caché", tokens.cached, JackPalette.green),
            ("Salida", tokens.output, JackPalette.amber),
            ("Razonamiento", tokens.reasoning, JackPalette.red),
        ].filter { $0.1 > 0 }
        let total = max(1, rows.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tokens").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(conversation.provider == .codex ? "Toda la sesión" : "Último turno")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
            }
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(rows, id: \.0) { row in
                        Rectangle().fill(row.2)
                            .frame(width: max(2, (proxy.size.width - 1.5 * CGFloat(rows.count - 1)) * CGFloat(row.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.2).frame(width: 7, height: 7)
                    Text(row.0).font(.system(size: 11))
                    Spacer()
                    Text(row.1.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(JackPalette.muted)
                }
            }
            if let cost = tokens.costUSD, cost > 0 {
                HStack {
                    Text("Coste estimado").font(.system(size: 11))
                    Spacer()
                    Text(cost.formatted(.currency(code: "USD"))).font(.system(size: 11).monospacedDigit()).foregroundStyle(JackPalette.muted)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(JackPalette.muted).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    private var modelTitle: String {
        let model = store.modelChoices(for: conversation.provider).first { $0.id == conversation.model }?.title ?? conversation.model
        return model.isEmpty ? "Modelo predeterminado" : model
    }

    static func tint(_ fraction: Double) -> Color {
        switch fraction {
        case 0.9...: JackPalette.red
        case 0.7...: JackPalette.amber
        default: JackPalette.accent
        }
    }
}
