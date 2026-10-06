import JackCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var store: ChatStore
    @State private var drafts: [UUID: String] = [:]
    @State private var attachments: [UUID: [String]] = [:]
    @State private var dropTargeted = false
    @StateObject private var workspace = WorkspaceSessions()
    @State private var showingWorkspace = false
    @State private var workspaceTool: WorkspaceTool = .terminal
    @State private var visibleMessageCounts: [UUID: Int] = [:]
    @State private var nearBottom = true
    @State private var showingNewConversation = false
    @State private var pendingProvider: ChatProvider?
    @State private var pendingSpace: String?
    @State private var searchRequest = 0
    @FocusState private var composerFocused: Bool
    @AppStorage("collapsedSpaces") private var collapsedSpacesValue = ""
    @State private var renamingConversation: ChatConversation?
    @State private var renameText = ""
    @State private var deletingConversation: ChatConversation?
    @State private var commandSelection = 0
    /// Draft for which the user closed the command list with Esc.
    @State private var dismissedCommandDraft: String?

    private var selectedConversation: ChatConversation? { store.selectedConversation }

    var body: some View {
        NavigationSplitView {
            JackSidebar(
                rows: sidebarRows,
                projectPaths: Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.projectPath) }),
                selectedID: store.selectedID,
                activeCount: store.activeCount,
                maxConcurrent: store.maxConcurrent,
                usage: store.usage,
                refreshingUsage: store.refreshingUsage,
                onRefreshUsage: { Task { await store.refreshUsage() } },
                onSetConcurrency: store.setConcurrency,
                onNewConversation: { openNewConversation() },
                onSelect: store.select,
                onRename: { id in store.conversations.first { $0.id == id }.map(beginRename) },
                onDelete: { id in deletingConversation = store.conversations.first { $0.id == id } },
                onSetUnread: store.setUnread,
                searchRequest: searchRequest
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            conversationPanel
        }
        
        .frame(minWidth: 900, minHeight: 620)
        .onChange(of: store.conversations.map(\.id)) { _, ids in workspace.prune(keeping: Set(ids)) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in workspace.terminateAll() }
        .focusedSceneValue(\.jackActions, actions)
        .sheet(isPresented: $showingNewConversation) {
            NewAgentSheet(
                spaces: recentSpaces,
                initialSpace: pendingSpace ?? selectedConversation?.projectPath,
                initialProvider: pendingProvider,
                modelChoices: store.modelChoices(for:)
            ) { request in
                createAgent(request)
                showingNewConversation = false
            } onCancel: {
                showingNewConversation = false
            }
        }
        .sheet(item: $renamingConversation) { conversation in
            ChatRenameSheet(title: $renameText) {
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { store.rename(conversation.id, title: title) }
                renamingConversation = nil
            } onCancel: { renamingConversation = nil }
        }
        .confirmationDialog(
            "¿Eliminar esta conversación?",
            isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } }),
            titleVisibility: .visible
        ) {
            if let conversation = deletingConversation {
                Button("Eliminar conversación", role: .destructive) {
                    store.remove(conversation.id)
                    deletingConversation = nil
                }
                Button("Cancelar", role: .cancel) { deletingConversation = nil }
            }
        } message: {
            Text("Se eliminará “\(deletingConversation?.title ?? "")” de Jack.")
        }
    }

    @ViewBuilder private var conversationPanel: some View {
        if let conversation = selectedConversation {
            conversationView(conversation)
        } else {
            VStack(spacing: 0) {
                if let error = store.errorMessage, !error.isEmpty { errorBanner(error) }
                EmptyChatView(
                    spaces: Array(recentSpaces.prefix(4)),
                    agentCount: store.conversations.count,
                    attentionCount: store.statuses.values.filter { $0 == .waiting }.count
                ) { space, provider in
                    openNewConversation(provider: provider, space: space)
                }
            }
        }
    }

    private func conversationView(_ conversation: ChatConversation) -> some View {
        let status = store.statuses[conversation.id] ?? .idle
        return VStack(spacing: 0) {
            if let error = store.errorMessage, !error.isEmpty { errorBanner(error) }
            messageHistory(conversation)
            if let approvals = store.approvals[conversation.id], !approvals.isEmpty {
                approvalsPanel(approvals, conversationID: conversation.id)
            }
            if isActive(conversation) {
                AgentActivityView(conversation: conversation, status: status, tokens: store.tokenUsage[conversation.id], projectPath: conversation.projectPath)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
            }
            if let query = commandQuery(for: conversation) {
                let matches = CommandSuggestions.matches(store.commands(for: conversation) ?? [], query: query)
                CommandSuggestions(commands: matches, loading: store.isLoadingCommands(for: conversation),
                                   selection: min(commandSelection, max(0, matches.count - 1))) { complete($0, in: conversation) }
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .onAppear { store.loadCommands(for: conversation) }
                    .onChange(of: query) { _, _ in commandSelection = 0 }
            }
            composer(conversation)
        }
        .background(JackPalette.canvas)
        .onDrop(of: AttachmentDrop.types, isTargeted: $dropTargeted) { providers in
            AttachmentDrop.load(providers) { attach($0, to: conversation.id) }
            return true
        }
        .overlay { if dropTargeted { AttachmentDropOverlay() } }
        .inspector(isPresented: $showingWorkspace) {
            WorkspacePanel(sessions: workspace, conversationID: conversation.id, projectPath: conversation.projectPath, tool: workspaceTool,
                           onSelect: { tool in withoutAnimation { workspaceTool = tool } },
                           onClose: { withoutAnimation { showingWorkspace = false } })
                .equatable()
                .inspectorColumnWidth(min: 340, ideal: 520, max: 1100)
        }
        .navigationTitle(conversation.title)
        .navigationSubtitle(conversationSubtitle(conversation))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let parent = conversation.parentID.flatMap({ id in store.conversations.first { $0.id == id } }) {
                    Button { store.select(parent.id) } label: {
                        Label("Delegado por \(parent.title)", systemImage: "arrow.turn.left.up")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .frame(maxWidth: 220)
                    }
                    .help("Ir al agente que delegó esta tarea")
                }
                StatusPill(status: status)
                if let context = conversation.contextUsage {
                    ContextGauge(usage: context, costUSD: (store.tokenUsage[conversation.id] ?? conversation.tokenUsage)?.costUSD)
                }
                AgentFoldersButton(store: store, conversation: conversation)
                ForEach(WorkspaceTool.allCases) { tool in
                    Button { toggleWorkspace(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                        .help(showingWorkspace && workspaceTool == tool ? "Ocultar \(tool.title.lowercased())" : "Mostrar \(tool.title.lowercased()) del proyecto")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: conversation.projectPath)])
                } label: { Label("Mostrar en Finder", systemImage: "folder") }
                    .help("Mostrar el proyecto en Finder")
                if status.isActive {
                    Button { store.stop(conversation.id) } label: { Label("Detener", systemImage: "stop.circle") }
                        .help("Detener este agente")
                }
            }
        }
    }

    private func messageHistory(_ conversation: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if conversation.messages.isEmpty {
                        ConversationWelcome(conversation: conversation) { text in send(text, in: conversation) }
                            .padding(.top, 90)
                    } else {
                        let count = visibleMessageCounts[conversation.id] ?? 100
                        let start = max(0, conversation.messages.count - count)
                        if start > 0 {
                            Button("Cargar mensajes anteriores") {
                                visibleMessageCounts[conversation.id] = count + 100
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(JackPalette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 16)
                        }
                        let lastID = conversation.messages.last?.id
                        let active = isActive(conversation)
                        ForEach(start..<conversation.messages.count, id: \.self) { index in
                            let message = conversation.messages[index]
                            ChatMessageRow(
                                message: message,
                                provider: conversation.provider,
                                projectPath: conversation.projectPath,
                                isStreaming: active && message.id == lastID,
                                topSpacing: index == start ? 0 : rowSpacing(previous: conversation.messages[index - 1].role, current: message.role)
                            )
                            .equatable()
                            .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
            .defaultScrollAnchor(.bottom)
            // Only a Bool crosses into view state, so scrolling does not re-render the chat.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 120
            } action: { _, isNearBottom in
                nearBottom = isNearBottom
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                if nearBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                if nearBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.id) { _, _ in
                nearBottom = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let bottomID = "jack-chat-bottom"

    private var sidebarRows: [SidebarRowModel] {
        let titles = Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.title) })
        return store.conversations.map { conversation in
            let status = store.statuses[conversation.id] ?? .idle
            return SidebarRowModel(
                id: conversation.id,
                title: conversation.title,
                projectName: URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                provider: conversation.provider,
                model: conversation.model,
                status: status,
                activity: sidebarActivity(conversation, status: status),
                unread: conversation.hasUnread == true,
                updatedAt: conversation.updatedAt,
                canEdit: !status.isActive,
                parentID: conversation.parentID,
                parentTitle: conversation.parentID.flatMap { titles[$0] }
            )
        }
    }

    /// One line for the sidebar: live action while working, otherwise the last turn's summary.
    private func sidebarActivity(_ conversation: ChatConversation, status: ChatStatus) -> String {
        switch status {
        case .waiting:
            guard let approval = store.approvals[conversation.id]?.first else { return "" }
            return approval.questions.isEmpty ? "Permiso: \(approval.title)" : "Tiene preguntas para ti"
        case .running:
            guard let last = conversation.messages.last else { return "" }
            switch last.role {
            case "tool":
                let tool = ToolPresentation(message: last, projectPath: conversation.projectPath)
                let subject = tool.kind == .command ? tool.subject : (tool.subject as NSString).lastPathComponent
                return [tool.verb(running: ["running", "inProgress", "pending"].contains(last.status)), subject].filter { !$0.isEmpty }.joined(separator: " ")
            case "reasoning": return "Pensando…"
            case "assistant": return "Escribiendo respuesta…"
            default: return "Preparando…"
            }
        case .failed:
            return conversation.messages.last { $0.role == "error" }?.text ?? conversation.preview ?? ""
        case .queued, .idle:
            return conversation.preview ?? ""
        }
    }

    private func rowSpacing(previous: String, current: String) -> CGFloat {
        let activity: Set<String> = ["tool", "reasoning"]
        if activity.contains(previous), activity.contains(current) { return 4 }
        if previous == "reasoning" || previous == "tool" || current == "reasoning" || current == "tool" { return 12 }
        return 22
    }

    private func conversationSubtitle(_ conversation: ChatConversation) -> String {
        let project = URL(fileURLWithPath: conversation.projectPath).lastPathComponent
        let model = conversation.model.trimmingCharacters(in: .whitespaces)
        return [project, conversation.provider.title, model.isEmpty ? nil : model].compactMap { $0 }.joined(separator: " · ")
    }

    private func approvalsPanel(_ approvals: [ChatApproval], conversationID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approvals) { approval in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: approval.questions.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill")
                            .foregroundStyle(JackPalette.amber)
                        Text(approval.questions.isEmpty ? "El agente necesita tu permiso" : "El agente tiene preguntas")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.amber)
                        Spacer()
                    }
                    if !approval.questions.isEmpty {
                        ChatQuestionForm(approval: approval) { answers in
                            store.answer(conversationID: conversationID, approvalID: approval.id, answers: answers)
                        }
                    } else {
                        Text(approval.title).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                        if !approval.detail.isEmpty {
                            Text(approval.detail.count > 4_000 ? approval.detail.prefix(4_000) + "\n…" : approval.detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(JackPalette.secondaryText)
                                .textSelection(.enabled)
                                .lineLimit(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: 7))
                        }
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Rechazar") { store.respond(conversationID: conversationID, approvalID: approval.id, allow: false) }
                                .keyboardShortcut(.escape, modifiers: [])
                                .help("Rechazar (Esc)")
                            Button("Permitir") { store.respond(conversationID: conversationID, approvalID: approval.id, allow: true) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: .command)
                                .help("Permitir (⌘↩)")
                        }
                        .controlSize(.regular)
                    }
                }
                .padding(12)
                .background(JackPalette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.amber.opacity(0.35), lineWidth: 1))
            }
        }
        .frame(maxWidth: 820).frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.bottom, 10)
    }

    private func composer(_ conversation: ChatConversation) -> some View {
        let status = store.statuses[conversation.id] ?? .idle
        let busy = status.isActive
        let draft = drafts[conversation.id] ?? ""
        let attached = attachments[conversation.id] ?? []
        let canSend = !busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty)
        return VStack(alignment: .leading, spacing: 4) {
            if !attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attached, id: \.self) { path in
                            AttachmentChip(path: path) { attachments[conversation.id]?.removeAll { $0 == path } }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 8)
            }
            ZStack(alignment: .topLeading) {
                // Invisible copy of the draft sizes the editor to its content.
                Text(draft.isEmpty ? " " : draft + " ")
                    .font(.system(size: 13))
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)
                    .accessibilityHidden(true)
                if draft.isEmpty {
                    Text(busy ? "\(conversation.provider.title) está trabajando…" : "Escribe a \(conversation.provider.title)…")
                        .font(.system(size: 13))
                        .foregroundStyle(JackPalette.faint)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: draftBinding(for: conversation.id))
                    .font(.system(size: 13))
                    .focused($composerFocused)
                    .scrollContentBackground(.hidden)
                    .modifier(DisableWritingTools())
                    .accessibilityLabel("Mensaje")
                    .help("Enter para enviar · Shift+Enter para un salto de línea")
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        // Enter completes a partly typed command; once the name is complete it sends.
                        if let query = commandQuery(for: conversation), let command = selectedCommand(for: conversation), command.name != query {
                            complete(command, in: conversation)
                            return .handled
                        }
                        sendDraft(in: conversation)
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                        guard commandQuery(for: conversation) != nil else { return .ignored }
                        let count = CommandSuggestions.matches(store.commands(for: conversation) ?? [], query: commandQuery(for: conversation) ?? "").count
                        switch press.key {
                        case .upArrow: commandSelection = max(0, min(commandSelection, count - 1) - 1)
                        case .downArrow: commandSelection = min(max(0, count - 1), commandSelection + 1)
                        case .tab:
                            guard let command = selectedCommand(for: conversation) else { return .ignored }
                            complete(command, in: conversation)
                        default: dismissedCommandDraft = drafts[conversation.id]
                        }
                        return .handled
                    }
            }
            .frame(minHeight: 20, maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6).padding(.top, 9)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ContextLogoButton(store: store, conversation: conversation, busy: busy)
                    ChatModelPicker(store: store, conversation: conversation, busy: busy)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
                Spacer()
                Button {
                    attach(AttachmentDrop.choose(from: conversation.projectPath), to: conversation.id)
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                .help("Adjuntar archivos (también puedes arrastrarlos al chat)")
                .accessibilityLabel("Adjuntar archivos")
                if status == .queued {
                    Text(store.maxConcurrent == 0 ? "En cola" : "En cola · máximo \(store.maxConcurrent) a la vez")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                }
                if busy {
                    Button { store.stop(conversation.id) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(JackPalette.panelStrong, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Detener (⌘.)")
                    .accessibilityLabel("Detener")
                } else {
                    Button { sendDraft(in: conversation) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : JackPalette.faint)
                            .frame(width: 26, height: 26)
                            .background(canSend ? JackPalette.accent : JackPalette.panelStrong, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Enviar (Enter)")
                    .accessibilityLabel("Enviar")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(JackPalette.composer, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 1))
        .frame(maxWidth: 820).frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.top, 6).padding(.bottom, 14)
        .background(JackPalette.canvas)
    }

    /// The command name being typed, while the draft is just `/name` with no arguments yet.
    private func commandQuery(for conversation: ChatConversation) -> String? {
        let draft = drafts[conversation.id] ?? ""
        guard draft.hasPrefix("/"), draft != dismissedCommandDraft, !draft.contains(where: \.isWhitespace), !isActive(conversation) else { return nil }
        let name = String(draft.dropFirst())
        return name.contains("/") ? nil : name
    }

    private func selectedCommand(for conversation: ChatConversation) -> ChatCommand? {
        let matches = CommandSuggestions.matches(store.commands(for: conversation) ?? [], query: commandQuery(for: conversation) ?? "")
        return matches.isEmpty ? nil : matches[min(commandSelection, matches.count - 1)]
    }

    private func complete(_ command: ChatCommand, in conversation: ChatConversation) {
        drafts[conversation.id] = "/\(command.name) "
        commandSelection = 0
        composerFocused = true
    }

    private func draftBinding(for id: UUID) -> Binding<String> {
        Binding(get: { drafts[id, default: ""] }, set: { drafts[id] = $0 })
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JackPalette.red)
            Text(text).font(.system(size: 11)).foregroundStyle(JackPalette.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9).background(JackPalette.red.opacity(0.08))
    }

    private func sendDraft(in conversation: ChatConversation) {
        let text = (drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments[conversation.id] ?? []
        guard !text.isEmpty || !files.isEmpty, !isActive(conversation) else { return }
        if store.selectedID != conversation.id { store.select(conversation.id) }
        store.send(text, attachments: files)
        drafts[conversation.id] = ""
        attachments[conversation.id] = nil
    }

    /// The panel appears at once: animating its width would relayout the chat and the terminal on every frame.
    private func toggleWorkspace(_ tool: WorkspaceTool) {
        withoutAnimation {
            if showingWorkspace && workspaceTool == tool { showingWorkspace = false }
            else { workspaceTool = tool; showingWorkspace = true }
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    private func attach(_ paths: [String], to id: UUID) {
        guard !paths.isEmpty else { return }
        var current = attachments[id] ?? []
        for path in paths where !current.contains(path) { current.append(path) }
        attachments[id] = current
        composerFocused = true
    }

    private func send(_ text: String, in conversation: ChatConversation) {
        guard !isActive(conversation) else { return }
        if store.selectedID != conversation.id { store.select(conversation.id) }
        store.send(text)
    }

    private func isActive(_ conversation: ChatConversation) -> Bool {
        let status = store.statuses[conversation.id] ?? .idle
        return status == .running || status == .waiting || status == .queued
    }

    private func openNewConversation(provider: ChatProvider? = nil, space: String? = nil) {
        pendingProvider = provider
        pendingSpace = space
        showingNewConversation = true
    }

    private func createAgent(_ request: NewAgentRequest) {
        let previous = store.selectedID
        store.create(projectPath: request.projectPath, provider: request.provider, model: request.model.isEmpty ? nil : request.model, effort: request.effort)
        guard store.selectedID != previous, let id = store.selectedID else { return }
        if request.firstMessage.isEmpty {
            composerFocused = true
        } else if let conversation = store.conversations.first(where: { $0.id == id }) {
            send(request.firstMessage, in: conversation)
        }
    }

    /// Project folders, most recently used first.
    private var recentSpaces: [String] {
        var seen = Set<String>()
        var paths = store.conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.projectPath)
        if let last = UserDefaults.standard.string(forKey: "lastProjectPath") { paths.append(last) }
        return paths.filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
    }

    // MARK: Keyboard navigation

    private var actions: JackActions {
        JackActions(
            newAgent: { openNewConversation() },
            move: moveSelection,
            selectIndex: { index in
                let ids = navigationOrder(includeFolded: false)
                if ids.indices.contains(index) { store.select(ids[index]) }
            },
            nextAttention: selectNextAttention,
            focusComposer: { composerFocused = true },
            focusSearch: { searchRequest += 1 },
            toggleUnread: {
                guard let conversation = selectedConversation else { return }
                store.setUnread(conversation.id, conversation.hasUnread != true)
            },
            toggleTerminal: { toggleWorkspace(.terminal) },
            toggleBrowser: { toggleWorkspace(.browser) },
            hasSelection: selectedConversation != nil,
            agentCount: store.conversations.count
        )
    }

    private func navigationOrder(includeFolded: Bool) -> [UUID] {
        SidebarSections(rows: sidebarRows, projectPaths: Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.projectPath) }))
            .visibleIDs(collapsed: includeFolded ? [] : SidebarSections.collapsed(collapsedSpacesValue))
    }

    private func moveSelection(_ delta: Int) {
        let ids = navigationOrder(includeFolded: false)
        guard !ids.isEmpty else { return }
        guard let current = store.selectedID, let index = ids.firstIndex(of: current) else {
            store.select(delta > 0 ? ids[0] : ids[ids.count - 1]); return
        }
        store.select(ids[min(max(index + delta, 0), ids.count - 1)])
    }

    /// Cycles through agents waiting for permission first, then unread ones, folded spaces included.
    private func selectNextAttention() {
        let ids = navigationOrder(includeFolded: true)
        let unread = Set(store.conversations.filter { $0.hasUnread == true }.map(\.id))
        let waiting = ids.filter { store.statuses[$0] == .waiting }
        let candidates = waiting.isEmpty ? ids.filter { unread.contains($0) } : waiting
        guard !candidates.isEmpty else { NSSound.beep(); return }
        let currentIndex = store.selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = candidates.first { (ids.firstIndex(of: $0) ?? 0) > currentIndex } ?? candidates[0]
        store.select(next)
    }

    private func beginRename(_ conversation: ChatConversation) {
        guard !isActive(conversation) else { return }
        renameText = conversation.title
        renamingConversation = conversation
    }
}

