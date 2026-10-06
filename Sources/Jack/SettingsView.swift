import AppKit
import JackCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        TabView {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentExecutablesSettings()
                .tabItem { Label("Agentes", systemImage: "terminal") }
            ShortcutsSettings()
                .tabItem { Label("Atajos", systemImage: "keyboard") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: ChatStore
    @AppStorage("collapsedSpaces") private var collapsedSpaces = ""
    @AppStorage("delegationEnabled") private var delegationEnabled = true
    @AppStorage("transcriptMonospaced") private var transcriptMonospaced = true
    @AppStorage(SimulatorSession.lightModeKey) private var simulatorLightMode = true
    @AppStorage(SimulatorSession.idleMinutesKey) private var simulatorIdleMinutes = 10
    @AppStorage(SimulatorSession.shutdownOnQuitKey) private var simulatorShutdownOnQuit = true

    var body: some View {
        Form {
            Section {
                Picker("Agentes en paralelo", selection: Binding(get: { store.maxConcurrent }, set: store.setConcurrency)) {
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                    Divider()
                    Text("Sin límite").tag(0)
                    if ![0, 1, 2, 3, 4, 6, 8].contains(store.maxConcurrent) {
                        Text("\(store.maxConcurrent)").tag(store.maxConcurrent)
                    }
                }
            } footer: {
                Text("Los mensajes que superen el límite esperan en cola. En un MacBook Air, 2–4 agentes a la vez mantienen el equipo fresco y fluido.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            Section {
                Toggle("Los agentes pueden delegar en otros agentes", isOn: $delegationEnabled)
            } header: {
                Text("Delegación")
            } footer: {
                Text("Codex, Claude Code y OpenCode reciben herramientas para crear otros agentes, enviarles tareas y esperar sus resultados. Los sub-agentes no pueden delegar a su vez. Los sub-agentes aparecen bajo su agente en la barra lateral y te piden permisos a ti. Se aplica al próximo mensaje.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            Section {
                Toggle("Modo ligero", isOn: $simulatorLightMode)
                Picker("Apagar si no lo miras durante", selection: $simulatorIdleMinutes) {
                    Text("5 minutos").tag(5)
                    Text("10 minutos").tag(10)
                    Text("30 minutos").tag(30)
                    Divider()
                    Text("Nunca").tag(0)
                }
                Toggle("Apagarlo al salir de Jack", isOn: $simulatorShutdownOnQuit)
            } header: {
                Text("Simulador de iOS")
            } footer: {
                Text("El modo ligero desactiva en el simulador Siri, Apple Intelligence, Spotlight, sugerencias, Mail, News y Tiempo de uso: unos 350 MB y 40 procesos menos. Se aplica la próxima vez que Jack lo encienda. Jack solo apaga los simuladores que encendió él y nunca mientras Xcode compila o pasa tests.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            Section("Apariencia") {
                Toggle("Conversación con letra monoespaciada", isOn: $transcriptMonospaced)
            }
            Section("Barra lateral") {
                LabeledContent("Spaces plegados") {
                    HStack {
                        let count = collapsedSpaces.split(separator: "\n").count
                        Text(count == 0 ? "Ninguno" : "\(count)").foregroundStyle(JackPalette.muted)
                        Button("Desplegar todos") { collapsedSpaces = "" }.disabled(count == 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

private struct AgentExecutablesSettings: View {
    @AppStorage("providerExecutablePath.codex") private var codexPath = ""
    @AppStorage("providerExecutablePath.claude") private var claudePath = ""
    @AppStorage("providerExecutablePath.opencode") private var opencodePath = ""
    @AppStorage(ChatDriverFactory.claudeKeepAliveKey) private var claudeKeepAlive = 5
    @AppStorage(StellarServer.contextLengthKey) private var stellarContext = StellarServer.defaultContextLength
    @AppStorage(StellarServer.customServerURLKey) private var stellarServer = ""

    var body: some View {
        Form {
            Section {
                Picker("Contexto máximo", selection: $stellarContext) {
                    Text("8 K tokens").tag(8_192)
                    Text("16 K tokens").tag(16_384)
                    Text("32 K tokens").tag(32_768)
                    Text("64 K tokens").tag(65_536)
                }
                TextField("Otro servidor compatible con OpenAI", text: $stellarServer, prompt: Text("http://127.0.0.1:8000"))
                if !stellarServer.isEmpty, URL(string: stellarServer).map(StellarServer.isLocal) != true {
                    Text("Solo se admiten direcciones locales o de tu red privada.").font(.system(size: 11)).foregroundStyle(JackPalette.amber)
                }
            } header: {
                HStack(spacing: 6) { Text("Stellar Code"); BetaBadge() }
            } footer: {
                Text("Stellar Code usa solo modelos locales: Ollama (11434, se inicia solo si está instalado), MLX (mlx_lm.server, 8080) y LM Studio (1234). Más contexto necesita más memoria.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            Section {
                ProviderExecutableRow(provider: .codex, path: $codexPath)
                ProviderExecutableRow(provider: .claude, path: $claudePath)
                ProviderExecutableRow(provider: .opencode, path: $opencodePath)
            } header: {
                Text("Ejecutables")
            } footer: {
                Text("Jack busca cada agente en tu PATH. Elige una ruta solo si está instalado en otro sitio; no cambia la configuración global del agente.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
            Section {
                Picker("Mantener abierto tras responder", selection: $claudeKeepAlive) {
                    Text("1 minuto").tag(1)
                    Text("5 minutos").tag(5)
                    Text("15 minutos").tag(15)
                    Text("30 minutos").tag(30)
                    Divider()
                    Text("Cerrar al responder").tag(0)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Abierto, el siguiente mensaje empieza al instante, puedes escribirle mientras trabaja y sus subagentes en segundo plano siguen hasta avisarte. Cada sesión abierta ocupa unos 350 MB; nunca se cierra mientras tiene tareas en segundo plano.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}

private struct ProviderExecutableRow: View {
    let provider: ChatProvider
    @Binding var path: String

    private var resolved: String? {
        ExecutableResolver.resolve(provider.rawValue, override: path.isEmpty ? nil : path)
    }

    var body: some View {
        let resolved = self.resolved
        HStack(alignment: .center, spacing: 10) {
            providerGlyph(provider, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.title).font(.system(size: 13, weight: .semibold))
                    if !path.isEmpty {
                        Text("Personalizado").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(JackPalette.panelStrong, in: Capsule())
                            .foregroundStyle(JackPalette.muted)
                    }
                }
                if let resolved {
                    Label((resolved as NSString).abbreviatingWithTildeInPath, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(JackPalette.muted)
                        .labelStyle(StatusLabelStyle(color: JackPalette.green))
                        .lineLimit(1).truncationMode(.middle)
                        .help(resolved)
                } else {
                    Label("No encontrado", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(JackPalette.amber)
                }
            }
            Spacer()
            if !path.isEmpty {
                Button("Restablecer") { path = "" }.buttonStyle(.borderless)
            }
            Button("Elegir…", action: choose)
        }
        .padding(.vertical, 3)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Seleccionar ejecutable de \(provider.title)"
        panel.prompt = "Seleccionar"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

private struct ShortcutsSettings: View {
    private let shortcuts: [(String, String)] = [
        ("Nuevo agente", "⌘N"),
        ("Agente anterior / siguiente", "⌥⌘↑  ⌥⌘↓"),
        ("Ir al agente 1–9 de la barra", "⌘1 … ⌘9"),
        ("Siguiente que necesita atención", "⇧⌘A"),
        ("Escribir mensaje", "⌘L"),
        ("Enviar · nueva línea", "↩  ⇧↩"),
        ("Interrumpir y enviar", "⌘↩"),
        ("Preguntar al margen sin interrumpir (como /btw) · cerrar", "⌥↩  ⎋"),
        ("Detener agente (devuelve los mensajes en espera)", "⌘."),
        ("Cambiar modo de Claude Code", "⇧⇥"),
        ("Mensajes enviados anteriores", "↑ ↓"),
        ("Usar la sugerencia", "⇥"),
        ("Permitir · rechazar permiso", "⌘↩  ⎋"),
        ("Permitir siempre", "⌥⌘↩"),
        ("Marcar como no leído", "⇧⌘U"),
        ("Buscar agentes", "⌘F"),
        ("Cerrar pestaña del agente", "⌘W"),
        ("Mostrar u ocultar barra lateral", "⌃⌘S"),
        ("Terminal · navegador · archivos", "⌃`  ⇧⌘B  ⇧⌘E"),
    ]

    var body: some View {
        Form {
            Section("Teclado") {
                ForEach(shortcuts, id: \.0) { title, keys in
                    LabeledContent(title) {
                        Text(keys).font(.system(size: 12, design: .rounded).weight(.medium)).foregroundStyle(JackPalette.secondaryText)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

struct ChatRenameSheet: View {
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Renombrar conversación").font(.system(size: 16, weight: .semibold))
            TextField("Título", text: $title)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(onSave)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar", action: onSave).buttonStyle(.borderedProminent).tint(JackPalette.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 370).background(JackPalette.canvas)
        .onAppear { focused = true }
    }
}

struct ChatConversationSettingsSheet: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let onClose: () -> Void

    private var current: ChatConversation {
        store.conversations.first { $0.id == conversation.id } ?? conversation
    }
    private var busy: Bool {
        let status = store.statuses[conversation.id] ?? .idle
        return status == .running || status == .waiting || status == .queued
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Configuración de \(conversation.provider.title)").font(.system(size: 16, weight: .semibold))
            Text("MODELO · ESFUERZO · MODO")
                .font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(JackPalette.muted)
            ChatModelPicker(store: store, conversation: current, busy: busy)
                .font(.system(size: 12, weight: .medium))
            Text(busy ? "Detén el agente para cambiar sus opciones." : "Los cambios se guardan al seleccionarlos y se aplican al próximo mensaje.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            HStack {
                Spacer()
                Button("Listo", action: onClose)
                    .buttonStyle(.borderedProminent).tint(JackPalette.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 510).background(JackPalette.canvas)
    }
}
