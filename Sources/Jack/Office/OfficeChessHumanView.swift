#if canImport(JackCore)
import JackCore
#endif
import SwiftUI

/// Los casilleros del tablero encima de la escena, para jugar con el ratón sobre las piezas en 3D: se pulsa una pieza propia y
/// se marcan sus casillas de destino; al pulsar una, la pieza se mueve con su arco. Solo escucha mientras el usuario está sentado
/// a la mesa y le toca mover.
struct OfficeChessBoardOverlay: View {
    @ObservedObject var game: OfficeChessGame
    let set: OfficeChessSet
    let camera: OfficeCamera
    let size: CGSize
    let interval: Double?

    @State private var selected: Int?
    @State private var dragging = false
    @State private var lastDrag = CGSize.zero
    @State private var lastMagnification: CGFloat = 1
    @State private var bases: [SIMD3<Float>] = []

    private struct Cell {
        var center: CGPoint
        var radius: CGSize
    }

    private var canPlay: Bool { game.humanSeated && game.awaitingMove }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval)) { _ in
            let cells = projectedCells()
            Canvas { context, _ in
                guard cells.count == 64 else { return }
                func fill(_ square: Int, _ color: Color, ring: Bool = false) {
                    let cell = cells[square]
                    let rect = CGRect(x: cell.center.x - cell.radius.width, y: cell.center.y - cell.radius.height,
                                      width: cell.radius.width * 2, height: cell.radius.height * 2)
                    if ring {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)), with: .color(color), lineWidth: 3)
                    } else {
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
                if let last = game.game.history.last?.move {
                    fill(last.from, .yellow.opacity(0.22))
                    fill(last.to, .yellow.opacity(0.28))
                }
                guard canPlay, let selected else { return }
                fill(selected, .yellow.opacity(0.5))
                for move in game.moves(from: selected) {
                    let capture = game.game.position[move.to] != nil || (game.game.position[selected]?.kind == .pawn && ChessSquare.file(move.to) != ChessSquare.file(selected))
                    if capture {
                        fill(move.to, Color(red: 0.95, green: 0.35, blue: 0.2), ring: true)
                    } else {
                        let cell = cells[move.to]
                        let dot = CGRect(x: cell.center.x - cell.radius.width * 0.28, y: cell.center.y - cell.radius.height * 0.28,
                                         width: cell.radius.width * 0.56, height: cell.radius.height * 0.56)
                        context.fill(Path(ellipseIn: dot), with: .color(Color(red: 0.3, green: 0.85, blue: 0.45).opacity(0.85)))
                    }
                }
            }
            .allowsHitTesting(false)
            .overlay {
                // Un clic sin mover elige casilla; arrastrar gira la cámara alrededor del tablero y pellizcar acerca o aleja.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard hypot(value.translation.width, value.translation.height) > 4 || dragging else { return }
                                dragging = true
                                camera.orbit(dx: value.translation.width - lastDrag.width, dy: value.translation.height - lastDrag.height)
                                lastDrag = value.translation
                            }
                            .onEnded { value in
                                if !dragging { tap(value.location) }
                                dragging = false
                                lastDrag = .zero
                            }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                camera.zoom(by: Float(lastMagnification / value.magnification))
                                lastMagnification = value.magnification
                            }
                            .onEnded { _ in lastMagnification = 1 }
                    )
            }
        }
        .onAppear { loadBases() }
        .onChange(of: game.awaitingMove) { _, waiting in if !waiting { selected = nil } }
        .onChange(of: game.humanSeated) { _, _ in selected = nil }
    }

    private func loadBases() {
        guard bases.isEmpty else { return }
        bases = (0..<64).compactMap { set.worldPosition(of: $0) }
    }

    /// Dónde cae cada casilla ahora mismo en la vista, y cuánto ocupa.
    private func projectedCells() -> [Cell] {
        guard bases.count == 64 else { return [] }
        let points = bases.map { camera.projectCurrent($0, in: size) }
        guard points.allSatisfy({ $0 != nil }) else { return [] }
        let center = points.compactMap { $0 }
        return (0..<64).map { square in
            let file = square & 7 == 7 ? square - 1 : square + 1
            let rank = square >> 3 == 7 ? square - 8 : square + 8
            return Cell(center: center[square], radius: CGSize(width: abs(center[file].x - center[square].x) / 2,
                                                              height: abs(center[rank].y - center[square].y) / 2))
        }
    }

    /// La casilla pulsada: se cuenta el cuerpo de la pieza (no solo su base), que en pantalla queda más arriba.
    private func square(at point: CGPoint) -> Int? {
        let cells = projectedCells()
        guard cells.count == 64 else { return nil }
        var best: (square: Int, distance: CGFloat)?
        for square in 0..<64 {
            let cell = cells[square]
            var center = cell.center
            if game.game.position[square] != nil,
               let body = camera.projectCurrent(bases[square] + SIMD3(0, set.pieceHeight * 0.4, 0), in: size) {
                center = body
            }
            let dx = (point.x - center.x) / max(cell.radius.width, 1), dy = (point.y - center.y) / max(cell.radius.height, 1)
            let distance = dx * dx + dy * dy
            if distance < 1.3, distance < (best?.distance ?? .infinity) { best = (square, distance) }
        }
        return best?.square
    }

    private func tap(_ point: CGPoint) {
        guard canPlay else { return }
        guard let square = square(at: point) else {
            selected = nil
            return
        }
        if let selected, game.move(from: selected, to: square) {
            OfficeSound.select.play()
            self.selected = nil
        } else if !game.moves(from: square).isEmpty {
            OfficeSound.open.play()
            selected = square
        } else {
            selected = nil
        }
    }
}

