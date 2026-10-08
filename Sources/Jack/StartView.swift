import AppKit
import JackCore
import SwiftUI

/// A draft chat: no conversation is created until the user sends its first message.
struct StartView: View {
    @ObservedObject var store: ChatStore
    let onStart: (NewAgentRequest) -> Void
    var onResumeClaude: (() -> Void)? = nil

    @AppStorage("lastNewAgentProvider") private var providerValue = ChatProvider.codex.rawValue
    @AppStorage("transcriptMonospaced") private var monospaced = true
    @Environment(\.interfaceStyle) private var interfaceStyle
    @State private var model = ""
    @State private var effort = "high"
    @State private var initializedEffort = false
    @State private var message = ""
    @State private var customModel = ""
    @State private var showingCustomModel = false
    @State private var linkingCloud = false
    @State private var cloudLinkError: String?
    @State private var cloudLinkLoading = false
    @State private var cloudLinkRequestID = UUID()
    @State private var remoteEnabled = false
    @State private var remoteDestination = LastRemote.destination
    @State private var remotePath = LastRemote.path
    @State private var showingRemote = false
    /// The folder chosen by hand. Nil: Jack finds it from the message.
    @State private var folder: String?
    @FocusState private var focused: Bool

    private var provider: ChatProvider { ChatProvider(rawValue: providerValue) ?? .codex }
    private var providerBinding: Binding<ChatProvider> {
        Binding(get: { provider }, set: { providerValue = $0.rawValue })
    }
    private var choices: [ChatModelChoice] { store.modelChoices(for: provider) }
    private var selectedModel: String {
        if !model.isEmpty { return model }
        if provider == .stellar { return StellarModels.preferredLocalID(in: store.localModels) }
        return provider.defaultModel
    }
    private var modelTitle: String { choices.first { $0.id == selectedModel }?.title ?? (selectedModel.isEmpty ? "Predeterminado" : selectedModel) }
    private var efforts: [String] { store.supportedEfforts(provider: provider, model: selectedModel) }
    private var hasMessage: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { hasMessage && (provider != .stellar || !selectedModel.isEmpty) }
    private var ice: Bool { interfaceStyle == .ice }
    /// A remote agent's folder lives on the other machine, so the Mac's folder only applies to local agents.
    private var folderUsed: String? { remoteEnabled && provider == .claude ? nil : folder }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                Text("¿En qué te ayudo?").font(.system(size: 24, weight: .medium))
                Text(folderUsed.map { "Trabajaré en \(($0 as NSString).abbreviatingWithTildeInPath)." } ?? "Dime qué quieres hacer. Encontraré el proyecto por ti, o elige la carpeta tú.")
                    .font(.system(size: 13)).foregroundStyle(JackPalette.muted)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(24)
            Spacer()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .jackSurface(.canvas)
        .onAppear {
            if !initializedEffort { effort = store.defaultEffort(for: provider); initializedEffort = true }
            focused = true
            ProjectIndex.shared.refreshIfStale()
        }
        .onChange(of: providerValue) { _, _ in model = ""; effort = store.defaultEffort(for: provider); focused = true }
        .onChange(of: selectedModel) { _, _ in
            if !efforts.isEmpty && !efforts.contains(effort) { effort = efforts.contains("high") ? "high" : efforts.last! }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Escribe a \(provider.title)…")
                        .font(.system(size: monospaced ? 12.5 : 13, design: monospaced ? .monospaced : .default))
                        .foregroundStyle(JackPalette.faint).padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(.system(size: monospaced ? 12.5 : 13, design: monospaced ? .monospaced : .default))
                    .scrollContentBackground(.hidden)
                    .writingToolsBehavior(.disabled)
                    .focused($focused)
                    .accessibilityLabel("Mensaje")
                    .help("Enter para enviar · Shift+Enter para un salto de línea")
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        start()
                        return .handled
                    }
            }
            .frame(minHeight: 18, maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                NewAgentProviderButton(provider: providerBinding, localModels: store.localModels)
                modelPicker
                if !efforts.isEmpty {
                    Menu {
                        ForEach(efforts, id: \.self) { option in
                            Button { effort = option } label: {
                                if effort == option { Label(ChatModelChoice.effortTitle(option), systemImage: "checkmark") }
                                else { Text(ChatModelChoice.effortTitle(option)) }
                            }
                        }
                    } label: { Text(ChatModelChoice.effortTitle(effort)) }
                    .menuStyle(.borderlessButton).fixedSize().help("Esfuerzo de razonamiento")
                }
                if !(remoteEnabled && provider == .claude) { folderMenu }
                Spacer(minLength: 8)
                if provider == .claude, let onResumeClaude {
                    Button(action: onResumeClaude) {
                        Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).help("Retomar una sesión de Claude Code (⇧⌘R)")
                }
                if provider == .claude {
                    Button { showingRemote.toggle() } label: {
                        Image(systemName: remoteEnabled ? "server.rack.fill" : "server.rack")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(remoteEnabled ? JackPalette.accent : JackPalette.muted)
                    .help(remoteEnabled ? "Remoto: \(remoteDestination)" : "Ejecutar en otra máquina por SSH")
                    .accessibilityLabel("Agente remoto por SSH")
                    .popover(isPresented: $showingRemote, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Agente remoto (SSH)").font(.headline)
                            Toggle("Ejecutar en otra máquina", isOn: $remoteEnabled)
                                .font(.system(size: 12))
                            if remoteEnabled {
                                RemoteEndpointForm(destination: $remoteDestination, remotePath: $remotePath)
                            }
                            Text("Vacía la carpeta para que Jack la detecte sola al leer tu mensaje. Necesita acceso por clave SSH y `claude` instalado en la otra máquina.")
                                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(width: 380)
                    }
                }
                Button(action: start) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(canSend ? .white : JackPalette.faint)
                        .frame(width: 24, height: 24)
                        .background(canSend ? JackPalette.accent : JackPalette.panelStrong,
                                    in: RoundedRectangle(cornerRadius: ice ? 12 : 6, style: .continuous))
                }
                .buttonStyle(.plain).disabled(!canSend)
                .help("Enviar (Enter)").accessibilityLabel("Enviar")
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .jackGlass(in: RoundedRectangle(cornerRadius: ice ? 18 : 8, style: .continuous), basic: JackPalette.panel)
        .overlay {
            if !ice {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? JackPalette.accent.opacity(0.45) : JackPalette.hairline, lineWidth: 1)
            }
        }
        .frame(maxWidth: MainWindowView.columnWidth).frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
    }

    /// Project folders the user worked in lately, most recent first.
    private var recentFolders: [String] {
        var seen = Set<String>()
        return store.conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.projectPath)
            .filter { $0 != ProjectLocator.unplacedFolder && seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
            .prefix(8).map { $0 }
    }

    private var folderMenu: some View {
        Menu {
            Button("Elegir carpeta…", systemImage: "folder") { chooseFolder() }
            if folder != nil {
                Button("Detectar por el mensaje", systemImage: "sparkle.magnifyingglass") { folder = nil }
            }
            let recents = recentFolders
            if !recents.isEmpty {
                Divider()
                ForEach(recents, id: \.self) { path in
                    Button { folder = path } label: {
                        let name = (path as NSString).lastPathComponent
                        if path == folder { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        } label: {
            Label(folder.map { ($0 as NSString).lastPathComponent } ?? "Carpeta", systemImage: folder == nil ? "folder" : "folder.fill")
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(folder == nil ? JackPalette.muted : JackPalette.accent)
        .help(folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Elegir la carpeta del proyecto, o déjalo y Jack la detecta por el mensaje")
        .accessibilityLabel("Carpeta del proyecto")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Carpeta del proyecto"
        panel.message = "Elige la carpeta donde trabajará el agente. Puedes crear una nueva."
        panel.prompt = "Elegir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder ?? recentFolders.first ?? NSHomeDirectory()).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { focused = true; return }
        folder = url.standardizedFileURL.path
        focused = true
    }

    private var modelPicker: some View {
        Menu {
            ForEach(choices) { choice in
                Button { model = choice.id } label: {
                    if choice.id == selectedModel { Label(choice.title, systemImage: "checkmark") }
                    else { Text(choice.title) }
                }
            }
            if provider == .stellar {
                Divider()
                if choices.isEmpty { Text("Sin modelos: inicia Ollama, MLX o LM Studio") }
                Button("Vincular modelo de nube…") { linkingCloud = true; cloudLinkError = nil; customModel = ""; showingCustomModel = true }
                Button("Actualizar modelos") { Task { await store.refreshLocalModels() } }
            }
            Divider()
            Button("Otro modelo…") { linkingCloud = false; customModel = selectedModel; showingCustomModel = true }
        } label: { Text(modelTitle).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading) }
        .menuStyle(.borderlessButton).fixedSize().help("Modelo")
        .popover(isPresented: $showingCustomModel) {
            VStack(alignment: .leading, spacing: 12) {
                Text(linkingCloud ? "Vincular modelo de Ollama Cloud" : "Modelo · \(provider.title)").font(.headline)
                TextField(linkingCloud ? "Nombre de Ollama, p. ej. gemma4:cloud" : provider == .opencode ? "proveedor/modelo" : "Identificador del modelo", text: $customModel)
                    .textFieldStyle(.roundedBorder).disabled(cloudLinkLoading).onSubmit { linkingCloud ? linkCloudModel() : applyCustomModel() }
                if linkingCloud {
                    Text("Usa la cuenta ya conectada en Ollama (`ollama signin`). La conversación y los archivos leídos se enviarán a Ollama Cloud.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    if let cloudLinkError { Text(cloudLinkError).font(.system(size: 11)).foregroundStyle(JackPalette.amber) }
                }
                HStack {
                    Button("Cancelar") { cloudLinkRequestID = UUID(); cloudLinkLoading = false; showingCustomModel = false; linkingCloud = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(cloudLinkLoading ? "Validando…" : linkingCloud ? "Validar y vincular" : "Usar modelo") { linkingCloud ? linkCloudModel() : applyCustomModel() }
                        .disabled(cloudLinkLoading).keyboardShortcut(.defaultAction)
                }
            }
            .padding(18).frame(width: 330)
        }
        .onChange(of: showingCustomModel) { _, shown in
            if !shown { cloudLinkRequestID = UUID(); cloudLinkLoading = false }
        }
    }

    private func applyCustomModel() {
        model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        showingCustomModel = false
        focused = true
    }

    private func linkCloudModel() {
        guard !cloudLinkLoading else { return }
        cloudLinkLoading = true
        let requestID = UUID()
        cloudLinkRequestID = requestID
        Task {
            do {
                let model = try await store.linkOllamaCloudModel(customModel)
                guard cloudLinkRequestID == requestID, showingCustomModel, linkingCloud else { return }
                self.model = model.id
                showingCustomModel = false; linkingCloud = false; cloudLinkError = nil
            } catch {
                guard cloudLinkRequestID == requestID else { return }
                cloudLinkError = error.localizedDescription
            }
            if cloudLinkRequestID == requestID { cloudLinkLoading = false }
        }
    }

    private func start() {
        guard canSend else { focused = true; return }
        let remote = provider == .claude
            ? remoteEndpoint(enabled: remoteEnabled, destination: remoteDestination, remotePath: remotePath)
            : nil
        if let remote {
            LastRemote.destination = remote.destination
            LastRemote.path = remote.remotePath ?? ""
        }
        onStart(NewAgentRequest(provider: provider, model: selectedModel, effort: effort,
                                firstMessage: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                remote: remote, folder: folderUsed))
    }
}
