import JackCore
import SwiftUI

struct ChatModelPicker: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let busy: Bool
    @State private var custom = false
    @State private var customModel = ""
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
        conversation.provider == .opencode ? openCodeModes : ChatRunMode.choices(for: conversation.provider)
    }
    private var modeTitle: String {
        modes.first { $0.id == conversation.mode }?.title ?? (conversation.mode ?? (conversation.provider == .opencode ? "Predeterminado" : conversation.provider == .claude ? "Manual" : "Normal"))
    }

    /// Claude Code's colors for the modes that change what it may do without asking.
    private var modeColor: Color {
        guard conversation.provider == .claude else { return JackPalette.muted }
        switch conversation.mode {
        case "plan": return JackPalette.blue
        case "acceptEdits": return JackPalette.purple
        case "auto", "dontAsk": return JackPalette.amber
        default: return JackPalette.muted
        }
    }
    private var modeHelp: String {
        switch conversation.provider {
        case .claude: return "Modo de permisos · ⇧⇥ para cambiar, también mientras trabaja"
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
                } else {
                    ForEach(choices) { choice in modelButton(choice) }
                }
                Divider()
                Button("Otro modelo…") { customModel = conversation.model; custom = true }
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
                    Text("Otro modelo · \(conversation.provider.title)").font(.headline)
                    TextField(conversation.provider == .opencode ? "proveedor/modelo" : "Identificador del modelo", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyCustom() }
                    HStack {
                        Button("Cancelar") { custom = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Usar modelo") { applyCustom() }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(18).frame(width: 330)
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
                        store.updateMode(id: conversation.id, mode: mode.id, supported: modes)
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
        }
        .foregroundStyle(JackPalette.accent)
        .onChange(of: conversation.id) { _, _ in custom = false }
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
        store.updateSettings(id: conversation.id, model: customModel, effort: conversation.effort)
        custom = false
    }
}
