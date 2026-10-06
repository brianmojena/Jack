import AppKit
import JackCore
import SwiftUI

private extension ProgressTask {
    var tint: Color {
        switch status {
        case .running: JackPalette.accent
        case .paused: JackPalette.muted
        case .done: JackPalette.green
        case .failed, .interrupted: JackPalette.red
        case .cancelled: JackPalette.faint
        }
    }

    var symbol: String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .interrupted: "bolt.horizontal.circle"
        case .cancelled: "xmark.circle"
        case .paused: "pause.circle.fill"
        case .running:
            switch kind {
            case "download": "arrow.down.circle"
            case "model": "cpu"
            default: "gearshape.2"
            }
        }
    }

    var statusTitle: String {
        switch status {
        case .running: "En curso"
        case .paused: "En pausa"
        case .done: "Terminada"
        case .failed: "Falló"
        case .cancelled: "Cancelada"
        case .interrupted: "Interrumpida"
        }
    }

    var isStalled: Bool { status == .running && Date().timeIntervalSince(updatedAt) > ProgressMonitor.stallInterval }

    /// Rounded down, so a bar never says 100 % before it ends.
    var percentText: String? {
        progress.map { (($0 * 100).rounded(.down) / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    var elapsed: TimeInterval {
        (finishedAt ?? (isActive ? Date() : updatedAt)).timeIntervalSince(startedAt)
    }
}

/// One task: a native bar with what it is doing, its speed and time left, and its controls.
struct ProgressTaskRow: View {
    let task: ProgressTask
    let monitor: ProgressMonitor
    var conversationTitle: String? = nil
    var onOpenConversation: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: task.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(task.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if let conversationTitle {
                        if let onOpenConversation {
                            Button(action: onOpenConversation) { Text(conversationTitle).lineLimit(1) }
                                .buttonStyle(.link)
                                .font(.system(size: 10.5))
                                .help("Ir al chat")
                        } else {
                            Text(conversationTitle).font(.system(size: 10.5)).foregroundStyle(JackPalette.faint).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if task.status != .done, let percent = task.percentText {
                    Text(percent)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(JackPalette.muted)
                }
                controls
            }
            bar
            Text(caption)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(captionColor)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 24)
            if expanded {
                ProgressTaskDetails(task: task)
                    .padding(.leading, 24).padding(.top, 3)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.title), \(task.statusTitle)")
    }

    private var bar: some View {
        Group {
            if let progress = task.progress ?? (task.status == .done ? 1 : nil) {
                ProgressView(value: progress)
            } else if task.status == .running {
                ProgressView()
            } else {
                ProgressView(value: 0)
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .tint(task.tint)
        .padding(.leading, 24)
        .accessibilityValue(task.percentText ?? task.statusTitle)
    }

    private var caption: String {
        let amounts = ProgressFormat.summary(task)
        switch task.status {
        case .running:
            if task.isStalled { return "Sin novedades desde hace \(ProgressFormat.duration(Date().timeIntervalSince(task.updatedAt)))" }
            let text = [task.detail, amounts.isEmpty ? nil : amounts].compactMap { $0 }.joined(separator: " · ")
            return text.isEmpty ? "Empezando…" : text
        case .paused:
            return ["En pausa", amounts].filter { !$0.isEmpty }.joined(separator: " · ")
        case .done:
            return ["Terminada en \(ProgressFormat.duration(task.elapsed))", amounts].filter { !$0.isEmpty }.joined(separator: " · ")
        case .failed:
            return task.message ?? "Falló"
        case .cancelled:
            return "Cancelada"
        case .interrupted:
            return "Interrumpida: el proceso terminó sin avisar"
        }
    }

    private var captionColor: Color {
        switch task.status {
        case .failed, .interrupted: JackPalette.red
        default: task.isStalled ? JackPalette.amber : JackPalette.muted
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if monitor.canPause(task) {
                let paused = task.status == .paused
                iconButton(paused ? "play.fill" : "pause.fill", help: paused ? "Reanudar" : "Pausar") {
                    paused ? monitor.resume(task) : monitor.pause(task)
                }
            }
            if task.isActive {
                // Without a process, Jack can only stop showing it as running.
                iconButton("xmark.circle.fill", help: task.pid == nil ? "Dejar de seguir" : "Cancelar") { monitor.cancel(task) }
            }
            if let file = task.file, FileManager.default.fileExists(atPath: file) {
                iconButton("magnifyingglass", help: "Mostrar en Finder") { reveal(file) }
            }
            if task.isFinished, let onDismiss {
                iconButton("xmark", help: "Quitar") { onDismiss() }
            }
            iconButton(expanded ? "chevron.up" : "chevron.down", help: expanded ? "Ocultar detalles" : "Ver detalles") {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(JackPalette.muted)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var menu: some View {
        if let onOpenConversation { Button("Ir al chat", action: onOpenConversation) }
        if let file = task.file {
            Button("Mostrar en Finder") { reveal(file) }
            Button("Copiar ruta") { copy(file) }
        }
        if let command = task.command { Button("Copiar comando") { copy(command) } }
        if task.isActive {
            Divider()
            Button(task.pid == nil ? "Dejar de seguir" : "Cancelar", role: .destructive) { monitor.cancel(task) }
        }
        if task.isFinished {
            Divider()
            Button("Borrar de la lista") { monitor.remove(task) }
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Everything known about a task, refreshed every second while it runs.
private struct ProgressTaskDetails: View {
    let task: ProgressTask

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(rows(now: context.date).enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(JackPalette.faint).gridColumnAlignment(.trailing)
                        Text(row.1).foregroundStyle(JackPalette.secondaryText)
                            .textSelection(.enabled)
                            .lineLimit(3).truncationMode(.middle)
                    }
                }
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }

    private func rows(now: Date) -> [(String, String)] {
        var rows: [(String, String)] = [("Estado", task.statusTitle)]
        if let detail = task.detail { rows.append(("Ahora", detail)) }
        if let percent = task.percentText { rows.append(("Progreso", percent)) }
        if let completed = task.completed {
            let done = ProgressFormat.amount(completed, unit: task.unit)
            rows.append(("Hecho", task.total.map { "\(done) de \(ProgressFormat.amount($0, unit: task.unit))" } ?? done))
        } else if let total = task.total {
            rows.append(("Total", ProgressFormat.amount(total, unit: task.unit)))
        }
        let elapsed = (task.finishedAt ?? (task.isActive ? now : task.updatedAt)).timeIntervalSince(task.startedAt)
        if task.status == .running, let speed = task.speed, speed > 0 { rows.append(("Velocidad", ProgressFormat.speed(speed, unit: task.unit))) }
        if let completed = task.completed, completed > 0, elapsed >= 1 {
            rows.append(("Velocidad media", ProgressFormat.speed(completed / elapsed, unit: task.unit)))
        }
        if task.status == .running, let eta = task.eta, eta.isFinite { rows.append(("Tiempo restante", ProgressFormat.duration(eta))) }
        rows.append(("Transcurrido", ProgressFormat.duration(elapsed)))
        rows.append(("Inicio", task.startedAt.formatted(date: .omitted, time: .standard)))
        rows += task.fields.map { ($0.name, $0.value) }
        if let file = task.file { rows.append(("Archivo", (file as NSString).abbreviatingWithTildeInPath)) }
        if let command = task.command { rows.append(("Comando", command)) }
        if let message = task.message, task.status != .failed { rows.append(("Mensaje", message)) }
        return rows
    }
}

/// This chat's progress bars, above the composer: what is running and what finished in the last minutes.
struct ChatProgressPanel: View {
    @ObservedObject var monitor: ProgressMonitor
    let conversationID: UUID
    let width: CGFloat
    private static let limit = 4

    var body: some View {
        let tasks = monitor.chatTasks(for: conversationID)
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tasks.prefix(Self.limit).enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider().padding(.leading, 34) }
                    ProgressTaskRow(task: task, monitor: monitor, onDismiss: { monitor.hideInChat(task) })
                }
                if tasks.count > Self.limit {
                    Divider().padding(.leading, 34)
                    Text("y \(tasks.count - Self.limit) más en Descargas, en la barra inferior")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                        .padding(.horizontal, 34).padding(.vertical, 6)
                }
            }
            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
            .frame(maxWidth: width).frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 4)
        }
    }
}

/// Status bar entry for the progress of every chat; opens the Downloads panel.
struct ProgressStatusItem: View {
    @ObservedObject var monitor: ProgressMonitor
    let title: (UUID) -> String?
    let open: (UUID) -> Void
    @State private var showing = false

    var body: some View {
        let active = monitor.active
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: active.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                    .foregroundStyle(active.isEmpty ? JackPalette.muted : JackPalette.accent)
                if !active.isEmpty {
                    if let overall = monitor.overallProgress {
                        ProgressView(value: overall)
                            .progressViewStyle(.linear).controlSize(.mini)
                            .tint(JackPalette.accent)
                            .frame(width: 46)
                    }
                    Text(active.count == 1 ? (active[0].percentText ?? "1") : "\(active.count)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active.isEmpty ? "Descargas y tareas" : active.count == 1 ? "1 tarea en curso" : "\(active.count) tareas en curso")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ProgressListView(monitor: monitor, title: title) { id in
                showing = false
                open(id)
            }
        }
    }
}

/// Downloads and other long work of every chat.
struct ProgressListView: View {
    @ObservedObject var monitor: ProgressMonitor
    let title: (UUID) -> String?
    let open: (UUID) -> Void

    var body: some View {
        let active = monitor.tasks.filter(\.isActive)
        let finished = monitor.tasks.filter(\.isFinished)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Descargas y tareas").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !finished.isEmpty {
                    Button("Borrar terminadas") { monitor.removeFinished() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if monitor.tasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 24)).foregroundStyle(JackPalette.faint)
                    Text("Nada en curso").font(.system(size: 13, weight: .medium))
                    Text("Cuando un agente descargue algo o ejecute una tarea larga, verás aquí su progreso.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else if monitor.tasks.count <= 5 {
                list(active: active, finished: finished)
            } else {
                ScrollView { list(active: active, finished: finished) }.frame(height: 460)
            }
        }
        .frame(width: 420)
    }

    private func list(active: [ProgressTask], finished: [ProgressTask]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            section("En curso", active)
            section("Terminadas", finished)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private func section(_ name: String, _ tasks: [ProgressTask]) -> some View {
        if !tasks.isEmpty {
            Text(name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(JackPalette.faint)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
            ForEach(tasks) { task in
                let chat = title(task.conversationID)
                ProgressTaskRow(task: task, monitor: monitor, conversationTitle: chat ?? "Chat eliminado",
                                onOpenConversation: chat == nil ? nil : { open(task.conversationID) },
                                onDismiss: { monitor.remove(task) })
                    .padding(.horizontal, 4)
            }
        }
    }
}
