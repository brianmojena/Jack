import JackCore
import SwiftUI

struct ChatModelPicker: View {
    /// The Normal window offers Claude Code's bypass mode; Light does not.
    var allowsBypass = false
    /// The cloud-linking control appears only on Normal surfaces.
    var allowsCloud = false
    @State private var confirmingBypass = false
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let busy: Bool
    @State private var custom = false
    @State private var customModel = ""
    @State private var linkingCloud = false
    @State private var cloudLinkLoading = false
    @State private var cloudLinkRequestID = UUID()
    @State private var providers: [OpenCodeProviderModels] = []
    @State private var openCodeModes: [ChatRunMode] = []
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var modelsRequestID = UUID()

    private var choices: [ChatModelChoice] { store.modelChoices(for: conversation.provider) }
    private var selected: ChatModelChoice? {
        (providers.flatMap(\.models) + choices).first { $0.id == conversation.model }
    }
    private var efforts: [String] {
        if conversation.provider == .opencode {
            return providers.flatMap(\.models).first { $0.id == conversation.model }?.efforts ?? []
        }
        return selected?.efforts ?? store.supportedEfforts(provider: conversation.provider, model: conversation.model)
    }
    private var modes: [ChatRunMode] {
        let base = conversation.provider == .opencode ? openCodeModes : ChatRunMode.choices(for: conversation.provider)
        return allowsBypass && conversation.provider == .claude ? base + [ChatRunMode.bypass] : base
    }
    private var modeTitle: String {
        modes.first { $0.id == conversation.mode }?.title ?? (conversation.mode ?? (conversation.provider == .opencode ? "Predeterminado" : conversation.provider == .claude ? "Manual" : "Normal"))
    }

