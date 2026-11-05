import SwiftUI

/// "See all": every project in a grid, like a console's game library. Arrow keys move, Return opens, Delete takes a project off
/// the list (or puts it back while the removed ones are shown with H), Esc goes back to the shelf.
struct CodeOSGridView: View {
    @ObservedObject var model: CodeOSModel

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            let cell = 220 * u
            let spacing = 34 * u
            let inner = geo.size.width - 2 * 110 * u
            let columns = max(Int((inner + spacing) / (cell + spacing)), 1)
            ZStack {
                Color.canvas.opacity(0.72).background(.ultraThinMaterial).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 26 * u) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("TODOS LOS PROYECTOS").font(.system(size: 30 * u, weight: .heavy)).tracking(2 * u)
                        Text("\(model.gridProjects.count)").font(.system(size: 22 * u, weight: .medium)).opacity(0.55)
                        Spacer()
                        if model.showHidden {
                            Label("Mostrando los quitados", systemImage: "eye").font(.system(size: 17 * u, weight: .semibold)).foregroundStyle(.orange)
                        }
                    }
                    .foregroundStyle(.ink)
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing, alignment: .top), count: columns), alignment: .leading, spacing: 34 * u) {
                                ForEach(Array(model.gridProjects.enumerated()), id: \.element.id) { index, project in
                                    cellView(project, focused: index == model.gridFocus, side: cell, u: u)
                                        .id(index)
                                        .onTapGesture { if index == model.gridFocus { model.activateGrid() } else { model.moveGrid(dx: index - model.gridFocus, dy: 0) } }
                                }
                            }
                            .padding(.vertical, 24 * u).padding(.horizontal, 8 * u)
                        }
                        .onChange(of: model.gridFocus) { _, index in withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { proxy.scrollTo(index, anchor: .center) } }
                    }
                    HStack(spacing: 38 * u) {
                        hint("FLECHAS", "NAVEGAR", u, action: nil)
                        hint("ENTER", "ABRIR", u) { model.activateGrid() }
                        hint("N", "NUEVO", u) { model.openPicker() }
                        hint("BORRAR", "QUITAR O RESTAURAR", u) { model.toggleGridHidden() }
                        hint("H", model.showHidden ? "OCULTAR LOS QUITADOS" : "MOSTRAR LOS QUITADOS", u) { model.toggleShowHidden() }
                        hint("ESC", "VOLVER", u) { model.closeGrid() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 110 * u).padding(.top, 70 * u).padding(.bottom, 40 * u)
            }
            .onAppear { model.gridColumns = columns }
            .onChange(of: columns) { _, value in model.gridColumns = value }
        }
    }

    private func hint(_ glyph: String, _ label: String, _ u: CGFloat, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 12 * u) {
                Text(glyph).font(.system(size: 16 * u, weight: .bold)).padding(.horizontal, 10 * u).frame(minWidth: 34 * u, minHeight: 34 * u)
                    .overlay(Capsule().strokeBorder(.ink.opacity(0.9), lineWidth: 2 * u))
                Text(label).font(.system(size: 16 * u, weight: .bold)).tracking(1.5 * u)
            }
            .foregroundStyle(.ink.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func cellView(_ project: CodeOSProject, focused: Bool, side: CGFloat, u: CGFloat) -> some View {
        let removed = model.hidden.contains(project.id)
        return VStack(alignment: .leading, spacing: 10 * u) {
            CodeOSArtwork(project: project, art: model.art[project.id], corner: 7 * u)
                .frame(width: side, height: side)
                .overlay(alignment: .topTrailing) {
                    if removed {
                        Image(systemName: "eye.slash.fill").font(.system(size: 16 * u, weight: .bold)).foregroundStyle(.white)
                            .padding(8 * u).background(.canvas.opacity(0.65), in: Circle()).padding(10 * u)
                    }
                }
                .focusRing(focused, u: u)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 22 * u, y: 8 * u)
                .scaleEffect(focused ? 1.07 : 1)
            Text(project.name).font(.system(size: 17 * u, weight: .semibold)).foregroundStyle(.ink.opacity(focused ? 1 : 0.65)).lineLimit(1)
        }
        .frame(width: side, alignment: .leading)
        .opacity(removed ? 0.45 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }
}
