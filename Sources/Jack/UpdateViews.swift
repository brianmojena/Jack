import AppKit
import JackCore
import SwiftUI

/// New releases and the result of a manual check, in the bottom status bar.
struct UpdateStatusItem: View {
    @ObservedObject var checker: UpdateChecker
    let activeAgents: Int
    @State private var showing = false

    var body: some View {
        if let release = checker.available {
            Button { showing.toggle() } label: {
                Label("Jack \(release.version) disponible", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(JackPalette.green)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hay una versión nueva de Jack")
            .popover(isPresented: $showing, arrowEdge: .top) {
                UpdateAvailableView(checker: checker, release: release, activeAgents: activeAgents, close: { showing = false })
            }
        } else {
            switch checker.status {
            case .checking:
                Label("Buscando actualizaciones…", systemImage: "arrow.triangle.2.circlepath")
            case .upToDate:
                Label("Jack está al día", systemImage: "checkmark.circle")
                    .help("No hay una versión más reciente de Jack")
            case .failed(let message):
                Button { showing.toggle() } label: {
                    Label("No se pudo buscar actualizaciones", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(JackPalette.amber)
                }
                .buttonStyle(.plain)
                .help(message)
                .popover(isPresented: $showing, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.system(size: 12)).textSelection(.enabled)
                        Button("Reintentar") {
                            showing = false
                            Task { await checker.check(manual: true) }
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                    .frame(width: 300)
                }
            default:
                EmptyView()
            }
        }
    }
}

private struct UpdateAvailableView: View {
    @ObservedObject var checker: UpdateChecker
    let release: AppRelease
    let activeAgents: Int
    let close: () -> Void
    @State private var errorMessage: String?

    private var busy: Bool { checker.status == .downloading || checker.status == .installing }
    private var installInPlace: Bool { checker.canInstallInPlace }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jack \(release.version) disponible").font(.system(size: 13, weight: .semibold))
            Text("Tienes la \(checker.currentVersion).").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            if installInPlace, activeAgents > 0 {
                Label(activeAgents == 1 ? "Hay 1 agente trabajando: se detendrá al reiniciar Jack." : "Hay \(activeAgents) agentes trabajando: se detendrán al reiniciar Jack.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.amber)
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(JackPalette.red)
            }
            HStack {
                Button("Omitir esta versión") { checker.skipAvailable(); close() }
                Spacer()
                Button("Ver en GitHub") { NSWorkspace.shared.open(release.pageURL) }
                Button { Task { await apply() } } label: {
                    switch checker.status {
                    case .downloading: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Descargando…") }
                    case .installing: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reiniciando…") }
                    default: Text(installInPlace ? (activeAgents > 0 ? "Instalar igualmente" : "Instalar y reiniciar") : "Descargar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(release.downloadURL == nil || busy)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func apply() async {
        errorMessage = nil
        do {
            if installInPlace {
                try await checker.install()
                // The helper waits for Jack to quit, replaces it and opens the new version.
                NSApp.terminate(nil)
            } else {
                let file = try await checker.download()
                NSWorkspace.shared.activateFileViewerSelecting([file])
                close()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The automatic check switch and a manual check, in Settings.
struct UpdateSettings: View {
    @ObservedObject var checker: UpdateChecker
    @AppStorage(UpdateChecker.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("Buscar actualizaciones automáticamente", isOn: $enabled)
            LabeledContent("Versión \(checker.currentVersion)") {
                HStack(spacing: 8) {
                    switch checker.status {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text("Estás al día").foregroundStyle(JackPalette.muted)
                    case .failed(let message): Text(message).foregroundStyle(JackPalette.red).lineLimit(2).help(message)
                    default: EmptyView()
                    }
                    Button("Buscar ahora") { Task { await checker.check(manual: true) } }
                        .disabled(checker.status == .checking || checker.status == .downloading || checker.status == .installing)
                }
            }
        } header: {
            Text("Actualizaciones")
        } footer: {
            Text("Jack consulta las versiones publicadas en GitHub al abrirse y cada pocas horas. Si hay una nueva, lo avisa en la barra de estado y la instalas con un clic: Jack se cierra, se sustituye y se vuelve a abrir. No instala nada sin que lo pidas.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
        }
    }
}
