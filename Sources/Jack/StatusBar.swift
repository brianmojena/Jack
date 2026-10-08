import Darwin
import JackCore
import SwiftUI

/// Bottom bar: each provider's quota at a glance, the projects' servers, downloads and other progress, agents running,
/// terminals and Jack's memory.
struct StatusBar: View, Equatable {
    let usage: [ChatProvider: ProviderUsage]
    let refreshing: Bool
    let activeCount: Int
    let maxConcurrent: Int
    @ObservedObject var sessions: WorkspaceSessions
    let progress: ProgressMonitor
    let servers: ServerMonitor
    let updates: UpdateChecker
    let refresh: () -> Void
    let setConcurrency: (Int) -> Void
    let conversationTitle: (UUID) -> String?
    let openConversation: (UUID) -> Void
    let enterBatterySaver: () -> Void

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
                    ForEach(ChatProvider.allCases.filter { $0 != .opencode && $0 != .stellar && usage[$0]?.windows.isEmpty == true && usage[$0]?.note.isEmpty == false }) { provider in
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
                ProviderUsageView(usage: usage, refreshing: refreshing, refresh: refresh, showsUsed: true)
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(refreshing ? 180 : 0))
            }
            .buttonStyle(.plain).disabled(refreshing)
            .help("Actualizar cuotas")

            Spacer(minLength: 8)

            UpdateStatusItem(checker: updates, activeAgents: activeCount)
            ServerStatusItem(monitor: servers, title: conversationTitle)
            ProgressStatusItem(monitor: progress, title: conversationTitle, open: openConversation)
            MemoryLabel()
            let terminalCount = sessions.terminalCount
            if terminalCount > 0 {
                Label("\(terminalCount)", systemImage: "apple.terminal")
                    .help(terminalCount == 1 ? "1 terminal abierto" : "\(terminalCount) terminales abiertos")
            }
            Button(action: enterBatterySaver) {
                Image(systemName: "leaf").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Modo ahorro de batería: cierra la ventana y deja Jack en la barra de menús (⌃⌘B)")
            .accessibilityLabel("Modo ahorro de batería")
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
            LightModeToggle()
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(JackPalette.muted)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .jackSurface(.chrome)
        .overlay(alignment: .top) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
}

/// Compact provider indicator: mark, used quota bar and reset countdown for the five-hour window.
private struct ProviderQuota: View {
    let provider: ChatProvider
    let windows: [UsageWindow]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                ProviderMark(provider: provider, size: 11)
                if let quota = fiveHourWindow?.usedPercent ?? windows.first?.usedPercent {
                    Capsule().fill(JackPalette.panelStrong).frame(width: 34, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint(quota)).frame(width: 34 * CGFloat(min(100, max(0, quota))) / 100, height: 4)
                        }
                }
                if let reset = fiveHourWindow?.resetsAt, reset > context.date {
                    Text(timeUntilReset(reset, now: context.date))
                        .foregroundStyle(JackPalette.muted)
                        .help("El límite de 5 h se reinicia \(reset.formatted(.relative(presentation: .named)))")
                }
            }
        }
    }

    private var fiveHourWindow: UsageWindow? {
        windows.first { $0.id == "five_hour" || $0.title.localizedCaseInsensitiveContains("5 h") }
    }

    private func timeUntilReset(_ reset: Date, now: Date) -> String {
        let minutes = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    private func tint(_ used: Double) -> Color {
        used >= 90 ? JackPalette.red : used >= 70 ? JackPalette.amber : JackPalette.secondaryText
    }
}

/// Jack's own memory footprint and process CPU usage; neither value includes other processes.
private struct MemoryLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 20)) { _ in
                if let bytes = Self.footprint() {
                    Label(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory), systemImage: "memorychip")
                        .help("Memoria que usa Jack")
                }
            }
            ProcessCPUUsageLabel()
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

private struct ProcessCPUUsageLabel: View {
    @State private var previousSample: CPUSample?
    @State private var percent: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            Group {
                if let percent {
                    Label("\(Int(percent.rounded())) %", systemImage: "cpu")
                } else {
                    Label("—", systemImage: "cpu")
                }
            }
            .help("Uso del procesador por Jack; puede superar el 100 % si usa varios núcleos")
            .onChange(of: context.date, initial: true) { _, date in
                guard let cpuSeconds = Self.processCPUSeconds() else { return }
                if let previousSample {
                    let elapsed = date.timeIntervalSince(previousSample.date)
                    if elapsed > 0 {
                        percent = max(0, (cpuSeconds - previousSample.cpuSeconds) / elapsed * 100)
                    }
                }
                previousSample = CPUSample(date: date, cpuSeconds: cpuSeconds)
            }
        }
    }

    private static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

private struct CPUSample {
    let date: Date
    let cpuSeconds: Double
}
