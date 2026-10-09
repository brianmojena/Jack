import JackCore
import SwiftUI

/// Automations mode: prompts that start an agent by themselves, once or on a schedule.
struct AutomationsView: View {
    @ObservedObject var schedules: ScheduleCenter
    let projectPaths: [String]
    @State private var editing: Automation?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Automatizaciones", systemImage: "clock.arrow.2.circlepath").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { editing = blank() } label: { Label("Nueva", systemImage: "plus") }
                    .help("Crear una automatización")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            if schedules.automations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 30)).foregroundStyle(JackPalette.faint)
                    Text("Sin automatizaciones").font(.system(size: 13, weight: .medium))
                    Text("Elige un agente, una carpeta y un prompt, y Jack lo lanzará a la hora que indiques.")
                        .font(.system(size: 12)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center)
                    Button("Crear automatización") { editing = blank() }.padding(.top, 4)
                }
                .frame(maxWidth: 340).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(schedules.automations) { automation in row(automation) }
                    }
                    .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
        }
        .jackSurface(.canvas)
        .sheet(item: $editing) { automation in
            AutomationEditor(automation: automation, projectPaths: projectPaths) { saved in
                schedules.upsert(saved); editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func blank() -> Automation {
        Automation(name: "", prompt: "", projectPath: projectPaths.first ?? "", provider: .claude,
                   frequency: .daily, startAt: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
    }

    private func row(_ automation: Automation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            providerGlyph(automation.provider, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(automation.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(automation.provider.title).font(.system(size: 10.5)).foregroundStyle(JackPalette.muted)
                }
                Text(automation.prompt).font(.system(size: 12)).foregroundStyle(JackPalette.secondaryText).lineLimit(2)
                Text(summary(automation)).font(.system(size: 11)).foregroundStyle(JackPalette.faint)
                if let error = automation.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(JackPalette.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { automation.enabled }, set: { schedules.setEnabled($0, for: automation.id) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            Menu {
                Button("Ejecutar ahora", systemImage: "play.fill") { schedules.runNow(automation.id) }
                Button("Editar…", systemImage: "pencil") { editing = automation }
                Divider()
                Button("Eliminar", systemImage: "trash", role: .destructive) { schedules.removeAutomation(automation.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
        }
        .padding(12)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 1))
        .opacity(automation.enabled ? 1 : 0.55)
    }

    private func summary(_ automation: Automation) -> String {
        let time = automation.startAt.formatted(date: .omitted, time: .shortened)
        var text: String
        switch automation.frequency {
        case .once: text = "Una vez · \(automation.startAt.formatted(date: .abbreviated, time: .shortened))"
        case .interval: text = "Cada \(intervalText(automation.intervalMinutes))"
        case .daily: text = "Cada día a las \(time)"
        case .weekdays: text = "De lunes a viernes a las \(time)"
        case .weekly: text = "Cada \(Calendar.current.weekdaySymbols[(automation.weekday - 1) % 7]) a las \(time)"
        }
        if let next = automation.nextRun() { text += " · próxima: \(next.formatted(date: .abbreviated, time: .shortened))" }
        if let last = automation.lastRunAt { text += " · última: \(last.formatted(date: .abbreviated, time: .shortened))" }
        return text + " · " + URL(fileURLWithPath: automation.projectPath).lastPathComponent
    }
}

func intervalText(_ minutes: Int) -> String {
    if minutes % 1440 == 0 { return minutes == 1440 ? "día" : "\(minutes / 1440) días" }
    if minutes % 60 == 0 { return minutes == 60 ? "hora" : "\(minutes / 60) horas" }
    return "\(minutes) min"
}

private struct AutomationEditor: View {
    @State var automation: Automation
    let projectPaths: [String]
    let onSave: (Automation) -> Void
    let onCancel: () -> Void
    @State private var unit = 60

    private var valid: Bool {
        !automation.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !automation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && automation.projectPath.hasPrefix("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(automation.name.isEmpty ? "Nueva automatización" : "Editar automatización").font(.headline)
            TextField("Nombre", text: $automation.name)
            Picker("Agente", selection: $automation.provider) {
                ForEach(ChatProvider.allCases) { Text($0.title).tag($0) }
            }
            TextField("Modelo (vacío: el predeterminado)", text: $automation.model)
            HStack {
                TextField("Carpeta del proyecto", text: $automation.projectPath)
                Menu("Elegir") {
                    ForEach(projectPaths.prefix(30), id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { automation.projectPath = path }
                    }
                    Divider()
                    Button("Otra carpeta…") { chooseFolder() }
                }
                .fixedSize()
            }
            Text("Prompt").font(.system(size: 11, weight: .medium)).foregroundStyle(JackPalette.muted)
            TextEditor(text: $automation.prompt).font(.system(size: 12.5))
                .frame(height: 110).scrollContentBackground(.hidden)
                .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 6))
            Picker("Cuándo", selection: $automation.frequency) {
                ForEach(AutomationFrequency.allCases) { Text($0.title).tag($0) }
            }
            switch automation.frequency {
            case .once:
                DatePicker("Fecha y hora", selection: $automation.startAt, displayedComponents: [.date, .hourAndMinute])
            case .interval:
                HStack {
                    Stepper("Cada \(max(1, automation.intervalMinutes / unit))", value: Binding(
                        get: { max(1, automation.intervalMinutes / unit) }, set: { automation.intervalMinutes = $0 * unit }), in: 1...999)
                    Picker("", selection: Binding(get: { unit }, set: { new in
                        let count = max(1, automation.intervalMinutes / unit); unit = new; automation.intervalMinutes = count * new
                    })) {
                        Text("minutos").tag(1); Text("horas").tag(60); Text("días").tag(1440)
                    }.labelsHidden().fixedSize()
                }
                DatePicker("Primera ejecución", selection: $automation.startAt, displayedComponents: [.date, .hourAndMinute])
            case .daily, .weekdays:
                DatePicker("Hora", selection: $automation.startAt, displayedComponents: .hourAndMinute)
            case .weekly:
                Picker("Día", selection: $automation.weekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1].capitalized).tag($0) }
                }
                DatePicker("Hora", selection: $automation.startAt, displayedComponents: .hourAndMinute)
            }
            Text("Cada ejecución abre una conversación nueva con ese agente. Jack debe estar abierto; si estaba cerrado, la ejecución pendiente se lanza al abrirlo.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var saved = automation
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
            let minutes = automation.intervalMinutes
            unit = minutes % 1440 == 0 ? 1440 : (minutes % 60 == 0 ? 60 : 1)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { automation.projectPath = url.path }
    }
}
