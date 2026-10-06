import JackCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var store: ChatStore
    @State private var drafts: [UUID: String] = [:]
    @State private var historyIndices: [UUID: Int] = [:]
    @State private var historyDrafts: [UUID: String] = [:]
    /// The conversation whose side-question card is waiting for a question typed in it.
    @State private var composingAside: UUID?
    @State private var attachments: [UUID: [String]] = [:]
    @State private var dropTargeted = false
    /// Held as plain state: only the panes observe it, so tabs opening never re-render the chat.
    @State private var workspace = WorkspaceSessions()
    @State private var workspaceVisible = false
    @AppStorage("explorerVisible") private var explorerVisible = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("openTabs") private var openTabsValue = ""
    @AppStorage("transcriptMonospaced") private var monospaced = true
    @State private var visibleMessageCounts: [UUID: Int] = [:]
    /// The chat follows the agent until the user scrolls up, and again once they return to the end.
    @State private var following = true
    @State private var showingNewConversation = false
    @State private var pendingProvider: ChatProvider?
    @State private var pendingSpace: String?
    @State private var searchRequest = 0
    @FocusState private var composerFocused: Bool
    @AppStorage("collapsedSpaces") private var collapsedSpacesValue = ""
    @State private var renamingConversation: ChatConversation?
    @State private var renameText = ""
    @State private var deletingConversation: ChatConversation?
    @State private var showingSessionPicker = false
    @State private var commandSelection = 0
    /// Draft for which the user closed the command list with Esc.
    @State private var dismissedCommandDraft: String?
    /// The image request open in Image Playground.
    @State private var playgroundRequest: ChatImageRequest?

    private var selectedConversation: ChatConversation? { store.selectedConversation }

    var body: some View {
        let conversation = selectedConversation
        VStack(spacing: 0) {
            PaneSplit(.leading, visible: sidebarVisible, widthKey: "sidebarWidth", defaultWidth: 264, range: 210...400, flexibleMinimum: 440) {
                JackSidebar(
                    rows: sidebarRows,
                    projectPaths: Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.projectPath) }),
                    selectedID: store.selectedID,
                    onNewConversation: { space in openNewConversation(space: space) },
                    onSelect: store.select,
                    onRename: { id in store.conversations.first { $0.id == id }.map(beginRename) },
                    onDelete: { id in deletingConversation = store.conversations.first { $0.id == id } },
                    onSetUnread: store.setUnread,
                    onContinueInTerminal: continueInTerminal,
                    onReloadFromClaude: reloadFromClaude,
                    onHide: toggleSidebar,
                    searchRequest: searchRequest
                )
            } trailing: {
                PaneSplit(.trailing, visible: explorerVisible && conversation != nil, widthKey: "explorerWidth", defaultWidth: 250,
                          range: 180...440, flexibleMinimum: 380) {
                    PaneSplit(.trailing, visible: workspaceVisible && conversation != nil, widthKey: "workspaceWidth", defaultWidth: 500,
                              range: 300...1200, flexibleMinimum: 340) {
                        centerColumn
                    } trailing: {
                        if let conversation {
                            WorkspacePane(sessions: workspace, conversationID: conversation.id, projectPath: conversation.projectPath,
                                          onClose: { withoutAnimation { workspaceVisible = false }; composerFocused = true })
                                .equatable()
                        }
                    }
                } trailing: {
                    if let conversation {
                        FileExplorer(model: workspace.explorer(for: conversation.projectPath),
                                     onAttach: { attach([$0], to: conversation.id) },
                                     onClose: { withoutAnimation { explorerVisible = false } })
                            .equatable()
                    }
                }
            }
            StatusBar(usage: store.usage, refreshing: store.refreshingUsage, activeCount: store.activeCount, maxConcurrent: store.maxConcurrent,
                      sessions: workspace, progress: store.progress, servers: store.servers, refresh: { Task { await store.refreshUsage() } }, setConcurrency: store.setConcurrency,
                      conversationTitle: { id in store.conversations.first { $0.id == id }?.title },
                      openConversation: store.select)
                .equatable()
        }
        .background(WindowChrome())
        .background(JackPalette.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: store.conversations.map(\.id)) { _, ids in
            workspace.prune(keeping: Set(ids))
            let open = openTabIDs.filter(Set(ids).contains)
            if open != openTabIDs { openTabsValue = OpenTabs.encode(open) }
        }
        .onChange(of: store.selectedID, initial: true) { previous, id in
            guard let id else { return }
            let open = OpenTabs.opening(id, in: openTabIDs, after: previous)
            if open != openTabIDs { openTabsValue = OpenTabs.encode(open) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in workspace.terminateAll() }
        .onChange(of: store.imageRequests.filter(\.isPending).count) { before, now in
            // An agent is waiting for an image while the user is elsewhere: bounce the Dock icon once.
            if now > before, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        .onAppear { workspace.attach = { id, paths in attach(paths, to: id) } }
        .focusedSceneValue(\.jackActions, actions)
        .sheet(isPresented: $showingNewConversation) {
            NewAgentSheet(
                spaces: recentSpaces,
                initialSpace: pendingSpace,
                initialProvider: pendingProvider,
                modelChoices: store.modelChoices(for:)
            ) { request in
                createAgent(request)
                showingNewConversation = false
            } onCancel: {
                showingNewConversation = false
            }
        }
        .sheet(isPresented: $showingSessionPicker) {
            ClaudeSessionPicker(imported: Set(store.conversations.compactMap { $0.provider == .claude ? $0.sessionID : nil })) { session in
                showingSessionPicker = false
                resumeClaudeSession(session)
            } onCancel: { showingSessionPicker = false }
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

    private var centerColumn: some View {
        VStack(spacing: 0) {
            AgentTabStrip(tabs: tabModels, selectedID: store.selectedID, sidebarVisible: sidebarVisible,
                          onSelect: store.select, onClose: closeTab, onNew: { openNewConversation() }, onShowSidebar: toggleSidebar)
                .equatable()
                .overlay(alignment: .trailing) {
                    WorkspaceToggles(sessions: workspace, conversationID: store.selectedID, paneVisible: workspaceVisible,
                                     explorerVisible: explorerVisible, onToggle: toggleWorkspace, onToggleExplorer: toggleExplorer)
                        .equatable()
                }
            conversationPanel
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private var openTabIDs: [UUID] { OpenTabs.decode(openTabsValue) }

    private var tabModels: [AgentTabModel] {
        let byID = Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0) })
        return openTabIDs.compactMap { id in
            byID[id].map { AgentTabModel(id: id, title: $0.title, provider: $0.provider, status: store.statuses[id] ?? .idle, unread: $0.hasUnread == true) }
        }
    }

    /// Closing the selected tab moves to its neighbour, as in a browser.
    private func closeTab(_ id: UUID) {
        var ids = openTabIDs
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        openTabsValue = OpenTabs.encode(ids)
        guard store.selectedID == id else { return }
        if ids.isEmpty { store.selectedID = nil } else { store.select(ids[max(0, index - 1)]) }
    }

    @ViewBuilder private var conversationPanel: some View {
        if let conversation = selectedConversation {
            conversationView(conversation)
        } else {
            VStack(spacing: 0) {
                if let error = store.errorMessage, !error.isEmpty { errorBanner(error) }
                StartView(
                    spaces: recentSpaces,
                    agentCount: store.conversations.count,
                    attentionCount: store.statuses.values.filter { $0 == .waiting }.count
                ) { path, provider, message in
                    createAgent(NewAgentRequest(projectPath: path, provider: provider, model: "", effort: "high", firstMessage: message))
                } onMoreOptions: { path, provider in
                    openNewConversation(provider: provider, space: path)
                } onResumeClaude: { showingSessionPicker = true }
            }
        }
    }

    private func conversationView(_ conversation: ChatConversation) -> some View {
        let status = store.statuses[conversation.id] ?? .idle
        return VStack(spacing: 0) {
            if let error = store.errorMessage, !error.isEmpty { errorBanner(error) }
            messageHistory(conversation)
            if let approvals = store.approvals[conversation.id], !approvals.isEmpty {
                approvalsPanel(approvals, conversation: conversation)
            }
            imageRequestsPanel(conversation)
            if isActive(conversation) {
                AgentActivityView(conversation: conversation, status: status, tokens: store.tokenUsage[conversation.id], projectPath: conversation.projectPath)
                    .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
            }
            if let waiting = store.waiting[conversation.id], !waiting.isEmpty {
                WaitingMessagesView(messages: waiting, provider: conversation.provider,
                                    readsWhileWorking: store.readsWhileWorking(conversation.id),
                                    onSendNow: { store.sendWaitingNow(conversation.id) },
                                    onEdit: { takeBack($0, from: conversation, restore: true) },
                                    onRemove: { takeBack($0, from: conversation, restore: false) })
                    .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
                    .padding(.horizontal, 22).padding(.top, 4)
            }
            ChatProgressPanel(monitor: store.progress, conversationID: conversation.id, width: Self.columnWidth)
            AsideView(asides: store.asides, conversationID: conversation.id, provider: conversation.provider,
                      composing: Binding(get: { composingAside == conversation.id }, set: { composingAside = $0 ? conversation.id : nil }),
                      onAsk: { store.askAside($0, in: conversation.id); composerFocused = true })
            if let query = commandQuery(for: conversation) {
                let matches = CommandSuggestions.matches(availableComposerCommands(conversation), query: query)
                CommandSuggestions(commands: matches, prefix: commandPrefix(conversation), loading: store.isLoadingCommands(for: conversation),
                                   error: commandPrefix(conversation) == "/" ? store.commandError(for: conversation) : nil,
                                   onRetry: { store.loadCommands(for: conversation) },
                                   selection: min(commandSelection, max(0, matches.count - 1))) { complete($0, in: conversation) }
                    .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .onAppear { store.loadCommands(for: conversation) }
                    .onChange(of: query) { _, _ in commandSelection = 0 }
            }
            composer(conversation)
        }
        .onChange(of: store.recalled[conversation.id]) { _, message in
            guard let message else { return }
            restore(message, to: conversation.id)
            store.clearRecalled(conversation.id)
        }
        .background(JackPalette.canvas)
        .onDrop(of: AttachmentDrop.types, isTargeted: $dropTargeted) { providers in
            AttachmentDrop.load(providers) { attach($0, to: conversation.id) }
            return true
        }
        .overlay { if dropTargeted { AttachmentDropOverlay() } }
        .modifier(ImagePlaygroundPresenter(request: $playgroundRequest, onFinish: finishImage))
        .onChange(of: store.imageRequests.first { $0.conversationID == conversation.id && $0.isPending }?.id, initial: true) { _, id in
            // Opens Image Playground as soon as the agent asks, if the user is looking at this chat.
            guard let id, playgroundRequest == nil, NSApp.isActive, let request = store.imageRequest(id) else { return }
            playgroundRequest = request
        }
        .onChange(of: status.isActive) { wasActive, active in
            // The agent may have changed files: refresh the tree once its turn ends.
            if wasActive, !active, explorerVisible { workspace.explorer(for: conversation.projectPath).refresh() }
        }
    }

    private func messageHistory(_ conversation: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if conversation.messages.isEmpty {
                        // Only on an empty chat: any row above the messages kept the bottom-anchored lazy stack
                        // from drawing the rows in view.
                        ConversationHeader(conversation: conversation).equatable()
                        ConversationWelcome(conversation: conversation) { text in send(text, in: conversation) }
                            .padding(.top, 40)
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
                                topSpacing: index == start ? 0 : rowSpacing(previous: conversation.messages[index - 1].role, current: message.role),
                                monospaced: monospaced
                            )
                            .equatable()
                            .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 18).padding(.bottom, 20)
            }
            .defaultScrollAnchor(.bottom)
            // Only the follow flag crosses into view state, and only when it flips, so scrolling does not re-render the chat.
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                ChatScrollMetrics(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                                  visible: geometry.containerSize.height,
                                  distanceToBottom: geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { old, new in
                var follow = following
                if new.distanceToBottom < 24 {
                    follow = true
                } else if new.offset < old.offset - 0.5, new.content >= old.content - 0.5, new.visible == old.visible {
                    // Moving up without the content shrinking is the user scrolling back.
                    follow = false
                }
                if follow != following { following = follow }
                if follow, new.distanceToBottom > 0.5, new.content != old.content || new.visible != old.visible {
                    // New text, a tool row or a panel below the chat: stay on the agent's last line.
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.id) { _, _ in
                following = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // A second scroll after the first layout makes the lazy list create the rows in view.
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                ZStack {
                    if !following {
                        Button {
                            following = true
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        } label: {
                            Label("Volver a la conversación", systemImage: "arrow.down")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(JackPalette.panelStrong, in: Capsule())
                                .overlay(Capsule().strokeBorder(JackPalette.hairline))
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: following)
            }
        }
    }

    private static let bottomID = "jack-chat-bottom"
    /// Widest line of the transcript and composer; wider lines are hard to read.
    static let columnWidth: CGFloat = 900

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
        if activity.contains(previous), activity.contains(current) { return 3 }
        if previous == "reasoning" || previous == "tool" || current == "reasoning" || current == "tool" { return 10 }
        return 16
    }

    @ViewBuilder private func imageRequestsPanel(_ conversation: ChatConversation) -> some View {
        let requests = store.imageRequests.filter { $0.conversationID == conversation.id }
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(requests) { request in
                    ImageRequestCard(request: request, projectPath: conversation.projectPath,
                                     onCreate: { playgroundRequest = request },
                                     onDecline: { store.resolveImage(request.id, .declined) },
                                     onDismiss: { store.dismissImage(request.id) })
                }
            }
            .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.bottom, 10)
        }
    }

    /// Saves what the user created where the agent asked, and tells the agent how it went.
    private func finishImage(_ request: ChatImageRequest, _ url: URL?) {
        guard let url else { store.resolveImage(request.id, .cancelled); return }
        do {
            let size = try ImagePlaygroundSupport.save(url, to: request.destination)
            store.resolveImage(request.id, .saved(path: request.destination.path, width: size.width, height: size.height))
        } catch {
            store.resolveImage(request.id, .failed(error.localizedDescription))
        }
    }

    private func approvalsPanel(_ approvals: [ChatApproval], conversation: ChatConversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approvals) { approval in
                ApprovalCard(approval: approval, provider: conversation.provider, projectPath: conversation.projectPath,
                             repliesInChat: store.canSend(to: conversation.id) && store.statuses[conversation.id]?.isActive == true,
                             // ⌘↩ belongs to the composer while it holds a message: it interrupts and sends it.
                             shortcutsEnabled: (drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             onRespond: { choice, message in store.respond(conversationID: conversation.id, approvalID: approval.id, choice: choice, message: message) },
                             onAnswer: { answers in store.answer(conversationID: conversation.id, approvalID: approval.id, answers: answers) })
            }
        }
        .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.bottom, 10)
    }

    private func composer(_ conversation: ChatConversation) -> some View {
        let status = store.statuses[conversation.id] ?? .idle
        let busy = status.isActive
        let draft = drafts[conversation.id] ?? ""
        let attached = attachments[conversation.id] ?? []
        // Claude Code takes messages while it works, as in its terminal.
        let steerable = busy && store.canSend(to: conversation.id)
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty
        let canSend = (!busy || steerable) && hasContent
        let design: Font.Design = monospaced ? .monospaced : .default
        let textSize: CGFloat = monospaced ? 12.5 : 13
        return VStack(alignment: .leading, spacing: 6) {
            if !attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attached, id: \.self) { path in
                            AttachmentChip(path: path) { attachments[conversation.id]?.removeAll { $0 == path } }
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text("›").font(.system(size: textSize + 2, weight: .bold, design: .monospaced))
                    .foregroundStyle(busy && !steerable ? JackPalette.faint : JackPalette.accent)
                ZStack(alignment: .topLeading) {
                    // Invisible copy of the draft sizes the editor to its content.
                    Text(draft.isEmpty ? " " : draft + " ")
                        .font(.system(size: textSize, design: design))
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(0)
                        .accessibilityHidden(true)
                    if draft.isEmpty {
                        if !busy, conversation.provider == .claude, let suggestion = store.suggestions[conversation.id] {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(suggestion).foregroundStyle(JackPalette.faint)
                                Text("Tab").font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(JackPalette.faint.opacity(0.7))
                            }
                            .font(.system(size: textSize, design: design))
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                        } else {
                            Text(placeholder(conversation, status: status, steerable: steerable))
                                .font(.system(size: textSize, design: design))
                                .foregroundStyle(JackPalette.faint)
                                .padding(.horizontal, 5)
                                .allowsHitTesting(false)
                        }
                    }
                TextEditor(text: draftBinding(for: conversation.id))
                    .font(.system(size: textSize, design: design))
                    .focused($composerFocused)
                    .scrollContentBackground(.hidden)
                    .modifier(DisableWritingTools())
                    .accessibilityLabel("Mensaje")
                    .help("Enter para enviar · Shift+Enter para un salto de línea · ⌥Enter para preguntar al margen")
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        // ⌥↩ asks on the side, like /btw in Claude Code: the agent keeps working and its history stays as is.
                        if press.modifiers.contains(.option), !press.modifiers.contains(.command) {
                            askAside(in: conversation)
                            return .handled
                        }
                        // ⌘↩ interrupts the agent so it reads the message now, instead of after its current step.
                        if press.modifiers.contains(.command) {
                            if hasContent { sendDraft(in: conversation, interrupting: true); return .handled }
                            guard store.waiting[conversation.id]?.isEmpty == false else { return .ignored }
                            store.sendWaitingNow(conversation.id)
                            return .handled
                        }
                        // Enter completes a partly typed command; once the name is complete it sends.
                        if let query = commandQuery(for: conversation), let command = selectedCommand(for: conversation), command.name != query {
                            complete(command, in: conversation)
                            return .handled
                        }
                        sendDraft(in: conversation)
                        return .handled
                    }
                    .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                        // Shift+Tab cycles Claude Code's permission modes, as in its terminal.
                        guard press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}"), conversation.provider == .claude,
                              commandQuery(for: conversation) == nil else { return .ignored }
                        store.cycleMode(conversation.id)
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                        if let query = commandQuery(for: conversation) {
                            let count = CommandSuggestions.matches(availableComposerCommands(conversation), query: query).count
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
                        if press.modifiers.isEmpty, (press.key == .upArrow || press.key == .downArrow) {
                            return navigateHistory(press.key, in: conversation) ? .handled : .ignored
                        }
                        if press.key == .tab, press.modifiers.isEmpty, draft.isEmpty,
                           conversation.provider == .claude, !busy,
                           let suggestion = store.suggestions[conversation.id] {
                            drafts[conversation.id] = suggestion
                            store.clearSuggestion(conversation.id)
                            return .handled
                        }
                        if press.key == .escape, store.asides.items[conversation.id] != nil {
                            store.asides.dismiss(conversation.id)
                            return .handled
                        }
                        return .ignored
                    }
                }
                .frame(minHeight: 18, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ContextLogoButton(store: store, conversation: conversation, busy: busy)
                    ChatModelPicker(store: store, conversation: conversation, busy: busy)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
                Spacer()
                if let parent = conversation.parentID.flatMap({ id in store.conversations.first { $0.id == id } }) {
                    Button { store.select(parent.id) } label: {
                        Label("Delegado por \(parent.title)", systemImage: "arrow.turn.left.up")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.accent)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help("Ir al agente que delegó esta tarea")
                }
                if status == .queued {
                    Text(store.maxConcurrent == 0 ? "En cola" : "En cola · máximo \(store.maxConcurrent) a la vez")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                }
                AgentFoldersButton(store: store, conversation: conversation)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    .frame(width: 24, height: 24)
                Button {
                    // With a message written it is asked as is, like ⌥↩; otherwise the card asks for one.
                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { askAside(in: conversation) }
                    else { composingAside = conversation.id }
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                .help("Preguntar al margen sin interrumpir al agente ni entrar en su historial (⌥↩)")
                .accessibilityLabel("Preguntar al margen")
                Button {
                    attach(AttachmentDrop.choose(from: conversation.projectPath), to: conversation.id)
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 12.5, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                .help("Adjuntar archivos (también puedes arrastrarlos al chat)")
                .accessibilityLabel("Adjuntar archivos")
                if busy {
                    Button { store.stop(conversation.id) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Detener (⌘.)")
                    .accessibilityLabel("Detener")
                }
                if !busy || (steerable && hasContent) {
                    Button { sendDraft(in: conversation) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : JackPalette.faint)
                            .frame(width: 24, height: 24)
                            .background(canSend ? JackPalette.accent : JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(busy ? "Poner en espera hasta que lo lea (Enter) · Interrumpir y enviar (⌘Enter)" : "Enviar (Enter)")
                    .accessibilityLabel("Enviar")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(composerFocused ? JackPalette.accent.opacity(0.45) : JackPalette.hairline, lineWidth: 1))
        .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
        .background(JackPalette.canvas)
    }

    /// The command name being typed, while the draft is just `/name` with no arguments yet.
    private func commandQuery(for conversation: ChatConversation) -> String? {
        let draft = drafts[conversation.id] ?? ""
        guard (draft.hasPrefix("/") || draft.hasPrefix("!")), draft != dismissedCommandDraft, !draft.contains(where: \.isWhitespace), !isActive(conversation) else { return nil }
        let name = String(draft.dropFirst())
        return name.contains("/") || name.contains("!") ? nil : name
    }

    private func commandPrefix(_ conversation: ChatConversation) -> String {
        (drafts[conversation.id] ?? "").hasPrefix("!") ? "!" : "/"
    }
    private func availableComposerCommands(_ conversation: ChatConversation) -> [ChatCommand] {
        commandPrefix(conversation) == "!" ? store.jackCommands : (store.commands(for: conversation) ?? [])
    }

    private func selectedCommand(for conversation: ChatConversation) -> ChatCommand? {
        let matches = CommandSuggestions.matches(availableComposerCommands(conversation), query: commandQuery(for: conversation) ?? "")
        return matches.isEmpty ? nil : matches[min(commandSelection, matches.count - 1)]
    }

    private func complete(_ command: ChatCommand, in conversation: ChatConversation) {
        drafts[conversation.id] = "\(commandPrefix(conversation))\(command.name) "
        resetHistory(for: conversation.id)
        commandSelection = 0
        composerFocused = true
    }

    private func draftBinding(for id: UUID) -> Binding<String> {
        Binding(get: { drafts[id, default: ""] }, set: { value in
            // Only typing leaves history navigation; the editor echoing the same text back does not.
            guard value != drafts[id, default: ""] else { return }
            drafts[id] = value
            resetHistory(for: id)
        })
    }

    private func navigateHistory(_ key: KeyEquivalent, in conversation: ChatConversation) -> Bool {
        let id = conversation.id
        let messages = conversation.messages.reversed().compactMap { message -> String? in
            guard message.role == "user" else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : message.text
        }
        var history: [String] = []
        for message in messages where history.last?.trimmingCharacters(in: .whitespacesAndNewlines) != message.trimmingCharacters(in: .whitespacesAndNewlines) {
            history.append(message)
        }
        let draft = drafts[id] ?? ""
        if key == .upArrow {
            if let index = historyIndices[id] {
                guard index + 1 < history.count, draft == history[index] else { return false }
                historyIndices[id] = index + 1
                drafts[id] = history[index + 1]
            } else {
                guard draft.isEmpty, let first = history.first else { return false }
                historyDrafts[id] = draft
                historyIndices[id] = 0
                drafts[id] = first
            }
            return true
        }
        guard let index = historyIndices[id], draft == history[index] else { return false }
        if index == 0 {
            drafts[id] = historyDrafts.removeValue(forKey: id) ?? ""
            historyIndices.removeValue(forKey: id)
        } else {
            historyIndices[id] = index - 1
            drafts[id] = history[index - 1]
        }
        return true
    }

    private func resetHistory(for id: UUID) {
        historyIndices.removeValue(forKey: id)
        historyDrafts.removeValue(forKey: id)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JackPalette.red)
            Text(text).font(.system(size: 11)).foregroundStyle(JackPalette.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9).background(JackPalette.red.opacity(0.08))
    }

    private func placeholder(_ conversation: ChatConversation, status: ChatStatus, steerable: Bool) -> String {
        let name = conversation.provider.title
        guard status.isActive else { return "Escribe a \(name)…  ! Jack · / proveedor" }
        guard steerable else { return "\(name) está trabajando…" }
        if status == .waiting, store.readsWhileWorking(conversation.id), store.approvals[conversation.id]?.contains(where: { $0.questions.isEmpty }) == true {
            return "Escribe para rechazar y decirle qué hacer en su lugar…"
        }
        return store.readsWhileWorking(conversation.id)
            ? "\(name) está trabajando · lo leerá al terminar el paso · ⌘↩ interrumpe"
            : "\(name) está trabajando · se enviará al terminar · ⌘↩ interrumpe"
    }

    private func sendDraft(in conversation: ChatConversation, interrupting: Bool = false) {
        let text = (drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments[conversation.id] ?? []
        guard !text.isEmpty || !files.isEmpty, store.canSend(to: conversation.id) else { return }
        if store.selectedID != conversation.id { store.select(conversation.id) }
        store.errorMessage = nil
        store.send(text, attachments: files, to: conversation.id, interrupting: interrupting)
        guard store.errorMessage == nil else { return }
        drafts[conversation.id] = ""
        resetHistory(for: conversation.id)
        attachments[conversation.id] = nil
    }

    private func askAside(in conversation: ChatConversation) {
        var text = (drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // `!btw pregunta` with ⌥↩ asks the same.
        if let command = JackCommandCatalog.parse(text), command.name == "btw" { text = command.arguments }
        guard !text.isEmpty else { return }
        store.askAside(text, in: conversation.id)
        drafts[conversation.id] = ""
        resetHistory(for: conversation.id)
    }

    /// Takes a waiting message back from the agent, into the composer to edit it or away.
    private func takeBack(_ message: ChatQueuedMessage, from conversation: ChatConversation, restore: Bool) {
        Task {
            guard let taken = await store.withdraw(message.id, from: conversation.id) else {
                store.errorMessage = "\(conversation.provider.title) ya leyó ese mensaje."
                return
            }
            if restore { self.restore(taken, to: conversation.id) }
        }
    }

    /// Puts a message back in the composer, before whatever is being written.
    private func restore(_ message: ChatQueuedMessage, to id: UUID) {
        let current = drafts[id] ?? ""
        drafts[id] = [message.text, current].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var files = message.attachments
        for path in attachments[id] ?? [] where !files.contains(path) { files.append(path) }
        attachments[id] = files.isEmpty ? nil : files
        composerFocused = true
    }

    /// The panel appears at once: animating its width would relayout the chat and the terminal on every frame.
    private func toggleWorkspace(_ tool: WorkspaceTool) {
        guard let id = store.selectedID else { return }
        withoutAnimation {
            if workspaceVisible, workspace.selectedTab(for: id)?.kind == tool {
                workspaceVisible = false
                composerFocused = true
            } else {
                workspace.reveal(tool, for: id)
                workspaceVisible = true
            }
        }
    }

    private func toggleExplorer() {
        withoutAnimation { explorerVisible.toggle() }
    }

    private func toggleSidebar() {
        withoutAnimation { sidebarVisible.toggle() }
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

    private func resumeClaudeSession(_ session: ClaudeSessionSummary) {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { ClaudeSessions.load(session) }.value
            store.importClaudeSession(session, messages: loaded.messages, model: loaded.model)
            composerFocused = true
        }
    }

    /// Hands the session to `claude --resume` in the agent's terminal; Jack's own process closes first
    /// so both never write to the session at once.
    private func continueInTerminal(_ id: UUID) {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else { return }
        guard let session = conversation.sessionID, !session.isEmpty else {
            store.errorMessage = "Esta conversación aún no tiene sesión de Claude Code: envía un mensaje primero."
            return
        }
        guard store.closeSession(id) else { store.errorMessage = "Detén el agente antes de seguir en la terminal."; return }
        if store.selectedID != id { store.select(id) }
        withoutAnimation {
            let tab = workspace.open(.terminal, for: id)
            workspace.terminal(tab.id, conversation: id, directory: conversation.projectPath).type("claude --resume \(session)\r")
            workspaceVisible = true
        }
    }

    /// Rereads the session after it continued in a terminal: Claude Code's file holds every turn, Jack's and the terminal's.
    private func reloadFromClaude(_ id: UUID) {
        guard let conversation = store.conversations.first(where: { $0.id == id }), let session = conversation.sessionID else { return }
        let summary = ClaudeSessionSummary(id: session, title: conversation.title, projectPath: conversation.projectPath, updatedAt: conversation.updatedAt)
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { ClaudeSessions.load(summary) }.value
            guard !loaded.messages.isEmpty else { store.errorMessage = "No se encontró la sesión de Claude Code en esta carpeta."; return }
            store.replaceTranscript(id, messages: loaded.messages)
        }
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
            resumeClaudeSession: { showingSessionPicker = true },
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
            toggleSimulator: { toggleWorkspace(.simulator) },
            toggleExplorer: toggleExplorer,
            toggleSidebar: toggleSidebar,
            closeTab: { store.selectedID.map(closeTab) },
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

private struct DisableWritingTools: ViewModifier {
    func body(content: Content) -> some View {
        content.writingToolsBehavior(.disabled)
    }
}


/// The top of a transcript, like a CLI's banner: who the agent is, its model and its folder.
private struct ChatScrollMetrics: Equatable {
    let offset: CGFloat
    let content: CGFloat
    let visible: CGFloat
    let distanceToBottom: CGFloat
}

private struct ConversationHeader: View, Equatable {
    let conversation: ChatConversation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation.provider == rhs.conversation.provider && lhs.conversation.model == rhs.conversation.model
            && lhs.conversation.effort == rhs.conversation.effort && lhs.conversation.projectPath == rhs.conversation.projectPath
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            providerGlyph(conversation.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.provider.title).font(.mono(12.5, weight: .semibold))
                Text([conversation.model.isEmpty ? "Modelo por defecto" : conversation.model, conversation.effort].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.mono(12)).foregroundStyle(JackPalette.muted)
                Text((conversation.projectPath as NSString).abbreviatingWithTildeInPath)
                    .font(.mono(12)).foregroundStyle(JackPalette.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
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
