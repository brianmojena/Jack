import AppKit
import JackCore
import SwiftUI

/// Jack Bot mode, drawn as a blueprint on black: persistent agents on the left, the selected agent's own chat in the middle,
/// its routines on the right and a title block along the bottom.
struct BotModeView<Chat: View>: View {
    @ObservedObject var bots: BotStore
    @ObservedObject var store: ChatStore
    let projectPaths: [String]
    @ViewBuilder let chat: () -> Chat
    @State private var selectedID: UUID?
    @State private var editingAgent: BotAgent?
    @State private var editingRoutine: BotRoutine?
    @State private var selectedChannelID: UUID?
    @State private var editingChannel: BotChannel?
    /// The table is the front page; the lists of agents, routines and channels are one tab away.
    private enum Tab { case table, agents }
    @State private var tab: Tab = .table

    private var selectedChannel: BotChannel? { bots.channels.first { $0.id == selectedChannelID } }
    /// The agent shown, unless a channel is.
    private var selected: BotAgent? { selectedChannel != nil ? nil : (bots.agents.first { $0.id == selectedID } ?? bots.agents.first) }
    private func isWorking(_ agent: BotAgent) -> Bool { agent.conversationID.map { store.statuses[$0]?.isActive == true } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if tab == .table {
                BotTableView(orchestrator: store.orchestrator, providers: store.apiProviders, bots: bots, store: store, projectPaths: projectPaths, chat: chat)
            } else {
                HStack(spacing: 0) {
                    agentList.frame(width: 250)
                    Rectangle().fill(BP.line.opacity(0.2)).frame(width: 1)
                    center.frame(maxWidth: .infinity)
                    if let agent = selected {
                        Rectangle().fill(BP.line.opacity(0.2)).frame(width: 1)
                        routinePanel(agent).frame(width: 310)
                    }
                }
                titleBlock
            }
        }
        .background { ZStack { BP.ink; BPGrid() } }
        .tint(BP.hi).toggleStyle(BPToggleStyle()).buttonStyle(BPButtonStyle())
        .preferredColorScheme(.dark)
        .onAppear { if tab == .agents { open(selected) } }
        .sheet(item: $editingAgent) { agent in
            BotAgentEditor(agent: agent, store: store, projectPaths: projectPaths) { saved in
                bots.upsert(saved); selectedID = saved.id; editingAgent = nil
                // An existing conversation moves to the edited engine and model, and takes the new instructions.
                if saved.conversationID != nil { store.botConversation(for: saved, applyEngine: true) }
            } onCancel: { editingAgent = nil }
        }
        .sheet(item: $editingChannel) { channel in
            BotChannelEditor(channel: channel, agents: bots.agents) { bots.upsert($0); selectedChannelID = $0.id; editingChannel = nil } onCancel: { editingChannel = nil }
        }
        .sheet(item: $editingRoutine) { routine in
            BotRoutineEditor(routine: routine) { bots.upsert($0); editingRoutine = nil } onCancel: { editingRoutine = nil }
        }
    }

    /// MESA (Jack and its team) or AGENTES (every agent, routines and channels).
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach([(Tab.table, "MESA"), (Tab.agents, "AGENTES · RUTINAS · CANALES")], id: \.1) { item in
                Button {
                    tab = item.0
                    if item.0 == .agents { open(selected) }
                } label: {
                    Text(item.1).font(BP.mono(10, .semibold)).tracking(1.2).foregroundStyle(tab == item.0 ? BP.hi : BP.dim)
                        .padding(.horizontal, 16).frame(height: 28)
                        .overlay(alignment: .bottom) { if tab == item.0 { Rectangle().fill(BP.hi).frame(height: 2) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .background(BP.ink.opacity(0.9))
        .overlay(alignment: .bottom) { Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1) }
    }

    /// Selecting an agent shows its conversation, when it already has one.
    private func open(_ agent: BotAgent?) {
        guard let id = agent?.conversationID, store.conversations.contains(where: { $0.id == id }) else { return }
        store.select(id)
    }

    private func blankAgent() -> BotAgent {
        BotAgent(name: "", projectPath: projectPaths.first ?? "", provider: .claude)
    }

    // MARK: Title block

    private var titleBlock: some View {
        let active = bots.routines.filter { !$0.paused }.count
        let cells = [("PLANO", "JACK BOT"), ("AGENTES", "\(bots.agents.count)"), ("TRABAJANDO", "\(bots.agents.filter(isWorking).count)"),
                     ("RUTINAS", "\(bots.routines.count) · \(active) ACT."), ("CANALES", "\(bots.channels.filter { $0.state != .archived }.count)")]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.0).font(BP.mono(8.5)).foregroundStyle(BP.faint).tracking(1)
                    Text(cell.1).font(BP.mono(11, .semibold)).foregroundStyle(index == 2 && cell.1 != "0" ? BP.hi : BP.text)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(maxWidth: index == 0 ? 170 : .infinity, alignment: .leading)
                Rectangle().fill(BP.line.opacity(0.2)).frame(width: 1)
            }
            Text("ESC 1:1").font(BP.mono(9.5)).foregroundStyle(BP.faint).padding(.horizontal, 14)
        }
        .frame(height: 38).background(BP.ink.opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(BP.line.opacity(0.35)).frame(height: 1) }
    }

    // MARK: Agents

    private var agentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("JACK·BOT").font(BP.mono(13, .bold)).tracking(2).foregroundStyle(BP.text)
                Spacer()
                Button { editingAgent = blankAgent() } label: { Image(systemName: "plus") }
                    .buttonStyle(BPIconButtonStyle()).help("Crear un agente").accessibilityLabel("Crear un agente")
            }
            .padding(14)
            Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1)
            if bots.agents.isEmpty {
                VStack(spacing: 10) {
                    ZStack {
                        Rectangle().strokeBorder(BP.line.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: 64, height: 64)
                        Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(BP.dim)
                    }
                    Text("SIN AGENTES").font(BP.mono(11, .semibold)).tracking(1.5).foregroundStyle(BP.text)
                    Text("Un agente es un compañero persistente: su carpeta, sus instrucciones y una sola conversación. Puede usar cualquier motor.")
                        .font(BP.mono(10.5)).foregroundStyle(BP.dim).multilineTextAlignment(.center)
                    Button("Crear agente") { editingAgent = blankAgent() }.buttonStyle(BPButtonStyle(prominent: true)).padding(.top, 4)
                }
                .padding(18).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6, pinnedViews: []) {
                        BPHeader("01", "AGENTES").padding(.bottom, 2)
                        ForEach(Array(bots.agents.enumerated()), id: \.element.id) { agentRow($0.element, index: $0.offset) }
                        BPHeader(number: "02", title: "CANALES") {
                            Button { editingChannel = BotChannel(name: "", memberIDs: [], ownerID: UUID()) } label: { Image(systemName: "plus") }
                                .buttonStyle(BPIconButtonStyle()).help("Crear un canal").disabled(bots.agents.count < 2).accessibilityLabel("Crear un canal")
                        }
                        .padding(.top, 14)
                        ForEach(Array(bots.channels.filter { $0.state != .archived }.enumerated()), id: \.element.id) { channelRow($0.element, index: $0.offset) }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func channelRow(_ channel: BotChannel, index: Int) -> some View {
        let isSelected = channel.id == selectedChannelID
        return Button { selectedChannelID = channel.id } label: {
            HStack(spacing: 10) {
                Text(BP.code("C", index)).font(BP.mono(10, .semibold)).foregroundStyle(isSelected ? BP.hi : BP.dim).frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(BP.mono(12, .medium)).foregroundStyle(BP.text).lineLimit(1)
                    Text("\(channel.memberIDs.count) MIEMBROS" + (channel.state == .stopped ? " · DETENIDO" : ""))
                        .font(BP.mono(9.5)).foregroundStyle(channel.state == .stopped ? BP.warn : BP.dim)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .bpBox(selected: isSelected).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Editar…", systemImage: "pencil") { editingChannel = channel }
            Button("Archivar", systemImage: "archivebox") { bots.setState(.archived, for: channel.id); if selectedChannelID == channel.id { selectedChannelID = nil } }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) { bots.remove(channel: channel.id); if selectedChannelID == channel.id { selectedChannelID = nil } }
        }
    }

    private func agentRow(_ agent: BotAgent, index: Int) -> some View {
        let conversation = agent.conversationID.flatMap { id in store.conversations.first { $0.id == id } }
        let working = isWorking(agent)
        let isSelected = agent.id == selected?.id
        let routines = bots.routines(of: agent.id)
        return Button {
            selectedID = agent.id; selectedChannelID = nil; open(agent)
        } label: {
            HStack(spacing: 10) {
                ProviderLogo(provider: agent.provider, size: 15, symbolScale: 0.8).foregroundStyle(isSelected ? BP.hi : BP.text)
                    .frame(width: 30, height: 30).bpBox(selected: isSelected)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(BP.code("A", index)).font(BP.mono(9.5, .semibold)).foregroundStyle(isSelected ? BP.hi : BP.faint)
                        Text(agent.name).font(BP.mono(12, .medium)).foregroundStyle(BP.text).lineLimit(1)
                    }
                    Text(working ? "■ TRABAJANDO" : "□ " + (routines.isEmpty ? "SIN RUTINAS" : "\(routines.count) RUTINA\(routines.count == 1 ? "" : "S")"))
                        .font(BP.mono(9.5)).foregroundStyle(working ? BP.hi : BP.dim)
                }
                Spacer(minLength: 4)
                if conversation?.hasUnread == true { Rectangle().fill(BP.hi).frame(width: 6, height: 6).accessibilityLabel("Sin leer") }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { if isSelected { Rectangle().fill(BP.hi).frame(width: 2) } }
            .background(isSelected ? BP.line.opacity(0.07) : .clear).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Editar…", systemImage: "pencil") { editingAgent = agent }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) { store.removeBotAgent(agent) }
        }
    }

    // MARK: Conversation

    @ViewBuilder private var center: some View {
        if let channel = selectedChannel {
            BotChannelView(bots: bots, channel: channel) { editingChannel = channel }
        } else if let agent = selected {
            VStack(spacing: 0) {
                agentStrip(agent)
                if let id = agent.conversationID, store.selectedID == id { chat() } else { emptyChat(agent) }
            }
        } else {
            Color.clear
        }
    }

    /// What the selected agent is made of, with the way to change it.
    private func agentStrip(_ agent: BotAgent) -> some View {
        let model = agent.model.isEmpty ? "PREDETERMINADO" : agent.model
        return HStack(spacing: 10) {
            Text(BP.code("A", bots.agents.firstIndex { $0.id == agent.id } ?? 0)).foregroundStyle(BP.hi)
            Text(agent.name).foregroundStyle(BP.text).lineLimit(1)
            Text("/").foregroundStyle(BP.faint)
            Text(agent.provider.title).foregroundStyle(BP.dim)
            Text(model).foregroundStyle(BP.faint).lineLimit(1)
            Spacer()
            Text("~/" + URL(fileURLWithPath: agent.projectPath).lastPathComponent).foregroundStyle(BP.faint).lineLimit(1)
            Button { editingAgent = agent } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(BPIconButtonStyle()).help("Editar el agente, su motor y su modelo").accessibilityLabel("Editar el agente")
        }
        .font(BP.mono(10.5, .semibold)).tracking(0.6).textCase(.uppercase)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1) }
    }

    private func emptyChat(_ agent: BotAgent) -> some View {
        VStack(spacing: 12) {
            ProviderLogo(provider: agent.provider, size: 34, symbolScale: 0.8).foregroundStyle(BP.hi)
                .frame(width: 84, height: 84).bpBox(marks: true)
            Text(agent.name).font(BP.mono(15, .bold)).tracking(1.5).foregroundStyle(BP.text)
            Text("\(agent.provider.title) · ~/\(URL(fileURLWithPath: agent.projectPath).lastPathComponent)").font(BP.mono(11)).foregroundStyle(BP.dim)
            if !agent.instructions.isEmpty {
                Text(agent.instructions).font(BP.mono(11)).foregroundStyle(BP.dim).lineLimit(4)
                    .multilineTextAlignment(.center).frame(maxWidth: 400)
            }
            Button("Abrir conversación") {
                guard let id = store.botConversation(for: agent) else {
                    store.errorMessage = "La carpeta «\(agent.projectPath)» no existe."; return
                }
                store.select(id)
            }
            .buttonStyle(BPButtonStyle(prominent: true)).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Routines

    private func routinePanel(_ agent: BotAgent) -> some View {
        let routines = bots.routines(of: agent.id)
        return VStack(spacing: 0) {
            HStack {
                Text("RUTINAS").font(BP.mono(12, .bold)).tracking(2).foregroundStyle(BP.text)
                Spacer()
                Button { editingRoutine = BotRoutine(agentID: agent.id, name: "", instruction: "", startAt: nineAM) } label: { Image(systemName: "plus") }
                    .buttonStyle(BPIconButtonStyle()).help("Crear una rutina").accessibilityLabel("Crear una rutina")
            }
            .padding(14)
            Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1)
            if routines.isEmpty {
                Text("Una rutina le escribe a este agente a la hora que indiques, en su misma conversación.")
                    .font(BP.mono(10.5)).foregroundStyle(BP.dim).multilineTextAlignment(.center)
                    .padding(20).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { LazyVStack(spacing: 10) { ForEach(Array(routines.enumerated()), id: \.element.id) { routineRow($0.element, index: $0.offset) } }.padding(12) }
            }
        }
    }

    private var nineAM: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func routineRow(_ routine: BotRoutine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(BP.code("R", index)).font(BP.mono(9.5, .semibold)).foregroundStyle(routine.paused ? BP.faint : BP.hi)
                Text(routine.name).font(BP.mono(12, .semibold)).foregroundStyle(BP.text).lineLimit(1)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { !routine.paused }, set: { bots.setPaused(!$0, for: routine.id) }))
                    .labelsHidden().help(routine.paused ? "Reanudar" : "Pausar")
                Menu {
                    Button("Ejecutar ahora", systemImage: "play.fill") { bots.runNow(routine.id) }
                    Button("Editar…", systemImage: "pencil") { editingRoutine = routine }
                    Divider()
                    Button("Eliminar", systemImage: "trash", role: .destructive) { bots.remove(routine: routine.id) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(BP.text) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("Acciones de la rutina")
            }
            Text(routine.instruction).font(BP.mono(10.5)).foregroundStyle(BP.dim).lineLimit(3)
            BPDimension(text: summary(routine))
            if let last = routine.lastRunAt { Text("ÚLTIMA · " + last.formatted(date: .abbreviated, time: .shortened)).font(BP.mono(9)).foregroundStyle(BP.faint) }
            if let error = routine.lastError { Text(error).font(BP.mono(10)).foregroundStyle(BP.warn).lineLimit(3) }
        }
        .padding(10).bpBox(fill: 0.03).opacity(routine.paused ? 0.55 : 1)
    }

    private func summary(_ routine: BotRoutine) -> String {
        if routine.apiOnly == true { return "SOLO API LOCAL" }
        let time = routine.startAt.formatted(date: .omitted, time: .shortened)
        switch routine.frequency {
        case .once: return routine.startAt.formatted(date: .abbreviated, time: .shortened)
        case .interval: return "CADA \(intervalText(routine.intervalMinutes))"
        case .daily: return "CADA DÍA \(time)"
        case .weekdays: return "L–V \(time)"
        case .weekly: return "\(Calendar.current.weekdaySymbols[(routine.weekday - 1) % 7]) \(time)"
        }
    }
}

