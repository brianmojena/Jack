import SwiftUI

/// The PlayStation "control center": a panel that slides up with the agents on top and the projects as cards below.
struct CodeOSControlCenter: View {
    @ObservedObject var model: CodeOSModel

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { model.closeControlCenter() }
                VStack(alignment: .leading, spacing: 26 * u) {
                    agentsRow(u)
                    Text("PROYECTOS")
                        .font(.system(size: 16 * u, weight: .heavy)).tracking(2.5 * u)
                        .foregroundStyle(.white.opacity(0.55))
                    projectsRow(u)
                }
                .padding(.horizontal, 90 * u)
                .padding(.top, 44 * u)
                .padding(.bottom, 56 * u)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 34 * u, topTrailingRadius: 34 * u))
                    .ignoresSafeArea()
                }
            }
        }
    }

    private func agentsRow(_ u: CGFloat) -> some View {
        HStack(spacing: 34 * u) {
            ForEach(Array(CodeOSAgent.allCases.enumerated()), id: \.element.id) { index, agent in
                let focused = model.ccRow == 0 && model.ccCol == index
                VStack(spacing: 12 * u) {
                    ZStack {
                        Circle().fill(.white.opacity(model.agent == agent ? 0.95 : 0.16))
                        CodeOSAgentGlyph(agent: agent)
                            .padding(22 * u)
                            .foregroundStyle(model.agent == agent ? .black : .white)
                    }
                    .frame(width: 92 * u, height: 92 * u)
                    .overlay(Circle().strokeBorder(.white, lineWidth: focused ? 4 * u : 0).padding(-6 * u))
                    .scaleEffect(focused ? 1.12 : 1)
                    Text(agent.rawValue).font(.system(size: 16 * u, weight: .semibold))
                        .foregroundStyle(.white.opacity(focused ? 1 : 0.55))
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectControl(row: 0, col: index) }
            }
            let exitFocused = model.ccRow == 0 && model.ccCol == CodeOSAgent.allCases.count
            VStack(spacing: 12 * u) {
                Image(systemName: "power").font(.system(size: 34 * u, weight: .medium))
                    .frame(width: 92 * u, height: 92 * u)
                    .background(Circle().fill(.white.opacity(0.16)))
                    .overlay(Circle().strokeBorder(.white, lineWidth: exitFocused ? 4 * u : 0).padding(-6 * u))
                    .scaleEffect(exitFocused ? 1.12 : 1)
                Text("Salir de CodeOS").font(.system(size: 16 * u, weight: .semibold)).foregroundStyle(.white.opacity(exitFocused ? 1 : 0.55))
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectControl(row: 0, col: CodeOSAgent.allCases.count) }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.ccCol)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.ccRow)
    }

    private func projectsRow(_ u: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24 * u) {
                    ForEach(Array(model.allProjects.enumerated()), id: \.element.id) { index, project in
                        let focused = model.ccRow == 1 && model.ccCol == index
                        HStack(spacing: 18 * u) {
                            CodeOSArtwork(project: project, art: model.art[project.id], corner: 10 * u)
                                .frame(width: 104 * u, height: 104 * u)
                            VStack(alignment: .leading, spacing: 6 * u) {
                                Text(project.name).font(.system(size: 22 * u, weight: .bold)).lineLimit(1)
                                Label(project.ago, systemImage: project.isLive ? "bolt.fill" : "clock")
                                    .font(.system(size: 14 * u, weight: .medium)).foregroundStyle(project.isLive ? Color.cyan : .white.opacity(0.6))
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white)
                        .padding(16 * u)
                        .frame(width: 360 * u, height: 136 * u)
                        .background(.white.opacity(focused ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 18 * u, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18 * u, style: .continuous).strokeBorder(.white, lineWidth: focused ? 4 * u : 0))
                        .scaleEffect(focused ? 1.05 : 1)
                        .id(index)
                        .onTapGesture { model.moveControl(dx: index - model.ccCol, dy: model.ccRow == 1 ? 0 : 1); model.activateControl() }
                    }
                }
                .padding(8 * u)
            }
            .onChange(of: model.ccCol) { _, col in
                guard model.ccRow == 1 else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { proxy.scrollTo(col, anchor: .center) }
            }
        }
        .frame(height: 170 * u)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.ccCol)
    }
}
