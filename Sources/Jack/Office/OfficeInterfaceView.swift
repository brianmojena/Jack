import JackCore
import SwiftUI
import simd

/// Lo que muestra el panel de abajo.
enum OfficePanelTarget: Equatable {
    /// La sesión de un agente: lo que respondió y el cuadro para seguir escribiéndole.
    case agent(UUID)
    /// Un agente nuevo, para el puesto indicado. `token` reinicia el formulario cada vez que se abre.
    case newAgent(slot: String?, token: UUID, provider: ChatProvider?, model: String?)
}

/// El panel que se abre abajo: el chat con la persona de un puesto.
private struct OfficeDock: Equatable {
    var slot: Int
    var mode = OfficeColleagueView.Mode.chat
}

/// El menú de acciones abierto sobre un personaje, y en qué paso va.
private struct OfficeActions: Hashable {
    enum Step: Hashable { case root, work, providers, models(ChatProvider), previous }

    var slot: Int
    var step = Step.root
}

/// La interfaz «Oficina 3D».
///
/// - Cada personaje es una persona (Gemma 4 31B Cloud) con un agente de programación a su cargo. Abajo se chatea con ella:
///   ella decide qué encargarle al agente, le escribe el prompt, cuenta cómo va y avisa al terminar.
/// - Cada personaje con un agente lleva sobre la cabeza una burbuja naranja, anclada a él, para elegir su modelo.
/// - Cuando el agente contesta, necesita algo o falla, su personaje muestra una burbuja verde, amarilla o roja; al pulsarla
///   se abre su chat. «Ver pantalla» acerca la cámara a su monitor, donde se ve el trabajo del agente tal cual.
struct OfficeInterfaceView<Content: View>: View {
    @ObservedObject var store: ChatStore
    var sidebarVisible: Bool
    var onShowSidebar: () -> Void
    /// El contenido del panel; lo construye quien tiene el chat completo de Jack.
    @ViewBuilder var dockContent: (OfficePanelTarget) -> Content

    @StateObject private var stage = OfficeStage()
    @StateObject private var assignments = OfficeAssignments()
    /// Los ajustes gráficos (el engranaje de arriba a la derecha).
    @StateObject private var graphics = OfficeGraphics()
    /// El avatar (modelo 3D) que lleva cada persona.
    @StateObject private var avatars = OfficeAvatarChoices()
    @State private var camera = OfficeCamera(target: OfficePose.world(x: 3.2, y: -4.5, z: 2.4))
    @State private var dock: OfficeDock?
    @State private var actions: OfficeActions?
    /// El puesto cuyo personaje está eligiendo avatar.
    @State private var choosingAvatar: Int?
    @State private var sceneSize = CGSize(width: 1000, height: 700)
    /// El agente (proveedor y modelo) que usará cada persona en su próximo encargo nuevo, por puesto.
    @State private var workerChoice: [String: OfficeAssignments.ModelChoice] = [:]
    /// Las personas que están pensando qué contestar.
    @State private var thinking: Set<String> = []
    /// El puesto cuya pantalla se mira de cerca.
    @State private var viewing: Int?
    /// La cámara ya llegó al monitor: encima del cristal se ve el chat real.
    @State private var screenReady = false
    /// Lo que cuenta cada agente de lo que va haciendo (Gemma 4 31B Cloud), por chat.
    @State private var narrator = OfficeNarrator()
    /// Los monitores «En vivo»: el chat real de cada puesto, montado fuera de la pantalla para fotografiarlo.
    @State private var liveScreens: [String: OfficeLiveScreen] = [:]
    /// Lo último que dijo cada persona en su bocadillo, por puesto.
    @State private var narration: [String: String] = [:]

    private var slots: [OfficeLayout.Slot] { stage.layout?.slots ?? [] }

