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

    init(store: ChatStore, batterySaver: BatterySaver, onOpen: @escaping (UUID) -> Void) {
        _viewModel = StateObject(wrappedValue: OfficeViewModel(store: store, onOpen: onOpen))
        _batterySaver = ObservedObject(wrappedValue: batterySaver)
    }

    private var animate: Bool {
        guard isVisible, !batterySaver.isOn, !reduceMotion, NSApp.isActive else { return false }
        return NSApp.mainWindow?.occlusionState.contains(.visible) ?? true
    }

    private var workingCount: Int {
        viewModel.agents.filter { $0.state == .working || $0.state == .thinking }.count
    }

    private var waitingCount: Int {
        viewModel.agents.filter { $0.state == .waiting || $0.state == .blocked }.count
    }

    private var inactiveCount: Int {
        viewModel.agents.count - workingCount - waitingCount
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.agents.isEmpty {
                emptyState
            } else {
                GeometryReader { proxy in
                    let layout = OfficeLayoutEngine.layout(agentCount: viewModel.agents.count, size: proxy.size)
                    TimelineView(.animation(paused: !animate)) { context in
                        ZStack(alignment: .topLeading) {
                            OfficeSceneView(layout: layout, agentsByDesk: Array(layout.desks.indices.map {
                                $0 < viewModel.agents.count ? viewModel.agents[$0] : nil
                            }), date: context.date, animate: animate)
                            ForEach(viewModel.agents) { agent in
                                if let placement = choreographer.placement(for: agent.id, now: context.date) {
                                    OfficeCharacterView(agent: agent, placement: placement, date: context.date,
                                                        animate: animate, isSelected: selectedID == agent.id,
                                                        isHovered: hoveredID == agent.id)
                                        .frame(width: 80, height: 120)
                                        .offset(y: -60)
                                        .scaleEffect(placement.scale, anchor: .bottom)
                                        .position(placement.position)
                                        .contentShape(Rectangle())
                                        .onHover { hoveredID = $0 ? agent.id : (hoveredID == agent.id ? nil : hoveredID) }
                                        .onTapGesture {
                                            selectedID = agent.id
                                            viewModel.open(agentID: agent.id)
                                        }
                                        .help([agent.name, agent.activity].compactMap { $0 }.joined(separator: " · "))
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(agent.name), \(stateTitle(agent.state))\(agent.activity.map { ", \($0)" } ?? "")")
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityAction { viewModel.open(agentID: agent.id) }
                                }
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    }
                    .onAppear {
                        choreographer.reduceMotion = reduceMotion
                        choreographer.update(agents: viewModel.agents, layout: layout, now: Date())
                    }
                    .onChange(of: reduceMotion) { _, value in choreographer.reduceMotion = value }
                    .onChange(of: viewModel.agents) { _, agents in
                        choreographer.update(agents: agents, layout: layout, now: Date())
                    }
                    .onChange(of: layout) { _, newLayout in
                        choreographer.update(agents: viewModel.agents, layout: newLayout, now: Date())
                    }
                }
            }
        }
        .background(OfficePalette.midnight)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "building.2.crop.circle").foregroundStyle(.secondary)
            Text("Oficina").font(.system(size: 14, weight: .semibold))
            Spacer()
            counter("Trabajando", value: workingCount, color: .green)
            counter("Esperando", value: waitingCount, color: .orange)
            counter("Inactivos", value: inactiveCount, color: .secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private func counter(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value) \(title.lowercased())").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(title): \(value)")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("La oficina está tranquila").font(.system(size: 16, weight: .semibold))
            Text("Cuando abras una sesión, aquí verás al agente y su actividad.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stateTitle(_ state: OfficeAgentState) -> String {
        switch state {
        case .working: "Trabajando"
        case .thinking: "Pensando"
        case .waiting: "Esperando tu respuesta"
        case .blocked: "Bloqueado"
        case .idle: "Inactivo"
        case .failed: "Con error"
        }
    }
}
