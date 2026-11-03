#if canImport(JackCore)
import JackCore
#endif
import SwiftUI

private let cardInk = Color(red: 0.11, green: 0.25, blue: 0.46)
private let cardOrange = LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.27), Color(red: 0.96, green: 0.45, blue: 0.09)], startPoint: .top, endPoint: .bottom)

// MARK: - Elegir juego

/// La tarjeta para sentar a un personaje (y a otro, si hace falta) a jugar a las cartas con el usuario: se elige el juego.
struct OfficeCardSetupCard: View {
    let me: String
    let anchor: CGPoint
    let bounds: CGSize
    /// Cuántos compañeros libres hay (contando a quien se pulsó).
    let free: Int
    let onStart: (OfficeCardSession.Game) -> Void
    let onClose: () -> Void

    @State private var shown = false
    private let size = CGSize(width: 330, height: 292)

    var body: some View {
        let x = min(max(anchor.x, size.width / 2 + 12), max(size.width / 2 + 12, bounds.width - size.width / 2 - 12))
        let y = min(max(anchor.y - 30 - size.height / 2, size.height / 2 + 12), max(size.height / 2 + 12, bounds.height - size.height / 2 - 12))
        card
            .frame(width: size.width, height: size.height)
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
            .position(x: x, y: y)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { shown = true } }
    }

    private var card: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Jugar a las cartas con \(me)").font(.system(size: 14, weight: .semibold)).foregroundStyle(cardInk).lineLimit(1)
                Spacer()
                Button {
                    OfficeSound.back.play()
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(cardInk.opacity(0.7))
                        .frame(width: 22, height: 22).background(Color(red: 0.9, green: 0.93, blue: 0.97), in: Circle())
                }
                .buttonStyle(.plain)
            }
            ForEach(OfficeCardSession.Game.allCases) { game in
                let enabled = free >= game.opponents
                Button {
                    OfficeSound.select.play()
                    onStart(game)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: game.symbol).font(.system(size: 17, weight: .bold)).foregroundStyle(Color(red: 0.96, green: 0.45, blue: 0.09)).frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(game.title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(cardInk)
                            Text(enabled ? game.blurb : "Hacen falta \(game.opponents + 1) personas libres en la oficina.")
                                .font(.system(size: 10.5)).foregroundStyle(cardInk.opacity(0.6)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.93, green: 0.96, blue: 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(enabled ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }
}

// MARK: - Estado

/// Arriba al centro: el juego, las líneas de estado (bote, fichas, turno…) y, en grande, el resultado.
struct OfficeCardHUD: View {
    @ObservedObject var session: OfficeCardSession

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(session.game?.title ?? "").font(.office(13, .bold)).foregroundStyle(.white)
                ForEach(Array(session.hud.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.office(11.5, .medium)).foregroundStyle(.white.opacity(0.78))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            if let banner = session.banner {
                Text(banner).font(.office(16, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 9)
                    .background(cardOrange, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: session.banner)
    }
}

// MARK: - Mano del Mentiroso

/// Las cartas del usuario en el Mentiroso, abiertas en abanico abajo: se pulsan para elegir las que se juegan.
struct OfficeCardHand: View {
    @ObservedObject var session: OfficeCardSession

    private var cards: [PlayingCard] { session.liar?.hands[0] ?? [] }
    private var choosing: Bool { if case .liarPlay? = session.prompt { true } else { false } }

    var body: some View {
        GeometryReader { proxy in
            let count = max(cards.count, 1)
            let cardWidth = min(92, (proxy.size.width - 60) / (1 + CGFloat(count - 1) * 0.42))
            let step = cardWidth * 0.42
            let total = cardWidth + CGFloat(count - 1) * step
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.element) { index, card in
                    let selected = session.selection.contains(card)
                    if let image = OfficeCardImages.image(for: .face(card)) {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: cardWidth, height: cardWidth * OfficeCardFace.aspect)
                            .overlay(RoundedRectangle(cornerRadius: cardWidth * 0.06, style: .continuous)
                                .strokeBorder(Color(red: 1.0, green: 0.66, blue: 0.27), lineWidth: selected ? 3 : 0))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .offset(x: CGFloat(index) * step, y: selected ? 0 : 22)
                            .onTapGesture { if choosing { OfficeSound.select.play(); session.toggle(card) } }
                    }
                }
            }
            .frame(width: total, height: cardWidth * OfficeCardFace.aspect + 22, alignment: .topLeading)
            .position(x: proxy.size.width / 2, y: proxy.size.height - (cardWidth * OfficeCardFace.aspect + 22) / 2 + 24)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: session.selection)
        }
        .frame(height: 180)
        .allowsHitTesting(true)
    }
}

// MARK: - Decisiones

/// Abajo al centro: lo que se le pregunta al usuario (apostar, pedir carta, acusar…).
struct OfficeCardActions: View {
    @ObservedObject var session: OfficeCardSession
    @State private var raise: Double = 0

