import JackCore
import SwiftUI

/// Qué se ve de una carta.
enum OfficeCardKind: Hashable {
    case face(PlayingCard)
    case back
    case joker
}

/// Las ilustraciones de las cartas (dorso, jota, reina, rey y comodín), en `Resources/Office/Cards` (las prepara
/// `scripts/office_cards_art.py`). Sin ellas, las cartas se dibujan con formas sencillas.
enum OfficeCardArt {
    /// Una carpeta de donde leerlas en vez del paquete de la app (para probar fuera de ella).
    static var folder: URL?
    private static var cache: [String: Image] = [:]

    static func image(_ name: String) -> Image? {
        if let cached = cache[name] { return cached }
        let url = folder?.appendingPathComponent("\(name).webp") ?? Bundle.main.url(forResource: name, withExtension: "webp")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        let result = Image(nsImage: image)
        cache[name] = result
        return result
    }
}

/// Las cartas de la baraja francesa dibujadas con SwiftUI (las cifras y los palos) sobre las ilustraciones de las figuras, el
/// dorso y el comodín. La vista mide siempre lo mismo (2 × 3); `OfficeCardImages` las renderiza a imagen para pegarlas en las
/// cartas en 3D.
struct OfficeCardFace: View {
    let kind: OfficeCardKind
    var width: CGFloat = OfficeCardFace.pixelWidth

    static let pixelWidth: CGFloat = 512
    static let aspect: CGFloat = 1.5

    private var height: CGFloat { width * Self.aspect }
    private static let ivory = Color(red: 0.985, green: 0.975, blue: 0.95)
    private static let red = Color(red: 0.80, green: 0.09, blue: 0.14)
    private static let black = Color(red: 0.09, green: 0.09, blue: 0.13)

    var body: some View {
        ZStack {
            switch kind {
            case .face(let card): face(card)
            case .back: back
            case .joker: joker
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.06, style: .continuous))
    }

    // MARK: - Cara

    private func face(_ card: PlayingCard) -> some View {
        let ink = card.suit.isRed ? Self.red : Self.black
        return ZStack {
            Self.ivory
            RoundedRectangle(cornerRadius: width * 0.06, style: .continuous)
                .strokeBorder(Color.black.opacity(0.22), lineWidth: width * 0.006)
            if card.rank.isFace {
                faceCard(card, ink: ink)
            } else {
                pips(card, ink: ink)
            }
            index(card, ink: ink)
            index(card, ink: ink).rotationEffect(.degrees(180))
        }
    }

    /// El número y el palo de la esquina (arriba a la izquierda; abajo a la derecha, del revés).
    private func index(_ card: PlayingCard, ink: Color) -> some View {
        VStack(spacing: width * 0.004) {
            Text(card.rank.symbol)
                .font(.system(size: width * (card.rank == .ten ? 0.135 : 0.16), weight: .bold, design: .serif))
                .tracking(card.rank == .ten ? -width * 0.012 : 0)
            suit(card.suit, size: width * 0.12)
        }
        .foregroundStyle(ink)
        .frame(width: width * 0.17)
        .position(x: width * 0.115, y: width * 0.19)
        .frame(width: width, height: height)
    }

    private func suit(_ suit: CardSuit, size: CGFloat) -> some View {
        let name = ["suit.spade.fill", "suit.heart.fill", "suit.diamond.fill", "suit.club.fill"][suit.rawValue]
        return Image(systemName: name).font(.system(size: size)).frame(width: size * 1.2, height: size * 1.2)
    }

    // MARK: - Números

    /// El hueco donde van los palos grandes: una columna en cada lado y otra en medio.
    private var field: CGRect { CGRect(x: width * 0.30, y: width * 0.25, width: width * 0.40, height: height - width * 0.5) }

    /// Dónde va cada palo de las cartas con número, en fracciones de `field` (columna 0, 0,5 o 1; fila de 0 a 1).
    private static let layouts: [CardRank: [(CGFloat, CGFloat)]] = [
        .two: [(0.5, 0), (0.5, 1)],
        .three: [(0.5, 0), (0.5, 0.5), (0.5, 1)],
        .four: [(0, 0), (1, 0), (0, 1), (1, 1)],
        .five: [(0, 0), (1, 0), (0.5, 0.5), (0, 1), (1, 1)],
        .six: [(0, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1), (1, 1)],
        .seven: [(0, 0), (1, 0), (0.5, 0.25), (0, 0.5), (1, 0.5), (0, 1), (1, 1)],
        .eight: [(0, 0), (1, 0), (0.5, 0.25), (0, 0.5), (1, 0.5), (0.5, 0.75), (0, 1), (1, 1)],
        .nine: [(0, 0), (1, 0), (0, 1 / 3), (1, 1 / 3), (0.5, 0.5), (0, 2 / 3), (1, 2 / 3), (0, 1), (1, 1)],
        .ten: [(0, 0), (1, 0), (0.5, 1 / 6), (0, 1 / 3), (1, 1 / 3), (0, 2 / 3), (1, 2 / 3), (0.5, 5 / 6), (0, 1), (1, 1)],
    ]

