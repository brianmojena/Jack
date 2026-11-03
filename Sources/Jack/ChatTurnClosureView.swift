import JackCore
import SwiftUI

struct ChatTurnClosureView: View {
    let closure: ChatTurnClosure
    let onOpenGit: (String?) -> Void
    let onReview: () -> Void
    @State private var expandedDiffs = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                Spacer()
                if closure.reviewedAt == nil {
                    Button("Marcar revisado", action: onReview).buttonStyle(.borderless)
                } else {
                    Text("Revisado").font(.caption).foregroundStyle(.secondary)
                }
                if closure.gitComparison.status == .compared {
                    Button("Abrir Git") { onOpenGit(nil) }.buttonStyle(.borderless)
                }
            }
            if closure.gitComparison.status == .unavailable {
                Text("Jack no pudo comparar snapshots Git para este turno.")
                    .foregroundStyle(.secondary)
            } else if closure.observedFileChanges.isEmpty {
                Text(closure.gitComparison.headBefore != closure.gitComparison.headAfter
                     ? "HEAD cambió entre los snapshots, pero no se detectaron diferencias de archivos."
                     : "No se observaron diferencias de estado Git entre los snapshots de inicio y fin.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Archivos observados entre snapshots Git")
                        .fontWeight(.medium)
                    Text("La comparación no permite atribuir estos cambios al agente; pudo haber ediciones concurrentes.")
                        .foregroundStyle(.secondary)
                    ForEach(closure.observedFileChanges) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(change.path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                if change.diff?.isEmpty == false {
                                    Button("Ver diff Git") {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            if expandedDiffs.contains(change.path) { expandedDiffs.remove(change.path) }
                                            else { expandedDiffs.insert(change.path) }
                                        }
                                    }
                                        .buttonStyle(.borderless)
                                }
                                Button("Abrir Git") { onOpenGit(change.path) }.buttonStyle(.borderless)
                            }
                            if expandedDiffs.contains(change.path), let diff = change.diff {
                                ScrollView(.horizontal) { Text(diff).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                                    .padding(7).background(JackPalette.chrome.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }

            if closure.checks.isEmpty {
                Text("Jack no capturó un evento declarado como comprobación; los comandos observados se muestran aparte.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comprobaciones capturadas por Jack").fontWeight(.medium)
                    ForEach(closure.checks) { check in
                        Label(check.command.map { "\(check.title): \($0)" } ?? check.title,
                              systemImage: check.status == .passed ? "checkmark.circle" : check.status == .failed ? "xmark.circle" : "questionmark.circle")
                        Text(check.exitStatus.map { "Código de salida observado: \($0)" } ?? "Código de salida no observado")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 21)
                    }
                }
            }

            let toolEvents = closure.capturedEvents.filter { $0.kind == .tool }
            if !toolEvents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ejecuciones observadas por Jack").fontWeight(.medium)
                    Text("El código de salida procede de metadatos estructurados del proveedor. Un código cero no basta para afirmar que se ejecutó una prueba.")
                        .foregroundStyle(.secondary)
                    ForEach(toolEvents) { event in
                        if let command = event.command, !command.isEmpty {
                            Text("\(command) · " + (event.exitStatus.map { "código de salida observado: \($0)" } ?? "ejecutado/resultado no verificado"))
                        } else {
                            Text(event.status.map { "\(event.title) · estado informado: \($0)" } ?? event.title)
                        }
                    }
                }
            }

            if !closure.agentStatements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Declaraciones del agente · no verificadas por Jack").fontWeight(.medium)
                    ForEach(closure.agentStatements) { statement in
                        Text(statement.kind == .pending ? "Pendiente declarado: \(statement.text)" : statement.text)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: 11.5))
        .padding(12)
        .frame(maxWidth: MainWindowView.columnWidth)
        .background(JackPalette.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(JackPalette.hairline) }
        .padding(.vertical, 10)
    }

    private var title: String {
        switch closure.ending {
        case .completed: "Turno terminado"
        case .failed: "Turno terminado con fallo"
        case .interrupted: "Turno interrumpido"
        }
    }

    private var symbol: String {
        switch closure.ending {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .interrupted: "pause.circle.fill"
        }
    }
}
