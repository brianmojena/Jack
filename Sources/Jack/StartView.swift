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
    var onResumeClaude: (() -> Void)? = nil

    @AppStorage("lastNewAgentProvider") private var providerValue = ChatProvider.codex.rawValue
    @ObservedObject private var index = ProjectIndex.shared
    /// A folder the user picked; without one, Jack reads the project from the request.
    @State private var chosenProject: String?
    @State private var message = ""
    @State private var showHint = false
    @FocusState private var focused: Bool

    private var provider: ChatProvider { ChatProvider(rawValue: providerValue) ?? .codex }
    private var resolution: ProjectFinder.Resolution {
        chosenProject == nil ? ProjectFinder.resolve(message, projects: index.ordered(recent: spaces)) : .none
    }
    private var detected: ProjectFinder.Match? { resolution.match }
    private var project: String? { chosenProject ?? detected?.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("jack").font(.mono(30, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(JackPalette.muted)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("›").font(.mono(15, weight: .bold)).foregroundStyle(JackPalette.accent)
                    TextField(chosenProject.map { "¿Qué hacemos en \(name(of: $0))?" } ?? "Pide algo y nombra el proyecto: «en Jack arregla el login»",
                              text: $message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.mono(13.5))
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(start)
                        .onChange(of: message) { _, _ in showHint = false }
                }
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

                let choices = resolution.choices
                if !choices.isEmpty { choiceRow(choices) }

                HStack(spacing: 6) {
                    projectMenu
                    ForEach(ChatProvider.allCases) { option in
                        Button { providerValue = option.rawValue } label: {
                            HStack(spacing: 5) {
                                ProviderMark(provider: option, size: 11)
                                Text(option.title).font(.system(size: 11.5, weight: .medium))
                                if option.isBeta { BetaBadge() }
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
                    if provider == .claude, let onResumeClaude {
                        Button(action: onResumeClaude) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11.5))
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                        .help("Retomar una sesión de Claude Code de la terminal (⇧⌘R)")
                    }
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
                    .buttonStyle(.plain)
                    .help(message.isEmpty ? "Abrir el agente" : "Crear el agente y enviar")
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .overlay(alignment: .bottomLeading) {
                if showHint {
                    Text(resolution.choices.isEmpty
                         ? "No sé en qué proyecto: nómbralo en el mensaje o elígelo en el menú de la carpeta."
                         : "Hay varias carpetas que encajan: elige una arriba.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.amber)
                        .offset(x: 4, y: 20)
                }
            }
            .jackGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), basic: JackPalette.panel)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? JackPalette.accent.opacity(0.5) : JackPalette.hairline))

            if !spaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROYECTOS RECIENTES").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(JackPalette.muted)
                        .padding(.bottom, 4)
                    ForEach(spaces.prefix(5), id: \.self) { path in
                        Button {
                            chosenProject = chosenProject == path ? nil : path
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
        .jackSurface(.canvas)
        .onAppear {
            focused = true
            index.refreshIfStale()
        }
    }

    /// Folders that fit the request equally well, told apart by where they live.
    private func choiceRow(_ choices: [ProjectFinder.Match]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("¿Cuál de estas carpetas?").font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
            HStack(spacing: 6) {
                ForEach(choices, id: \.path) { choice in
                    Button {
                        chosenProject = choice.path
                        focused = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder").font(.system(size: 10.5)).foregroundStyle(JackPalette.accent)
                            Text(name(of: choice.path)).font(.system(size: 11.5, weight: .medium))
                            Text(location(of: choice.path)).font(.mono(10.5)).foregroundStyle(JackPalette.muted)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(JackPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(JackPalette.accent.opacity(0.35)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help((choice.path as NSString).abbreviatingWithTildeInPath)
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
        .transition(.opacity)
    }

    /// The folder that holds a project, e.g. "Proyectos Personales" for two folders named Orion.
    private func location(of path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        return "en " + parent.lastPathComponent
    }

    private var projectMenu: some View {
        Menu {
            Button { chosenProject = nil } label: {
                if chosenProject == nil { Label("Automático", systemImage: "checkmark") } else { Text("Automático") }
            }
            Divider()
            ForEach(spaces.prefix(8), id: \.self) { path in
                Button(name(of: path)) { chosenProject = path }
            }
            let others = index.ordered(recent: []).filter { !spaces.contains($0) }
            if !others.isEmpty {
                Menu("Todos los proyectos") {
                    ForEach(others.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }, id: \.self) { path in
                        Button(name(of: path)) { chosenProject = path }
                    }
                }
            }
            Divider()
            Button("Elegir carpeta…", action: chooseProject)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chosenProject != nil ? "folder" : detected != nil ? "sparkles" : "wand.and.stars")
                    .font(.system(size: 11))
                Text(project.map(name(of:)) ?? "Automático").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(detected != nil ? JackPalette.accent : Color.primary)
            .padding(.horizontal, 8).frame(height: 24)
            .background(detected != nil ? JackPalette.accent.opacity(0.14) : JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: detected?.path)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(projectHelp)
    }

    private var projectHelp: String {
        if let chosenProject { return (chosenProject as NSString).abbreviatingWithTildeInPath }
        if let detected { return "Detectado por «\(detected.mention)»: \((detected.path as NSString).abbreviatingWithTildeInPath)" }
        return "Automático: Jack elige la carpeta según el proyecto que nombres"
    }

    private var subtitle: String {
        if attentionCount > 0 {
            return attentionCount == 1 ? "Un agente espera tu permiso en la barra lateral." : "\(attentionCount) agentes esperan tu permiso en la barra lateral."
        }
        return "Di qué quieres y en qué proyecto; Jack abre la carpeta por ti."
    }

    private func name(of path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private func start() {
        guard let project else {
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { focused = true } else { showHint = true }
            return
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        message = ""
        chosenProject = nil
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
        chosenProject = url.path
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