/// Los controles de la partida, abajo a la derecha, mientras el usuario está sentado a la mesa: un botón flotante que abre y cierra
/// la charla con el maestro (con un aviso si contesta estando cerrada), y al lado los botones para levantarse, recolocar la vista
/// y dejar la partida. Cerrado casi no ocupa sitio.
struct OfficeTableDock: View {
    let chat: [OfficeChessGame.ChatLine]
    let replying: Bool
    let status: String
    let tint: Color
    /// A quién se le escribe («Remy» o «la mesa») y cómo se dice que está escribiendo.
    let opponent: String
    let typing: String
    let canSend: Bool
    let finished: Bool
    let onStandUp: () -> Void
    let onResetView: () -> Void
    let onQuit: () -> Void
    let onSend: (String) -> Void

    @State private var open = false
    @State private var unread = 0
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let ink = Color(red: 0.11, green: 0.25, blue: 0.46)
    private let orange = Color(red: 0.96, green: 0.45, blue: 0.09)
    private var canSendNow: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !replying && canSend }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if open {
                panel.transition(.scale(scale: 0.88, anchor: .bottomTrailing).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                if !open { statusChip.transition(.opacity) }
                mini("figure.stand", help: "Levantarme: ver la oficina sin perder la partida", action: onStandUp)
                mini("arrow.counterclockwise", help: "Recolocar la vista del tablero", action: onResetView)
                mini("flag.checkered", help: finished ? "Cerrar la partida" : "Abandonar la partida", action: onQuit)
                fab
            }
        }
        .padding(.trailing, 18).padding(.bottom, 18)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: open)
        .onChange(of: chat) { old, chat in
            // Una respuesta nueva con la charla cerrada se avisa en el botón.
            if !open, chat.count > old.count, chat.last?.fromMe == false { unread += 1 }
        }
    }

    // MARK: - Botones

    private var fab: some View {
        Button {
            OfficeSound.open.play()
            open.toggle()
            if open {
                unread = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
            } else {
                focused = false
            }
        } label: {
            Image(systemName: open ? "xmark" : "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.27), orange], startPoint: .top, endPoint: .bottom), in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 && !open {
                        Text("\(unread)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18).background(Color.red, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(open ? "Cerrar la charla" : "Charlar con \(opponent)")
    }

    private func mini(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain).help(help)
    }

    /// De quién es el turno, en una píldora pequeña junto a los botones.
    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(status).font(.office(12, .bold)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Charla

    private var panel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(status).font(.office(12.5, .bold)).foregroundStyle(ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            log
            composer
        }
        .padding(12)
        .frame(width: 320)
        .background(.white, in: RoundedRectangle(cornerRadius: JackPalette.radius(18), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JackPalette.radius(18), style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    @ViewBuilder private var log: some View {
        if chat.isEmpty && !replying {
            Text("Escríbele a \(opponent) mientras jugáis.").font(.system(size: 12)).foregroundStyle(ink.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(chat) { line in
                            VStack(alignment: line.fromMe ? .trailing : .leading, spacing: 1) {
                              if let speaker = line.speaker, !line.fromMe { Text(speaker).font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.opacity(0.5)).padding(.leading, 6) }
                              HStack {
                                if line.fromMe { Spacer(minLength: 36) }
                                Text(line.text).font(.system(size: 12.5)).foregroundStyle(line.fromMe ? .white : ink)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(line.fromMe ? orange : Color(red: 0.93, green: 0.96, blue: 1), in: RoundedRectangle(cornerRadius: JackPalette.radius(12), style: .continuous))
                                if !line.fromMe { Spacer(minLength: 36) }
                              }
                            }
                            .id(line.id)
                        }
                        if replying {
                            Text(typing).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.5)).id("typing")
                        }
                    }
                }
                .frame(maxHeight: 190)
                .onChange(of: chat) { _, chat in
                    if let last = chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: replying) { _, replying in
                    if replying { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Escribe a \(opponent)…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ink)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(red: 0.93, green: 0.96, blue: 1), in: Capsule())
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(canSendNow ? orange : Color(red: 0.8, green: 0.84, blue: 0.9), in: Circle())
            }
            .buttonStyle(.plain).disabled(!canSendNow).help("Enviar (Enter)")
        }
    }

    private func send() {
        guard canSendNow else { return }
        let text = draft
        draft = ""
        onSend(text)
        focused = true
    }
}

