import Darwin
import JackCore
import SwiftUI

/// Bottom bar: each provider's quota at a glance, agents running, terminals and Jack's memory.
struct StatusBar: View, Equatable {
    let usage: [ChatProvider: ProviderUsage]
    let refreshing: Bool
    let activeCount: Int
    let maxConcurrent: Int
    @ObservedObject var sessions: WorkspaceSessions
    let refresh: () -> Void
    let setConcurrency: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usage == rhs.usage && lhs.refreshing == rhs.refreshing && lhs.activeCount == rhs.activeCount
            && lhs.maxConcurrent == rhs.maxConcurrent
    }

    @State private var showingUsage = false

    var body: some View {
        HStack(spacing: 14) {
            Button { showingUsage.toggle() } label: {
                HStack(spacing: 14) {
                    let providers = ChatProvider.allCases.filter { !(usage[$0]?.windows.isEmpty ?? true) }
                    if providers.isEmpty {
                        Label("Uso y límites", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    ForEach(providers) { provider in
                        ProviderQuota(provider: provider, windows: Array(usage[provider]?.windows.prefix(2) ?? []))
                    }
                    // A provider whose quota could not be read says why, instead of vanishing from the bar.
                    ForEach(ChatProvider.allCases.filter { $0 != .opencode && usage[$0]?.windows.isEmpty == true && usage[$0]?.note.isEmpty == false }) { provider in
                        Label(provider.title, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(JackPalette.amber)
                            .help(usage[provider]?.note ?? "")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Uso y límites de cada proveedor")
            .popover(isPresented: $showingUsage, arrowEdge: .top) {
                ProviderUsageView(usage: usage, refreshing: refreshing, refresh: refresh)
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(refreshing ? 180 : 0))
            }
            .buttonStyle(.plain).disabled(refreshing)
            .help("Actualizar cuotas")

            Spacer(minLength: 8)

            MemoryLabel()
            let terminalCount = sessions.terminalCount
            if terminalCount > 0 {
                Label("\(terminalCount)", systemImage: "apple.terminal")
                    .help(terminalCount == 1 ? "1 terminal abierto" : "\(terminalCount) terminales abiertos")
            }
            Menu {
                Section("Agentes en paralelo") {
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { count in
                        Button { setConcurrency(count) } label: {
                            if count == maxConcurrent { Label("\(count)", systemImage: "checkmark") } else { Text("\(count)") }
                        }
                    }
                    Button { setConcurrency(0) } label: {
                        if maxConcurrent == 0 { Label("Sin límite", systemImage: "checkmark") } else { Text("Sin límite") }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(activeCount > 0 ? JackPalette.green : JackPalette.faint).frame(width: 6, height: 6)
                    Text(maxConcurrent == 0 ? "\(activeCount) activos" : "\(activeCount)/\(maxConcurrent) activos")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(JackPalette.muted)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Agentes trabajando ahora y máximo en paralelo")
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(JackPalette.muted)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(JackPalette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
}

/// "✳ ▰▰▱ 58% 5h · 41% 7d": used share of the first two windows of a provider.
private struct ProviderQuota: View {
    let provider: ChatProvider
    let windows: [UsageWindow]

    var body: some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 11)
            if let first = windows.first?.usedPercent {
                Capsule().fill(JackPalette.panelStrong).frame(width: 34, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint(first)).frame(width: 34 * CGFloat(min(100, max(0, first))) / 100, height: 4)
                    }
            }
            Text(windows.map { window in
                "\(window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "–") \(shortTitle(window.title))"
            }.joined(separator: " · "))
        }
    }

    private func shortTitle(_ title: String) -> String {
        (title.components(separatedBy: " · ").last ?? title).replacingOccurrences(of: " ", with: "")
    }

    private func tint(_ used: Double) -> Color {
        used >= 90 ? JackPalette.red : used >= 70 ? JackPalette.amber : JackPalette.secondaryText
    }
}

/// Jack's own memory footprint, read every 20 seconds; only this label redraws.
private struct MemoryLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            if let bytes = Self.footprint() {
                Label(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory), systemImage: "memorychip")
                    .help("Memoria que usa Jack")
            }
        }
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
