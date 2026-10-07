// Light retains its existing sheet; Normal's new-agent features do not propagate here.
import AppKit
import JackCore
import SwiftUI
import UniformTypeIdentifiers

/// What the sheet needs to create an agent; the first message is optional and sent right away.
struct LightNewAgentRequest {
    var projectPath: String
    var provider: ChatProvider
    var model: String
    var effort: String
    var firstMessage: String
}

struct LightNewAgentSheet: View {
    let spaces: [String]
    let modelChoices: (ChatProvider) -> [ChatModelChoice]
    /// Stellar Code's models; it is ready when a local server offers one.
    let localModels: [StellarModel]
    let onCreate: (LightNewAgentRequest) -> Void
    let onCancel: () -> Void

    /// Empty means automatic: the agent's model chooses the folder from the first message.
    @State private var projectPath: String
    @State private var provider: ChatProvider
    @State private var model: String
    @State private var effort = "high"
    @State private var firstMessage = ""
    @State private var dropTargeted = false
    /// Resolved once: checking executables touches the file system.
    @State private var installed: [ChatProvider: Bool] = [:]
    @FocusState private var messageFocused: Bool
    @ObservedObject private var index = ProjectIndex.shared

    init(
        spaces: [String],
        initialSpace: String?,
        initialProvider: ChatProvider?,
        modelChoices: @escaping (ChatProvider) -> [ChatModelChoice],
        localModels: [StellarModel] = [],
        onCreate: @escaping (LightNewAgentRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.spaces = spaces
        self.modelChoices = modelChoices
        self.localModels = localModels
        self.onCreate = onCreate
        self.onCancel = onCancel
        let provider = initialProvider ?? Self.lastProvider
        _projectPath = State(initialValue: initialSpace ?? "")
        _provider = State(initialValue: provider)
        _model = State(initialValue: provider == .stellar ? Self.firstLocal(localModels) : provider.defaultModel)
    }

    private static func firstLocal(_ models: [StellarModel]) -> String { (models.first { $0.tools } ?? models.first)?.id ?? "" }

    private static var lastProvider: ChatProvider {
        UserDefaults.standard.string(forKey: "lastNewAgentProvider").flatMap(ChatProvider.init(rawValue:)) ?? .codex
    }

    private var choices: [ChatModelChoice] { provider == .opencode ? [] : modelChoices(provider) }
    private var efforts: [String] {
        choices.first { $0.id == model }?.efforts ?? ChatModelChoice.fallbackEfforts(provider: provider, model: model.trimmingCharacters(in: .whitespaces))
    }
    private var automatic: Bool { projectPath.isEmpty }
    private var canCreate: Bool { !automatic || !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nuevo agente").font(.system(size: 17, weight: .semibold))
                Text("Elige dónde trabaja y con qué agente.").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            }
            .padding(.bottom, 18)

            label("Space")
            spacePicker.padding(.bottom, 18)

            label("Agente")
            providerCards.padding(.bottom, 14)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    label("Modelo")
                    modelField
                }
                if provider != .opencode && !efforts.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        label("Esfuerzo")
                        let picker = Picker("Esfuerzo", selection: $effort) {
                            ForEach(efforts, id: \.self) { Text(ChatModelChoice.effortTitle($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        // Five levels do not fit beside the model field as segments.
                        if efforts.count > 4 { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
                    }
                }
            }
            .padding(.bottom, 18)

            label(automatic ? "Primer mensaje" : "Primer mensaje (opcional)")
            ZStack(alignment: .topLeading) {
                if firstMessage.isEmpty {
                    Text(automatic ? "Describe la tarea; el agente buscará el proyecto: «arregla el login de Jack»…" : "Describe la tarea y el agente empezará en cuanto lo crees…")
                        .font(.system(size: 12)).foregroundStyle(JackPalette.faint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $firstMessage)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .writingToolsBehavior(.disabled)
            }
            .frame(height: 64)
            .padding(8)
            .background(JackPalette.composer, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(messageFocused ? JackPalette.accent.opacity(0.6) : JackPalette.hairline, lineWidth: 1))

            HStack {
                Text(canCreate ? "⌘↩ para crear" : "Escribe la tarea o elige una carpeta")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button(firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Crear agente" : "Crear y enviar", action: create)
                    .buttonStyle(.borderedProminent)
                    .tint(JackPalette.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCreate)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 540)
        .background(JackPalette.canvas)
        .onChange(of: provider) { _, value in
            model = value == .stellar ? Self.firstLocal(localModels) : value.defaultModel
            if !efforts.isEmpty && !efforts.contains(effort) { effort = efforts.contains("high") ? "high" : efforts.last! }
        }
        .onChange(of: localModels.map(\.id)) { _, _ in
            if provider == .stellar, model.isEmpty { model = Self.firstLocal(localModels) }
        }
        .onChange(of: model) { _, _ in
            if !efforts.isEmpty && !efforts.contains(effort) { effort = efforts.contains("high") ? "high" : efforts.last! }
        }
        .onAppear {
            if automatic { messageFocused = true }
            index.refreshIfStale()
        }
        .task {
            var found: [ChatProvider: Bool] = [:]
            for provider in ChatProvider.allCases where !provider.isBuiltIn {
                let override = UserDefaults.standard.string(forKey: "providerExecutablePath.\(provider.rawValue)")
                found[provider] = ExecutableResolver.resolve(provider.rawValue, override: override?.isEmpty == false ? override : nil) != nil
            }
            installed = found
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundStyle(JackPalette.muted)
            .padding(.bottom, 6)
    }

    // MARK: Space

    private var spacePicker: some View {
        let listed = spaces.contains(projectPath) || projectPath.isEmpty ? spaces : [projectPath] + spaces
        return VStack(spacing: 0) {
            automaticRow
            ForEach(listed.prefix(4), id: \.self) { path in
                Divider().padding(.leading, 34)
                spaceRow(path)
            }
            if !listed.isEmpty { Divider() }
            Button(action: chooseProject) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").frame(width: 16)
                    Text(listed.isEmpty ? "Elegir carpeta del proyecto…" : "Otra carpeta…")
                    Spacer()
                    Text("o arrastra una carpeta aquí").foregroundStyle(JackPalette.faint)
                }
                .font(.system(size: 12))
                .foregroundStyle(JackPalette.accent)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(dropTargeted ? JackPalette.accent : JackPalette.hairline, style: StrokeStyle(lineWidth: dropTargeted ? 2 : 0.5, dash: dropTargeted ? [5, 3] : []))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
                Task { @MainActor in projectPath = url.path }
            }
            return true
        }
    }

    /// The default: the agent's model reads the first message and chooses the folder.
    private var automaticRow: some View {
        Button { projectPath = ""; messageFocused = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(automatic ? JackPalette.accent : JackPalette.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Automático").font(.system(size: 12, weight: automatic ? .semibold : .regular))
                    Text("El agente elige la carpeta del proyecto a partir del primer mensaje")
                        .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if automatic {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(automatic ? JackPalette.accent.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func spaceRow(_ path: String) -> some View {
        let selected = path == projectPath
        return Button { projectPath = path } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .foregroundStyle(selected ? JackPalette.accent : JackPalette.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? JackPalette.accent.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Agent

    private var providerCards: some View {
        HStack(spacing: 8) {
            ForEach(ChatProvider.allCases) { option in
                let selected = option == provider
                let available = option == .stellar ? !localModels.isEmpty : installed[option] ?? true
                Button { provider = option } label: {
                    HStack(spacing: 9) {
                        providerGlyph(option, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(option.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                if option.isBeta { BetaBadge() }
                            }
                            Text(option == .stellar ? (available ? "\(localModels.count) local\(localModels.count == 1 ? "" : "es")" : "Sin modelos locales") : available ? "Listo" : "No encontrado")
                                .font(.system(size: 10))
                                .foregroundStyle(available ? JackPalette.muted : JackPalette.amber)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity)
                    .background(selected ? JackPalette.accent.opacity(0.1) : JackPalette.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? JackPalette.accent : JackPalette.hairline, lineWidth: selected ? 1.5 : 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(option == .stellar
                      ? (available ? "Stellar Code (beta): el agente de Jack, solo con modelos locales" : "Stellar Code (beta) necesita un modelo local: inicia Ollama, MLX o LM Studio")
                      : available ? option.title : "No se encontró \(option.rawValue). Configura su ruta en Ajustes.")
            }
        }
    }

    @ViewBuilder private var modelField: some View {
        if provider == .opencode {
            TextField("Predeterminado (proveedor/modelo)", text: $model)
                .textFieldStyle(.roundedBorder)
        } else {
            HStack(spacing: 6) {
                TextField("Modelo", text: $model).textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(choices) { choice in
                        Button { model = choice.id } label: {
                            if choice.id == model { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                        }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Modelos recientes y disponibles")
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        UserDefaults.standard.set(provider.rawValue, forKey: "lastNewAgentProvider")
        onCreate(LightNewAgentRequest(
            projectPath: projectPath,
            provider: provider,
            model: model.trimmingCharacters(in: .whitespaces),
            effort: effort,
            firstMessage: firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Seleccionar carpeta del proyecto"
        panel.prompt = "Usar carpeta"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !projectPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: projectPath).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path
    }
}