    var body: some View {
        OfficeSceneView(stage: stage, camera: camera, quality: graphics.quality, measuresFPS: graphics.showFPS, onFPS: { graphics.fps = $0 }, onPick: { tag, _ in if viewing == nil { pick(tag.index) } }, onPickNothing: { actions = nil; choosingAvatar = nil })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JackPalette.chrome)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sceneSize = $0 }
            .overlay { anchoredOverlay }
            .overlay(alignment: .bottom) { dockOverlay }
            .overlay { screenContent }
            .overlay(alignment: .top) { screenOverlay }
            .overlay(alignment: .topLeading) { if !sidebarVisible { sidebarButton } }
            .overlay(alignment: .topTrailing) { if viewing == nil { OfficeGraphicsMenu(graphics: graphics) } }
            .onChange(of: stage.state) { _, _ in sendCommands(); restoreAvatars() }
            .onChange(of: commands) { _, _ in sendCommands() }
            .onChange(of: store.selectedID) { _, id in
                // Lo que se elige en la barra lateral abre el chat con la persona que lo lleva.
                guard dock == nil, viewing == nil, let id, let slot = assignments.slot(of: id), let index = slots.firstIndex(where: { $0.id == slot }) else { return }
                dock = OfficeDock(slot: index)
            }
            .onChange(of: sceneSize) { _, _ in if let viewing { focusScreen(viewing) } }
            .onChange(of: assignments.working) { _, working in
                // Si su personaje deja de trabajar, su pantalla se apaga: la cámara vuelve a la sala.
                if let viewing, slots.indices.contains(viewing), !working.contains(slots[viewing].id) { leaveScreen() }
            }
            .task(id: stage.state) { await refreshScreens() }
            .task(id: stage.state) { await narrate() }
    }

    // MARK: - Lo que cuenta cada agente

    /// Mientras un personaje trabaja, cada poco (si hubo novedades) y al terminar, su agente cuenta en una frase lo que ha
    /// ido haciendo; se ve en un bocadillo sobre su cabeza.
    private func narrate() async {
        guard stage.state == .ready else { return }
        var summarized: [UUID: String] = [:]
        var lastAt: [UUID: Date] = [:]
        var active: Set<UUID> = []
        var busy: Set<UUID> = []
        var working: Set<UUID> = []
        while !Task.isCancelled {
            for slot in slots where assignments.working.contains(slot.id) && !store.lightModeEnabled {
                guard let conversation = conversation(in: slot) else { continue }
                let id = conversation.id
                let status = store.statuses[id] ?? .idle
                let finished = active.contains(id) && !status.isActive
                if status.isActive { active.insert(id) } else { active.remove(id) }
                // Cuando el agente deja de trabajar (terminó, falló o pide permiso), la persona se lo cuenta al usuario.
                let busyNow = status == .running || status == .queued
                if working.contains(id), !busyNow {
                    working.remove(id)
                    report(slot: slot, conversation: conversation, status: status)
                } else if busyNow {
                    working.insert(id)
                }
                let key = "\(conversation.messages.count)|\(conversation.messages.last?.text.count ?? 0)"
                guard summarized[id] != key, !busy.contains(id) else { continue }
                let due = finished || (status.isActive && Date().timeIntervalSince(lastAt[id] ?? .distantPast) > 20)
                guard due else { continue }
                summarized[id] = key
                lastAt[id] = Date()
                busy.insert(id)
                let messages = conversation.messages
                let previous = narration[slot.id]
                let name = slot.name, tool = tool(for: slot), slotID = slot.id
                Task {
                    defer { busy.remove(id) }
                    guard let text = try? await narrator.summary(as: name, tool: tool, of: messages, previous: previous,
                                                                 lightMode: store.lightModeEnabled) else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { narration[slotID] = text }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// La persona le cuenta al usuario cómo acabó el encargo, en su chat y en el bocadillo.
    private func report(slot: OfficeLayout.Slot, conversation: ChatConversation, status: ChatStatus) {
        guard !assignments.chat(in: slot.id).isEmpty else { return }
        let worker = OfficeWorker(tool: tool(for: slot), status: status, messages: conversation.messages)
        let history = assignments.chat(in: slot.id)
        Task {
            guard let text = try? await narrator.report(as: slot.name, history: history, worker: worker, lightMode: store.lightModeEnabled) else { return }
            assignments.append(OfficeLine(role: .person, text: text), slot: slot.id)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { narration[slot.id] = text }
            // Quien pidió ayuda se entera de cómo acabó la parte de su compañero.
            if let leader = assignments.leaders[slot.id] {
                assignments.append(OfficeLine(role: .note, text: "\(slot.name): \(text)"), slot: leader)
            }
        }
    }

    // MARK: - Hablar con la persona

    /// El usuario le dice algo a la persona (Enter): el diálogo se cierra y ella se levanta y va a su escritorio. Contesta en su
    /// bocadillo y, si hace falta, le pasa el encargo a su agente y pide ayuda a compañeros libres.
    private func talk(_ text: String, slot index: Int) {
        guard slots.indices.contains(index) else { return }
        let slot = slots[index]
        assignments.append(OfficeLine(role: .user, text: text), slot: slot.id)
        assignments.setWorking(true, slot: slot.id)
        dock = nil
        let conversation = conversation(in: slot)
        let worker = OfficeWorker(tool: tool(for: slot), status: conversation.map { store.statuses[$0.id] ?? .idle },
                                  messages: conversation?.messages ?? [])
        let history = assignments.chat(in: slot.id)
        let team = teamDescription(for: slot), catalog = modelCatalog
        thinking.insert(slot.id)
        Task {
            defer { thinking.remove(slot.id) }
            do {
                let decision = try await narrator.reply(as: slot.name, history: history, worker: worker, team: team, catalog: catalog,
                                                        lightMode: store.lightModeEnabled)
                assignments.append(OfficeLine(role: .person, text: decision.reply), slot: slot.id)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { narration[slot.id] = decision.reply }
                if let task = decision.task { delegate(task, slot: index) }
                if !decision.helpers.isEmpty { recruit(decision.helpers, leader: index) }
            } catch is CancellationError {
            } catch {
                assignments.append(OfficeLine(role: .note, text: "\(slot.name) no pudo contestar: \(error.localizedDescription)"), slot: slot.id)
                withAnimation { narration[slot.id] = "Perdona, ahora mismo no puedo pensar (no responde \(OfficeNarrator.modelName))." }
            }
        }
    }

    /// La persona pide ayuda: cada compañero libre (el que nombró o, si no está libre, otro) se levanta, va a su escritorio y
    /// le pasa su parte a un agente nuevo con el proveedor y el modelo que ella eligió.
    private func recruit(_ helpers: [OfficeHelper], leader index: Int) {
        guard slots.indices.contains(index) else { return }
        let leader = slots[index]
        for helper in helpers {
            let named = slots.firstIndex { $0.id != leader.id && isFree($0)
                && $0.name.compare(helper.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            guard let target = named ?? slots.firstIndex(where: { $0.id != leader.id && isFree($0) }) else {
                assignments.append(OfficeLine(role: .note, text: "No hay compañeros libres para ayudar a \(leader.name)."), slot: leader.id)
                return
            }
            let slot = slots[target]
            let choice = modelChoice(provider: helper.provider, model: helper.model) ?? lastChoice
            workerChoice[slot.id] = choice
            // El ayudante deja lo que tuviera: empieza de cero con su parte.
            if assignments.conversation(in: slot.id) != nil { assignments.clear(slot: slot.id) }
            assignments.clearChat(slot: slot.id)
            assignments.setLeader(leader.id, for: slot.id)
            let tool = "\(choice.provider.title) · \(modelTitle(choice))"
            assignments.append(OfficeLine(role: .note, text: "\(leader.name) le pidió ayuda a \(slot.name), que trabaja con \(tool)."), slot: leader.id)
            assignments.append(OfficeLine(role: .note, text: "\(slot.name) ayuda a \(leader.name) con \(tool)."), slot: slot.id)
            delegate(helper.task, slot: target)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { narration[slot.id] = "Voy, \(leader.name) me pidió una mano." }
        }
    }

    /// Libre: ni en su escritorio, ni con un agente trabajando, ni pensando una respuesta.
    private func isFree(_ slot: OfficeLayout.Slot) -> Bool {
        !assignments.working.contains(slot.id) && !thinking.contains(slot.id)
            && conversation(in: slot).map { store.statuses[$0.id]?.isActive == true } != true
    }

    /// Los compañeros de una persona, para que decida a quién pedir ayuda y sepa cómo van los que ya la ayudan.
    private func teamDescription(for leader: OfficeLayout.Slot) -> String {
        slots.filter { $0.id != leader.id }.map { slot in
            guard !isFree(slot) else { return "- \(slot.name): libre" }
            let conversation = conversation(in: slot)
            let status = conversation.map { (store.statuses[$0.id] ?? .idle).title } ?? "en su escritorio"
            var line = "- \(slot.name): ocupado (\(tool(for: slot)), \(status))"
            if assignments.leaders[slot.id] == leader.id {
                line += ", te está ayudando"
                if let said = conversation?.messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text {
                    line += ". Lo último de su agente: " + String(said.prefix(300)).replacingOccurrences(of: "\n", with: " ")
                }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Los modelos que hay por proveedor, para que la persona elija con cuál trabaja cada ayudante.
    private var modelCatalog: String {
        ChatProvider.allCases.compactMap { provider in
            let choices = store.modelChoices(for: provider).filter { !$0.id.isEmpty }.prefix(8)
            guard !choices.isEmpty else { return nil }
            return "\(provider.rawValue): " + choices.map { "\($0.id) — \($0.title)" }.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    /// El proveedor y el modelo que pidió la persona, solo si existen; si no, `nil`.
    private func modelChoice(provider name: String, model: String) -> OfficeAssignments.ModelChoice? {
        let wanted = name.lowercased()
        guard let provider = ChatProvider.allCases.first(where: { $0.rawValue == wanted || $0.title.lowercased() == wanted }) else { return nil }
        let choices = store.modelChoices(for: provider)
        let id = choices.first { $0.id == model || $0.title.lowercased() == model.lowercased() }?.id ?? ""
        return OfficeAssignments.ModelChoice(provider: provider, model: id)
    }

    /// La persona le pasa el encargo a su agente: al que ya tiene, o a uno nuevo con el modelo elegido, en el proyecto que
    /// Jack encuentre a partir del encargo.
    private func delegate(_ task: String, slot index: Int) {
        guard slots.indices.contains(index) else { return }
        let slot = slots[index]
        assignments.append(OfficeLine(role: .task, text: task), slot: slot.id)
        assignments.setWorking(true, slot: slot.id)
        if let conversation = conversation(in: slot) {
            store.send(task, to: conversation.id)
            return
        }
        let choice = workerChoice[slot.id] ?? lastChoice
        let projects = ProjectIndex.shared.ordered(recent: recentProjects)
        guard let id = store.createLocating(task, provider: choice.provider, model: choice.model.isEmpty ? nil : choice.model, projects: projects) else {
            assignments.append(OfficeLine(role: .note, text: "No se pudo crear el agente: \(store.errorMessage ?? "revisa la configuración de \(choice.provider.title).")"), slot: slot.id)
            return
        }
        assignments.assign(id, to: slot.id)
    }

    /// Las carpetas de proyecto usadas hace poco, para que Jack sitúe los encargos nuevos.
    private var recentProjects: [String] {
        var seen = Set<String>()
        var paths = store.conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.projectPath)
        if let last = UserDefaults.standard.string(forKey: "lastProjectPath") { paths.append(last) }
        return paths.filter { $0 != ProjectLocator.unplacedFolder && FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
    }

    /// El agente que tiene (o tendrá) a su cargo la persona de un puesto, como «Claude Code · Haiku».
    private func tool(for slot: OfficeLayout.Slot) -> String {
        if let conversation = conversation(in: slot) {
            return "\(conversation.provider.title) · \(modelTitle(OfficeAssignments.ModelChoice(provider: conversation.provider, model: conversation.model)))"
        }
        let choice = workerChoice[slot.id] ?? lastChoice
        return "\(choice.provider.title) · \(modelTitle(choice))"
    }

    // MARK: - Monitores

    /// Mientras su personaje trabaja, el monitor enseña su chat: el real, igual que «Ver pantalla» («En vivo»), o un resumen
    /// ligero («Ahorro»). Sigue encendido aunque el agente ya haya contestado, hasta «Terminar de trabajar»; si no, apagado.
    private func refreshScreens() async {
        guard stage.state == .ready else { return }
        var shown: [String: String] = [:]
        var labeled: [String: String] = [:]
        var tvKey = ""
        var tick = 0
        while !Task.isCancelled {
            // La tele: el uso de Claude, al minuto.
            let usage = store.usage[.claude]
            let minute = Int(Date().timeIntervalSince1970 / 60)
            let key = "\(minute)|" + (usage?.windows ?? []).map { "\($0.id):\($0.usedPercent ?? -1):\($0.resetsAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: ",")
            if key != tvKey, let image = OfficeTVView.image(usage: usage, now: Date()) {
                tvKey = key
                stage.setTV(image: image)
            }
            for (index, slot) in slots.enumerated() {
                // El letrero de la pared: el nombre del chat del puesto, en cuanto lo tiene.
                let title = conversation(in: slot)?.title ?? ""
                if labeled[slot.id] != title, stage.setLabel(slot: index, image: title.isEmpty ? nil : OfficeLabelView.image(title: title)) {
                    labeled[slot.id] = title
                }
            }
            let live = graphics.quality.liveScreens
            tick += 1
            for (index, slot) in slots.enumerated() {
                var key = "off"
                var image: CGImage?
                let conversation = conversation(in: slot)
                if let conversation {
                    let status = store.statuses[conversation.id] ?? .idle
                    // Una vez que el agente trabaja, el personaje se queda en su puesto.
                    if status.isActive, !assignments.working.contains(slot.id) { assignments.setWorking(true, slot: slot.id) }
                }
                if let conversation, assignments.working.contains(slot.id) {
                    let status = store.statuses[conversation.id] ?? .idle
                    let last = conversation.messages.last
                    let ultrawide = (slot.monitor ?? "").contains("ultrawide")
                    key = "\(live)|\(conversation.id)|\(conversation.messages.count)|\(last?.text.count ?? 0)|\(last?.status ?? "")|\(status)|\(conversation.model)"
                    if live {
                        // En vivo: mientras el agente trabaja se fotografía en cada vuelta (el texto llega a trozos); la que se
                        // está mirando de cerca no hace falta, porque encima ya está el chat de verdad.
                        if status.isActive { key += "|\(tick)" }
                        if viewing == index { continue }
                        // Al tamaño exacto de la vista real de «Ver pantalla»: al acercarse se ve lo mismo, sin saltos.
                        let size = closeUpSize(index) ?? (ultrawide ? CGSize(width: 1260, height: 540) : CGSize(width: 960, height: 540))
                        key += "|\(Int(size.width))x\(Int(size.height))"
                        if shown[slot.id] != key {
                            let screen = liveScreens[slot.id] ?? OfficeLiveScreen(size: size)
                            screen.resize(to: size)
                            liveScreens[slot.id] = screen
                            screen.show(conversation.id, AnyView(dockContent(.agent(conversation.id)).background(JackPalette.canvas)))
                            image = screen.snapshot()
                        }
                    } else if shown[slot.id] != key {
                        image = OfficeMonitorView.image(conversation: conversation, status: status, model: conversation.model,
                                                        size: ultrawide ? CGSize(width: 1260, height: 540) : CGSize(width: 960, height: 540))
                    }
                }
                // Sin trabajo en vivo, su ventana invisible sobra.
                if !live || key == "off" { liveScreens[slot.id] = nil }
                guard shown[slot.id] != key else { continue }
                shown[slot.id] = key
                stage.setScreen(slot: slot.id, image: image)
            }
            try? await Task.sleep(for: .milliseconds(Int(graphics.quality.screenInterval * 1000)))
        }
    }

    // MARK: - Puestos y estado

    private func conversation(in slot: OfficeLayout.Slot) -> ChatConversation? {
        assignments.conversation(in: slot.id).flatMap { found in store.conversations.first { $0.id == found } }
    }

    private func freeSlot() -> String? {
        slots.first { conversation(in: $0) == nil }?.id
    }

    /// Qué hace cada personaje según lo que hace su agente: ejecutando se sienta a teclear; esperando
    /// una respuesta o mandado a trabajar teclea despacio; con error se queda en el sofá negando con la cabeza.
    private var commands: [OfficeCommand] {
        slots.map { slot in
            let atDesk = assignments.working.contains(slot.id)
            guard let conversation = conversation(in: slot) else { return atDesk ? .desk(waiting: true) : .sofa(failed: false) }
            switch store.statuses[conversation.id] ?? .idle {
            case .running: return .desk(waiting: false)
            case .waiting, .queued: return .desk(waiting: true)
            case .failed: return atDesk ? .desk(waiting: true) : .sofa(failed: true)
            case .idle: return atDesk ? .desk(waiting: true) : .sofa(failed: false)
            }
        }
    }

    private func sendCommands() {
        for (index, command) in commands.enumerated() { stage.command(command, forSlot: index) }
    }

    // MARK: - Acciones

    /// Pulsar a un personaje (o su escritorio) solo abre sus acciones; no hace nada más.
    private func pick(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        OfficeSound.open.play()
        actions = OfficeActions(slot: index)
    }

    /// Las acciones que salen alrededor de un personaje, según el paso en que va.
    private func pills(for menu: OfficeActions) -> [OfficePill] {
        guard slots.indices.contains(menu.slot) else { return [] }
        let index = menu.slot
        let slot = slots[index]
        let conversation = conversation(in: slot)
        let working = assignments.working.contains(slot.id) || conversation.map { store.statuses[$0.id]?.isActive == true } == true
        func go(_ step: OfficeActions.Step) -> () -> Void { { actions?.step = step } }
        let parent: OfficeActions.Step = switch menu.step {
        case .root, .work: .root
        case .providers, .previous: .work
        case .models: .providers
        }
        let back = OfficePill(title: "Volver", symbol: "chevron.left", tint: .gray, back: true, action: go(parent))
        switch menu.step {
        case .root:
            let changeAvatar = OfficePill(title: "Cambiar avatar", symbol: "person.crop.circle", tint: .purple) { actions = nil; choosingAvatar = index }
            guard working else { return [OfficePill(title: "Trabajar", symbol: "keyboard", tint: .orange, action: go(.work)), changeAvatar] }
            var items: [OfficePill] = []
            items.append(OfficePill(title: "Hablar con \(slot.name)", symbol: "text.bubble", tint: .blue) { actions = nil; openChat(slot: index) })
            // Su monitor solo está encendido mientras trabaja con un agente.
            if conversation != nil, assignments.working.contains(slot.id) {
                items.append(OfficePill(title: "Ver pantalla", symbol: "display", tint: .teal) { actions = nil; viewScreen(index) })
            }
            items.append(OfficePill(title: "Terminar de trabajar", symbol: "moon.zzz", tint: .purple) { actions = nil; stopWorking(slot: index) })
            items.append(changeAvatar)
            return items
        case .work:
            // Lo primero, un encargo nuevo con el último modelo elegido; «Otro modelo» deja escoger otro.
            let last = lastChoice
            var items = [OfficePill(title: "Encargo nuevo · \(modelTitle(last))", symbol: "sparkles", tint: .orange) {
                actions = nil
                startNew(slot: index, provider: last.provider, model: last.model)
            }]
            if let conversation {
                items.append(OfficePill(title: "Seguir con «\(Self.short(conversation.title))»", symbol: "arrow.uturn.forward", tint: .blue) {
                    actions = nil
                    openChat(slot: index)
                })
            }
            items.append(OfficePill(title: "Otro modelo", symbol: "cpu", tint: .orange, action: go(.providers)))
            items.append(OfficePill(title: "Trabajo previo", symbol: "clock.arrow.circlepath", tint: .teal, action: go(.previous)))
            items.append(back)
            return items
        case .providers:
            var items = ChatProvider.allCases.map { provider in
                OfficePill(title: provider.title, symbol: provider == lastChoice.provider ? "checkmark" : "sparkles", tint: .orange,
                           action: go(.models(provider)))
            }
            items.append(back)
            return items
        case .models(let provider):
            let chosen = lastChoice
            var choices = store.modelChoices(for: provider).map { (id: $0.id, title: $0.title) }
            if choices.isEmpty { choices = [(id: "", title: "Modelo predeterminado")] }
            var items = choices.map { choice in
                let current = chosen.provider == provider && chosen.model == choice.id
                return OfficePill(title: choice.title.isEmpty ? "Modelo predeterminado" : choice.title,
                                  symbol: current ? "checkmark" : "cpu", tint: .orange) {
                    actions = nil
                    startNew(slot: index, provider: provider, model: choice.id)
                }
            }
            items.append(back)
            return items
        case .previous:
            var items = store.conversations.filter { $0.parentID == nil }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8).map { chat in
                OfficePill(title: Self.short(chat.title), symbol: "bubble.left", tint: .teal) { actions = nil; choose(chat.id, slot: index) }
            }
            if items.isEmpty { items.append(OfficePill(title: "Aún no hay trabajos", symbol: "bubble.left", tint: .gray, action: {})) }
            items.append(back)
            return items
        }
    }

    /// El último proveedor y modelo elegidos; si nunca se eligió ninguno, el proveedor del último agente nuevo con su modelo por defecto.
    private var lastChoice: OfficeAssignments.ModelChoice {
        if let last = assignments.lastModel { return last }
        let provider = UserDefaults.standard.string(forKey: "lastNewAgentProvider").flatMap(ChatProvider.init(rawValue:)) ?? .codex
        return OfficeAssignments.ModelChoice(provider: provider, model: "")
    }

    private func modelTitle(_ choice: OfficeAssignments.ModelChoice) -> String {
        let id = choice.model.isEmpty ? choice.provider.defaultModel : choice.model
        let title = store.modelChoices(for: choice.provider).first { $0.id == id }?.title ?? id
        return Self.short(title.isEmpty ? choice.provider.title : title)
    }

    private static func short(_ title: String) -> String {
        title.count > 26 ? String(title.prefix(25)) + "…" : title
    }

    /// Abre el chat con la persona de un puesto.
    private func openChat(slot index: Int) {
        guard slots.indices.contains(index) else { return }
        if let conversation = conversation(in: slots[index]) { store.setUnread(conversation.id, false) }
        dock = OfficeDock(slot: index)
    }

    /// La persona retoma un trabajo previo: ese chat pasa a ser el de su agente.
    private func choose(_ id: UUID, slot index: Int) {
        guard slots.indices.contains(index) else { return }
        let slot = slots[index]
        if assignments.conversation(in: slot.id) != id, let chat = store.conversations.first(where: { $0.id == id }) {
            assignments.append(OfficeLine(role: .note, text: "\(slot.name) retoma «\(chat.title)» con \(chat.provider.title)."), slot: slot.id)
        }
        assignments.assign(id, to: slot.id)
        openChat(slot: index)
    }

    /// Un encargo nuevo con el proveedor y el modelo elegidos (por defecto, los últimos): se abre el chat con la persona, que
    /// deja el trabajo anterior; se levanta al recibir el primer mensaje, y el agente se crea con su primer encargo.
    private func startNew(slot index: Int, provider: ChatProvider? = nil, model: String? = nil) {
        guard slots.indices.contains(index) else { return }
        let slot = slots[index]
        let choice = provider.map { OfficeAssignments.ModelChoice(provider: $0, model: model ?? "") } ?? lastChoice
        assignments.remember(provider: choice.provider, model: choice.model)
        workerChoice[slot.id] = choice
        if assignments.conversation(in: slot.id) != nil || !assignments.chat(in: slot.id).isEmpty {
            assignments.clear(slot: slot.id)
            assignments.clearChat(slot: slot.id)
        }
        assignments.setLeader(nil, for: slot.id)
        narration[slot.id] = nil
        openChat(slot: index)
    }

    // MARK: - Avatares

    /// Al abrir la oficina, cada puesto se pone el avatar que tenía elegido (si no es el de siempre).
    private func restoreAvatars() {
        guard stage.state == .ready else { return }
        for (index, slot) in slots.enumerated() where avatars.avatar(for: slot) != slot.file {
            Task { await stage.setAvatar(avatars.avatar(for: slot), forSlot: index) }
        }
    }

    private func chooseAvatar(_ avatar: String, slot index: Int) {
        guard slots.indices.contains(index) else { return }
        choosingAvatar = nil
        avatars.choose(avatar, for: slots[index])
        Task { await stage.setAvatar(avatar, forSlot: index) }
    }

    // MARK: - Ver pantalla

    /// La cámara se pone justo delante del monitor del personaje, que se aparta para no taparlo; al llegar, en el monitor
    /// aparece el chat tal cual se ve en el modo Normal, para leerlo y seguir escribiendo.
    private func viewScreen(_ index: Int) {
        guard slots.indices.contains(index), stage.screenFrame(slot: index) != nil else { return }
        closeDock()
        if let conversation = conversation(in: slots[index]) {
            if store.selectedID != conversation.id { store.select(conversation.id) }
            store.setUnread(conversation.id, false)
        }
        screenReady = false
        withAnimation(.easeOut(duration: 0.3)) { viewing = index }
        focusScreen(index)
        for (other, actor) in stage.actors.enumerated() { actor.concealed = other == index }
        // La vista real se pone encima cuando la cámara se detiene. En vivo, el monitor ya muestra lo mismo al mismo tamaño,
        // así que aparece sin fundido: solo pasa a poder tocarse. Con el resumen ligero sí se funde.
        let live = graphics.quality.liveScreens
        Task {
            for _ in 0..<60 where !camera.isSettled {
                try? await Task.sleep(for: .milliseconds(50))
                guard viewing == index else { return }
            }
            guard viewing == index else { return }
            if live { screenReady = true } else { withAnimation(.easeOut(duration: 0.3)) { screenReady = true } }
        }
    }

    /// El tamaño en puntos que tendrá el cristal de un monitor al mirarlo de cerca (el mismo cálculo que el encuadre de la
    /// cámara: la pantalla llena el ancho o el alto de la vista, con su margen).
    private func closeUpSize(_ index: Int) -> CGSize? {
        guard let frame = stage.screenFrame(slot: index), frame.size.y > 0, sceneSize.width > 0, sceneSize.height > 0 else { return nil }
        let aspect = CGFloat(frame.size.x / frame.size.y)
        let width = min(sceneSize.width, sceneSize.height * aspect) / CGFloat(OfficeCamera.closeUpMargin)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    /// El cristal del monitor en la vista, ya con la cámara delante.
    private func screenRect(_ index: Int) -> CGRect? {
        guard let frame = stage.screenFrame(slot: index) else { return nil }
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(frame.facing, up))
        let corners = [(-1, -1), (-1, 1), (1, -1), (1, 1)].compactMap { x, y in
            camera.projectGoal(frame.center + right * frame.size.x / 2 * Float(x) + up * frame.size.y / 2 * Float(y), in: sceneSize)
        }
        guard corners.count == 4, let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max(), maxX - minX > 200, maxY - minY > 120 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func focusScreen(_ index: Int) {
        guard let frame = stage.screenFrame(slot: index) else { return }
        camera.focus(screen: frame.center, facing: frame.facing, size: frame.size, view: sceneSize)
    }

    private func leaveScreen() {
        screenReady = false
        camera.leaveFocus()
        for actor in stage.actors { actor.concealed = false }
        withAnimation(.easeOut(duration: 0.25)) { viewing = nil }
    }

    /// Se cierra el panel sin enviar nada: la persona sigue donde estaba.
    private func closeDock() {
        dock = nil
    }

    /// El agente deja de trabajar: se detiene si estaba ejecutando y su personaje vuelve al sofá.
    private func stopWorking(slot index: Int) {
        guard slots.indices.contains(index) else { return }
        let slot = slots[index]
        if let conversation = conversation(in: slot), store.statuses[conversation.id]?.isActive == true { store.stop(conversation.id) }
        assignments.setWorking(false, slot: slot.id)
        assignments.setLeader(nil, for: slot.id)
        narration[slot.id] = nil
        dock = nil
    }

    // MARK: - Capas

    private var sidebarButton: some View {
        Button(action: onShowSidebar) { Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.45), in: Circle())
            .padding(.top, 10).padding(.leading, 80)
            .help("Mostrar la barra lateral")
    }

    /// Las burbujas de los personajes, ancladas a su cabeza: se mueven con la cámara.
    @ViewBuilder private var anchoredOverlay: some View {
        if stage.state == .ready, viewing == nil {
            TimelineView(.animation(minimumInterval: graphics.quality.hudInterval)) { _ in
                ZStack {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        let conversation = conversation(in: slot)
                        let said = assignments.working.contains(slot.id) ? narration[slot.id] : nil
                        if conversation != nil || said != nil, stage.actors.indices.contains(index),
                           let point = camera.projectCurrent(stage.actors[index].headPosition, in: sceneSize) {
                            VStack(spacing: 6) {
                                if let said { OfficeSpeechBubble(text: said).transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)) }
                                if let conversation {
                                    let status = store.statuses[conversation.id] ?? .idle
                                    OfficeModelBubble(store: store, conversation: conversation, status: status,
                                                      badge: badge(for: conversation, status: status, slot: index),
                                                      onBadge: { openChat(slot: index) })
                                }
                            }
                            .modifier(OfficeAnchor(point: point, lift: 12,
                                                   size: CGSize(width: said == nil ? 190 : 260, height: (said == nil ? 0 : 80) + (conversation == nil ? 0 : 34)),
                                                   bounds: sceneSize))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if let actions, stage.actors.indices.contains(actions.slot),
                       let chest = camera.projectCurrent(stage.actors[actions.slot].chestPosition, in: sceneSize) {
                        OfficePillMenu(items: pills(for: actions), anchor: chest, bounds: sceneSize)
                            .id(actions)
                    }
                    if let index = choosingAvatar, slots.indices.contains(index), stage.actors.indices.contains(index),
                       let chest = camera.projectCurrent(stage.actors[index].chestPosition, in: sceneSize) {
                        OfficeAvatarPicker(
                            current: avatars.avatar(for: slots[index]),
                            taken: Set(slots.indices.filter { $0 != index }.map { avatars.avatar(for: slots[$0]) }),
                            anchor: chest, bounds: sceneSize,
                            onPick: { chooseAvatar($0, slot: index) }, onClose: { choosingAvatar = nil }
                        )
                    }
                }
            }
        }
    }

    /// El chat real (el mismo del modo Normal) encajado en el cristal del monitor que se mira.
    @ViewBuilder private var screenContent: some View {
        if let viewing, screenReady, slots.indices.contains(viewing), let conversation = conversation(in: slots[viewing]),
           let rect = screenRect(viewing) {
            // Igual que se dibuja en el monitor (mismo tamaño y fondo), para que al aparecer no cambie nada.
            let size = closeUpSize(viewing) ?? rect.size
            dockContent(.agent(conversation.id))
                .frame(width: size.width, height: size.height)
                .background(JackPalette.canvas)
                .clipped()
                .position(x: rect.midX, y: rect.midY)
                .transition(graphics.quality.liveScreens ? .identity : .opacity)
        }
    }

    /// Mientras se mira una pantalla: quién la usa y volver a la sala. Esc se deja al chat, como en el modo Normal.
    @ViewBuilder private var screenOverlay: some View {
        if let viewing, slots.indices.contains(viewing) {
            let slot = slots[viewing]
            HStack(spacing: 6) {
                Button(action: leaveScreen) {
                    Label("Volver a la oficina", systemImage: "chevron.left")
                }
                .help("Volver a la oficina")
                Text(slot.name).font(.office(12.5, .bold)).foregroundStyle(.white.opacity(0.6)).padding(.trailing, 8)
            }
            .buttonStyle(OfficeGlassButtonStyle())
            .padding(5)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// El aviso sobre un personaje: verde si contestó, amarillo si necesita algo del usuario, rojo si falló.
    private func badge(for conversation: ChatConversation, status: ChatStatus, slot index: Int) -> OfficeBadge? {
        switch status {
        case .waiting: return .needsYou
        case .failed: return .failed
        case .idle where conversation.hasUnread == true && dock?.slot != index: return .replied
        default: return nil
        }
    }

    @ViewBuilder private var dockOverlay: some View {
        if let dock, slots.indices.contains(dock.slot) {
            let slot = slots[dock.slot]
            let conversation = conversation(in: slot)
            let status = conversation.map { store.statuses[$0.id] ?? .idle }
            OfficeColleagueView(
                name: slot.name,
                tool: tool(for: slot),
                status: status,
                lines: assignments.chat(in: slot.id),
                thinking: thinking.contains(slot.id),
                canViewScreen: conversation != nil && assignments.working.contains(slot.id),
                working: assignments.working.contains(slot.id) || status?.isActive == true,
                previous: store.conversations.filter { $0.parentID == nil }.sorted { $0.updatedAt > $1.updatedAt }
                    .map { OfficeChat(id: $0.id, title: $0.title, project: URL(fileURLWithPath: $0.projectPath).lastPathComponent,
                                      status: store.statuses[$0.id] ?? .idle, current: $0.id == conversation?.id) },
                mode: Binding(get: { dock.mode }, set: { self.dock?.mode = $0 }),
                onSend: { talk($0, slot: dock.slot) },
                onViewScreen: { viewScreen(dock.slot) },
                onChoose: { choose($0, slot: dock.slot) },
                onNewJob: { startNew(slot: dock.slot) },
                onStopWork: { stopWorking(slot: dock.slot) },
                onClose: closeDock
            )
            .id(slot.id)
            .padding(.bottom, 14).padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dock.mode)
        }
    }
}

// MARK: - Botones

private struct OfficeGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.office(12.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.1), in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Burbujas

/// La tipografía de la oficina: redondeada, como los menús del juego.
extension Font {
    static func office(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// El naranja de las burbujas.
private enum OfficeOrange {
    static let top = Color(red: 1.0, green: 0.66, blue: 0.27)
    static let bottom = Color(red: 0.96, green: 0.45, blue: 0.09)
    static var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom) }
}

/// Coloca una burbuja con su pico justo encima de un punto de la vista.
private struct OfficeAnchor: ViewModifier {
    let point: CGPoint
    let lift: CGFloat
    /// Tamaño aproximado de la burbuja y de la vista: la burbuja se desplaza lo justo para verse siempre entera.
    var size = CGSize(width: 180, height: 40)
    var bounds = CGSize(width: 1000, height: 700)

    func body(content: Content) -> some View {
        let x = min(max(point.x, size.width / 2 + 10), max(size.width / 2 + 10, bounds.width - size.width / 2 - 10))
        let y = min(max(point.y, size.height + lift + 10), max(size.height + lift + 10, bounds.height - 10))
        content
            .fixedSize()
            .alignmentGuide(.leading) { $0.width / 2 }
            .alignmentGuide(.top) { $0.height + lift }
            .offset(x: x, y: y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// El aviso de un personaje.
enum OfficeBadge {
    case replied, needsYou, failed

    var color: Color {
        switch self {
        case .replied: Color(red: 0.2, green: 0.8, blue: 0.4)
        case .needsYou: Color(red: 1, green: 0.78, blue: 0.1)
        case .failed: Color(red: 0.95, green: 0.25, blue: 0.22)
        }
    }

    var symbol: String {
        switch self {
        case .replied: "checkmark"
        case .needsYou: "questionmark"
        case .failed: "exclamationmark"
        }
    }

    var help: String {
        switch self {
        case .replied: "Contestó: pulsa para ver la respuesta"
        case .needsYou: "Necesita algo de ti: pulsa para verlo"
        case .failed: "Falló: pulsa para ver qué pasó"
        }
    }
}

/// Una burbuja de diálogo naranja con su pico hacia abajo.
private struct OfficeBubble<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: -1) {
            content
                .background(OfficeOrange.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1.6))
            OfficeTail()
                .fill(OfficeOrange.bottom)
                .overlay(OfficeTail().stroke(.white.opacity(0.7), lineWidth: 1.6))
                .frame(width: 16, height: 9)
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }
}

private struct OfficeTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Sobre un personaje con agente: el modelo con el que trabaja, que se cambia con un toque,
/// y su aviso (verde, amarillo o rojo) cuando hay algo que ver.
private struct OfficeModelBubble: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    let status: ChatStatus
    let badge: OfficeBadge?
    let onBadge: () -> Void

    private var choices: [ChatModelChoice] { store.modelChoices(for: conversation.provider) }
    private var title: String { choices.first { $0.id == conversation.model }?.title ?? (conversation.model.isEmpty ? "Modelo" : conversation.model) }

    var body: some View {
        OfficeBubble {
            Menu {
                ForEach(choices) { choice in
                    Button {
                        store.updateSettings(id: conversation.id, model: choice.id, effort: conversation.effort)
                    } label: {
                        if choice.id == conversation.model { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.office(12.5, .bold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .heavy)).opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(status.isActive)
            .help(status.isActive ? "Detén el agente para cambiar de modelo" : "Cambiar el modelo de \(conversation.title)")
        }
        .overlay(alignment: .topTrailing) {
            if let badge {
                Button(action: onBadge) {
                    Image(systemName: badge.symbol).font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(badge.color, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                }
                .buttonStyle(.plain).help(badge.help)
                .offset(x: 9, y: -9)
            }
        }
    }
}

/// Lo que cuenta el agente, en un bocadillo blanco sobre su personaje.
private struct OfficeSpeechBubble: View {
    let text: String

    var body: some View {
        VStack(spacing: -1) {
            Text(text)
                .font(.office(12, .medium))
                .foregroundStyle(Color(red: 0.13, green: 0.12, blue: 0.16))
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            OfficeTail().fill(.white).frame(width: 14, height: 8)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .help(text)
    }
}

// MARK: - Estado

struct OfficeStatusPill: View {
    let status: ChatStatus

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch status {
        case .idle: "Libre"
        case .queued: "En cola"
        case .running: "Trabajando"
        case .waiting: "Te espera"
        case .failed: "Error"
        }
    }

    private var color: Color {
        switch status {
        case .idle: JackPalette.muted
        case .queued: JackPalette.amber
        case .running: JackPalette.green
        case .waiting: JackPalette.blue
        case .failed: JackPalette.red
        }
    }
}

// MARK: - Acciones al estilo de Los Sims

/// Una acción de las que salen alrededor de un personaje.
struct OfficePill {
    enum Tint { case orange, blue, purple, teal, gray }

    var title: String
    var symbol: String
    var tint: Tint
    var back = false
    var action: () -> Void

    init(title: String, symbol: String, tint: Tint, back: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.back = back
        self.action = action
    }
}

/// Las acciones de un personaje: píldoras blancas con letra azul oscura repartidas a los lados del pecho y una arriba, como el
/// menú de interacción de Los Sims. Cada una suena al abrirse, al pasar el ratón y al elegirla.
private struct OfficePillMenu: View {
    let items: [OfficePill]
    let anchor: CGPoint
    let bounds: CGSize

    @State private var shown = false
    @State private var hovered: Int?

    var body: some View {
        // Las píldoras salen a ambos lados del pecho: se deja sitio para las más anchas.
        let margin = min(320, bounds.width / 2)
        let cx = min(max(anchor.x, margin), max(margin, bounds.width - margin))
        let cy = min(max(anchor.y, 120), max(120, bounds.height - 90 - CGFloat((items.count / 2) * 44)))
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                pill(item, index: index)
                    .modifier(OfficePillPlace(index: index, center: CGPoint(x: cx, y: cy)))
                    .scaleEffect(shown ? (hovered == index ? 1.05 : 1) : 0.5)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.72).delay(Double(index) * 0.035), value: shown)
                    .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { shown = true }
    }

    private func pill(_ item: OfficePill, index: Int) -> some View {
        Button {
            (item.back ? OfficeSound.back : OfficeSound.select).play()
            item.action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(color(item.tint), in: Circle())
                Text(item.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.25, blue: 0.46))
                    .lineLimit(1)
            }
            .padding(.leading, 5).padding(.trailing, 14).padding(.vertical, 4)
            .background(Capsule().fill(hovered == index ? Color(red: 0.88, green: 0.95, blue: 1) : .white))
            .overlay(Capsule().strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { if hovered != index { OfficeSound.hover.play() }; hovered = index } else if hovered == index { hovered = nil }
        }
    }

    private func color(_ tint: OfficePill.Tint) -> Color {
        switch tint {
        case .orange: Color(red: 0.98, green: 0.55, blue: 0.14)
        case .blue: Color(red: 0.22, green: 0.55, blue: 0.95)
        case .purple: Color(red: 0.55, green: 0.38, blue: 0.9)
        case .teal: Color(red: 0.14, green: 0.7, blue: 0.7)
        case .gray: Color(red: 0.55, green: 0.6, blue: 0.68)
        }
    }
}

/// Coloca una píldora respecto al pecho del personaje: la primera arriba, las demás a los lados en filas.
private struct OfficePillPlace: ViewModifier {
    let index: Int
    let center: CGPoint

    func body(content: Content) -> some View {
        let stagger: [CGFloat] = [0, -14, 26]
        if index == 0 {
            content.fixedSize()
                .alignmentGuide(.leading) { $0.width / 2 }.alignmentGuide(.top) { $0.height / 2 }
                .offset(x: center.x, y: center.y - 78)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let side = (index - 1) % 2 == 0 ? -1.0 : 1.0
            let row = (index - 1) / 2
            let offset = stagger[row % 3]
            content.fixedSize()
                // Las de la izquierda quedan con su borde derecho junto al personaje; las de la derecha, con el izquierdo.
                .alignmentGuide(.leading) { side < 0 ? $0.width : 0 }
                .alignmentGuide(.top) { $0.height / 2 }
                .offset(x: center.x + CGFloat(side) * (62 + (side < 0 ? -offset : offset)), y: center.y - 22 + CGFloat(row) * 42)
                // Cada píldora en su propio marco: si no, las de la izquierda ensanchan el grupo y lo desplazan.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