    /// Claude Code's colors for the modes that change what it may do without asking.
    private var modeColor: Color {
        guard conversation.provider == .claude || conversation.provider == .stellar else { return JackPalette.muted }
        switch conversation.mode {
        case "plan": return JackPalette.blue
        case "acceptEdits": return JackPalette.purple
        case "auto", "dontAsk": return JackPalette.amber
        case ChatRunMode.bypass.id: return JackPalette.red
        default: return JackPalette.muted
        }
    }
    private var modeHelp: String {
        switch conversation.provider {
        case .claude: return "Modo de permisos · ⇧⇥ para cambiar, también mientras trabaja. Bypass no pide ningún permiso"
        case .stellar: return "Manual pide permiso para editar y ejecutar; Aceptar ediciones solo para comandos; Auto no pregunta dentro del proyecto"
        case .codex where conversation.mode == "auto": return "Auto ejecuta dentro del proyecto; las acciones que requieren permiso se deniegan"
        default: return "Modo de trabajo para el próximo mensaje"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if conversation.provider == .opencode {
                    modelButton(ChatModelChoice(id: "", efforts: []))
                    ForEach(providers) { provider in
                        Menu(provider.title) {
                            ForEach(provider.models) { choice in modelButton(choice) }
                        }
                    }
                    Divider()
                    if loadingModels { Text("Cargando modelos…") }
                    if let modelsError { Text(modelsError) }
                    if !loadingModels && modelsError == nil && providers.isEmpty {
                        Text("No hay proveedores conectados")
                    }
                    Button("Actualizar modelos") { Task { await refreshModels() } }
                        .disabled(loadingModels)
                } else if conversation.provider == .stellar {
                    ForEach(choices) { choice in modelButton(choice) }
                    Divider()
                    if store.loadingLocalModels { Text("Buscando modelos de Ollama y locales…") }
                    else if choices.isEmpty { Text("Sin modelos: inicia Ollama, MLX o LM Studio") }
                    if allowsCloud { Button("Vincular modelo de nube…") { linkingCloud = true; customModel = ""; custom = true } }
                    Button(allowsCloud ? "Actualizar modelos" : "Actualizar modelos locales") { Task { await store.refreshLocalModels() } }
                        .disabled(store.loadingLocalModels)
                } else {
                    ForEach(choices) { choice in modelButton(choice) }
                }
                Divider()
                Button("Otro modelo…") { linkingCloud = false; customModel = conversation.model; custom = true }
            } label: {
                Text(selected?.title ?? conversation.model).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(busy ? "Detén el agente para cambiar de modelo" : "Cambiar modelo para el próximo mensaje")
            .disabled(busy)
            .popover(isPresented: $custom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(linkingCloud ? "Vincular modelo de Ollama Cloud" : "Otro modelo · \(conversation.provider.title)").font(.headline)
                    TextField(linkingCloud ? "Nombre de Ollama, p. ej. gemma4:cloud" : conversation.provider == .opencode ? "proveedor/modelo" : conversation.provider == .stellar ? "servidor/modelo, p. ej. ollama/qwen3:8b" : "Identificador del modelo", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(cloudLinkLoading)
                        .onSubmit { applyCustom() }
                    if linkingCloud {
                        Text("Usa la cuenta ya conectada en Ollama (`ollama signin`). La conversación y los archivos leídos se enviarán a Ollama Cloud.")
                            .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    }
                    HStack {
                        Button("Cancelar") { cloudLinkRequestID = UUID(); cloudLinkLoading = false; custom = false; linkingCloud = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(cloudLinkLoading ? "Validando…" : linkingCloud ? "Validar y vincular" : "Usar modelo") { applyCustom() }
                            .disabled(cloudLinkLoading).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(18).frame(width: 330)
            }
            .onChange(of: custom) { _, shown in
                if !shown { cloudLinkRequestID = UUID(); cloudLinkLoading = false }
            }
            if conversation.provider == .opencode || !efforts.isEmpty { Menu {
                if conversation.provider == .opencode {
                    Button {
                        store.updateVariant(id: conversation.id, variant: nil, supported: efforts)
                    } label: {
                        if conversation.variant == nil { Label("Automático", systemImage: "checkmark") }
                        else { Text("Automático") }
                    }
                    if efforts.isEmpty {
                        Text(loadingModels ? "Cargando opciones…" : conversation.model.isEmpty ? "Selecciona un modelo para configurar el esfuerzo" : "Este modelo no ofrece variantes de esfuerzo")
                    }
                }
                    ForEach(efforts, id: \.self) { effort in
                        Button {
                            if conversation.provider == .opencode {
                                store.updateVariant(id: conversation.id, variant: effort, supported: efforts)
                            } else {
                                store.updateSettings(id: conversation.id, model: conversation.model, effort: effort)
                            }
                        } label: {
                            let title = conversation.provider == .opencode ? effort : ChatModelChoice.effortTitle(effort)
                            if effort == (conversation.provider == .opencode ? conversation.variant : conversation.effort) { Label(title, systemImage: "checkmark") }
                            else { Text(title) }
                        }
                    }
                } label: {
                    Text(conversation.provider == .opencode ? (conversation.variant ?? "Automático") : ChatModelChoice.effortTitle(conversation.effort)).foregroundStyle(JackPalette.muted)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Esfuerzo de razonamiento")
                .disabled(busy) }
            Menu {
                if conversation.provider == .opencode {
                    Button("Predeterminado") { store.updateMode(id: conversation.id, mode: nil, supported: modes) }
                }
                ForEach(modes) { mode in
                    Button {
                        if mode.id == ChatRunMode.bypass.id, conversation.mode != mode.id { confirmingBypass = true }
                        else { store.updateMode(id: conversation.id, mode: mode.id, supported: modes) }
                    } label: {
                        if mode.id == conversation.mode { Label(mode.title, systemImage: "checkmark") }
                        else { Text(mode.title) }
                    }
                }
                if conversation.provider == .opencode && modes.isEmpty {
                    Text(loadingModels ? "Cargando modos…" : "Actualiza el catálogo para cargar los modos")
                }
            } label: { Text(modeTitle).foregroundStyle(modeColor) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(modeHelp)
            .disabled(busy && !store.changesModeLive(conversation.id))
            .confirmationDialog("¿Activar el modo Bypass?", isPresented: $confirmingBypass, titleVisibility: .visible) {
                Button("Activar Bypass", role: .destructive) {
                    store.updateMode(id: conversation.id, mode: ChatRunMode.bypass.id, supported: modes)
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Claude Code ejecutará comandos y editará archivos sin pedir ninguna confirmación. Úsalo solo en proyectos y máquinas de confianza.")
            }
        }
        .foregroundStyle(JackPalette.accent)
        .onChange(of: conversation.id) { _, _ in custom = false; linkingCloud = false }
        .task(id: conversation.id) {
            providers = []; openCodeModes = []; modelsError = nil
            if conversation.provider == .opencode { await refreshModels() }
        }
    }

    private func modelButton(_ choice: ChatModelChoice) -> some View {
        Button {
            store.updateSettings(id: conversation.id, model: choice.id, effort: conversation.effort)
        } label: {
            if choice.id == conversation.model { Label(choice.title, systemImage: "checkmark") }
            else { Text(choice.title) }
        }
    }

    private func refreshModels() async {
        let requestID = UUID()
        modelsRequestID = requestID
        loadingModels = true
        modelsError = nil
        defer { if modelsRequestID == requestID { loadingModels = false } }
        do {
            let available = try await OpenCodeModelService.load(directory: conversation.projectPath)
            try Task.checkCancellation()
            guard modelsRequestID == requestID else { return }
            providers = available.providers
            openCodeModes = available.modes
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, modelsRequestID == requestID else { return }
            modelsError = "No se pudieron cargar los modelos"
        }
    }

    private func applyCustom() {
        if linkingCloud, conversation.provider == .stellar, allowsCloud {
            guard !cloudLinkLoading else { return }
            cloudLinkLoading = true
            let requestID = UUID()
            cloudLinkRequestID = requestID
            Task {
                do {
                    let model = try await store.linkOllamaCloudModel(customModel)
                    guard cloudLinkRequestID == requestID, custom, linkingCloud, allowsCloud else { return }
                    store.updateSettings(id: conversation.id, model: model.id, effort: conversation.effort)
                    custom = false; linkingCloud = false
                } catch {
                    guard cloudLinkRequestID == requestID else { return }
                    store.errorMessage = error.localizedDescription
                }
                if cloudLinkRequestID == requestID { cloudLinkLoading = false }
            }
            return
        }
        store.updateSettings(id: conversation.id, model: customModel, effort: conversation.effort)
        custom = false
    }
}
