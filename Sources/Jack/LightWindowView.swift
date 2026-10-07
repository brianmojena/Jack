import AppKit
import JackCore
import SwiftUI
import UserNotifications

/// Light is a separate view tree. Normal's transcript, panes, effects and monitors aren't mounted.
struct LightWindowView: View {
    @ObservedObject var store: ChatStore
    let memory: WindowMemory
    @AppStorage("lightModeEnabled") private var lightMode = true
    @State private var drafts: [UUID: String] = [:]
    @State private var attachments: [UUID: [String]] = [:]
    @State private var panel: Panel?
    @State private var newAgent = false
    @State private var resumeSession = false
    @State private var focusRequest = 0
    @State private var visibleCount = 100
    @State private var windowVisible = true
    @State private var previousStatuses: [UUID: ChatStatus] = [:]
    @State private var formattedMessages: [ChatMessage] = []

    private enum Panel: String, Identifiable {
        case conversations, options, commands, activity, usage, progress, servers, files, formatted
        var id: String { rawValue }
    }
    private var conversation: ChatConversation? { store.selectedConversation }
    private var spaces: [String] { Array(Set(store.conversations.map(\.projectPath))).sorted() }
    private var imported: Set<String> { Set(store.conversations.filter { $0.provider == .claude }.compactMap(\.sessionID)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.errorMessage {
                HStack {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Cerrar") { store.errorMessage = nil }
                }.padding(10)
            }
            if let conversation {
                chat(conversation)
            } else {
                VStack(spacing: 14) {
                    Text("Jack Light").font(.title2)
                    Text("Elige una conversación o crea un agente.").foregroundStyle(.secondary)
                    Button("Nuevo agente…") { newAgent = true }.keyboardShortcut("n")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.interfaceStyle, .basic)
        .background(LightWindowVisibility { windowVisible = $0; store.setLightWindowVisible($0) })
        .onAppear {
            drafts = memory.drafts; attachments = memory.attachments
            store.showInPanes([])
            UNUserNotificationCenter.jack?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .onDisappear {
            memory.drafts = drafts; memory.attachments = attachments
            store.setLightDetailsVisible(false)
        }
        .onChange(of: store.selectedID) { _, _ in visibleCount = 100; panel = nil }
        .onChange(of: panel) { _, value in
            store.setLightDetailsVisible(value == .activity)
            if value == .formatted, let conversation { formattedMessages = LightTranscript.messages(in: conversation, limit: visibleCount) }
        }
        .onReceive(store.$statuses.removeDuplicates()) { statuses in
            defer { previousStatuses = statuses }
            guard !previousStatuses.isEmpty, !windowVisible || !NSApp.isActive else { return }
            for (id, status) in statuses where status != previousStatuses[id] {
                guard let chat = store.conversations.first(where: { $0.id == id }), chat.parentID == nil else { continue }
                let title: String
                switch status {
                case .idle where previousStatuses[id]?.isActive == true: title = "Terminó: " + chat.title
                case .waiting: title = "Necesita tu respuesta: " + chat.title
                case .failed: title = "Falló: " + chat.title
                default: continue
                }
                let content = UNMutableNotificationContent()
                content.title = title
                let detail = status == .waiting ? store.approvals[id]?.first?.title : chat.messages.last(where: { $0.role == (status == .failed ? "error" : "assistant") })?.text
                content.body = String((detail ?? chat.preview ?? "").prefix(240))
                content.userInfo = ["conversation": id.uuidString]
                UNUserNotificationCenter.jack?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
        .onChange(of: store.recalled) { _, recalled in
            for (id, message) in recalled {
                drafts[id] = [message.text, drafts[id] ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                addAttachments(message.attachments, to: id)
                store.clearRecalled(id)
            }
        }
        .onDrop(of: AttachmentDrop.types, isTargeted: nil) { providers in
            guard let id = store.selectedID else { return false }
            AttachmentDrop.load(providers) { addAttachments($0, to: id) }
            return true
        }
        .sheet(isPresented: $newAgent) {
            LightNewAgentSheet(spaces: spaces, initialSpace: conversation?.projectPath, initialProvider: conversation?.provider,
                          modelChoices: store.modelChoices(for:), localModels: store.localModels) { request in
                if request.projectPath.isEmpty {
                    _ = store.createLocating(request.firstMessage, provider: request.provider, model: request.model, effort: request.effort, projects: spaces)
                } else if let id = store.create(projectPath: request.projectPath, provider: request.provider, model: request.model, effort: request.effort), !request.firstMessage.isEmpty {
                    store.send(request.firstMessage, to: id)
                }
                newAgent = false
            } onCancel: { newAgent = false }
            .task { await store.refreshLocalModels() }
        }
        .sheet(isPresented: $resumeSession) {
            ClaudeSessionPicker(imported: imported) { session in
                _ = store.importClaudeSessions([session])
                if let chat = store.conversations.first(where: { $0.provider == .claude && $0.sessionID == session.id }) { store.select(chat.id) }
                resumeSession = false
            } onCancel: { resumeSession = false }
        }
        .sheet(item: $panel) { selected in
            VStack(spacing: 0) {
                panelContent(selected)
                Divider()
                HStack { Spacer(); Button("Cerrar") { panel = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }.frame(minWidth: 480, minHeight: 250)
                .environment(\.interfaceStyle, .basic)
        }
        .focusedSceneValue(\.jackActions, actions)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Buscar conversaciones…") { panel = .conversations }
                Divider()
                ForEach(store.conversations) { chat in
                    Button {
                        store.select(chat.id)
                    } label: {
                        let attention = store.statuses[chat.id] == .waiting ? " · Necesita respuesta" : ""
                        Text(chat.title + attention + (chat.hasUnread == true ? " · Nuevo" : ""))
                    }
                }
            } label: { Text(conversation?.title ?? "Conversaciones").lineLimit(1) }
            .disabled(store.conversations.isEmpty)
            Spacer(minLength: 4)
            if let waiting = store.conversations.first(where: { $0.id != store.selectedID && store.statuses[$0.id] == .waiting }) {
                Button("Atención", systemImage: "hand.raised") { store.select(waiting.id) }
                    .help("\(waiting.title) necesita tu respuesta")
            }
            Button("Nuevo", systemImage: "plus") { newAgent = true }.help("Nuevo agente (⌘N)")
            Menu {
                Button("Opciones del agente…") { panel = .options }.disabled(conversation == nil)
                Button("Uso y límites…") { panel = .usage }
                Button("Progreso y descargas…") { panel = .progress }
                Button("Servidores…") { panel = .servers }
                Button("Archivos del proyecto…") { panel = .files }.disabled(conversation == nil)
                Button("Ver texto con formato…") { panel = .formatted }.disabled(conversation == nil)
                Button("Retomar sesión de Claude Code…") { resumeSession = true }
                Divider()
                Button("Volver al modo Normal") { lightMode = false }
            } label: { Image(systemName: "ellipsis.circle") }
            .help("Carpetas, modelo, límites y más opciones")
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Keep the mode switch in the bottom chrome, as in Normal, without mounting its monitors.
    private var footer: some View {
        HStack {
            Spacer(minLength: 8)
            LightModeToggle()
        }
        .foregroundStyle(JackPalette.muted)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .jackSurface(.chrome)
        .overlay(alignment: .top) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }

    private func chat(_ conversation: ChatConversation) -> some View {
        let id = conversation.id
        let status = store.statuses[id] ?? .idle
        return VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: conversation.projectPath).lastPathComponent).lineLimit(1)
                    .help(conversation.projectPath)
                Spacer()
                Text(statusText(status)).accessibilityLabel("Estado del agente")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
            if LightTranscript.messages(in: conversation, limit: visibleCount + 1).count > visibleCount {
                Button("Cargar mensajes anteriores") { visibleCount += 100 }.font(.system(size: 11)).padding(4)
            }
            LightNativeTranscript(conversationID: id, messages: LightTranscript.messages(in: conversation, limit: visibleCount), isVisible: windowVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let approvals = store.approvals[id], !approvals.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(approvals) { approval in
                            ApprovalCard(approval: approval, provider: conversation.provider, projectPath: conversation.projectPath,
                                         repliesInChat: store.canSend(to: id) && status.isActive, shortcutsEnabled: false,
                                         onRespond: { store.respond(conversationID: id, approvalID: approval.id, choice: $0, message: $1) },
                                         onAnswer: { store.answer(conversationID: id, approvalID: approval.id, answers: $0) })
                        }
                    }.padding(12)
                }.frame(maxHeight: 240)
            }
            if let waiting = store.waiting[id], !waiting.isEmpty {
                WaitingMessagesView(messages: waiting, provider: conversation.provider, readsWhileWorking: store.readsWhileWorking(id),
                                    onSendNow: { store.sendWaitingNow(id) },
                                    onEdit: { takeBack($0, in: id, restore: true) },
                                    onRemove: { takeBack($0, in: id, restore: false) }).padding(.horizontal, 12)
            }
            let images = store.imageRequests.filter { $0.conversationID == id && $0.isPending }
            ForEach(images) { request in
                HStack {
                    Text("Imagen pendiente").font(.system(size: 12))
                    Spacer()
                    Button("Ahora no") { store.resolveImage(request.id, .declined) }
                    Button("Abrir en Normal") { lightMode = false }
                }.padding(.horizontal, 14).padding(.vertical, 6)
            }
            Divider()
            AsideView(asides: store.asides, conversationID: id, provider: conversation.provider,
                      composing: .constant(false), onAsk: { store.askAside($0, in: id) })
            composer(conversation, status: status)
        }
    }

    private func composer(_ conversation: ChatConversation, status: ChatStatus) -> some View {
        let id = conversation.id
        return VStack(alignment: .leading, spacing: 8) {
            if let files = attachments[id], !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(files, id: \.self) { file in
                            Button(URL(fileURLWithPath: file).lastPathComponent + " ×") { attachments[id]?.removeAll { $0 == file } }
                                .font(.system(size: 11)).help(file)
                        }
                    }
                }
            }
            LightNativeComposer(text: Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 }), conversationID: id,
                                focusRequest: focusRequest,
                                onSend: { send($0, to: id, interrupting: $1) },
                                onAside: { text in
                                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                    store.askAside(text, in: id)
                                    drafts[id] = ""
                                }, onStop: { store.stop(id) })
                .frame(height: 76)
            HStack(spacing: 10) {
                Button("Adjuntar", systemImage: "paperclip") { addAttachments(AttachmentDrop.choose(from: conversation.projectPath), to: id) }
                Button("Comandos", systemImage: "command") { panel = .commands }
                Button("Actividad", systemImage: "terminal") { panel = .activity }
                Spacer()
                if status.isActive { Button("Detener") { store.stop(id) }.keyboardShortcut(".") }
                Button(status.isActive ? "En cola" : "Enviar") { send(drafts[id] ?? "", to: id) }
                    .disabled((drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (attachments[id] ?? []).isEmpty)
            }.controlSize(.small)
            Text("Enter: enviar · Shift+Enter: salto de línea · ⌘Enter: interrumpir y enviar")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(12)
    }

