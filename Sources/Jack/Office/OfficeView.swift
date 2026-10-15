import AppKit
import JackCore
import SwiftUI

struct OfficeView: View {
    @StateObject private var viewModel: OfficeViewModel
    @StateObject private var choreographer = OfficeChoreographer()
    @ObservedObject private var batterySaver: BatterySaver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var sidebarOpen = true

    init(store: ChatStore, batterySaver: BatterySaver, onOpen: @escaping (UUID) -> Void) {
        _viewModel = StateObject(wrappedValue: OfficeViewModel(store: store, onOpen: onOpen))
        _batterySaver = ObservedObject(wrappedValue: batterySaver)
    }

    private var animate: Bool {
        guard isVisible, !batterySaver.isOn, !reduceMotion, NSApp.isActive else { return false }
        return NSApp.mainWindow?.occlusionState.contains(.visible) ?? true
    }

    private var workingCount: Int { viewModel.agents.filter { $0.state == .working || $0.state == .thinking }.count }
    private var waitingCount: Int { viewModel.agents.filter { $0.state == .waiting || $0.state == .blocked }.count }
    private var cameraZoom: CGFloat { selectedID == nil ? 1 : 1.7 }

    var body: some View {
        GeometryReader { proxy in
            let topInset: CGFloat = 84
            let sideInset: CGFloat = sidebarOpen && proxy.size.width > 900 ? 350 : 0
            let available = CGSize(width: max(1, proxy.size.width - sideInset), height: max(1, proxy.size.height - topInset))
            let scale = min(available.width / OfficeNav.world.width, available.height / OfficeNav.world.height) * 0.99
            ZStack(alignment: .topLeading) {
                Color(red: 0.035, green: 0.047, blue: 0.10).ignoresSafeArea()
                if viewModel.agents.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    officeWorld(scale: scale, available: available, viewport: proxy.size, topInset: topInset)
                }

                header
                if !viewModel.agents.isEmpty {
                    if sidebarOpen { sidebar.frame(width: 326).padding(.top, 76).padding(.trailing, 12).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing) }
                    if let selected = selectedAgent { detailCard(selected).padding(.leading, 16).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onExitCommand { select(nil) }
        }
        .background(Color(red: 0.035, green: 0.047, blue: 0.10))
    }

    private var selectedAgent: OfficeAgent? { viewModel.agents.first { $0.id == selectedID } }

    private func officeWorld(scale: CGFloat, available: CGSize, viewport: CGSize, topInset: CGFloat) -> some View {
        let layout = OfficeNav.layout(agentCount: viewModel.agents.count)
        return TimelineView(.animation(paused: !animate)) { context in
            ZStack {
                worldCanvas(layout: layout, date: context.date, animate: animate)
                    .frame(width: OfficeNav.world.width, height: OfficeNav.world.height)
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
            choreographer.reduceMotion = reduceMotion
            choreographer.update(agents: viewModel.agents, layout: layout, now: Date())
        }
        .onChange(of: reduceMotion) { _, value in choreographer.reduceMotion = value }
        .onChange(of: viewModel.agents) { _, agents in
            choreographer.update(agents: agents, layout: OfficeNav.layout(agentCount: agents.count), now: Date())
            if let selectedID, !agents.contains(where: { $0.id == selectedID }) { select(nil) }
        }
    }

    private func worldCanvas(layout: OfficeLayout, date: Date, animate: Bool) -> some View {
        let deskAgents = layout.desks.indices.map { index in index < viewModel.agents.count ? viewModel.agents[index] : nil }
        return ZStack(alignment: .topLeading) {
            OfficeSceneView(layout: layout, agentsByDesk: deskAgents, date: date, animate: animate)
            Color.clear.contentShape(Rectangle()).onTapGesture { select(nil) }
            ForEach(viewModel.agents) { agent in
                characterView(agent, layout: layout, date: date, animate: animate)
            }
        }
    }

    @ViewBuilder
    private func characterView(_ agent: OfficeAgent, layout: OfficeLayout, date: Date, animate: Bool) -> some View {
        if let placement = choreographer.placement(for: agent.id, now: date) {
            let character = OfficeCharacterView(agent: agent, placement: placement, date: date, animate: animate,
                                                isSelected: selectedID == agent.id, isHovered: hoveredID == agent.id)
            let frame = officeCharacterFrame(for: placement)
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
                .accessibilityAction { viewModel.open(agentID: agent.id) }
        }
    }

    private func cameraOffset(layout: OfficeLayout, scale: CGFloat, viewport: CGSize, topInset: CGFloat) -> CGSize {
        guard let selectedID, let placement = choreographer.placement(for: selectedID, now: Date()) else { return .zero }
        let inset: CGFloat = sidebarOpen && viewport.width > 900 ? 350 : 0
        let center = CGPoint(x: (viewport.width - inset) / 2, y: topInset + (viewport.height - topInset) / 2)
        let worldCenter = CGPoint(x: layout.size.width / 2, y: layout.size.height / 2)
        let zoom = cameraZoom
        return CGSize(width: center.x - (worldCenter.x + (placement.position.x - worldCenter.x) * zoom * scale),
                      height: center.y - (worldCenter.y + (placement.position.y - worldCenter.y) * zoom * scale))
    }

    private var header: some View {
        HStack(spacing: 14) {
            brandIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("Oficina").font(.system(size: 15, weight: .bold)).tracking(-0.15)
                Text("Agentes activos").font(.system(size: 11)).foregroundStyle(officeMuted)
            }
            HStack(spacing: 8) {
                statChip(value: viewModel.agents.count, title: "total", color: officeAccent)
                statChip(value: workingCount, title: "trabajando", color: Color(red: 0.20, green: 0.83, blue: 0.60))
                statChip(value: waitingCount, title: "esperando", color: Color(red: 1, green: 0.36, blue: 0.42))
            }.padding(.leading, 8)
            Spacer(minLength: 2)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits).locale(Locale(identifier: "en_US"))))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(officeMuted)
            }
            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { sidebarOpen.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: 14, weight: .medium)).frame(width: 34, height: 34)
            }
            .buttonStyle(OfficeIconButtonStyle()).help(sidebarOpen ? "Ocultar agentes" : "Mostrar agentes")
            .accessibilityLabel(sidebarOpen ? "Ocultar panel de agentes" : "Mostrar panel de agentes")
        }
        .padding(.horizontal, 14).frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).fill(Color(red: 14 / 255, green: 18 / 255, blue: 46 / 255).opacity(0.58)))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 7)
        .padding(.horizontal, 12).padding(.top, 12)
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
                if viewModel.agents.count > 7 {
                    ScrollView { agentRows }
                } else {
                    agentRows
                }
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

    private func agentRow(_ agent: OfficeAgent) -> some View {
        let conversation = viewModel.conversationsByAgent[agent.id]
        let role = roleForKind(agent.kind)
        let color = OfficePalette.ROLE_COLORS[role] ?? OfficePalette.ROLE_COLORS["Developer"]!
        return HStack(spacing: 10) {
            OfficeCharacterAvatar(agent: agent, diameter: 40)
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

    private func detailCard(_ agent: OfficeAgent) -> some View {
        let conversation = viewModel.conversationsByAgent[agent.id]
        let color = OfficePalette.agentColor(seed: agent.seed)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 13) {
                OfficeCharacterAvatar(agent: agent, diameter: 64)
                VStack(alignment: .leading, spacing: 7) {
                    Text(agent.name).font(.system(size: 16, weight: .bold)).lineLimit(2)
                    HStack(spacing: 6) {
                        tag(conversation?.provider.title ?? agent.kind.capitalized, color: color)
                        tag("Jack", color: officeMuted)
                    }
                }
                Spacer(minLength: 0)
                Button { select(nil) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(OfficeIconButtonStyle())
            }
            HStack(spacing: 9) { stateBadge(agent.state); Text(agent.activity ?? stateTitle(agent.state)).font(.system(size: 12)).foregroundStyle(officeMuted).lineLimit(2) }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            detailRow("ID", value: String(agent.id.prefix(8)).uppercased())
            detailRow("Actividad", value: conversation.map { relativeTime($0.updatedAt) } ?? "—")
            detailRow("Origen", value: "Sesión de Jack")
            detailRow("Carpeta", value: conversation?.projectPath ?? "—", monospaced: true)
            Button { viewModel.open(agentID: agent.id) } label: {
                Label("Abrir sesión", systemImage: "arrow.up.right.square").font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
            }.buttonStyle(.borderedProminent).tint(color)
        }
        .padding(16).frame(width: 310, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 25, y: 10).shadow(color: color.opacity(0.15), radius: 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Text("Oficina vacía").font(.system(size: 18, weight: .bold))
            Text("No hay agentes de IA ejecutándose. Inicia una sesión en Jack para ver aquí su actividad.")
                .font(.system(size: 12)).foregroundStyle(officeMuted).lineSpacing(3).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 26).padding(.vertical, 22).frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
    }

    private func select(_ id: String?) {
        withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { selectedID = id }
    }

    private func stateBadge(_ state: OfficeAgentState) -> some View {
        let color = OfficePalette.stateColor(state)
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

    private func stateTitle(_ state: OfficeAgentState) -> String {
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

private struct OfficeCharacterAvatar: View {
    let agent: OfficeAgent
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
                let color = Color(red: 0.11, green: 0.13, blue: 0.24)
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(color))
                let skin = OfficePalette.SKINS[Int((agent.seed % 7) % UInt64(OfficePalette.SKINS.count))]
                let hair = OfficePalette.HAIRS[Int((agent.seed >> 3) % UInt64(OfficePalette.HAIRS.count))]
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
                let accent = OfficePalette.ROLE_COLORS[role] ?? OfficePalette.ROLE_COLORS["Developer"]!
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

private struct OfficeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color(red: 0.56, green: 0.59, blue: 0.79))
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.09), lineWidth: 1))
    }
}