func intervalText(_ minutes: Int) -> String {
    if minutes % 1440 == 0 { return minutes == 1440 ? "día" : "\(minutes / 1440) días" }
    if minutes % 60 == 0 { return minutes == 60 ? "hora" : "\(minutes / 60) horas" }
    return "\(minutes) min"
}

/// Creates or edits an agent. Any engine Jack knows can run it, with any model that engine offers.
private struct BotAgentEditor: View {
    @State var agent: BotAgent
    @ObservedObject var store: ChatStore
    let projectPaths: [String]
    let onSave: (BotAgent) -> Void
    let onCancel: () -> Void
    /// Whether each engine's command was found on this Mac; filled in off the main thread.
    @State private var installed: [ChatProvider: Bool] = [:]
    @State private var openCode: [OpenCodeProviderModels] = []
    @State private var openCodeState: LoadState = .idle
    private enum LoadState: Equatable { case idle, loading, ready, failed(String) }

    private var valid: Bool { !agent.name.trimmingCharacters(in: .whitespaces).isEmpty && agent.projectPath.hasPrefix("/") }

    /// Default first, then what the engine knows. OpenCode's come from its own server, grouped by provider.
    private var models: [(id: String, title: String)] {
        let known = agent.provider == .opencode
            ? openCode.flatMap { group in group.models.map { (id: $0.id, title: "\(group.title) · \($0.title)") } }
            : store.modelChoices(for: agent.provider).map { (id: $0.id, title: $0.title) }
        return [(id: "", title: "Predeterminado")] + known.filter { !$0.id.isEmpty }
    }

