import AppKit
import JackCore
import SwiftUI

struct Office2DView: View {
    @StateObject private var viewModel: Office2DViewModel
    @StateObject private var choreographer = Office2DChoreographer()
    @ObservedObject private var batterySaver: BatterySaver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var sidebarOpen = false
    @State private var floor = 0
    @State private var viewportWidth: CGFloat = 1100
    @State private var appActive = NSApp.isActive
    @State private var windowVisible = true
    @AppStorage("office2DAnimations") private var animationsEnabled = true
    @State private var plantsWatered = false
    @State private var coffeeCount = 0
    private let suspended: Bool
    private let sidebarVisible: Bool
    private let onShowSidebar: () -> Void
    private let onNew: () -> Void

    init(store: ChatStore, batterySaver: BatterySaver, sidebarVisible: Bool = true, suspended: Bool = false,
         onShowSidebar: @escaping () -> Void = {}, onNew: @escaping () -> Void = {}, onOpen: @escaping (UUID) -> Void) {
        _viewModel = StateObject(wrappedValue: Office2DViewModel(store: store, onOpen: onOpen))
        _batterySaver = ObservedObject(wrappedValue: batterySaver)
        self.suspended = suspended
        self.sidebarVisible = sidebarVisible
        self.onShowSidebar = onShowSidebar
        self.onNew = onNew
    }

    private var animate: Bool {
        return isVisible && !suspended && animationsEnabled && !batterySaver.isOn && !reduceMotion && appActive && windowVisible
    }

    private var workingCount: Int { viewModel.agents.filter { $0.state == .working || $0.state == .thinking }.count }
    private var waitingCount: Int { viewModel.agents.filter { $0.state == .waiting || $0.state == .blocked }.count }
    private var cameraZoom: CGFloat { selectedID == nil ? 1 : 1.45 }
    private var floorCount: Int { max(1, (viewModel.agents.count + 11) / 12) }
    private var visibleAgents: [Office2DAgent] { Array(viewModel.agents.dropFirst(floor * 12).prefix(12)) }

