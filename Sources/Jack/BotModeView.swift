import AppKit
import JackCore
import SwiftUI

/// Jack Bot mode: persistent agents on the left, the selected agent's own chat in the middle, its routines on the right.
struct BotModeView<Chat: View>: View {
    @ObservedObject var bots: BotStore
    @ObservedObject var store: ChatStore
    let projectPaths: [String]
    @ViewBuilder let chat: () -> Chat
    @State private var selectedID: UUID?
    @State private var editingAgent: BotAgent?
    @State private var editingRoutine: BotRoutine?

    private var selected: BotAgent? { bots.agents.first { $0.id == selectedID } ?? bots.agents.first }

    var body: some View {
        HStack(spacing: 0) {
            agentList.frame(width: 230)
            Rectangle().fill(JackPalette.hairline).frame(width: 1)
            center.frame(maxWidth: .infinity)
            if let agent = selected {
                Rectangle().fill(JackPalette.hairline).frame(width: 1)
                routinePanel(agent).frame(width: 300)
            }
        }
        .jackSurface(.canvas)
        .onAppear { open(selected) }
        .sheet(item: $editingAgent) { agent in
            BotAgentEditor(agent: agent, projectPaths: projectPaths) { saved in
                bots.upsert(saved); selectedID = saved.id; editingAgent = nil
                // An existing conversation keeps its own folder and engine; only the pinned instructions follow the edit.
                if saved.conversationID != nil { store.botConversation(for: saved) }
            } onCancel: { editingAgent = nil }
        }
        .sheet(item: $editingRoutine) { routine in
            BotRoutineEditor(routine: routine) { bots.upsert($0); editingRoutine = nil } onCancel: { editingRoutine = nil }
        }
    }

    /// Selecting an agent shows its conversation, when it already has one.
    private func open(_ agent: BotAgent?) {
        guard let id = agent?.conversationID, store.conversations.contains(where: { $0.id == id }) else { return }
        store.select(id)
    }

    private func blankAgent() -> BotAgent {
        BotAgent(name: "", projectPath: projectPaths.first ?? "", provider: .claude)
    }

    // MARK: Agents