    var body: some View {
        BPSheet(figure: "01", title: agent.name.isEmpty ? "Nuevo agente" : "Editar agente", width: 580) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("01", "NOMBRE") { TextField("Nombre", text: $agent.name).bpField() }
                    section("02", "MOTOR") { providerGrid }
                    section("03", "MODELO") { modelList }
                    section("04", "CARPETA DE TRABAJO") {
                        HStack(spacing: 8) {
                            TextField("/ruta/de/la/carpeta", text: $agent.projectPath).bpField()
                            Menu("Elegir") {
                                ForEach(projectPaths.prefix(30), id: \.self) { path in
                                    Button(URL(fileURLWithPath: path).lastPathComponent) { agent.projectPath = path }
                                }
                                Divider()
                                Button("Otra carpeta…") { chooseFolder() }
                            }
                            .menuStyle(.button).buttonStyle(BPButtonStyle()).fixedSize()
                        }
                    }
                    section("05", "INSTRUCCIONES") {
                        TextEditor(text: $agent.instructions).bpEditor(height: 110)
                        Text("Acompañan a cada mensaje del agente. Su conversación es siempre la misma.").font(BP.mono(10)).foregroundStyle(BP.faint)
                    }
                    section("06", "SCRIPTS") {
                        Toggle("Permitir scripts locales (API y jack-bot)", isOn: $agent.allowScripts)
                        if agent.allowScripts {
                            Text("Un script de este Mac con el token de Jack puede escribirle hasta \(BotAPI.runsPerHour) veces por hora. Úsalo solo con scripts de confianza.")
                                .font(BP.mono(10)).foregroundStyle(BP.faint)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 560)
            HStack {
                if agent.conversationID != nil {
                    Text("Cambiar de motor abre una sesión nueva en la misma conversación.").font(BP.mono(9.5)).foregroundStyle(BP.faint)
                }
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var saved = agent
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    onSave(saved)
                }
                .buttonStyle(BPButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .onAppear {
            if agent.provider == .opencode { loadOpenCode() }
            Task.detached {
                let found = Dictionary(uniqueKeysWithValues: ChatProvider.allCases.map { ($0, $0.isBuiltIn || ExecutableResolver.resolve($0.executableName) != nil) })
                await MainActor.run { installed = found }
            }
        }
    }

    private func section<Body: View>(_ number: String, _ title: String, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 8) { BPHeader(number, title); body() }
    }

    private var providerGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(ChatProvider.allCases) { provider in
                let isSelected = provider == agent.provider
                let found = installed[provider]
                Button {
                    guard provider != agent.provider else { return }
                    agent.provider = provider; agent.model = ""
                    if provider == .opencode { loadOpenCode() }
                } label: {
                    HStack(spacing: 8) {
                        ProviderLogo(provider: provider, size: 15, symbolScale: 0.8).foregroundStyle(isSelected ? BP.hi : BP.text).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title).font(BP.mono(11, .semibold)).foregroundStyle(BP.text).lineLimit(1)
                            Text(found == nil ? "…" : provider.isBuiltIn ? "INTEGRADO" : found == true ? "INSTALADO" : "NO ENCONTRADO")
                                .font(BP.mono(8.5)).foregroundStyle(found == false ? BP.warn : BP.faint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).bpBox(selected: isSelected).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var modelList: some View {
        if agent.provider == .opencode, openCodeState == .loading {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("CONSULTANDO LOS MODELOS DE OPENCODE…").font(BP.mono(10)).foregroundStyle(BP.dim) }
        } else if agent.provider == .opencode, case .failed(let message) = openCodeState {
            VStack(alignment: .leading, spacing: 6) {
                Text("No se pudieron cargar los modelos de OpenCode: \(message)").font(BP.mono(10)).foregroundStyle(BP.warn).lineLimit(3)
                Button("Reintentar") { loadOpenCode() }
            }
        }
        let options = models
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(options, id: \.id) { option in
                    let isSelected = option.id == agent.model
                    Button { agent.model = option.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "square.fill" : "square").font(.system(size: 8)).foregroundStyle(isSelected ? BP.hi : BP.faint)
                            Text(option.title).font(BP.mono(11, isSelected ? .semibold : .regular)).foregroundStyle(BP.text).lineLimit(1)
                            if option.title != option.id, !option.id.isEmpty { Text(option.id).font(BP.mono(9.5)).foregroundStyle(BP.faint).lineLimit(1) }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5).background(isSelected ? BP.line.opacity(0.1) : .clear).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: min(CGFloat(options.count) * 27 + 4, 140)).bpBox(fill: 0.02)
        TextField(placeholder, text: $agent.model).bpField()
    }

    private var placeholder: String {
        switch agent.provider {
        case .opencode: "proveedor/modelo (vacío: el predeterminado)"
        case .stellar: "servidor/modelo, por ejemplo ollama/gemma4:31b-cloud"
        default: "otro modelo (vacío: \(agent.provider.defaultModel.isEmpty ? "el predeterminado" : agent.provider.defaultModel))"
        }
    }

    private func loadOpenCode() {
        guard openCodeState != .loading, openCodeState != .ready else { return }
        openCodeState = .loading
        let directory = FileManager.default.fileExists(atPath: agent.projectPath) ? agent.projectPath : FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            do { openCode = try await OpenCodeModelService.list(directory: directory); openCodeState = .ready }
            catch { openCodeState = .failed(error.localizedDescription) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { agent.projectPath = url.path }
    }
}

private struct BotRoutineEditor: View {
    @State var routine: BotRoutine
    let onSave: (BotRoutine) -> Void
    let onCancel: () -> Void
    @State private var unit = 60

    private var valid: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !routine.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        BPSheet(figure: "02", title: routine.name.isEmpty ? "Nueva rutina" : "Editar rutina", width: 500) {
            VStack(alignment: .leading, spacing: 8) {
                BPHeader("01", "NOMBRE")
                TextField("Nombre", text: $routine.name).bpField()
                BPHeader("02", "INSTRUCCIÓN").padding(.top, 6)
                TextEditor(text: $routine.instruction).bpEditor(height: 100)
                BPHeader("03", "CUÁNDO").padding(.top, 6)
            }
            Toggle("Solo cuando un script la llame (webhook local)", isOn: Binding(get: { routine.apiOnly == true }, set: { routine.apiOnly = $0 ? true : nil }))
            VStack(alignment: .leading, spacing: 10) {
                Picker("Cuándo", selection: $routine.frequency) {
                    ForEach(AutomationFrequency.allCases) { Text($0.title).tag($0) }
                }.disabled(routine.apiOnly == true)
                switch routine.apiOnly == true ? nil : routine.frequency {
                case nil: EmptyView()
                case .once?:
                    DatePicker("Fecha y hora", selection: $routine.startAt, displayedComponents: [.date, .hourAndMinute])
                case .interval?:
                    HStack {
                        Stepper("Cada \(max(1, routine.intervalMinutes / unit))", value: Binding(
                            get: { max(1, routine.intervalMinutes / unit) }, set: { routine.intervalMinutes = $0 * unit }), in: 1...999)
                        Picker("", selection: Binding(get: { unit }, set: { new in
                            let count = max(1, routine.intervalMinutes / unit); unit = new; routine.intervalMinutes = count * new
                        })) {
                            Text("minutos").tag(1); Text("horas").tag(60); Text("días").tag(1440)
                        }.labelsHidden().fixedSize()
                    }
                    DatePicker("Primera ejecución", selection: $routine.startAt, displayedComponents: [.date, .hourAndMinute])
                case .daily?, .weekdays?:
                    DatePicker("Hora", selection: $routine.startAt, displayedComponents: .hourAndMinute)
                case .weekly?:
                    Picker("Día", selection: $routine.weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1].capitalized).tag($0) }
                    }
                    DatePicker("Hora", selection: $routine.startAt, displayedComponents: .hourAndMinute)
                }
            }
            .font(BP.mono(11.5)).foregroundStyle(BP.text)
            Text("La instrucción llega a la conversación del agente. Jack debe estar abierto; si estaba cerrado, la ejecución pendiente se lanza al abrirlo.")
                .font(BP.mono(10)).foregroundStyle(BP.faint)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var saved = routine
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.createdAt = Date()
                    onSave(saved)
                }
                .buttonStyle(BPButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .onAppear {
            let minutes = routine.intervalMinutes
            unit = minutes % 1440 == 0 ? 1440 : (minutes % 60 == 0 ? 60 : 1)
        }
    }
}