    var body: some View {
        Group {
            switch session.prompt {
            case .bet(let chips)?: bet(chips)
            case .blackjack(let canDouble)?: blackjack(canDouble)
            case .liarPlay(let rank)?: liarPlay(rank)
            case .liarRespond(let claim)?: liarRespond(claim)
            case .poker(let options)?: poker(options)
            case .next(let label)?: row { primary(label) { session.submit(.next) } }
            case nil: EmptyView()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: session.prompt)
    }

    // MARK: Piezas

    private func row<Content: View>(title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 6) {
            if let title { Text(title).font(.office(12.5, .semibold)).foregroundStyle(.white.opacity(0.85)) }
            HStack(spacing: 8, content: content)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            OfficeSound.select.play()
            action()
        } label: {
            Text(title).font(.office(13, .bold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 8)
                .background(cardOrange, in: Capsule()).opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private func secondary(_ title: String, tint: Color = .white.opacity(0.18), action: @escaping () -> Void) -> some View {
        Button {
            OfficeSound.select.play()
            action()
        } label: {
            Text(title).font(.office(13, .semibold)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Juegos

    private func bet(_ chips: Int) -> some View {
        row(title: "¿Cuánto apuestas? Tienes \(chips) fichas") {
            ForEach([10, 25, 50, 100, 250].filter { $0 < chips }, id: \.self) { value in
                secondary("\(value)") { session.submit(.bet(value)) }
            }
            primary("Todo (\(chips))") { session.submit(.bet(chips)) }
        }
    }

    private func blackjack(_ canDouble: Bool) -> some View {
        row {
            primary("Pedir carta") { session.submit(.blackjack(.hit)) }
            secondary("Plantarme") { session.submit(.blackjack(.stand)) }
            if canDouble { secondary("Doblar") { session.submit(.blackjack(.double)) } }
        }
    }

    private func liarPlay(_ rank: CardRank) -> some View {
        let count = session.selection.count
        let word = OfficeCardSession.rankName(rank)
        return row(title: "Elige de 1 a 4 cartas y di que son: \(word)") {
            primary(count == 0 ? "Elige cartas" : "Jugar \(count) como \(word)", enabled: count > 0) { session.submit(.liarPlay(Array(session.selection))) }
        }
    }

    private func liarRespond(_ claim: String) -> some View {
        row(title: "\(claim) ¿Te lo crees?") {
            secondary("¡Mentiroso!", tint: Color(red: 0.85, green: 0.2, blue: 0.2)) { session.submit(.liarCall(true)) }
            secondary("Dejar pasar") { session.submit(.liarCall(false)) }
        }
    }

    private func poker(_ options: OfficeCardSession.PokerOptions) -> some View {
        VStack(spacing: 8) {
            row(title: options.toCall > 0 ? "Hay \(options.toCall) por igualar · bote \(options.pot)" : "Bote \(options.pot)") {
                secondary("Retirarme") { session.submit(.poker(.fold)) }
                if options.canCheck {
                    secondary("Pasar") { session.submit(.poker(.check)) }
                } else {
                    primary("Igualar \(min(options.toCall, options.stack))") { session.submit(.poker(.call)) }
                }
                if let range = options.raise {
                    primary(raise >= Double(range.upperBound) ? "All-in \(range.upperBound)" : "Subir a \(Int(raise))") {
                        session.submit(.poker(.raise(to: Int(raise))))
                    }
                }
            }
            if let range = options.raise, range.lowerBound < range.upperBound {
                HStack(spacing: 8) {
                    Text("\(range.lowerBound)").font(.office(11, .medium)).foregroundStyle(.white.opacity(0.7))
                    Slider(value: $raise, in: Double(range.lowerBound)...Double(range.upperBound), step: 5).frame(width: 190).tint(Color(red: 1.0, green: 0.66, blue: 0.27))
                    Text("\(range.upperBound)").font(.office(11, .medium)).foregroundStyle(.white.opacity(0.7))
                    ForEach([("½", 0.5), ("Bote", 1.0)], id: \.0) { label, fraction in
                        secondary(label) { raise = min(max(Double(options.pot) * fraction + Double(range.lowerBound), Double(range.lowerBound)), Double(range.upperBound)) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())
            }
        }
        .onAppear { raise = Double(options.raise?.lowerBound ?? 0) }
        .onChange(of: options) { _, new in raise = Double(new.raise?.lowerBound ?? 0) }
    }
}

// MARK: - Controles de la mesa

/// Los controles de abajo a la derecha de la partida de cartas: charla, levantarse y dejar la mesa.
struct OfficeCardDock: View {
    @ObservedObject var session: OfficeCardSession
    let onStandUp: () -> Void
    let onResetView: () -> Void
    let onQuit: () -> Void

    private var status: String {
        if session.phase == .finished { return "Partida terminada" }
        if session.phase == .seating { return "Esperando a la mesa…" }
        if session.prompt != nil { return "Tu turno" }
        return "Juegan los demás…"
    }

    private var tint: Color {
        if session.phase == .finished { return .purple }
        return session.prompt != nil ? Color(red: 0.3, green: 0.8, blue: 0.4) : Color(red: 1.0, green: 0.66, blue: 0.27)
    }

    var body: some View {
        OfficeTableDock(chat: session.chat, replying: session.replying, status: status, tint: tint, opponent: "la mesa",
                        typing: "Están escribiendo…", canSend: session.phase != .idle, finished: session.phase == .finished,
                        onStandUp: onStandUp, onResetView: onResetView, onQuit: onQuit, onSend: { session.send($0) })
    }
}

/// El botón de arriba cuando el usuario se ha levantado de la mesa de cartas con la partida en marcha.
struct OfficeTableReturnButton: View {
    let title: String
    let subtitle: String
    let hot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "suit.spade.fill")
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.office(12.5, .bold))
                    Text(subtitle).font(.office(10.5, .medium)).opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(LinearGradient(colors: hot ? [Color(red: 1.0, green: 0.66, blue: 0.27), Color(red: 0.96, green: 0.45, blue: 0.09)]
                                                  : [Color(red: 0.32, green: 0.36, blue: 0.44), Color(red: 0.2, green: 0.23, blue: 0.3)],
                                       startPoint: .top, endPoint: .bottom), in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: hot)
    }
}