private struct ChatQuestionForm: View {
    let approval: ChatApproval
    let onAnswer: ([String: String]) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(approval.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.system(size: 12, weight: .medium))
                    if let options = question.options, !options.isEmpty {
                        ForEach(options, id: \.label) { option in
                            Button {
                                answers[question.id] = option.label
                            } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: answers[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        Text(option.description).foregroundStyle(JackPalette.muted)
                                    }
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    let binding = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                    if question.isSecret == true {
                        SecureField("Respuesta", text: binding).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Escribe tu respuesta", text: binding).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Enviar respuestas") { onAnswer(answers) }
                    .buttonStyle(.borderedProminent).tint(JackPalette.accent)
                    .disabled(approval.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
    }
}

private struct DisableWritingTools: ViewModifier {
    func body(content: Content) -> some View {
        content.writingToolsBehavior(.disabled)
    }
}


func providerGlyph(_ provider: ChatProvider, size: CGFloat = 25) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(JackPalette.accent.opacity(0.13)).frame(width: size, height: size)
        Image(systemName: providerSymbol(provider)).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(JackPalette.accent)
    }.accessibilityHidden(true)
}

func providerSymbol(_ provider: ChatProvider) -> String {
    switch provider { case .codex: "chevron.left.forwardslash.chevron.right"; case .claude: "sparkle"; case .opencode: "terminal" }
}