    private var agentList: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Jack Bot", systemImage: "person.2.wave.2").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { editingAgent = blankAgent() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Crear un agente")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            if bots.agents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.wave.2").font(.system(size: 28)).foregroundStyle(JackPalette.faint)
                    Text("Sin agentes").font(.system(size: 13, weight: .medium))
                    Text("Un agente es un compañero persistente: tiene su carpeta, sus instrucciones y una sola conversación.")
                        .font(.system(size: 12)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center)
                    Button("Crear agente") { editingAgent = blankAgent() }.padding(.top, 4)
                }
                .padding(16).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(bots.agents) { agentRow($0) } }.padding(8)
                }
            }
        }
    }

    private func agentRow(_ agent: BotAgent) -> some View {
        let conversation = agent.conversationID.flatMap { id in store.conversations.first { $0.id == id } }
        let working = conversation.map { store.statuses[$0.id]?.isActive == true } ?? false
        let routines = bots.routines(of: agent.id)
        return Button {
            selectedID = agent.id; open(agent)
        } label: {
            HStack(spacing: 10) {
                providerGlyph(agent.provider, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(working ? "Trabajando…" : routines.isEmpty ? "Sin rutinas" : "\(routines.count) rutina\(routines.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(working ? JackPalette.accent : JackPalette.muted)
                }
                Spacer(minLength: 4)
                if conversation?.hasUnread == true { Circle().fill(JackPalette.accent).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(agent.id == selected?.id ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: JackPalette.radius(6)))
        .contextMenu {
            Button("Editar…", systemImage: "pencil") { editingAgent = agent }
            Divider()
            Button("Eliminar", systemImage: "trash", role: .destructive) { store.removeBotAgent(agent) }
        }
    }

    // MARK: Conversation

    @ViewBuilder private var center: some View {
        if let agent = selected {
            if let id = agent.conversationID, store.selectedID == id { chat() } else { emptyChat(agent) }
        } else {
            Color.clear
        }
    }

    private func emptyChat(_ agent: BotAgent) -> some View {
        VStack(spacing: 8) {
            providerGlyph(agent.provider, size: 40)
            Text(agent.name).font(.system(size: 15, weight: .semibold))
            Text(URL(fileURLWithPath: agent.projectPath).lastPathComponent).font(.system(size: 12)).foregroundStyle(JackPalette.muted)
            if !agent.instructions.isEmpty {
                Text(agent.instructions).font(.system(size: 12)).foregroundStyle(JackPalette.secondaryText).lineLimit(4)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            Button("Abrir conversación") {
                guard let id = store.botConversation(for: agent) else {
                    store.errorMessage = "La carpeta «\(agent.projectPath)» no existe."; return
                }
                store.select(id)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Routines

    private func routinePanel(_ agent: BotAgent) -> some View {
        let routines = bots.routines(of: agent.id)
        return VStack(spacing: 0) {
            HStack {
                Label("Rutinas", systemImage: "clock.arrow.2.circlepath").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { editingRoutine = BotRoutine(agentID: agent.id, name: "", instruction: "", startAt: nineAM) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Crear una rutina")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            if routines.isEmpty {
                Text("Una rutina le escribe a este agente a la hora que indiques, en su misma conversación.")
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center)
                    .padding(20).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { LazyVStack(spacing: 8) { ForEach(routines) { routineRow($0) } }.padding(12) }
            }
        }
    }

    private var nineAM: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func routineRow(_ routine: BotRoutine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(routine.instruction).font(.system(size: 11.5)).foregroundStyle(JackPalette.secondaryText).lineLimit(2)
                Text(summary(routine)).font(.system(size: 10.5)).foregroundStyle(JackPalette.faint)
                if let error = routine.lastError { Text(error).font(.system(size: 10.5)).foregroundStyle(JackPalette.red).lineLimit(2) }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { !routine.paused }, set: { bots.setPaused(!$0, for: routine.id) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            Menu {
                Button("Ejecutar ahora", systemImage: "play.fill") { bots.runNow(routine.id) }
                Button("Editar…", systemImage: "pencil") { editingRoutine = routine }
                Divider()
                Button("Eliminar", systemImage: "trash", role: .destructive) { bots.remove(routine: routine.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
        }
        .padding(10)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: JackPalette.radius(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JackPalette.radius(8), style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: JackPalette.borderWidth(1)))
        .opacity(routine.paused ? 0.55 : 1)
    }

    private func summary(_ routine: BotRoutine) -> String {
        let time = routine.startAt.formatted(date: .omitted, time: .shortened)
        var text: String
        switch routine.frequency {
        case .once: text = "Una vez · \(routine.startAt.formatted(date: .abbreviated, time: .shortened))"
        case .interval: text = "Cada \(intervalText(routine.intervalMinutes))"
        case .daily: text = "Cada día a las \(time)"
        case .weekdays: text = "De lunes a viernes a las \(time)"
        case .weekly: text = "Cada \(Calendar.current.weekdaySymbols[(routine.weekday - 1) % 7]) a las \(time)"
        }
        if let next = routine.nextRun() { text += " · próxima: \(next.formatted(date: .abbreviated, time: .shortened))" }
        if let last = routine.lastRunAt { text += " · última: \(last.formatted(date: .abbreviated, time: .shortened))" }
        return text
    }
}

func intervalText(_ minutes: Int) -> String {
    if minutes % 1440 == 0 { return minutes == 1440 ? "día" : "\(minutes / 1440) días" }
    if minutes % 60 == 0 { return minutes == 60 ? "hora" : "\(minutes / 60) horas" }
    return "\(minutes) min"
}

private struct BotAgentEditor: View {
    @State var agent: BotAgent
    let projectPaths: [String]
    let onSave: (BotAgent) -> Void
    let onCancel: () -> Void

    private var valid: Bool { !agent.name.trimmingCharacters(in: .whitespaces).isEmpty && agent.projectPath.hasPrefix("/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(agent.name.isEmpty ? "Nuevo agente" : "Editar agente").font(.headline)
            TextField("Nombre", text: $agent.name)
            Picker("Motor", selection: $agent.provider) {
                ForEach(ChatProvider.allCases) { Text($0.title).tag($0) }
            }
            TextField("Modelo (vacío: el predeterminado)", text: $agent.model)
            HStack {
                TextField("Carpeta de trabajo", text: $agent.projectPath)
                Menu("Elegir") {
                    ForEach(projectPaths.prefix(30), id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { agent.projectPath = path }
                    }
                    Divider()
                    Button("Otra carpeta…") { chooseFolder() }
                }
                .fixedSize()
            }
            Text("Instrucciones").font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
            TextEditor(text: $agent.instructions).font(.system(size: 12.5))
                .frame(height: 130).scrollContentBackground(.hidden)
                .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: JackPalette.radius(6)))
            Text("Las instrucciones acompañan a cada mensaje del agente. Su conversación es siempre la misma.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var saved = agent
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 460)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(routine.name.isEmpty ? "Nueva rutina" : "Editar rutina").font(.headline)
            TextField("Nombre", text: $routine.name)
            Text("Instrucción").font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
            TextEditor(text: $routine.instruction).font(.system(size: 12.5))
                .frame(height: 110).scrollContentBackground(.hidden)
                .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: JackPalette.radius(6)))
            Picker("Cuándo", selection: $routine.frequency) {
                ForEach(AutomationFrequency.allCases) { Text($0.title).tag($0) }
            }
            switch routine.frequency {
            case .once:
                DatePicker("Fecha y hora", selection: $routine.startAt, displayedComponents: [.date, .hourAndMinute])
            case .interval:
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
            case .daily, .weekdays:
                DatePicker("Hora", selection: $routine.startAt, displayedComponents: .hourAndMinute)
            case .weekly:
                Picker("Día", selection: $routine.weekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1].capitalized).tag($0) }
                }
                DatePicker("Hora", selection: $routine.startAt, displayedComponents: .hourAndMinute)
            }
            Text("La instrucción llega a la conversación del agente. Jack debe estar abierto; si estaba cerrado, la ejecución pendiente se lanza al abrirlo.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var saved = routine
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.createdAt = Date()
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 460)
        .onAppear {
            let minutes = routine.intervalMinutes
            unit = minutes % 1440 == 0 ? 1440 : (minutes % 60 == 0 ? 60 : 1)
        }
    }
}