    @ViewBuilder private func panelContent(_ selected: Panel) -> some View {
        switch selected {
        case .conversations:
            LightConversationsPanel(store: store) { store.select($0); panel = nil }
        case .usage:
            ProviderUsageView(usage: store.usage, refreshing: store.refreshingUsage, refresh: { Task { await store.refreshUsage() } })
        case .options:
            VStack(alignment: .leading, spacing: 16) {
                Text("Opciones de Light").font(.headline)
                if let conversation {
                    ChatModelPicker(store: store, conversation: conversation, busy: store.isBusy(conversation.id))
                    AgentFoldersButton(store: store, conversation: conversation)
                }
                Picker("Agentes simultáneos en Light", selection: Binding(get: { store.lightMaxConcurrent }, set: store.setLightConcurrency)) {
                    ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text(String($0)).tag($0) }
                }
                Text("El modo Normal conserva su configuración. Las sesiones inactivas de Claude se cierran en un máximo de 30 segundos si no tienen trabajo pendiente.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(width: 500)
        case .commands:
            if let conversation {
                LightCommandsPanel(store: store, conversation: conversation) { command in
                    drafts[conversation.id] = command + " "
                    panel = nil; focusRequest += 1
                }
            }
        case .activity:
            if let conversation { LightActivityPanel(conversation: conversation) }
        case .formatted:
            if conversation != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(formattedMessages) { message in
                            Text(message.role == "user" ? "Tú" : "Agente").font(.caption).foregroundStyle(.secondary)
                            MarkdownText(text: message.text, fontSize: 13, design: .default)
                        }
                    }.padding(20)
                }.frame(width: 620, height: 460)
            }
        case .progress:
            LightProgressPanel(monitor: store.progress)
        case .servers:
            LightServersPanel(monitor: store.servers)
        case .files:
            if let conversation {
                LightFilesPanel(root: conversation.projectPath, onAttach: { addAttachments([$0], to: conversation.id) }, onClose: { panel = nil })
            }
        }
    }

    private func send(_ text: String, to id: UUID, interrupting: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(attachments[id] ?? []).isEmpty else {
            if interrupting, store.waiting[id]?.isEmpty == false { store.sendWaitingNow(id) }
            return
        }
        store.errorMessage = nil
        store.send(text, attachments: attachments[id] ?? [], to: id, interrupting: interrupting)
        if store.errorMessage == nil { drafts[id] = ""; attachments[id] = [] }
    }
    private func addAttachments(_ files: [String], to id: UUID) {
        for file in files where !(attachments[id] ?? []).contains(file) { attachments[id, default: []].append(file) }
    }
    private func takeBack(_ message: ChatQueuedMessage, in id: UUID, restore: Bool) {
        Task {
            if let removed = await store.withdraw(message.id, from: id), restore {
                drafts[id] = [removed.text, drafts[id] ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                addAttachments(removed.attachments, to: id)
            }
        }
    }
    private func statusText(_ status: ChatStatus) -> String {
        switch status {
        case .running: "Trabajando…"
        case .queued: "En cola"
        case .waiting: "Necesita tu respuesta"
        case .failed: "Falló"
        case .idle: "Listo"
        }
    }
    private func move(_ delta: Int) {
        let ids = store.conversations.map(\.id)
        guard !ids.isEmpty else { return }
        let index = store.selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        store.select(ids[(index + delta + ids.count) % ids.count])
    }
    private var actions: JackActions {
        JackActions(newAgent: { newAgent = true }, resumeClaudeSession: { resumeSession = true }, move: move,
                    selectIndex: { index in if store.conversations.indices.contains(index) { store.select(store.conversations[index].id) } },
                    nextAttention: { if let chat = store.conversations.first(where: { store.statuses[$0.id] == .waiting }) { store.select(chat.id) } },
                    focusComposer: { focusRequest += 1 }, focusSearch: { panel = .conversations },
                    toggleUnread: { if let chat = conversation { store.setUnread(chat.id, chat.hasUnread != true) } },
                    toggleTerminal: { panel = .activity }, toggleBrowser: {}, toggleSimulator: {}, toggleGit: {},
                    toggleExplorer: { panel = .files }, toggleSidebar: {}, closeTab: { store.selectedID = nil },
                    cyclePane: { _ in }, closePanes: {}, paneCount: 0,
                    enterBatterySaver: { NSApp.keyWindow?.miniaturize(nil) },
                    hasSelection: conversation != nil, agentCount: store.conversations.count)
    }
}