/// A channel's shared history, with its task owner and the controls to stop, resume, reassign and archive it.
private struct BotChannelView: View {
    @ObservedObject var bots: BotStore
    let channel: BotChannel
    let onEdit: () -> Void
    @State private var draft = ""
    @State private var notice: String?

    private func name(_ id: UUID?) -> String { id == nil ? "Tú" : (bots.agents.first { $0.id == id }?.name ?? "Agente eliminado") }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(channel.messages) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name(message.authorID) + " ›").font(BP.mono(10.5, .semibold)).tracking(0.6).textCase(.uppercase)
                                    .foregroundStyle(message.authorID == nil ? BP.hi : BP.dim)
                                Text(message.text).font(BP.mono(12.5)).foregroundStyle(BP.text).textSelection(.enabled)
                            }
                            .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(BP.line.opacity(message.authorID == nil ? 0.7 : 0.25)).frame(width: 1) }
                            .id(message.id)
                        }
                    }
                    .padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: channel.messages.last?.id) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
            }
            if let notice { Text(notice).font(BP.mono(10.5)).foregroundStyle(BP.warn).padding(.horizontal, 20) }
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("#").font(BP.mono(14, .bold)).foregroundStyle(BP.hi)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(BP.mono(13, .bold)).tracking(1).textCase(.uppercase).foregroundStyle(BP.text)
                Text("DUEÑO DE LA TAREA · \(name(channel.ownerID))").font(BP.mono(9.5)).tracking(0.6).textCase(.uppercase).foregroundStyle(BP.dim)
            }
            Spacer()
            Menu("Reasignar") {
                ForEach(channel.memberIDs, id: \.self) { id in
                    Button(name(id) + (id == channel.ownerID ? "  ✓" : "")) { bots.setOwner(id, in: channel.id) }
                }
            }
            .menuStyle(.button).buttonStyle(BPButtonStyle()).fixedSize()
            if channel.state == .stopped {
                Button { bots.setState(.active, for: channel.id) } label: { Image(systemName: "play.fill") }.help("Reanudar").accessibilityLabel("Reanudar")
            } else {
                Button { bots.setState(.stopped, for: channel.id) } label: { Image(systemName: "pause.fill") }.help("Detener").accessibilityLabel("Detener")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }.help("Editar").accessibilityLabel("Editar")
            Button { bots.setState(.archived, for: channel.id) } label: { Image(systemName: "archivebox") }.help("Archivar").accessibilityLabel("Archivar")
        }
        .buttonStyle(BPIconButtonStyle())
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1) }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(channel.state == .stopped ? "El canal está detenido: se guarda, pero nadie lo lee" : "Escribe al dueño de la tarea…", text: $draft)
                .bpField().onSubmit(send)
            Button("Enviar", action: send).buttonStyle(BPButtonStyle(prominent: true)).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }

    private func send() {
        notice = bots.post(draft, inChannel: channel.id)
        draft = ""
    }
}

