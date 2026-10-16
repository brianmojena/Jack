import JackCore
import SwiftUI

/// El cuadro para mandar a dos personajes a jugar al ajedrez: con quién juega el personaje pulsado y qué maestro interpreta
/// cada uno. Mismo estilo que el selector de avatar: tarjeta blanca anclada al personaje.
struct OfficeChessSetupCard: View {
    struct Candidate: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    let me: Candidate
    let rivals: [Candidate]
    let anchor: CGPoint
    let bounds: CGSize
    let onStart: (_ white: (slot: Int, master: ChessMaster), _ black: (slot: Int, master: ChessMaster)) -> Void
    let onClose: () -> Void

    @State private var rival: Candidate?
    @State private var masters = OfficeChessGame.randomMasters()
    @State private var meIsWhite = true
    @State private var shown = false

    private let ink = Color(red: 0.11, green: 0.25, blue: 0.46)
    private let size = CGSize(width: 340, height: 262)

    var body: some View {
        let x = min(max(anchor.x, size.width / 2 + 12), max(size.width / 2 + 12, bounds.width - size.width / 2 - 12))
        let y = min(max(anchor.y - 30 - size.height / 2, size.height / 2 + 12), max(size.height / 2 + 12, bounds.height - size.height / 2 - 12))
        card
            .frame(width: size.width, height: size.height)
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
            .position(x: x, y: y)
            .onAppear {
                rival = rivals.first
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { shown = true }
            }
    }

    private var card: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Partida de ajedrez").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Button {
                    OfficeSound.back.play()
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ink.opacity(0.7))
                        .frame(width: 22, height: 22).background(Color(red: 0.9, green: 0.93, blue: 0.97), in: Circle())
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 8) {
                row(color: meIsWhite ? "Blancas" : "Negras", symbol: meIsWhite ? "circle" : "circle.fill") {
                    Text(me.name).font(.system(size: 13, weight: .bold)).foregroundStyle(ink)
                } master: {
                    masterMenu(for: meIsWhite ? 0 : 1)
                }
                Button {
                    OfficeSound.select.play()
                    meIsWhite.toggle()
                } label: {
                    Label("Cambiar colores", systemImage: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.75))
                }
                .buttonStyle(.plain)
                row(color: meIsWhite ? "Negras" : "Blancas", symbol: meIsWhite ? "circle.fill" : "circle") {
                    rivalMenu
                } master: {
                    masterMenu(for: meIsWhite ? 1 : 0)
                }
            }
            Spacer(minLength: 0)
            Button(action: start) {
                Text("Empezar partida").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.27), Color(red: 0.96, green: 0.45, blue: 0.09)],
                                               startPoint: .top, endPoint: .bottom), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(rival == nil)
            .opacity(rival == nil ? 0.5 : 1)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    private func row<Who: View, Master: View>(color: String, symbol: String, @ViewBuilder who: () -> Who, @ViewBuilder master: () -> Master) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(ink.opacity(0.7))
                Text(color).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink.opacity(0.6))
                who()
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("como").font(.system(size: 11)).foregroundStyle(ink.opacity(0.55))
                master()
            }
            .padding(.leading, 18)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.93, green: 0.96, blue: 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rivalMenu: some View {
        Menu {
            ForEach(rivals) { candidate in
                Button(candidate.name) { rival = candidate }
            }
        } label: {
            HStack(spacing: 4) {
                Text(rival?.name ?? "Sin compañero libre").font(.system(size: 13, weight: .bold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(ink)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func masterMenu(for index: Int) -> some View {
        Menu {
            ForEach(ChessMasters.all) { master in
                Button {
                    if index == 0 { masters.0 = master } else { masters.1 = master }
                } label: {
                    Text("\(master.name) — \(master.tagline)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(index == 0 ? masters.0.name : masters.1.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(Color(red: 0.86, green: 0.38, blue: 0.05))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func start() {
        guard let rival else { return }
        OfficeSound.select.play()
        let mine = (slot: me.id, master: meIsWhite ? masters.0 : masters.1)
        let theirs = (slot: rival.id, master: meIsWhite ? masters.1 : masters.0)
        if meIsWhite { onStart(mine, theirs) } else { onStart(theirs, mine) }
    }
}