    private func pips(_ card: PlayingCard, ink: Color) -> some View {
        ZStack {
            if card.rank == .ace {
                suit(card.suit, size: width * 0.42).foregroundStyle(ink).position(x: width / 2, y: height / 2)
            } else {
                ForEach(Array((Self.layouts[card.rank] ?? []).enumerated()), id: \.offset) { _, spot in
                    suit(card.suit, size: width * 0.16)
                        .foregroundStyle(ink)
                        // La mitad de abajo va del revés, como en una baraja de verdad.
                        .rotationEffect(.degrees(spot.1 > 0.5 ? 180 : 0))
                        .position(x: field.minX + field.width * spot.0, y: field.minY + field.height * spot.1)
                }
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: - Figuras

    /// J, Q y K: la ilustración en un cuadro con el color del palo; sin ella, la letra grande con una corona, repetida del revés.
    @ViewBuilder private func faceCard(_ card: PlayingCard, ink: Color) -> some View {
        let name = card.rank == .jack ? "CardJack" : card.rank == .queen ? "CardQueen" : "CardKing"
        if let art = OfficeCardArt.image(name) {
            let panel = CGSize(width: width * 0.62, height: width * 0.93)
            ZStack {
                RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                    .fill(ink.opacity(0.10))
                art.resizable().scaledToFit()
                    .padding(width * 0.015)
                RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                    .strokeBorder(ink.opacity(0.8), lineWidth: width * 0.009)
            }
            .frame(width: panel.width, height: panel.height)
            .clipShape(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                suit(card.suit, size: width * 0.09).foregroundStyle(ink).padding(width * 0.015)
            }
            .overlay(alignment: .topLeading) {
                suit(card.suit, size: width * 0.09).foregroundStyle(ink).padding(width * 0.015)
            }
            .frame(width: width, height: height)
        } else {
            lettered(card, ink: ink)
        }
    }

    private func lettered(_ card: PlayingCard, ink: Color) -> some View {
        let panel = CGRect(x: width * 0.22, y: width * 0.15, width: width * 0.56, height: height - width * 0.3)
        let emblem = card.rank == .jack ? "shield.lefthalf.filled" : "crown.fill"
        return ZStack {
            RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                .fill(ink.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous).strokeBorder(ink.opacity(0.75), lineWidth: width * 0.008))
                .frame(width: panel.width, height: panel.height)
            Rectangle().fill(ink.opacity(0.35)).frame(width: panel.width, height: width * 0.005)
            half(card, ink: ink, emblem: emblem)
                .offset(y: -panel.height * 0.25)
            half(card, ink: ink, emblem: emblem).rotationEffect(.degrees(180))
                .offset(y: panel.height * 0.25)
        }
        .frame(width: width, height: height)
    }

    private func half(_ card: PlayingCard, ink: Color, emblem: String) -> some View {
        VStack(spacing: width * 0.01) {
            Image(systemName: emblem).font(.system(size: width * 0.1))
            Text(card.rank.symbol).font(.system(size: width * 0.3, weight: .black, design: .serif))
            suit(card.suit, size: width * 0.1)
        }
        .foregroundStyle(ink)
    }

    // MARK: - Comodín

    /// El comodín viene dibujado entero (marco, texto y esquinas), tal cual.
    @ViewBuilder private var joker: some View {
        if let art = OfficeCardArt.image("CardJoker") {
            art.resizable().frame(width: width, height: height)
        } else {
            ZStack {
                Self.ivory
                Text("Comodín").font(.system(size: width * 0.14, weight: .bold, design: .serif)).foregroundStyle(Self.red)
            }
        }
    }

    // MARK: - Dorso

    @ViewBuilder private var back: some View {
        if let art = OfficeCardArt.image("CardBack") {
            art.resizable().frame(width: width, height: height)
        } else {
            drawnBack
        }
    }

    private var drawnBack: some View {
        let navy = Color(red: 0.09, green: 0.15, blue: 0.30)
        let orange = Color(red: 0.98, green: 0.58, blue: 0.20)
        return ZStack {
            Self.ivory
            RoundedRectangle(cornerRadius: width * 0.04, style: .continuous)
                .fill(navy)
                .padding(width * 0.04)
            // Una celosía de rombos, como la de un dorso clásico.
            Canvas { context, size in
                let step = width * 0.07
                var path = Path()
                var x = -size.height
                while x < size.width + size.height {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    path.move(to: CGPoint(x: x + size.height, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                context.stroke(path, with: .color(orange.opacity(0.32)), lineWidth: width * 0.006)
            }
            .clipShape(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous))
            .padding(width * 0.07)
            RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                .strokeBorder(orange.opacity(0.9), lineWidth: width * 0.008)
                .padding(width * 0.07)
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.27), Color(red: 0.96, green: 0.45, blue: 0.09)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Self.ivory, lineWidth: width * 0.012))
                .overlay(Text("J").font(.system(size: width * 0.26, weight: .black, design: .rounded)).foregroundStyle(.white))
                .frame(width: width * 0.4, height: width * 0.4)
        }
    }
}

/// Las imágenes de las cartas, renderizadas una sola vez.
@MainActor enum OfficeCardImages {
    private static var cache: [OfficeCardKind: CGImage] = [:]

    /// Con transparencia en las esquinas redondeadas.
    static func image(for kind: OfficeCardKind) -> CGImage? {
        if let cached = cache[kind] { return cached }
        let renderer = ImageRenderer(content: OfficeCardFace(kind: kind))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        cache[kind] = image
        return image
    }
}

#Preview("Cartas") {
    let cards = PlayingCard.deck
    return ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 8), count: 6), spacing: 8) {
            ForEach(cards) { OfficeCardFace(kind: .face($0), width: 150) }
            OfficeCardFace(kind: .back, width: 150)
            OfficeCardFace(kind: .joker, width: 150)
        }
        .padding()
    }
    .frame(width: 1000, height: 700)
    .background(Color(red: 0.12, green: 0.4, blue: 0.25))
}