private struct LightConversationsPanel: View {
    @ObservedObject var store: ChatStore
    let onSelect: (UUID) -> Void
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversaciones").font(.headline)
            TextField("Buscar por título o carpeta", text: $query).textFieldStyle(.roundedBorder)
            List(store.conversations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.projectPath.localizedCaseInsensitiveContains(query) }) { chat in
                Button { onSelect(chat.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.title).font(.system(size: 12, weight: .medium))
                        Text(chat.provider.title + " · " + chat.projectPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.padding(20).frame(width: 540, height: 420)
    }
}

private struct LightFilesPanel: View {
    @StateObject private var model: FileTreeModel
    let onAttach: (String) -> Void
    let onClose: () -> Void
    init(root: String, onAttach: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: FileTreeModel(root: root))
        self.onAttach = onAttach
        self.onClose = onClose
    }
    var body: some View {
        FileExplorer(model: model, onAttach: onAttach, onClose: onClose).frame(width: 500, height: 460)
    }
}

private struct LightCommandsPanel: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let onPick: (String) -> Void
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comandos").font(.headline)
            TextField("Buscar comando", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Del proveedor").font(.caption).foregroundStyle(.secondary)
                    if store.isLoadingCommands(for: conversation) { Text("Cargando…") }
                    if let error = store.commandError(for: conversation) {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Reintentar") { store.loadCommands(for: conversation) }
                    }
                    commandRows(store.commands(for: conversation) ?? [], prefix: "/")
                    Divider()
                    Text("De Jack").font(.caption).foregroundStyle(.secondary)
                    commandRows(JackCommandCatalog.builtins + store.jackTemplates.map { ChatCommand(name: $0.name, description: $0.prompt) }, prefix: "!")
                }
            }
        }.padding(20).frame(width: 530, height: 430)
            .onAppear { store.loadCommands(for: conversation) }
    }
    private func commandRows(_ commands: [ChatCommand], prefix: String) -> some View {
        ForEach(commands.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }) { command in
            Button { onPick(prefix + command.name) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prefix + command.name + (command.argumentHint.isEmpty ? "" : " " + command.argumentHint)).font(.system(size: 12, design: .monospaced))
                    Text(command.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.vertical, 4)
        }
    }
}

