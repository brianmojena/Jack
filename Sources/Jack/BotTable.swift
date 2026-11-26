import AppKit
import JackCore
import SwiftUI

/// The table: Jack Bot's front page, a blueprint on black. «Jack» sits in the middle, the bots it creates hang from it,
/// and everything that needs a decision (a team to approve, a limit reached) is shown here, not decided for the user.
struct BotTableView<Chat: View>: View {
    @ObservedObject var orchestrator: BotOrchestrator
    @ObservedObject var bots: BotStore
    @ObservedObject var store: ChatStore
    let projectPaths: [String]
    @ViewBuilder let chat: () -> Chat
    @State private var prompt = ""
    @State private var showingProviders = false
    @State private var folder = ""
    @State private var confirmStop = false
    @State private var confirmDissolve = false
    @State private var tick = Date()

    private var jack: BotAgent? { orchestrator.principal() }
    private var session: BotOrchestrator.Session? { orchestrator.activeSession }
    private var team: [BotAgent] { jack.map { orchestrator.children(of: $0.id) } ?? [] }
    private var pending: BotProposal? { orchestrator.proposals.first { $0.state == .pending } }
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        if let jack { table(jack) } else { createJack }
                    }
                    .padding(22).frame(maxWidth: .infinity)
                }
                if let proposal = pending { proposalPanel(proposal) }
                if let jack { promptBar(jack) }
            }
            .frame(minWidth: 540)
            if jack != nil {
                Rectangle().fill(BP.line.opacity(0.2)).frame(width: 1)
                chatPanel.frame(width: 430)
            }
        }
        .background { ZStack { BP.ink; BPGrid() } }
        .tint(BP.hi).toggleStyle(BPToggleStyle()).buttonStyle(BPButtonStyle())
        .preferredColorScheme(.dark)
        .onAppear { orchestrator.scanCLIs(); if let jack, let id = jack.conversationID, store.conversations.contains(where: { $0.id == id }) { store.select(id) } }
        .onReceive(clock) { tick = $0 }
        .confirmationDialog("¿Detener a todos los bots?", isPresented: $confirmStop) {
            Button("Detener todo", role: .destructive) { orchestrator.stopAll() }
        } message: { Text("Para a Jack y a sus bots hijos y termina la sesión. Lo que ya hicieron se queda como está.") }
        .confirmationDialog("¿Disolver el equipo?", isPresented: $confirmDissolve) {
            Button("Disolver", role: .destructive) { orchestrator.dissolveTeam() }
        } message: { Text("Quita los bots hijos de Jack Bot. Sus conversaciones se quedan como chats normales.") }
    }

    // MARK: Top bar and limits

    private var topBar: some View {
        let policy = orchestrator.policy
        let s = session
        let left = orchestrator.timeLeft().map { Int($0 / 60) }
        let cells: [(String, String)] = [
            ("SESIÓN", s == nil ? "SIN SESIÓN" : "ACTIVA · \(left ?? 0) MIN"),
            ("HIJOS", "\(s.map { orchestrator.activeChildren(in: $0).count } ?? 0)/\(policy.maxActiveChildren)"),
            ("CREADOS", "\(s?.spawned ?? 0)/\(policy.maxChildrenPerSession)"),
            ("MENSAJES", "\(s?.messages ?? 0)/\(policy.maxMessagesPerSession)"),
            ("MODO", orchestrator.approvalMode == .autonomous ? "AUTÓNOMO" : "PREGUNTAR"),
        ]
        _ = tick
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("JACK·MESA").font(BP.mono(13, .bold)).tracking(2).foregroundStyle(BP.text).lineLimit(1)
                Spacer(minLength: 8)
                modeSwitch
                Button("Disolver equipo") { confirmDissolve = true }.disabled(team.isEmpty).buttonStyle(BPButtonStyle())
                Button("Detener todo") { confirmStop = true }.disabled(session == nil).buttonStyle(BPButtonStyle(destructive: true))
            }
            .padding(.horizontal, 16).frame(height: 38)
            Rectangle().fill(BP.line.opacity(0.2)).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                    if index > 0 { Rectangle().fill(BP.line.opacity(0.2)).frame(width: 1) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.0).font(BP.mono(8.5)).foregroundStyle(BP.faint).tracking(1)
                        Text(cell.1).font(BP.mono(10.5, .semibold)).foregroundStyle(BP.text).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).help(limitHelp(cell.0))
                }
            }
            .frame(height: 38)
            if orchestrator.approvalMode == .autonomous {
                HStack(spacing: 8) {
                    Text("AUTÓNOMO").font(BP.mono(10, .bold)).tracking(1.5).foregroundStyle(BP.warn)
                    Text("Jack crea y lanza bots sin pedirte aprobación. Los límites y «Detener todo» siguen activos; los mensajes entre bots siguen siendo datos, no órdenes.")
                        .font(BP.mono(9.5)).foregroundStyle(BP.warn.opacity(0.85)).lineLimit(2)
                    Spacer(minLength: 6)
                    Button("Volver a preguntar") { if let jack { orchestrator.setApprovalMode(.ask, principal: jack) } }
                }
                .padding(.horizontal, 16).padding(.vertical, 6).background(BP.warn.opacity(0.1))
                .overlay(alignment: .bottom) { Rectangle().fill(BP.warn.opacity(0.7)).frame(height: 1) }
            }
        }
    }

    /// PREGUNTAR / AUTÓNOMO. Only this switch or the user's own message to Jack can make it autonomous.
    private var modeSwitch: some View {
        let autonomous = orchestrator.approvalMode == .autonomous
        return HStack(spacing: 0) {
            ForEach([(BotApprovalMode.ask, "PREGUNTAR"), (BotApprovalMode.autonomous, "AUTÓNOMO")], id: \.1) { item in
                Button {
                    if let jack { orchestrator.setApprovalMode(item.0, principal: jack) }
                } label: {
                    Text(item.1).font(BP.mono(9.5, .semibold)).tracking(0.8)
                        .foregroundStyle(item.0 == (autonomous ? .autonomous : .ask) ? (item.0 == .autonomous ? BP.warn : BP.hi) : BP.dim)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background((item.0 == (autonomous ? .autonomous : .ask)) ? (item.0 == .autonomous ? BP.warn : BP.hi).opacity(0.14) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(jack == nil)
            }
        }
        .overlay(Rectangle().strokeBorder(BP.line.opacity(0.4), lineWidth: 1))
        .help("PREGUNTAR: crear bots necesita tu aprobación. AUTÓNOMO: Jack crea y lanza bots sin preguntar. Solo tú puedes activarlo y vuelve a PREGUNTAR en cada sesión nueva.")
    }

    private func limitHelp(_ cell: String) -> String {
        let p = orchestrator.policy
        switch cell {
        case "HIJOS": return "Bots hijos trabajando a la vez. Máximo \(p.maxActiveChildren). Los hijos no crean bots (profundidad \(p.maxDepth))."
        case "CREADOS": return "Bots creados en esta sesión. Máximo \(p.maxChildrenPerSession)."
        case "MENSAJES": return "Mensajes entre bots en esta sesión (\(p.maxMessagesPerChild) por hijo). Es también el tope de gasto: no hay precio por token, el límite son los turnos y el tiempo."
        case "SESIÓN": return "Una sesión empieza cuando le escribes a Jack y termina a los \(Int(p.sessionDuration / 60)) minutos o con «Detener todo». Cada sesión nueva empieza en PREGUNTAR."
        default: return "PREGUNTAR: crear bots exige tu aprobación aquí. AUTÓNOMO: Jack los lanza sin preguntar. Las acciones de cada bot siguen el modo de permisos de su propio chat."
        }
    }

    // MARK: Create Jack

    private var createJack: some View {
        let choices = providerChoices
        return VStack(spacing: 14) {
            ZStack {
                Rectangle().strokeBorder(BP.line.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: 84, height: 84)
                Text("J").font(BP.mono(34, .bold)).foregroundStyle(BP.hi)
            }
            Text("MESA DE JACK").font(BP.mono(15, .bold)).tracking(2).foregroundStyle(BP.text)
            Text("Jack es el bot principal. Tú le hablas; cuando la tarea lo pide, te propone un equipo de bots y tú lo apruebas. Elige con qué motor trabaja (las CLI que Jack ya integra).")
                .font(BP.mono(11)).foregroundStyle(BP.dim).multilineTextAlignment(.center).frame(maxWidth: 460)
            providerList(selected: nil, choices: choices) { choice in create(choice) }
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Text("CARPETA").font(BP.mono(9.5)).foregroundStyle(BP.faint)
                Picker("", selection: $folder) {
                    ForEach(projectPaths, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                    if !folder.isEmpty && !projectPaths.contains(folder) { Text(URL(fileURLWithPath: folder).lastPathComponent).tag(folder) }
                }
                .labelsHidden().frame(maxWidth: 220)
                Button("Elegir…") { chooseFolder() }
            }
        }
        .padding(.top, 30).onAppear { if folder.isEmpty { folder = projectPaths.first ?? "" } }
    }

    private func create(_ choice: BotProviderChoice) {
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { store.errorMessage = "Elige la carpeta donde trabajará Jack."; return }
        let agent = orchestrator.ensurePrincipal(projectPath: folder, choice: choice)
        if let id = agent.conversationID { store.select(id) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"; panel.message = "Carpeta de trabajo de Jack"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    // MARK: Table

    private var providerChoices: [BotProviderOption] { orchestrator.providerOptions() }

    private func providerLabel(_ agent: BotAgent) -> String {
        let choice = orchestrator.choice(of: agent)
        return providerChoices.first { $0.choice == choice }?.title ?? agent.provider.title
    }

    private func providerList(selected: BotProviderChoice?, choices: [BotProviderOption], pick: @escaping (BotProviderChoice) -> Void) -> some View {
        VStack(spacing: 4) {
            ForEach(choices) { row in
                Button { pick(row.choice) } label: {
                    HStack(spacing: 8) {
                        Rectangle().fill(row.choice == selected ? BP.hi : .clear).frame(width: 6, height: 6).overlay(Rectangle().strokeBorder(BP.line.opacity(0.5), lineWidth: 1))
                        Text(row.title).font(BP.mono(11, .semibold)).foregroundStyle(row.available ? BP.text : BP.faint)
                        Spacer(minLength: 6)
                        Text(row.detail).font(BP.mono(9)).foregroundStyle(row.available ? BP.dim : BP.warn).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity)
                    .bpBox(selected: row.choice == selected)
                }
                .buttonStyle(.plain).disabled(!row.available)
            }
            HStack {
                Button("Volver a buscar") { orchestrator.scanCLIs() }.disabled(orchestrator.scanning)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func table(_ jack: BotAgent) -> some View {
        VStack(spacing: 0) {
            BPHeader("01", "MESA").padding(.bottom, 14)
            jackCard(jack)
            if team.isEmpty {
                Text("Sin bots hijos. Pídele algo a Jack: si hace falta ayuda, te propondrá un equipo y no creará nada sin tu aprobación.")
                    .font(BP.mono(10.5)).foregroundStyle(BP.dim).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 22)
            } else {
                Rectangle().fill(BP.line.opacity(0.5)).frame(width: 1, height: 22)
                let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14, alignment: .top)]
                LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
                    ForEach(Array(team.enumerated()), id: \.element.id) { childCard($0.element, index: $0.offset) }
                }
                .overlay(alignment: .top) { Rectangle().fill(BP.line.opacity(0.28)).frame(height: 1).padding(.horizontal, 100).offset(y: -8) }
            }
        }
    }

    private func jackCard(_ jack: BotAgent) -> some View {
        let working = jack.conversationID.map { store.statuses[$0]?.isActive == true } ?? false
        let waiting = jack.conversationID.map { (store.approvals[$0] ?? []).count } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack { Rectangle().fill(BP.hi.opacity(0.1)); Text("J").font(BP.mono(20, .bold)).foregroundStyle(BP.hi) }
                    .frame(width: 44, height: 44).overlay(Rectangle().strokeBorder(BP.hi.opacity(0.7), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("JACK · PRINCIPAL").font(BP.mono(12, .bold)).tracking(1.2).foregroundStyle(BP.text)
                    Text(providerLabel(jack) + (jack.model.isEmpty || jack.provider == .stellar ? "" : " · " + jack.model)).font(BP.mono(10)).foregroundStyle(BP.dim).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button("Proveedor") { showingProviders.toggle() }
                    .popover(isPresented: $showingProviders, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            BPHeader("P", "PROVEEDOR DE JACK")
                            providerList(selected: orchestrator.choice(of: jack), choices: providerChoices) { choice in
                                orchestrator.setProvider(choice, for: jack); showingProviders = false
                            }
                            Text("Un bot que está trabajando cambia de motor cuando termine. Solo aparecen los motores que Jack ya integra y tienes instalados.")
                                .font(BP.mono(9.5)).foregroundStyle(BP.faint)
                        }
                        .padding(14).frame(width: 340).background { ZStack { BP.ink; BPGrid() } }
                        .tint(BP.hi).buttonStyle(BPButtonStyle()).preferredColorScheme(.dark)
                    }
            }
            HStack(spacing: 8) {
                badge(working ? "TRABAJANDO" : "EN REPOSO", color: working ? BP.hi : BP.dim)
                if waiting > 0 { badge("\(waiting) APROBACIÓN\(waiting == 1 ? "" : "ES")", color: BP.warn) }
                Spacer()
                Text("~/" + URL(fileURLWithPath: jack.projectPath).lastPathComponent).font(BP.mono(9.5)).foregroundStyle(BP.faint).lineLimit(1)
            }
        }
        .padding(12).frame(width: 430).bpBox(marks: true, selected: true)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(BP.mono(9, .semibold)).tracking(0.8).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2).overlay(Rectangle().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }

    private func childState(_ agent: BotAgent) -> (String, Color) {
        let state = orchestrator.session?.children[agent.id]
        if state == .stopped { return ("DETENIDO", BP.warn) }
        let status = agent.conversationID.flatMap { store.statuses[$0] }
        if (agent.conversationID.map { (store.approvals[$0] ?? []).isEmpty } ?? true) == false { return ("ESPERANDO TU APROBACIÓN", BP.warn) }
        if status == .failed { return ("ERROR", BP.warn) }
        if status?.isActive == true { return ("TRABAJANDO", BP.hi) }
        if state == .reported { return ("TERMINADO", BP.dim) }
        return ("EN REPOSO", BP.dim)
    }

    private func childCard(_ agent: BotAgent, index: Int) -> some View {
        let (text, color) = childState(agent)
        let used = orchestrator.session?.perChild[agent.id] ?? 0
        let isOpen = agent.conversationID == store.selectedID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(BP.code("H", index)).font(BP.mono(9.5, .semibold)).foregroundStyle(BP.hi)
                Text(agent.name).font(BP.mono(12, .semibold)).foregroundStyle(BP.text).lineLimit(1)
                Spacer(minLength: 4)
            }
            Text(providerLabel(agent)).font(BP.mono(10)).foregroundStyle(BP.dim).lineLimit(1)
            HStack(spacing: 8) {
                badge(text, color: color)
                Spacer()
                Text("MSJ \(used)/\(orchestrator.policy.maxMessagesPerChild)").font(BP.mono(9)).foregroundStyle(BP.faint)
            }
            if let report = orchestrator.session?.reports[agent.id] {
                Text(report).font(BP.mono(9.5)).foregroundStyle(BP.dim).lineLimit(3)
            }
            HStack(spacing: 6) {
                Button("Abrir") {
                    if let id = store.botConversation(for: agent) { store.select(id) }
                }
                Button("Detener") { orchestrator.stop(child: agent.id) }
                    .disabled(orchestrator.session?.children[agent.id] != .working)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).bpBox(selected: isOpen)
    }

    // MARK: Proposal

    private func proposalPanel(_ proposal: BotProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BPHeader(number: "!", title: "PROPUESTA DE JACK · NECESITA TU APROBACIÓN") { EmptyView() }
            if !proposal.rationale.isEmpty { Text(proposal.rationale).font(BP.mono(10.5)).foregroundStyle(BP.text) }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(proposal.children.enumerated()), id: \.offset) { index, child in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(BP.code("H", index)).foregroundStyle(BP.hi); Text(child.name).foregroundStyle(BP.text) }.font(BP.mono(11, .semibold))
                            Text(child.providerLabel).font(BP.mono(9.5)).foregroundStyle(BP.dim)
                            ScrollView { Text(child.task).font(BP.mono(10)).foregroundStyle(BP.text).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 60)
                        }
                        .padding(8).frame(width: 240, alignment: .leading).bpBox(fill: 0.03)
                    }
                }
            }
            HStack {
                Text("Los bots trabajan en la carpeta de Jack, con el modo de permisos de cada agente.").font(BP.mono(9.5)).foregroundStyle(BP.faint)
                Spacer()
                Button("Rechazar") { orchestrator.reject(proposal.id) }
                Button("Aprobar y lanzar") {
                    if case .failure(let error) = orchestrator.approve(proposal.id) { store.errorMessage = error.message }
                }
                .buttonStyle(BPButtonStyle(prominent: true))
            }
        }
        .padding(14).background(BP.warn.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(BP.warn.opacity(0.7)).frame(height: 1) }
    }

    // MARK: Prompt

    private func promptBar(_ jack: BotAgent) -> some View {
        HStack(spacing: 8) {
            Text("›").font(BP.mono(14, .bold)).foregroundStyle(BP.hi)
            TextField("Pídele algo a Jack…", text: $prompt).bpField().onSubmit { send(jack) }
            Button("Enviar") { send(jack) }.buttonStyle(BPButtonStyle(prominent: true)).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12).overlay(alignment: .top) { Rectangle().fill(BP.line.opacity(0.35)).frame(height: 1) }
    }

    private func send(_ jack: BotAgent) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch orchestrator.ask(text, principal: jack) {
        case .success(let id): prompt = ""; store.select(id)
        case .failure(let error): store.errorMessage = error.message
        }
    }

    @ViewBuilder private var chatPanel: some View {
        if let id = jack?.conversationID, store.selectedID != nil, store.conversations.contains(where: { $0.id == id }) { chat() }
        else { VStack { Text("La conversación aparece aquí").font(BP.mono(11)).foregroundStyle(BP.faint) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
