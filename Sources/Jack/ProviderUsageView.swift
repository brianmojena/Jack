import JackCore
import SwiftUI

struct ProviderUsageView: View {
    let usage: [ChatProvider: ProviderUsage]
    let refreshing: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Uso y límites").font(.system(size: 14, weight: .semibold))
                    Text("Cuota restante de cada proveedor").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                }
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(refreshing)
                    .help("Actualizar cuotas sin enviar mensajes a los modelos")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ChatProvider.allCases) { provider in
                        ProviderUsageCard(provider: provider, usage: usage[provider], refreshing: refreshing)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 360, height: 460)
        .background(JackPalette.canvas)
    }
}

private struct ProviderUsageCard: View {
    let provider: ChatProvider
    let usage: ProviderUsage?
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                providerGlyph(provider, size: 22)
                Text(provider.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let observed = usage?.windows.map(\.observedAt).max() {
                    Text("Leído \(observed.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10)).foregroundStyle(JackPalette.faint)
                        .help(observed.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    UsageWindowRow(window: window)
                }
            } else {
                Text(refreshing ? "Consultando…" : "Sin datos todavía")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            if let note = usage?.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow

    private var color: Color {
        guard let remaining = window.remainingPercent else { return JackPalette.faint }
        if remaining <= 10 { return JackPalette.red }
        if remaining <= 30 { return JackPalette.amber }
        return JackPalette.green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 11, weight: .medium))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded())) %")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(remaining <= 30 ? color : JackPalette.secondaryText)
                    Text("restante").font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                } else {
                    Text(window.resetsAt.map { $0 <= Date() } == true ? "Lectura vencida" : "Sin porcentaje")
                        .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(JackPalette.panelStrong)
                    Capsule().fill(color)
                        .frame(width: proxy.size.width * CGFloat((window.remainingPercent ?? 0) / 100))
                }
            }
            .frame(height: 5)
            if let reset = window.resetsAt, reset > Date() {
                Text("Se reinicia \(reset.formatted(.relative(presentation: .named))) · \(reset.formatted(date: Calendar.current.isDateInToday(reset) ? .omitted : .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
            }
        }
    }
}