private struct LightActivityPanel: View {
    let conversation: ChatConversation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Comandos y herramientas").font(.headline)
                let tools = conversation.messages.filter { $0.role == "tool" }.suffix(100)
                if tools.isEmpty { Text("Todavía no hay actividad de herramientas.").foregroundStyle(.secondary) }
                ForEach(Array(tools)) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.text + " · " + tool.status).font(.system(size: 12, weight: .semibold))
                        Text(tool.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    Divider()
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 640, height: 460)
    }
}

private struct LightProgressPanel: View {
    @ObservedObject var monitor: ProgressMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Progreso y descargas").font(.headline); Spacer(); Button("Actualizar") { monitor.scan() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if monitor.tasks.isEmpty { Text("No hay tareas registradas.").foregroundStyle(.secondary) }
                    ForEach(monitor.tasks) { task in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title).fontWeight(.medium)
                            Text(task.status.rawValue + (task.progress.map { " · \(Int($0 * 100)) %" } ?? "")).foregroundStyle(.secondary)
                            if let detail = task.detail { Text(detail).font(.caption) }
                            HStack {
                                if monitor.canPause(task) {
                                    Button(task.status == .paused ? "Reanudar" : "Pausar") {
                                        if task.status == .paused { monitor.resume(task) } else { monitor.pause(task) }
                                    }
                                }
                                if monitor.canCancel(task) { Button("Cancelar") { monitor.cancel(task); monitor.scan() } }
                                if let file = task.file {
                                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                                }
                            }.controlSize(.small)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(width: 540, height: 420).onAppear { monitor.scan() }
    }
}

private struct LightServersPanel: View {
    @ObservedObject var monitor: ServerMonitor
    @State private var refreshing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Servidores").font(.headline); Spacer(); Button("Actualizar") { refresh() }.disabled(refreshing) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if monitor.servers.isEmpty { Text(refreshing ? "Consultando…" : "Sin servidores detectados.").foregroundStyle(.secondary) }
                    ForEach(monitor.servers) { server in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.command).font(.system(size: 12, design: .monospaced))
                                Text(server.ports.map(String.init).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = server.url { Link("Abrir", destination: url) }
                        }
                    }
                }
            }
        }.padding(20).frame(width: 540, height: 400).onAppear { refresh() }
    }
    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { await monitor.refresh(); refreshing = false }
    }
}