private struct EmptyChatView: View {
    let spaces: [String]
    let agentCount: Int
    let attentionCount: Int
    let onNew: (String?, ChatProvider?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text(agentCount == 0 ? "Bienvenido a Jack" : "Elige un agente").font(.system(size: 24, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(JackPalette.muted)
            }

            if !spaces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Empezar en un space")
                    VStack(spacing: 0) {
                        ForEach(Array(spaces.enumerated()), id: \.element) { index, path in
                            if index > 0 { Divider().padding(.leading, 40) }
                            Button { onNew(path, nil) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundStyle(JackPalette.accent).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13, weight: .medium))
                                        Text((path as NSString).abbreviatingWithTildeInPath)
                                            .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.faint)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Nuevo agente con")
                HStack(spacing: 8) {
                    ForEach(ChatProvider.allCases) { provider in
                        Button { onNew(nil, provider) } label: {
                            HStack(spacing: 8) {
                                providerGlyph(provider, size: 22)
                                Text(provider.title).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity)
                            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 18) {
                shortcut("⌘N", "Nuevo agente")
                shortcut("⌥⌘↓", "Siguiente")
                shortcut("⇧⌘A", "Atención")
                shortcut("⌘F", "Buscar")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JackPalette.canvas)
    }

    private var subtitle: String {
        if agentCount == 0 { return "Crea un agente en la carpeta de un proyecto para empezar." }
        if attentionCount > 0 { return attentionCount == 1 ? "Un agente espera tu permiso en la barra lateral." : "\(attentionCount) agentes esperan tu permiso en la barra lateral." }
        return "Selecciona uno en la barra lateral o crea otro."
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(JackPalette.muted)
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

private struct ConversationWelcome: View {
    let conversation: ChatConversation
    let onPrompt: (String) -> Void
    private let suggestions: [(symbol: String, text: String)] = [
        ("doc.text.magnifyingglass", "Resume este proyecto"),
        ("arrow.triangle.branch", "Revisa los cambios recientes"),
        ("list.bullet.clipboard", "Ayúdame a planificar el siguiente paso"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                providerGlyph(conversation.provider, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿Qué hacemos hoy?").font(.system(size: 22, weight: .semibold))
                    Text("\(conversation.provider.title) está listo en \(URL(fileURLWithPath: conversation.projectPath).lastPathComponent).")
                        .font(.system(size: 13)).foregroundStyle(JackPalette.muted)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    if index > 0 { Divider().padding(.leading, 40) }
                    Button { onPrompt(suggestion.text) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: suggestion.symbol).foregroundStyle(JackPalette.accent).frame(width: 18)
                            Text(suggestion.text).font(.system(size: 13))
                            Spacer()
                            Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(JackPalette.faint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