    var body: some View {
        GeometryReader { proxy in
            let topInset: CGFloat = sidebarVisible ? 116 : 136
            let sideInset: CGFloat = sidebarOpen && proxy.size.width > 900 ? 310 : 0
            let available = CGSize(width: max(1, proxy.size.width - sideInset), height: max(1, proxy.size.height - topInset))
            let scale = min(available.width / Office2DNav.world.width, available.height / Office2DNav.world.height) * 0.99
            ZStack(alignment: .topLeading) {
                Color(red: 0.035, green: 0.047, blue: 0.10).ignoresSafeArea()
                officeWorld(scale: scale, available: available, viewport: proxy.size, topInset: topInset)
                if viewModel.agents.isEmpty {
                    emptyState.padding(.leading, 20).padding(.bottom, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                header
                if !viewModel.agents.isEmpty {
                    if sidebarOpen { sidebar.frame(width: min(286, proxy.size.width - 32)).padding(.top, topInset).padding(.trailing, 12).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing) }
                    if let selected = selectedAgent { detailCard(selected).frame(maxHeight: proxy.size.height - 135).padding(.leading, 16).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onExitCommand { select(nil) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                windowVisible = NSApp.mainWindow?.occlusionState.contains(.visible) ?? true
            }
        }
        .background(Color(red: 0.035, green: 0.047, blue: 0.10))
        .environment(\.colorScheme, .dark)
    }

    private var selectedAgent: Office2DAgent? { viewModel.agents.first { $0.id == selectedID } }

    private func officeWorld(scale: CGFloat, available: CGSize, viewport: CGSize, topInset: CGFloat) -> some View {
        let layout = Office2DNav.layout(agentCount: max(3, visibleAgents.count))
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            ZStack {
                worldCanvas(layout: layout, date: context.date, animate: animate)
                    .frame(width: Office2DNav.world.width, height: Office2DNav.world.height)
                    .scaleEffect(scale * cameraZoom, anchor: .center)
                    .position(x: available.width / 2,
                              y: topInset + available.height / 2)
                    .offset(cameraOffset(layout: layout, scale: scale, viewport: viewport, topInset: topInset))
                    .clipped()
            }
            .frame(width: viewport.width, height: viewport.height)
            .clipped()
        }
        .onAppear {
            choreographer.reduceMotion = !animate
            choreographer.update(agents: visibleAgents, layout: layout, now: Date())
        }
        .onChange(of: animate) { _, value in choreographer.reduceMotion = !value }
        .onChange(of: visibleAgents) { _, agents in
            choreographer.update(agents: agents, layout: layout, now: Date())
        }
        .onChange(of: viewModel.agents) { _, agents in
            if floor >= floorCount { floor = floorCount - 1 }
            if let selectedID, !agents.contains(where: { $0.id == selectedID }) { select(nil) }
        }
    }

    private func worldCanvas(layout: Office2DLayout, date: Date, animate: Bool) -> some View {
        let deskAgents = layout.desks.indices.map { index in index < visibleAgents.count ? visibleAgents[index] : nil }
        return ZStack(alignment: .topLeading) {
            Office2DSceneView(layout: layout, agentsByDesk: deskAgents, date: date, animate: animate, plantWatered: plantsWatered)
            Color.clear.contentShape(Rectangle()).onTapGesture { select(nil) }
            decorInteractions
            ForEach(layout.desks, id: \.index) { desk in
                if visibleAgents.indices.contains(desk.index) {
                    let agent = visibleAgents[desk.index]
                    Button { select(agent.id) } label: {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(selectedID == agent.id ? 0.08 : 0.001))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(officeAccent.opacity(selectedID == agent.id ? 0.65 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .frame(width: desk.deskFrame.width, height: desk.deskFrame.height)
                    .position(x: desk.deskFrame.midX, y: desk.deskFrame.midY)
                    .help("Ver el puesto de \(agent.name)")
                    .accessibilityLabel("Puesto de \(agent.name)")
                }
            }
            ForEach(visibleAgents) { agent in
                characterView(agent, layout: layout, date: date, animate: animate)
            }
        }
    }

    @ViewBuilder
    private func characterView(_ agent: Office2DAgent, layout: Office2DLayout, date: Date, animate: Bool) -> some View {
        if let placement = choreographer.placement(for: agent.id, now: date) {
            let character = Office2DCharacterView(agent: agent, placement: placement, date: date, animate: animate,
                                                isSelected: selectedID == agent.id, isHovered: hoveredID == agent.id)
            let frame = office2DCharacterFrame(for: placement)
            character.frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .contentShape(Rectangle())
                .onHover { hoveredID = $0 ? agent.id : (hoveredID == agent.id ? nil : hoveredID) }
                .onTapGesture(count: 2) { viewModel.open(agentID: agent.id) }
                .onTapGesture { select(agent.id) }
                .help([agent.name, agent.activity].compactMap { $0 }.joined(separator: " · "))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(agent.name), \(stateTitle(agent.state))\(agent.activity.map { ", \($0)" } ?? "")")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { select(agent.id) }
                .contextMenu {
                    Button("Abrir conversación", systemImage: "text.bubble") { viewModel.open(agentID: agent.id) }
                    if agent.state == .idle {
                        Button("Saludar", systemImage: "hand.wave") { choreographer.greet(agentID: agent.id, now: Date()) }
                        Button("Ir a por café", systemImage: "cup.and.saucer") { choreographer.visitLounge(agentID: agent.id, spot: 0, now: Date()) }
                        Button("Descansar en el sofá", systemImage: "sofa") { choreographer.visitLounge(agentID: agent.id, spot: 3, now: Date()) }
                    }
                }
        }
    }

    private func cameraOffset(layout: Office2DLayout, scale: CGFloat, viewport: CGSize, topInset: CGFloat) -> CGSize {
        guard let selectedID, let placement = choreographer.placement(for: selectedID, now: Date()) else { return .zero }
        let worldCenter = CGPoint(x: layout.size.width / 2, y: layout.size.height / 2)
        let contentWidth = viewport.width - (sidebarOpen && viewport.width > 900 ? 310 : 0)
        let inspectorOffset: CGFloat = contentWidth < 900 ? min(150, contentWidth * 0.22) : 0
        return CGSize(width: (worldCenter.x - placement.position.x) * cameraZoom * scale + inspectorOffset,
                      height: (worldCenter.y - placement.position.y) * cameraZoom * scale)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if !sidebarVisible {
                    Button(action: onShowSidebar) { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }
                        .buttonStyle(Office2DIconButtonStyle()).help("Mostrar la barra lateral")
                }
                brandIcon
                Text("Oficina 2D").font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                OfficePresentationPicker()
                Button(action: onNew) { Image(systemName: "plus").frame(width: 30, height: 30) }
                    .buttonStyle(Office2DIconButtonStyle()).help("Nuevo agente").accessibilityLabel("Nuevo agente")
                Button { animationsEnabled.toggle() } label: {
                    Image(systemName: animationsEnabled ? "pause" : "play").frame(width: 30, height: 30)
                }
                .buttonStyle(Office2DIconButtonStyle())
                .help(animationsEnabled ? "Pausar animaciones" : "Activar animaciones")
                .accessibilityLabel(animationsEnabled ? "Pausar animaciones" : "Activar animaciones")
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { sidebarOpen.toggle() } } label: {
                    Image(systemName: "person.2").frame(width: 30, height: 30)
                }
                .buttonStyle(Office2DIconButtonStyle()).help(sidebarOpen ? "Ocultar agentes" : "Mostrar agentes")
                .accessibilityLabel(sidebarOpen ? "Ocultar agentes" : "Mostrar agentes")
            }
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        statChip(value: workingCount, title: "trabajando", color: .mint)
                        statChip(value: waitingCount, title: "te necesitan", color: .orange)
                    }
                    Text("\(workingCount) trabajando · \(waitingCount) te necesitan").font(.system(size: 11))
                }
                Spacer(minLength: 0)
                if floorCount > 1 {
                    Button { select(nil); floor = max(0, floor - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(floor == 0).help("Planta anterior")
                    Text("\(floor + 1)/\(floorCount)").font(.system(size: 11).monospacedDigit())
                    Button { select(nil); floor = min(floorCount - 1, floor + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(floor == floorCount - 1).help("Planta siguiente")
                } else if selectedID != nil {
                    Button("Ver toda la oficina", systemImage: "arrow.up.left.and.arrow.down.right") { select(nil) }
                        .font(.system(size: 11)).buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 12).padding(.top, sidebarVisible ? 12 : 32)
        .environment(\.colorScheme, .dark)
    }

    private var decorInteractions: some View {
        ZStack(alignment: .topLeading) {
            decorButton(title: coffeeCount == 0 ? "Preparar café" : "Otro café · \(coffeeCount) preparados", symbol: "cup.and.saucer.fill",
                        point: CGPoint(x: 1033, y: 155), size: CGSize(width: 64, height: 85), tint: .orange) {
                coffeeCount += 1
                if let agent = selectedAgent, agent.state == .idle {
                    choreographer.visitLounge(agentID: agent.id, spot: 0, now: Date())
                }
            }
            if coffeeCount > 0 {
                Text("Café ×\(coffeeCount)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                    .padding(7).background(.black.opacity(0.75), in: Capsule()).position(x: 1100, y: 120)
                    .allowsHitTesting(false)
            }
            decorButton(title: plantsWatered ? "Planta regada" : "Regar la planta", symbol: plantsWatered ? "heart.fill" : "drop.fill",
                        point: CGPoint(x: 1240, y: 495), size: CGSize(width: 65, height: 130), tint: .mint) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.55)) { plantsWatered.toggle() }
            }
        }
        .frame(width: Office2DNav.world.width, height: Office2DNav.world.height)
    }

    private func decorButton(title: String, symbol: String, point: CGPoint, size: CGSize, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.001))
                .overlay(alignment: .top) {
                    Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint).padding(8).background(.black.opacity(0.65), in: Circle())
                        .offset(y: -20)
                }
        }
        .buttonStyle(.plain).frame(width: size.width, height: size.height).position(point)
        .help(title).accessibilityLabel(title)
        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : coffeeCount + (plantsWatered ? 1 : 0))
    }

    private func statChip(value: Int, title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: 5)
            Text("\(value)").fontWeight(.bold).monospacedDigit()
            Text(title).foregroundStyle(officeMuted)
        }
        .font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 5)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .ignore).accessibilityLabel("\(value) \(title)")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AGENTES").font(.system(size: 12, weight: .bold)).tracking(1.4).foregroundStyle(officeMuted)
                Spacer()
                Text("\(viewModel.agents.count)").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3).background(.white.opacity(0.08), in: Capsule())
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            Group {
                ScrollView { agentRows }.scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 10).padding(.vertical, 4)
            if viewModel.agents.isEmpty { Text("Sin agentes activos").font(.system(size: 12)).foregroundStyle(officeMuted).padding(20) }
        }
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18).fill(Color(red: 14 / 255, green: 18 / 255, blue: 46 / 255).opacity(0.58)))
        }
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func agentRow(_ agent: Office2DAgent) -> some View {
        let conversation = viewModel.conversationsByAgent[agent.id]
        let role = roleForKind(agent.kind)
        let color = Office2DPalette.ROLE_COLORS[role] ?? Office2DPalette.ROLE_COLORS["Developer"]!
        return HStack(spacing: 10) {
            Office2DCharacterAvatar(agent: agent, diameter: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(role).font(.system(size: 11, weight: .semibold)).foregroundStyle(color.opacity(0.9))
                    Text("·").foregroundStyle(officeMuted)
                    Text(shortPath(conversation?.projectPath ?? "")).font(.system(size: 10)).foregroundStyle(officeMuted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 4) {
                stateBadge(agent.state)
                Text(conversation.map { elapsedTime($0.updatedAt) } ?? "").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(officeMuted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedID == agent.id ? color.opacity(0.15) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedID == agent.id ? color.opacity(0.55) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(agent.name), \(conversation?.provider.title ?? agent.kind), \(shortPath(conversation?.projectPath ?? "")), \(stateTitle(agent.state))")
    }

    private var agentRows: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.agents) { agent in
                agentRow(agent)
                    .onTapGesture(count: 2) { viewModel.open(agentID: agent.id) }
                    .onTapGesture { select(agent.id) }
            }
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    private func detailCard(_ agent: Office2DAgent) -> some View {
        let conversation = viewModel.conversationsByAgent[agent.id]
        let color = Office2DPalette.agentColor(seed: agent.seed)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 13) {
                    Office2DCharacterAvatar(agent: agent, diameter: 64)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(agent.name).font(.system(size: 16, weight: .bold)).lineLimit(2)
                        HStack(spacing: 6) {
                            tag(conversation?.provider.title ?? agent.kind.capitalized, color: color)
                            tag("Jack", color: officeMuted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { select(nil) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(Office2DIconButtonStyle())
                }
                HStack(spacing: 9) { stateBadge(agent.state); Text(agent.activity ?? stateTitle(agent.state)).font(.system(size: 12)).foregroundStyle(officeMuted).lineLimit(2) }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                detailRow("Actividad", value: conversation.map { relativeTime($0.updatedAt) } ?? "—")
                detailRow("Carpeta", value: conversation?.projectPath ?? "—", monospaced: true)
                Button { viewModel.open(agentID: agent.id) } label: {
                    Label("Abrir sesión", systemImage: "arrow.up.right.square").font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.borderedProminent).tint(color)
                if agent.state == .idle {
                    HStack {
                        Button("Saludar", systemImage: "hand.wave") { choreographer.greet(agentID: agent.id, now: Date()) }
                        Button("Café", systemImage: "cup.and.saucer") { choreographer.visitLounge(agentID: agent.id, spot: 0, now: Date()) }
                        Button("Sofá", systemImage: "sofa") { choreographer.visitLounge(agentID: agent.id, spot: 3, now: Date()) }
                    }.font(.system(size: 11)).buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 340)
        .frame(width: 310, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 25, y: 10).shadow(color: color.opacity(0.15), radius: 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Text("Tu estudio está listo").font(.system(size: 18, weight: .bold))
            Text("Crea un agente o pon uno a trabajar. Verás cómo teclea, pide ayuda y descansa al terminar. Mientras tanto, hay café y plantas que regar.")
                .font(.system(size: 12)).foregroundStyle(officeMuted).lineSpacing(3).multilineTextAlignment(.center)
            Button("Crear un agente", systemImage: "plus", action: onNew).buttonStyle(.borderedProminent).tint(officeAccent)
        }
        .padding(.horizontal, 26).padding(.vertical, 22).frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
    }

    private func select(_ id: String?) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.82)) {
            if let id, let index = viewModel.agents.firstIndex(where: { $0.id == id }) {
                floor = index / 12
                if viewportWidth <= 900 { sidebarOpen = false }
            }
            selectedID = id
        }
    }

    private func stateBadge(_ state: Office2DAgentState) -> some View {
        let color = Office2DPalette.stateColor(state)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(stateTitle(state)).font(.system(size: 9, weight: .semibold)).lineLimit(1)
        }.padding(.horizontal, 7).padding(.vertical, 3).foregroundStyle(color).background(color.opacity(0.13), in: Capsule())
    }

    private func tag(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.17), in: Capsule())
    }

    private func detailRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(officeMuted).frame(width: 62, alignment: .leading)
            Text(value).font(monospaced ? .system(size: 10.5, design: .monospaced) : .system(size: 12))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateTitle(_ state: Office2DAgentState) -> String {
        switch state {
        case .working: "Trabajando"
        case .thinking: "Pensando"
        case .waiting: "Esperando"
        case .blocked: "Bloqueado"
        case .idle: "Libre"
        case .failed: "Con error"
        }
    }

    private var brandIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [Color(red: 0.49, green: 0.55, blue: 1), Color(red: 0.88, green: 0.40, blue: 0.74)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(Color(red: 0.035, green: 0.047, blue: 0.14)).frame(width: 13, height: 13).offset(y: -2)
            HStack(spacing: 3) {
                Circle().fill(.white).frame(width: 2.2, height: 2.2)
                Circle().fill(.white).frame(width: 2.2, height: 2.2)
            }.offset(y: -3)
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 8)
                .fill(Color(red: 0.035, green: 0.047, blue: 0.14)).frame(width: 16, height: 7).offset(y: 9)
        }
        .frame(width: 30, height: 30)
        .shadow(color: officeAccent.opacity(0.45), radius: 10)
    }

    private func roleForKind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "claude": "Developer"
        case "codex": "Architect"
        case "opencode": "DevOps"
        case "gemini": "Researcher"
        case "aider": "QA"
        case "cursor-agent": "Designer"
        case "amp": "PM"
        case "goose": "DevOps"
        default: "Developer"
        }
    }

    private func shortPath(_ path: String) -> String {
        guard !path.isEmpty else { return "—" }
        return "~/" + (path.split(separator: "/").last.map(String.init) ?? path)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "ahora" }
        if seconds < 3_600 { return "hace \(seconds / 60)m" }
        if seconds < 86_400 { return "hace \(seconds / 3_600)h" }
        return "hace \(seconds / 86_400)d"
    }

    private func elapsedTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private var officeMuted: Color { Color(red: 0.56, green: 0.59, blue: 0.79) }
    private var officeAccent: Color { Color(red: 0.49, green: 0.55, blue: 1) }
}