private struct BotChannelEditor: View {
    @State var channel: BotChannel
    let agents: [BotAgent]
    let onSave: (BotChannel) -> Void
    let onCancel: () -> Void

    private var valid: Bool {
        !channel.name.trimmingCharacters(in: .whitespaces).isEmpty && channel.memberIDs.count >= 2 && channel.memberIDs.contains(channel.ownerID)
    }

    var body: some View {
        BPSheet(figure: "03", title: channel.name.isEmpty ? "Nuevo canal" : "Editar canal", width: 440) {
            VStack(alignment: .leading, spacing: 8) {
                BPHeader("01", "NOMBRE")
                TextField("Nombre", text: $channel.name).bpField()
                BPHeader("02", "MIEMBROS").padding(.top, 6)
                ForEach(agents) { agent in
                    Toggle(agent.name, isOn: Binding(
                        get: { channel.memberIDs.contains(agent.id) },
                        set: { on in
                            channel.memberIDs.removeAll { $0 == agent.id }
                            if on { channel.memberIDs.append(agent.id) }
                            if !channel.memberIDs.contains(channel.ownerID) { channel.ownerID = channel.memberIDs.first ?? channel.ownerID }
                        }))
                }
                BPHeader("03", "DUEÑO DE LA TAREA").padding(.top, 6)
                Picker("Dueño de la tarea", selection: $channel.ownerID) {
                    ForEach(agents.filter { channel.memberIDs.contains($0.id) }) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Text("Solo el dueño oye lo que escribes en el canal. Los demás miembros entran cuando el dueño les delega una tarea.")
                    .font(BP.mono(10)).foregroundStyle(BP.faint)
            }
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var saved = channel
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    onSave(saved)
                }
                .buttonStyle(BPButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
    }
}
