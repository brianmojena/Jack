import AppKit
import JackCore
import SwiftUI

/// What Jack shows when no agent is open: pick a project and an agent, then write the first task.
struct StartView: View {
    let spaces: [String]
    let agentCount: Int
    let attentionCount: Int
    /// Creates the agent; an empty message just opens it.
    let onStart: (_ projectPath: String, _ provider: ChatProvider, _ message: String) -> Void
    let onMoreOptions: (_ projectPath: String?, _ provider: ChatProvider) -> Void

    @AppStorage("lastProjectPath") private var projectPath = ""
    @AppStorage("lastNewAgentProvider") private var providerValue = ChatProvider.codex.rawValue
    @State private var message = ""
    @FocusState private var focused: Bool

    private var provider: ChatProvider { ChatProvider(rawValue: providerValue) ?? .codex }
    private var project: String? {
        if !projectPath.isEmpty, FileManager.default.fileExists(atPath: projectPath) { return projectPath }
        return spaces.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("jack").font(.mono(30, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(JackPalette.muted)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("›").font(.mono(15, weight: .bold)).foregroundStyle(JackPalette.accent)
                    TextField(project == nil ? "Elige un proyecto para empezar" : "¿Qué hacemos en \(name(of: project!))?",
                              text: $message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.mono(13.5))
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(start)
                }
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

                HStack(spacing: 6) {
                    projectMenu
                    ForEach(ChatProvider.allCases) { option in
                        Button { providerValue = option.rawValue } label: {
                            HStack(spacing: 5) {
                                ProviderMark(provider: option, size: 11)
                                Text(option.title).font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(option == provider ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(option == provider ? Color.primary : JackPalette.muted)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Usar \(option.title)")
                    }
                    Spacer(minLength: 6)
                    Button { onMoreOptions(project, provider) } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11.5))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                    .help("Modelo, esfuerzo y más opciones")
                    Button(action: start) {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(project == nil ? JackPalette.panelStrong : JackPalette.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(project == nil ? JackPalette.muted : .white)
                    }
                    .buttonStyle(.plain).disabled(project == nil)
                    .help(message.isEmpty ? "Abrir el agente" : "Crear el agente y enviar")
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? JackPalette.accent.opacity(0.5) : JackPalette.hairline))

            if !spaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROYECTOS RECIENTES").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(JackPalette.muted)
                        .padding(.bottom, 4)
                    ForEach(spaces.prefix(5), id: \.self) { path in
                        Button {
                            projectPath = path
                            focused = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: path == project ? "folder.fill" : "folder")
                                    .font(.system(size: 12)).foregroundStyle(path == project ? JackPalette.accent : JackPalette.muted)
                                    .frame(width: 16)
                                Text(name(of: path)).font(.system(size: 12.5, weight: .medium))
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .font(.mono(11)).foregroundStyle(JackPalette.faint)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(path == project ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 18) {
                shortcut("↩", "Empezar")
                shortcut("⌘N", "Nuevo agente")
                shortcut("⇧⌘A", "Atención")
                shortcut("⌘F", "Buscar")
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JackPalette.canvas)
        .onAppear { focused = true }
    }

    private var projectMenu: some View {
        Menu {
            ForEach(spaces, id: \.self) { path in
                Button(name(of: path)) { projectPath = path }
            }
            if !spaces.isEmpty { Divider() }
            Button("Elegir carpeta…", action: chooseProject)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(project.map(name(of:)) ?? "Elegir proyecto").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(project.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Carpeta en la que trabajará el agente")
    }

    private var subtitle: String {
        if attentionCount > 0 {
            return attentionCount == 1 ? "Un agente espera tu permiso en la barra lateral." : "\(attentionCount) agentes esperan tu permiso en la barra lateral."
        }
        if agentCount == 0 { return "Elige un proyecto y un agente, y escribe qué quieres hacer." }
        return "Empieza un agente nuevo o abre uno de la barra lateral."
    }

    private func name(of path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private func start() {
        guard let project else { chooseProject(); return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        message = ""
        onStart(project, provider, text)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Seleccionar carpeta del proyecto"
        panel.prompt = "Usar carpeta"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path
        focused = true
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 4))
            Text(title).font(.system(size: 11))
        }
        .foregroundStyle(JackPalette.muted)
    }
}