private struct Office2DCharacterAvatar: View {
    let agent: Office2DAgent
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
                let color = Color(red: 0.11, green: 0.13, blue: 0.24)
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(color))
                let skin = Office2DPalette.SKINS[Int((agent.seed % 7) % UInt64(Office2DPalette.SKINS.count))]
                let hair = Office2DPalette.HAIRS[Int((agent.seed >> 3) % UInt64(Office2DPalette.HAIRS.count))]
                let d = min(size.width, size.height)
                let face = CGRect(x: d * 0.19, y: d * 0.17, width: d * 0.62, height: d * 0.70)
                let eye = Color(red: 0.10, green: 0.11, blue: 0.20)
                context.fill(Path(ellipseIn: CGRect(x: d * 0.11, y: d * 0.43, width: d * 0.19, height: d * 0.20)), with: .color(skin))
                context.fill(Path(ellipseIn: CGRect(x: d * 0.70, y: d * 0.43, width: d * 0.19, height: d * 0.20)), with: .color(skin))
                context.fill(Path(ellipseIn: face), with: .color(skin))
                var cap = Path()
                cap.move(to: CGPoint(x: d * 0.20, y: d * 0.47))
                cap.addCurve(to: CGPoint(x: d * 0.80, y: d * 0.47), control1: CGPoint(x: d * 0.18, y: d * 0.06), control2: CGPoint(x: d * 0.82, y: d * 0.06))
                cap.addCurve(to: CGPoint(x: d * 0.20, y: d * 0.47), control1: CGPoint(x: d * 0.56, y: d * 0.23), control2: CGPoint(x: d * 0.34, y: d * 0.31))
                cap.closeSubpath()
                context.fill(cap, with: .color(hair))
                for x in [d * 0.38, d * 0.62] {
                    context.fill(Path(ellipseIn: CGRect(x: x - d * 0.045, y: d * 0.49, width: d * 0.09, height: d * 0.12)), with: .color(eye))
                    context.fill(Path(ellipseIn: CGRect(x: x - d * 0.012, y: d * 0.51, width: d * 0.035, height: d * 0.035)), with: .color(.white))
                }
                var smile = Path()
                smile.move(to: CGPoint(x: d * 0.42, y: d * 0.69))
                smile.addQuadCurve(to: CGPoint(x: d * 0.58, y: d * 0.69), control: CGPoint(x: d * 0.50, y: d * 0.76))
                context.stroke(smile, with: .color(Color(red: 0.29, green: 0.14, blue: 0.20)), style: StrokeStyle(lineWidth: max(1, d * 0.045), lineCap: .round))

                let role = Self.role(for: agent.kind)
                let accent = Office2DPalette.ROLE_COLORS[role] ?? Office2DPalette.ROLE_COLORS["Developer"]!
                if role == "Developer" {
                    var band = Path()
                    band.addArc(center: CGPoint(x: d / 2, y: d * 0.47), radius: d * 0.39, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
                    context.stroke(band, with: .color(Color(red: 0.11, green: 0.13, blue: 0.28)), lineWidth: d * 0.09)
                    for x in [d * 0.09, d * 0.82] {
                        context.fill(Path(roundedRect: CGRect(x: x, y: d * 0.41, width: d * 0.10, height: d * 0.27), cornerRadius: d * 0.05), with: .color(accent))
                    }
                } else if role == "QA" || role == "Architect" || role == "Researcher" {
                    let lensColor = Color(red: 0.11, green: 0.13, blue: 0.28)
                    for x in [d * 0.29, d * 0.52] {
                        let lens = CGRect(x: x, y: d * 0.46, width: d * 0.20, height: d * 0.17)
                        context.stroke(Path(roundedRect: lens, cornerRadius: d * 0.045), with: .color(lensColor), lineWidth: max(1, d * 0.045))
                    }
                    var bridge = Path(); bridge.move(to: CGPoint(x: d * 0.49, y: d * 0.53)); bridge.addLine(to: CGPoint(x: d * 0.52, y: d * 0.53))
                    context.stroke(bridge, with: .color(lensColor), lineWidth: max(1, d * 0.04))
                } else if role == "DevOps" {
                    context.fill(Path(roundedRect: CGRect(x: d * 0.24, y: d * 0.08, width: d * 0.52, height: d * 0.15), cornerRadius: d * 0.08), with: .color(Color(red: 0.98, green: 0.74, blue: 0.08)))
                    context.fill(Path(roundedRect: CGRect(x: d * 0.16, y: d * 0.21, width: d * 0.68, height: d * 0.07), cornerRadius: d * 0.04), with: .color(Color(red: 0.92, green: 0.70, blue: 0.04)))
                }
            }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.11), lineWidth: 1))
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private static func role(for kind: String) -> String {
        switch kind.lowercased() {
        case "claude": "Developer"
        case "codex": "Architect"
        case "opencode": "DevOps"
        case "gemini": "Researcher"
        case "aider": "QA"
        case "cursor-agent": "Designer"
        case "amp": "PM"
        case "goose": "DevOps"
        default: "Developer"
        }
    }
}

private struct Office2DIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color(red: 0.56, green: 0.59, blue: 0.79))
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.09), lineWidth: 1))
    }
}