/// Los controles de la partida de ajedrez: el panel de la mesa con el estado de la partida.
struct OfficeChessDock: View {
    @ObservedObject var game: OfficeChessGame
    let opponent: String
    let onStandUp: () -> Void
    let onResetView: () -> Void
    let onQuit: () -> Void
    let onSend: (String) -> Void

    private var status: String {
        if game.phase == .finishing || game.game.outcome.isOver { return game.game.outcome.title.prefix(1).uppercased() + game.game.outcome.title.dropFirst() }
        if game.awaitingMove { return "Tu turno" }
        return "\(opponent) está pensando…"
    }

    private var tint: Color {
        if game.phase == .finishing { return .purple }
        return game.awaitingMove ? Color(red: 0.3, green: 0.8, blue: 0.4) : Color(red: 1.0, green: 0.66, blue: 0.27)
    }

    var body: some View {
        OfficeTableDock(chat: game.chat, replying: game.replying, status: status, tint: tint, opponent: opponent,
                        typing: "\(opponent) está escribiendo…", canSend: game.phase != .idle, finished: game.phase == .finishing,
                        onStandUp: onStandUp, onResetView: onResetView, onQuit: onQuit, onSend: onSend)
    }
}

/// El botón de arriba cuando el usuario se ha levantado de la mesa con la partida en marcha: lo avisa si le toca mover.
struct OfficeChessReturnButton: View {
    @ObservedObject var game: OfficeChessGame
    let opponent: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkerboard.rectangle")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Volver a la partida").font(.office(12.5, .bold))
                    Text(game.awaitingMove ? "Te toca mover" : "\(opponent) está pensando…").font(.office(10.5, .medium)).opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(LinearGradient(colors: game.awaitingMove ? [Color(red: 1.0, green: 0.66, blue: 0.27), Color(red: 0.96, green: 0.45, blue: 0.09)]
                                                               : [Color(red: 0.32, green: 0.36, blue: 0.44), Color(red: 0.2, green: 0.23, blue: 0.3)],
                                       startPoint: .top, endPoint: .bottom), in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: game.awaitingMove)
    }
}
