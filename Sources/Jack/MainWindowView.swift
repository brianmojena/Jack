import JackCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var store: ChatStore
    /// Not observed here: only the panes observe it, so tabs opening never re-render the chat.
    /// Owned by the app, so it outlives the window in battery saver.
    let workspace: WorkspaceSessions
    let memory: WindowMemory
    let batterySaver: BatterySaver
    let updateChecker: UpdateChecker
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var drafts: [UUID: String] = [:]
    @State private var historyIndices: [UUID: Int] = [:]
    @State private var historyDrafts: [UUID: String] = [:]
    /// The conversation whose side-question card is waiting for a question typed in it.
    @State private var composingAside: UUID?
    @State private var attachments: [UUID: [String]] = [:]
    /// Where the main chat and the agents opened beside it sit: columns of chats stacked one above another.
    @AppStorage("agentPaneLayout") private var paneLayoutValue = ""
    /// How many columns fit at the window's width.
    @State private var columnRoom = 4
    /// The chat shaded under a drag. Held, not observed: only the shades redraw while dragging.
    @State private var paneDrops = PaneDropState()
    @State private var workspaceVisible = false
    /// Plans of the selected agent that already had their flowchart shown, or were there when it was selected.
    @State private var seenPlans: Set<String> = []
    @AppStorage("explorerVisible") private var explorerVisible = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("openTabs") private var openTabsValue = ""
    @AppStorage("transcriptMonospaced") private var monospaced = true
    @AppStorage(InterfaceStyle.key) private var interfaceStyle = InterfaceStyle.basic
    @State private var newChatID = UUID()
    @State private var searchRequest = 0
    /// The composer being typed in: the main chat's or a pane's.
    @FocusState private var focusedComposer: UUID?
    @AppStorage("collapsedSpaces") private var collapsedSpacesValue = ""
    @AppStorage("sidebarProjectSort") private var projectSortValue = ""
    @AppStorage("sidebarProjectsAlphabetical") private var legacyAlphabeticalProjects = false
    @AppStorage("sidebarProjectOrder") private var projectOrderValue = ""
    @State private var renamingConversation: ChatConversation?
    @State private var renameText = ""
    @State private var deletingConversation: ChatConversation?
    @State private var showingSessionPicker = false
    @AppStorage(ClaudeImportSheet.offeredKey) private var claudeImportOffered = false
    /// Claude Code chats found on first launch, offered once.
    @State private var firstImport: [ClaudeSessionSummary]?
    @State private var commandSelection = 0
    /// Draft for which the user closed the command list with Esc.
    @State private var dismissedCommandDraft: String?
    /// The image request open in Image Playground.
    @State private var playgroundRequest: ChatImageRequest?

    private var selectedConversation: ChatConversation? { store.selectedConversation }
    private var importedClaudeSessions: Set<String> { Set(store.conversations.compactMap { $0.provider == .claude ? $0.sessionID : nil }) }
    private var selectedGitSession: GitSession? {
        guard !store.lightModeEnabled, let conversation = selectedConversation, conversation.remote == nil else { return nil }
        return workspace.git(for: conversation.projectPath)
    }
    private func showGitPanel() {
        guard !store.lightModeEnabled, let id = store.selectedID else { return }
        workspace.reveal(.git, for: id)
        workspaceVisible = true
    }
    private var ice: Bool { interfaceStyle == .ice }
    private var sidebarProjectSort: SidebarProjectSort {
        SidebarProjectSort.resolve(projectSortValue, legacyAlphabetical: legacyAlphabeticalProjects)
    }
    /// Identifies the plan the selected agent is putting forward, when it has steps to draw.
    private var planKey: String? {
        guard let id = store.selectedID, let offer = store.plan(for: id), PlanFlow.parse(offer.markdown) != nil else { return nil }
        return "\(id.uuidString)|\(offer.key)"
    }

    var body: some View {
        Group {
            if interfaceStyle == .terminal, !store.lightModeEnabled {
                TerminalInterfaceView(workspace: workspace.terminalInterface(), store: store,
                                      enterBatterySaver: enterBatterySaver)
            } else {
                Group { if interfaceStyle == .ice { iceLayout } else { basicLayout } }
                    .focusedSceneValue(\.jackActions, actions)
            }
        }
        .environment(\.interfaceStyle, interfaceStyle)
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: store.conversations.map(\.id)) { previous, ids in
            workspace.prune(keeping: Set(ids))
            let open = openTabIDs.filter(Set(ids).contains)
            if open != openTabIDs { openTabsValue = OpenTabs.encode(open) }
            // A sub-agent of an agent on screen opens under it by itself.
            var layout = PaneLayout(encoded: paneLayoutValue).keeping(Set(ids))
            let before = Set(previous)
            for conversation in store.conversations where !before.contains(conversation.id) {
                guard let parent = conversation.parentID else { continue }
                if parent == store.selectedID {
                    layout = layout.opening(conversation.id, under: .main)
                } else if layout.contains(parent) {
                    layout = layout.opening(conversation.id, under: .agent(parent))
                }
            }
            setLayout(layout)
        }
        .onChange(of: store.selectedID, initial: true) { previous, id in
            guard let id else { return }
            // A plan already there when the agent is selected is not news.
            if let key = planKey { seenPlans.insert(key) }
            let open = OpenTabs.opening(id, in: openTabIDs, after: previous)
            if open != openTabIDs { openTabsValue = OpenTabs.encode(open) }
            // The agent now in the main chat leaves its pane.
            let layout = PaneLayout(encoded: paneLayoutValue)
            if layout.contains(id) { setLayout(layout.removing(id)) }
        }
        // A plan put forward by the agent in the main chat draws its flowchart in the right pane.
        .onChange(of: planKey) { _, key in
            guard let key, seenPlans.insert(key).inserted, let id = store.selectedID else { return }
            withoutAnimation {
                workspace.reveal(.flow, for: id)
                workspaceVisible = true
            }
        }
        .onChange(of: paneLayoutValue, initial: true) { _, _ in store.showInPanes(paneLayout.agents) }
        .onChange(of: store.imageRequests.filter(\.isPending).count) { before, now in
            // An agent is waiting for an image while the user is elsewhere: bounce the Dock icon once.
            if now > before, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        .onAppear {
            workspace.attach = { id, paths in attach(paths, to: id) }
            workspace.sendToAgent = { id, text, files, now in sendToAgent(text, files: files, to: id, now: now) }
            if drafts.isEmpty { drafts = memory.drafts }
            if attachments.isEmpty { attachments = memory.attachments }
        }
        .onChange(of: store.lightModeEnabled) { _, light in
            if light { workspace.cancelAutomaticGitCommits(); workspace.suspendTerminalInterface() }
        }
        .onDisappear {
            workspace.cancelAutomaticGitCommits()
            memory.drafts = drafts
            memory.attachments = attachments
        }
        // Stellar Code's local models, so its cards and pickers know what is available.
        .task { if interfaceStyle != .terminal { await store.refreshLocalModels() } }
        .task {
            guard interfaceStyle != .terminal, !claudeImportOffered else { return }
            let found = await ClaudeImportSheet.find(.quarter, excluding: importedClaudeSessions)
            if found.isEmpty { claudeImportOffered = true } else { firstImport = found }
        }
        .sheet(isPresented: Binding(get: { firstImport != nil }, set: { if !$0 { firstImport = nil; claudeImportOffered = true } })) {
            ClaudeImportSheet(initial: firstImport, imported: importedClaudeSessions) { sessions in
                store.importClaudeSessions(sessions)
                firstImport = nil; claudeImportOffered = true
            } onCancel: { firstImport = nil; claudeImportOffered = true }
        }
        .sheet(isPresented: $showingSessionPicker) {
            ClaudeSessionPicker(imported: importedClaudeSessions) { session in
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

    /// Jack's own dense workspace: hidden title bar, custom strips and panes.
    private var basicLayout: some View {
        VStack(spacing: 0) {
            PaneSplit(.leading, visible: sidebarVisible, widthKey: "sidebarWidth", defaultWidth: 264, range: 210...400, flexibleMinimum: 440) {
                sidebar
            } trailing: {
                detailPanes
            }
            statusBar
        }
        .background(WindowChrome())
        .background(JackPalette.canvas)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// macOS's own Liquid Glass structure: floating sidebar, glass toolbar and the composer
    /// floating over the transcript, which scrolls beneath it.
    private var iceLayout: some View {
        let conversation = selectedConversation
        return NavigationSplitView(columnVisibility: Binding(get: { sidebarVisible ? .all : .detailOnly },
                                                             set: { sidebarVisible = $0 != .detailOnly })) {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 264, max: 400)
        } detail: {
            VStack(spacing: 0) {
                detailPanes
                statusBar
            }
            .navigationTitle(conversation?.title ?? "Jack")
            .navigationSubtitle(conversation.map { URL(fileURLWithPath: $0.projectPath).lastPathComponent } ?? "")
            .toolbar {
                if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
                ToolbarItem {
                    WorkspaceToolbarButtons(sessions: workspace, conversationID: store.selectedID, paneVisible: workspaceVisible,
                                            explorerVisible: explorerVisible, onToggle: toggleWorkspace, onToggleExplorer: toggleExplorer,
                                            gitSession: selectedGitSession, gitActionsAllowed: { !store.lightModeEnabled }, onShowGit: showGitPanel)
                }
                ToolbarItem {
                    Button("Nuevo agente", systemImage: "square.and.pencil") { openNewConversation() }
                        .help("Nuevo agente (⌘N)")
                }
            }
        }
        .background(IceWindowChrome())
    }

    private var sidebar: some View {
        JackSidebar(
            rows: sidebarRows,
            projectPaths: Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.projectPath) }),
            selectedID: store.selectedID,
            onNewConversation: { _ in openNewConversation() },
            onSelect: store.select,
            onRename: { id in store.conversations.first { $0.id == id }.map(beginRename) },
            onImproveNameWithAI: store.improveChatName(withAI:),
            onDelete: { id in deletingConversation = store.conversations.first { $0.id == id } },
            onSetUnread: store.setUnread,
            onSetPinned: { id, pinned in store.setPinned(id, pinned) },
            onSetPending: store.setPending,
            onContinueInTerminal: continueInTerminal,
            onReloadFromClaude: reloadFromClaude,
            onOpenInPane: openInPane,
            isImprovingChatNames: store.improvingChatNames,
            onImproveChatNames: store.improveChatNames,
            onHide: toggleSidebar,
            searchRequest: searchRequest
        )
    }

    /// The chat with the workspace and file panes beside it.
    private var detailPanes: some View {
        let conversation = selectedConversation
        return PaneSplit(.trailing, visible: explorerVisible && conversation != nil, widthKey: "explorerWidth", defaultWidth: 250,
                         range: 180...440, flexibleMinimum: 380) {
            PaneSplit(.trailing, visible: workspaceVisible && conversation != nil, widthKey: "workspaceWidth", defaultWidth: 500,
                      range: 300...1200, flexibleMinimum: 340) {
                centerColumn
            } trailing: {
                if let conversation {
                    WorkspacePane(sessions: workspace, store: store, conversationID: conversation.id, projectPath: conversation.projectPath, remote: conversation.remote,
                                  onClose: { withoutAnimation { workspaceVisible = false }; focusedComposer = store.selectedID })
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

    private var statusBar: some View {
        StatusBar(usage: store.usage, refreshing: store.refreshingUsage, activeCount: store.activeCount, maxConcurrent: store.maxConcurrent,
                  sessions: workspace, progress: store.progress, servers: store.servers, updates: updateChecker, refresh: { Task { await store.refreshUsage() } }, setConcurrency: store.setConcurrency,
                  conversationTitle: { id in store.conversations.first { $0.id == id }?.title },
                  openConversation: store.select, enterBatterySaver: enterBatterySaver)
            .equatable()
    }

    /// Ice shows the open agents as glass tabs over the top of the chat, once there is more than one.
    @ViewBuilder private var iceTabs: some View {
        if interfaceStyle == .ice, tabModels.count > 1 {
            IceAgentTabs(tabs: tabModels, selectedID: store.selectedID, onSelect: store.select, onClose: closeTab)
                .equatable()
        }
    }

    @ViewBuilder private var centerColumn: some View {
        if interfaceStyle == .ice {
            chatWithPanes
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        } else {
            basicCenterColumn
        }
    }

    private var basicCenterColumn: some View {
        VStack(spacing: 0) {
            AgentTabStrip(tabs: tabModels, selectedID: store.selectedID, sidebarVisible: sidebarVisible,
                          onSelect: store.select, onClose: closeTab, onNew: { openNewConversation() }, onShowSidebar: toggleSidebar)
                .equatable()
                .overlay(alignment: .trailing) {
                    WorkspaceToggles(sessions: workspace, conversationID: store.selectedID, paneVisible: workspaceVisible,
                                     explorerVisible: explorerVisible, onToggle: toggleWorkspace, onToggleExplorer: toggleExplorer,
                                     gitSession: selectedGitSession, gitActionsAllowed: { !store.lightModeEnabled }, onShowGit: showGitPanel)
                        .equatable()
                }
            chatWithPanes
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private var openTabIDs: [UUID] { OpenTabs.decode(openTabsValue) }

    /// The chats beside the main one, without agents that are gone or now in the main chat.
    private var paneLayout: PaneLayout {
        var ids = Set(store.conversations.map(\.id))
        if let selected = store.selectedID { ids.remove(selected) }
        return PaneLayout(encoded: paneLayoutValue).keeping(ids)
    }
    private func setLayout(_ layout: PaneLayout) {
        let value = layout.encoded
        if value != paneLayoutValue { withoutAnimation { paneLayoutValue = value } }
    }
    /// Opens an agent in a column at the right; with nothing selected it becomes the main chat.
    private func openInPane(_ id: UUID) {
        guard store.conversations.contains(where: { $0.id == id }) else { return }
        guard let selected = store.selectedID, selected != id else { store.select(id); return }
        setLayout(paneLayout.opening(id))
    }
    /// The pane's agent takes the main chat, and the one there takes its pane.
    private func promotePane(_ id: UUID) {
        let layout = paneLayout
        setLayout(store.selectedID.map { layout.replacing(id, with: $0) } ?? layout.removing(id))
        withoutAnimation { store.select(id) }
        focusedComposer = store.selectedID
    }
    private func closePane(_ id: UUID) {
        setLayout(paneLayout.removing(id))
        if focusedComposer == id { focusedComposer = store.selectedID }
    }
    /// An agent dragged from the sidebar or by its pane's bar, dropped on a chat: beside it, above, below or in its place.
    private func dropAgent(_ id: UUID, on target: PaneLayout.Slot, _ zone: PaneLayout.Zone) {
        guard store.conversations.contains(where: { $0.id == id }) else { return }
        guard let selected = store.selectedID else { store.select(id); return }
        let layout = paneLayout
        if target == .main, zone == .center {
            // In the main chat's place: it becomes the main chat, and the one there takes its pane if it had one.
            if layout.contains(id) { promotePane(id) } else if id != selected { withoutAnimation { store.select(id) } }
            return
        }
        // The main chat's own agent, dragged from the sidebar, moves the main chat.
        setLayout(layout.placing(id == selected ? .main : .agent(id), at: target, zone))
        if id != selected, store.conversations.first(where: { $0.id == id })?.parentID == nil { focusedComposer = id }
    }
    /// The columns on screen: the main chat's and the nearest that fit. The rest come back when the window grows.
    private var visibleColumns: [Int] { paneLayout.visibleColumns(columnRoom) }
    private var visiblePaneIDs: [UUID] {
        guard selectedConversation != nil else { return [] }
        let layout = paneLayout
        return visibleColumns.flatMap { layout.columns[$0] }.compactMap { if case .agent(let id) = $0 { id } else { nil } }
    }
    /// Brings a chat hidden for lack of room back, under the main chat.
    private func revealPane(_ id: UUID) {
        let layout = paneLayout
        guard let main = layout.position(of: .main), let last = layout.columns[main.column].last else { return }
        setLayout(layout.placing(.agent(id), at: last, .bottom))
        focusedComposer = id
    }
    /// The composers ⌥⌘← and ⌥⌘→ move between: the main chat's and those of the agents beside it.
    private func cycleComposer(_ delta: Int) {
        let ids = (store.selectedID.map { [$0] } ?? []) + visiblePaneIDs.filter { id in
            store.conversations.first { $0.id == id }?.parentID == nil
        }
        guard !ids.isEmpty else { return }
        let index = focusedComposer.flatMap(ids.firstIndex(of:)) ?? 0
        focusedComposer = ids[(index + delta + ids.count) % ids.count]
    }

    /// The main chat and the agents beside it: columns the user resizes, each a stack of chats.
    /// Dragging an agent over a chat shows where it would land; files dropped on a chat attach to its agent.
    private var chatWithPanes: some View {
        let layout = selectedConversation == nil ? PaneLayout() : paneLayout
        let visible = layout.visibleColumns(columnRoom)
        let hidden = layout.columns.indices.filter { !visible.contains($0) }.flatMap { layout.columns[$0] }
            .compactMap { if case .agent(let id) = $0 { id } else { nil } }
        return PaneStack(.horizontal, count: visible.count, key: "agentPaneWidths") {
            ForEach(visible, id: \.self) { column in
                let slots = layout.columns[column]
                PaneStack(.vertical, count: slots.count, key: "agentPaneHeights.\(column)") {
                    ForEach(slots, id: \.self) { slot in paneCell(slot, hidden: hidden) }
                }
            }
        }
        // Only a change in how many columns fit crosses into the window's state, not every point of a resize.
        .onGeometryChange(for: Int.self) { AgentPanes.columns(in: $0.size.width) } action: { room in
            if room != columnRoom { withoutAnimation { columnRoom = room } }
        }
    }

    @ViewBuilder private func paneCell(_ slot: PaneLayout.Slot, hidden: [UUID]) -> some View {
        switch slot {
        case .main:
            PaneCell(slot, drops: paneDrops, accepts: selectedConversation != nil, onFiles: { providers in
                guard let id = store.selectedID else { return }
                AttachmentDrop.load(providers) { attach($0, to: id) }
            }, onAgent: { dropAgent($0, on: .main, $1) }) {
                conversationPanel
                    .overlay(alignment: .topTrailing) { if !hidden.isEmpty { hiddenPanesMenu(hidden) } }
            }
        case .agent(let id):
            PaneCell(slot, drops: paneDrops, onFiles: { providers in AttachmentDrop.load(providers) { attach($0, to: id) } },
                     onAgent: { dropAgent($0, on: slot, $1) }) {
                agentPane(id)
            }
        }
    }

    /// Agents left without room beside the chat, one click away.
    private func hiddenPanesMenu(_ ids: [UUID]) -> some View {
        Menu {
            Section("Sin espacio en la ventana") {
                ForEach(ids, id: \.self) { id in
                    if let conversation = store.conversations.first(where: { $0.id == id }) {
                        Button(conversation.title) { revealPane(id) }
                    }
                }
            }
            Divider()
            Button("Cerrar estos paneles") { setLayout(ids.reduce(paneLayout) { $0.removing($1) }) }
        } label: {
            Label("+\(ids.count)", systemImage: "rectangle.split.3x1")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .jackGlass(in: Capsule(), basic: JackPalette.panelStrong, interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("Agentes abiertos al lado que no caben; amplía la ventana o elige uno")
        .padding(.top, ice ? 52 : 8).padding(.trailing, 10)
    }

    /// An agent beside the selected one looks like the main chat; a sub-agent gets the compact view, as the helper it is.
    @ViewBuilder private func agentPane(_ id: UUID) -> some View {
        if let conversation = store.conversations.first(where: { $0.id == id }) {
            let status = store.statuses[id] ?? .idle
            let parentTitle = conversation.parentID.flatMap { parent in store.conversations.first { $0.id == parent }?.title }
            if conversation.parentID != nil {
                AgentPaneView(
                    conversation: conversation,
                    status: status,
                    approvals: store.approvals[id] ?? [],
                    locating: store.locating.contains(id),
                    parentTitle: parentTitle,
                    monospaced: monospaced,
                    onSend: { store.send($0, to: id) },
                    onStop: { store.stop(id) },
                    onPromote: { promotePane(id) },
                    onClose: { closePane(id) },
                    onRespond: { approval, choice, message in store.respond(conversationID: id, approvalID: approval, choice: choice, message: message) },
                    onAnswer: { approval, answers in store.answer(conversationID: id, approvalID: approval, answers: answers) }
                )
                .equatable()
                .jackSurface(.canvas)
            } else {
                VStack(spacing: 0) {
                    AgentPaneHeader(conversation: conversation, status: status, subtitle: URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                                    onStop: nil, onPromote: { promotePane(id) }, onClose: { closePane(id) })
                        .equatable()
                    Rectangle().fill(JackPalette.hairline).frame(height: 1)
                    conversationView(conversation, inPane: true)
                }
                .jackSurface(.canvas)
            }
        }
    }


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
                StartView(store: store, onStart: createAgent, onResumeClaude: { showingSessionPicker = true })
                    .id(newChatID)
                .jackEdgeBar(.top) { iceTabs }
            }
        }
    }

    /// The whole chat of an agent: the selected one, or one in a pane, which looks the same.
    private func conversationView(_ conversation: ChatConversation, inPane: Bool = false) -> some View {
        let status = store.statuses[conversation.id] ?? .idle
        return VStack(spacing: 0) {
            if !inPane, let error = store.errorMessage, !error.isEmpty { errorBanner(error) }
            messageHistory(conversation)
                .jackEdgeBar(.top) { if !inPane { iceTabs } }
                .jackEdgeBar(.bottom) { bottomPanels(conversation, status: status, inPane: inPane) }
        }
        .onChange(of: store.recalled[conversation.id]) { _, message in
            guard let message else { return }
            restore(message, to: conversation.id)
            store.clearRecalled(conversation.id)
        }
        .jackSurface(.canvas)
        // One presenter, on the main chat: a sheet per pane would open Image Playground several times.
        .modifier(ImagePlaygroundPresenter(request: inPane ? .constant(nil) : $playgroundRequest, onFinish: finishImage))
        .onChange(of: store.imageRequests.first { $0.conversationID == conversation.id && $0.isPending }?.id, initial: true) { _, id in
            // Opens Image Playground as soon as the agent asks, if the user is looking at this chat.
            guard !inPane, let id, playgroundRequest == nil, NSApp.isActive, let request = store.imageRequest(id) else { return }
            playgroundRequest = request
        }
        .onChange(of: status.isActive) { wasActive, active in
            // The agent may have changed files: refresh the tree once its turn ends.
            if wasActive, !active, explorerVisible { workspace.explorer(for: conversation.projectPath).refresh() }
        }
    }

    /// Approvals, live activity, queued messages, side questions, commands and the composer.
    private func bottomPanels(_ conversation: ChatConversation, status: ChatStatus, inPane: Bool) -> some View {
        VStack(spacing: 0) {
            if let approvals = store.approvals[conversation.id], !approvals.isEmpty {
                approvalsPanel(approvals, conversation: conversation, inPane: inPane)
            }
            imageRequestsPanel(conversation)
            if isActive(conversation) {
                AgentActivityView(conversation: conversation, status: status, tokens: store.tokenUsage[conversation.id], projectPath: conversation.projectPath,
                                  locating: store.locating.contains(conversation.id))
                    .padding(.vertical, ice ? 6 : 0)
                    .jackGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), basic: .clear)
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
                      onAsk: { store.askAside($0, in: conversation.id); focusedComposer = conversation.id })
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
            composer(conversation, inPane: inPane)
        }
    }

    private func messageHistory(_ conversation: ChatConversation) -> some View {
        ChatTranscript(conversation: conversation, active: isActive(conversation), monospaced: monospaced, ice: ice,
                       onPrompt: { send($0, in: conversation) })
            .equatable()
    }

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
                pinnedAt: conversation.pinnedAt,
                pending: conversation.isPending == true,
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

    private func approvalsPanel(_ approvals: [ChatApproval], conversation: ChatConversation, inPane: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approvals) { approval in
                ApprovalCard(approval: approval, provider: conversation.provider, projectPath: conversation.projectPath,
                             repliesInChat: store.canSend(to: conversation.id) && store.statuses[conversation.id]?.isActive == true,
                             // ⌘↩ belongs to the composer while it holds a message: it interrupts and sends it.
                             shortcutsEnabled: !inPane && (drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             onRespond: { choice, message in store.respond(conversationID: conversation.id, approvalID: approval.id, choice: choice, message: message) },
                             onAnswer: { answers in store.answer(conversationID: conversation.id, approvalID: approval.id, answers: answers) })
            }
        }
        .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.bottom, 10)
    }

    private func composer(_ conversation: ChatConversation, inPane: Bool = false) -> some View {
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
                    .focused($focusedComposer, equals: conversation.id)
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
                    ChatModelPicker(allowsBypass: true, allowsCloud: true, store: store, conversation: conversation, busy: busy)
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
                if conversation.provider == .claude, conversation.parentID == nil {
                    RemoteAgentButton(store: store, conversation: conversation)
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                }
                Button {
                    // With a message written it is asked as is, like ⌥↩; otherwise the card asks for one.
                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { askAside(in: conversation) }
                    else { composingAside = conversation.id }
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                .help(conversation.provider == .claude ? "Preguntar con Haiku y un extracto reciente, sin interrumpir al agente (⌥↩)" : "Preguntar al margen sin interrumpir al agente ni entrar en su historial (⌥↩)")
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
                            .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: ice ? 12 : 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // ⌘. stops the main chat's agent; a pane's has its button.
                    .keyboardShortcut(inPane ? nil : KeyboardShortcut(".", modifiers: .command))
                    .help("Detener (⌘.)")
                    .accessibilityLabel("Detener")
                }
                if !busy || (steerable && hasContent) {
                    Button { sendDraft(in: conversation) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : JackPalette.faint)
                            .frame(width: 24, height: 24)
                            .background(canSend ? JackPalette.accent : JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: ice ? 12 : 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(busy ? "Poner en espera hasta que lo lea (Enter) · Interrumpir y enviar (⌘Enter)" : "Enviar (Enter)")
                    .accessibilityLabel("Enviar")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        // Ice: a glass field floating over the transcript, as in the system's own apps.
        .jackGlass(in: RoundedRectangle(cornerRadius: ice ? 18 : 8, style: .continuous), basic: JackPalette.panel)
        .overlay {
            if !ice {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focusedComposer == conversation.id ? JackPalette.accent.opacity(0.45) : JackPalette.hairline, lineWidth: 1)
            }
        }
        .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
        .jackSurface(.canvas)
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
        focusedComposer = store.selectedID
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
        focusedComposer = id
    }

    /// The panel appears at once: animating its width would relayout the chat and the terminal on every frame.
    private func toggleWorkspace(_ tool: WorkspaceTool) {
        guard let id = store.selectedID else { return }
        withoutAnimation {
            if workspaceVisible, workspace.selectedTab(for: id)?.kind == tool {
                workspaceVisible = false
                focusedComposer = store.selectedID
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

    /// A message about elements picked in the browser. When the agent cannot take it now, or the user
    /// wants to keep writing, it waits in the agent's composer with the pictures attached.
    private func sendToAgent(_ text: String, files: [String], to id: UUID, now: Bool) {
        if now, store.canSend(to: id) {
            store.errorMessage = nil
            store.send(text, attachments: files, to: id)
            if store.errorMessage == nil { return }
        }
        let current = drafts[id] ?? ""
        drafts[id] = [current, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        attach(files, to: id)
        focusedComposer = id
    }

    private func attach(_ paths: [String], to id: UUID) {
        guard !paths.isEmpty else { return }
        var current = attachments[id] ?? []
        for path in paths where !current.contains(path) { current.append(path) }
        attachments[id] = current
        focusedComposer = store.selectedID
    }

    private func send(_ text: String, in conversation: ChatConversation) {
        guard !isActive(conversation) else { return }
        store.send(text, to: conversation.id)
    }

    private func isActive(_ conversation: ChatConversation) -> Bool {
        let status = store.statuses[conversation.id] ?? .idle
        return status == .running || status == .waiting || status == .queued
    }

    private func resumeClaudeSession(_ session: ClaudeSessionSummary) {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { ClaudeSessions.load(session) }.value
            store.importClaudeSession(session, messages: loaded.messages, model: loaded.model)
            focusedComposer = store.selectedID
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
            workspace.terminal(tab.id, conversation: id, directory: conversation.projectPath, remote: conversation.remote).type("claude --resume \(session)\r")
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

    private func openNewConversation() {
        newChatID = UUID()
        store.selectedID = nil
        store.errorMessage = nil
        Task { await store.refreshLocalModels() }
    }

    private func createAgent(_ request: NewAgentRequest) {
        store.errorMessage = nil
        // A folder chosen by hand needs no search: the agent starts there with the first message.
        if let folder = request.folder, request.remote == nil {
            if let id = store.create(projectPath: folder, provider: request.provider,
                                     model: request.model.isEmpty ? nil : request.model, effort: request.effort) {
                store.send(request.firstMessage, to: id)
                focusedComposer = id
            }
            return
        }
        if let id = store.createLocating(request.firstMessage, provider: request.provider,
                                        model: request.model.isEmpty ? nil : request.model, effort: request.effort,
                                        projects: ProjectIndex.shared.ordered(recent: recentSpaces),
                                        remote: request.remote) {
            focusedComposer = id
        }
    }

    /// Project folders, most recently used first.
    private var recentSpaces: [String] {
        var seen = Set<String>()
        var paths = store.conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.projectPath)
        if let last = UserDefaults.standard.string(forKey: "lastProjectPath") { paths.append(last) }
        return paths.filter { $0 != ProjectLocator.unplacedFolder && FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
    }

    // MARK: Keyboard navigation

    /// Closes the window and leaves Jack in the menu bar, notifying as agents finish.
    private func enterBatterySaver() {
        batterySaver.enter(store: store)
        dismissWindow(id: "main")
    }

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
            focusComposer: { focusedComposer = store.selectedID },
            focusSearch: { searchRequest += 1 },
            toggleUnread: {
                guard let conversation = selectedConversation else { return }
                store.setUnread(conversation.id, conversation.hasUnread != true)
            },
            toggleTerminal: { toggleWorkspace(.terminal) },
            toggleBrowser: { toggleWorkspace(.browser) },
            toggleSimulator: { toggleWorkspace(.simulator) },
            toggleGit: { toggleWorkspace(.git) },
            toggleExplorer: toggleExplorer,
            toggleSidebar: toggleSidebar,
            // ⌘W in a pane's composer closes that pane, not the main chat's tab.
            closeTab: {
                if let id = focusedComposer, visiblePaneIDs.contains(id) { closePane(id) } else { store.selectedID.map(closeTab) }
            },
            cyclePane: cycleComposer,
            closePanes: { setLayout(PaneLayout()); focusedComposer = store.selectedID },
            paneCount: visiblePaneIDs.count,
            enterBatterySaver: enterBatterySaver,
            hasSelection: selectedConversation != nil,
            agentCount: store.conversations.count
        )
    }

    private func navigationOrder(includeFolded: Bool) -> [UUID] {
        SidebarSections(rows: sidebarRows, projectPaths: Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.projectPath) }),
                        projectOrder: projectOrderValue.split(separator: "\n").map(String.init), sort: sidebarProjectSort)
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
