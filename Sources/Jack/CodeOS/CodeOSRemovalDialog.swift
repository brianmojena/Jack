import SwiftUI

/// "Remove this project from the list?": asked before a project leaves the shelf. Left and right choose, Enter answers, Esc cancels.
/// The project's files are never touched; the grid's H brings removed projects back.
struct CodeOSRemovalDialog: View {
    @ObservedObject var model: CodeOSModel
    let project: CodeOSProject

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            ZStack {
                Color.canvas.opacity(0.55).ignoresSafeArea().onTapGesture { model.cancelRemoval() }
                VStack(spacing: 26 * u) {
                    CodeOSArtwork(project: project, art: model.art[project.id], corner: 16 * u)
                        .frame(width: 120 * u, height: 120 * u)
                        .shadow(color: .black.opacity(0.35), radius: 18 * u, y: 8 * u)
                    VStack(spacing: 10 * u) {
                        Text("¿Quitar «\(project.name)» de la lista?").font(.system(size: 32 * u, weight: .heavy)).multilineTextAlignment(.center)
                        Text("Sus archivos no se tocan. En «Ver todos», la tecla H muestra los quitados y puedes devolverlo.")
                            .font(.system(size: 19 * u, weight: .medium)).foregroundStyle(.ink.opacity(0.7)).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 22 * u) {
                        choice("Cancelar", remove: false, u)
                        choice("Quitar", remove: true, u)
                    }
                    HStack(spacing: 34 * u) {
                        hint("◀ ▶", "ELEGIR", u)
                        hint("ENTER", "ACEPTAR", u)
                        hint("ESC", "CANCELAR", u)
                    }
                }
                .foregroundStyle(.ink)
                .padding(44 * u)
                .frame(width: min(820 * u, geo.size.width - 80))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30 * u, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30 * u, style: .continuous).strokeBorder(.ink.opacity(0.15)))
            }
        }
    }

    private func choice(_ title: String, remove: Bool, _ u: CGFloat) -> some View {
        let focused = model.removalConfirmed == remove
        return Button {
            model.chooseRemoval(remove)
            model.answerRemoval()
        } label: {
            Text(title).font(.system(size: 22 * u, weight: .bold))
                .foregroundStyle(focused ? Color.canvas : (remove ? Color.red : Color.ink))
                .frame(width: 210 * u).padding(.vertical, 15 * u)
                .background(focused ? (remove ? Color.red : Color.ink) : Color.ink.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }

    private func hint(_ key: String, _ label: String, _ u: CGFloat) -> some View {
        HStack(spacing: 10 * u) {
            Text(key).font(.system(size: 14 * u, weight: .bold)).padding(.horizontal, 10 * u).frame(minWidth: 30 * u, minHeight: 30 * u)
                .overlay(Capsule().strokeBorder(.ink.opacity(0.8), lineWidth: 1.8 * u))
            Text(label).font(.system(size: 15 * u, weight: .bold)).tracking(1.2 * u)
        }
        .foregroundStyle(.ink.opacity(0.8))
    }
}
