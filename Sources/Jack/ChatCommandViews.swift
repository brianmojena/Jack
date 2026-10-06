import JackCore
import SwiftUI

/// How full the model's context window is, shown in the conversation toolbar.
struct ContextGauge: View {
    let usage: ChatContextUsage
    let costUSD: Double?

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(JackPalette.panelStrong, lineWidth: 2.5)
                Circle().trim(from: 0, to: usage.fraction ?? 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(usage.window.map { "\(Self.short(usage.used)) / \(Self.short($0))" } ?? Self.short(usage.used))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(JackPalette.muted)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ventana de contexto")
        .accessibilityValue(usage.fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? Self.short(usage.used))
    }

    private var tint: Color {
        switch usage.fraction ?? 0 {
        case 0.9...: JackPalette.red
        case 0.7...: JackPalette.amber
        default: JackPalette.accent
        }
    }

    private var help: String {
        var lines = [usage.window.map { "Ventana de contexto: \(usage.used.formatted()) de \($0.formatted()) tokens" } ?? "Contexto usado: \(usage.used.formatted()) tokens (ventana desconocida)"]
        if let fraction = usage.fraction { lines[0] += " (\(Int((fraction * 100).rounded())) %)" }
        if let costUSD, costUSD > 0 { lines.append("Coste estimado: \(costUSD.formatted(.currency(code: "USD")))") }
        return lines.joined(separator: "\n")
    }

    static func short(_ tokens: Int) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if tokens >= 1_000_000 { return (Double(tokens) / 1_000_000).formatted(format) + "M" }
        if tokens >= 1_000 { return (Double(tokens) / 1_000).formatted(format) + "K" }
        return String(tokens)
    }
}

/// Matching slash commands while the user types `/name`.
struct CommandSuggestions: View {
    let commands: [ChatCommand]
    let loading: Bool
    let selection: Int
    let onPick: (ChatCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text(loading ? "Cargando comandos…" : "No hay comandos que coincidan")
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    .padding(.horizontal, 12).padding(.vertical, 9)
            }
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { onPick(command) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/" + command.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(index == selection ? Color.white : Color.primary)
                        if !command.argumentHint.isEmpty {
                            Text(command.argumentHint)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(index == selection ? Color.white.opacity(0.75) : JackPalette.faint)
                                .lineLimit(1)
                        }
                        Text(command.description)
                            .font(.system(size: 11))
                            .foregroundStyle(index == selection ? Color.white.opacity(0.85) : JackPalette.muted)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(index == selection ? JackPalette.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(command.description)
            }
        }
        .padding(4)
        .background(JackPalette.composer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 1))
    }

    /// Commands whose name starts with the query first, then those that contain it.
    static func matches(_ commands: [ChatCommand], query: String, limit: Int = 8) -> [ChatCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return Array(commands.prefix(limit)) }
        let prefixed = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let contained = commands.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return Array((prefixed + contained).prefix(limit))
    }
}
