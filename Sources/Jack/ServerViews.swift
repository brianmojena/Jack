import AppKit
import JackCore
import SwiftUI

/// Status bar entry for the servers running in the user's projects; opens the list.
struct ServerStatusItem: View {
    @ObservedObject var monitor: ServerMonitor
    let title: (UUID) -> String?
    @State private var showing = false

    var body: some View {
        let count = monitor.servers.count
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .foregroundStyle(count == 0 ? JackPalette.muted : JackPalette.green)
                if count > 0 { Text("\(count)") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count == 0 ? "Servidores de tus proyectos" : count == 1 ? "1 servidor en marcha" : "\(count) servidores en marcha")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ServerListView(monitor: monitor, title: title)
        }
    }
}

/// The servers of every project, whichever session started them.
struct ServerListView: View {
    @ObservedObject var monitor: ServerMonitor
    let title: (UUID) -> String?

    var body: some View {
        let groups = Dictionary(grouping: monitor.servers) { $0.project ?? $0.directory }
        let projects = groups.keys.sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Servidores").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Actualizar")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if monitor.servers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: 24)).foregroundStyle(JackPalette.faint)
                    Text("Nada en marcha").font(.system(size: 13, weight: .medium))
                    Text("Aquí aparecen los servidores que se ejecutan en tus proyectos, como npm run dev, aunque los haya iniciado otra sesión.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else {
                let list = VStack(alignment: .leading, spacing: 0) {
                    ForEach(projects, id: \.self) { project in
                        Text((project as NSString).lastPathComponent.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(JackPalette.faint)
                            .help(project)
                            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                        ForEach(groups[project] ?? []) { server in
                            ServerRow(server: server, startedBy: startedBy(server), onStop: { monitor.stop(server) })
                        }
                    }
                }
                .padding(.bottom, 6)
                if monitor.servers.count <= 5 { list } else { ScrollView { list }.frame(height: 420) }
            }
        }
        .frame(width: 440)
    }

    private func startedBy(_ server: ServerProcess) -> String {
        if let id = server.conversationID { return title(id).map { "Agente: \($0)" } ?? "Un agente de Jack" }
        if let agent = server.foreignAgent { return "\(agent) · otra sesión" }
        return "Otra sesión"
    }
}

private struct ServerRow: View {
    let server: ServerProcess
    let startedBy: String
    let onStop: () -> Void
    @State private var showingInfo = false
    @State private var confirmingStop = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(JackPalette.green).frame(width: 7, height: 7)
                .shadow(color: JackPalette.green.opacity(0.6), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ForEach(server.ports.prefix(3), id: \.self) { port in
                        Button(":\(port)") { open(port) }
                            .buttonStyle(.link)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .help("Abrir http://localhost:\(port)")
                    }
                    Text(server.command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(JackPalette.secondaryText)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text("\(startedBy) · \(ProgressFormat.duration(Date().timeIntervalSince(server.startedAt)))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(JackPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let first = server.ports.first {
                iconButton("safari", help: "Abrir en el navegador") { open(first) }
            }
            iconButton("info.circle", help: "Consumo y detalles") { showingInfo.toggle() }
                .popover(isPresented: $showingInfo, arrowEdge: .trailing) { ServerInfo(server: server, startedBy: startedBy) }
            iconButton("stop.circle", help: "Detener") { confirmingStop = true }
                .confirmationDialog("¿Detener \(server.command)?", isPresented: $confirmingStop) {
                    Button("Detener", role: .destructive, action: onStop)
                } message: {
                    Text("Se cerrará el proceso \(server.pid) y lo que lo lanzó. Si un agente lo está usando, dejará de responder.")
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(server.ports, id: \.self) { port in Button("Abrir localhost:\(port)") { open(port) } }
            Button("Mostrar carpeta en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.directory)]) }
            Button("Copiar comando") { copy(server.commandLine) }
            Divider()
            Button("Detener", role: .destructive) { confirmingStop = true }
        }
    }

    private func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(JackPalette.muted)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// What a server costs: CPU, memory and processes, refreshed with each scan.
private struct ServerInfo: View {
    let server: ServerProcess
    let startedBy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                gauge("CPU", value: server.cpuPercent.map { "\(Int($0.rounded())) %" } ?? "—",
                      fraction: server.cpuPercent.map { min(1, $0 / 100) })
                gauge("Memoria", value: ByteCountFormatter.string(fromByteCount: Int64(server.memory), countStyle: .memory),
                      fraction: min(1, Double(server.memory) / Double(ProcessInfo.processInfo.physicalMemory)))
                gauge("Procesos", value: "\(server.processCount)", fraction: nil)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Puertos", server.ports.map(String.init).joined(separator: ", "))
                row("PID", "\(server.pid)")
                row("En marcha", ProgressFormat.duration(Date().timeIntervalSince(server.startedAt)))
                row("CPU usada", ProgressFormat.duration(server.cpuTime))
                row("Iniciado por", startedBy)
                row("Carpeta", (server.directory as NSString).abbreviatingWithTildeInPath)
                row("Comando", server.commandLine)
            }
            .font(.system(size: 11).monospacedDigit())
        }
        .padding(14)
        .frame(width: 340)
    }

    private func gauge(_ title: String, value: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(JackPalette.faint)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini)
                    .tint(fraction > 0.75 ? JackPalette.amber : JackPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(JackPalette.faint).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(JackPalette.secondaryText).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }
}
