import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Un ajedrecista cuyo papel interpreta Gemma al elegir sus jugadas.
public struct ChessMaster: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Una línea para el selector: época y rasgo principal.
    public let tagline: String
    /// Cómo juega, para que el modelo lo imite.
    let style: String
}

public enum ChessMasters {
    public static let all: [ChessMaster] = [
        ChessMaster(id: "capablanca", name: "José Raúl Capablanca", tagline: "La claridad hecha ajedrez",
                    style: "Juego natural, sencillo y limpio. Desarrollo armonioso, cambia piezas para simplificar cuando tiene ventaja, finales impecables y casi nunca complica sin necesidad."),
        ChessMaster(id: "kasparov", name: "Garry Kasparov", tagline: "Iniciativa y energía",
                    style: "Dinámico y agresivo. Busca la iniciativa a toda costa, ataca el rey con piezas activas, prepara las aperturas a fondo y calcula variantes largas y forzadas."),
        ChessMaster(id: "fischer", name: "Bobby Fischer", tagline: "Precisión y voluntad de ganar",
                    style: "Preciso, claro y combativo. Abre con e4, desarrolla rápido, exprime hasta la ventaja más pequeña y convierte los finales con una técnica brutal."),
        ChessMaster(id: "carlsen", name: "Magnus Carlsen", tagline: "El jugador universal",
                    style: "Universal y práctico. Evita las líneas teóricas, mantiene la tensión en posiciones iguales y gana en finales donde otros ven tablas, esperando el error del rival."),
        ChessMaster(id: "tal", name: "Mijaíl Tal", tagline: "El mago de Riga",
                    style: "Atacante y especulativo. Sacrifica material por iniciativa, crea complicaciones que el rival no puede calcular y prefiere una posición caótica a una cómoda."),
        ChessMaster(id: "karpov", name: "Anatoli Karpov", tagline: "El estrangulador",
                    style: "Posicional y paciente. Acumula pequeñas ventajas, limita el juego de las piezas rivales, cambia con precisión y asfixia poco a poco sin que el rival lo note."),
        ChessMaster(id: "morphy", name: "Paul Morphy", tagline: "El romántico",
                    style: "Desarrollo rapidísimo y ataque abierto. Domina el centro, saca todas las piezas antes de atacar, abre líneas contra el rey y castiga cada pérdida de tiempo."),
        ChessMaster(id: "alekhine", name: "Alexander Alekhine", tagline: "Combinaciones profundas",
                    style: "Ataque combinativo y complicaciones profundas. Concentra sus piezas contra un punto débil, prepara golpes tácticos con paciencia y rara vez aceptan tablas."),
        ChessMaster(id: "petrosian", name: "Tigran Petrosian", tagline: "El muro de hierro",
                    style: "Profiláctico y sólido. Se anticipa a los planes rivales, sacrifica la calidad por una posición segura y deja que el rival se estrelle contra su defensa."),
        ChessMaster(id: "spassky", name: "Borís Spassky", tagline: "Elegancia universal",
                    style: "Universal y elegante. Sabe atacar con furia y jugar posicional con calma, elige el plan según la posición y mantiene la sangre fría."),
        ChessMaster(id: "anand", name: "Viswanathan Anand", tagline: "El rayo de Madrás",
                    style: "Rápido e intuitivo. Juega con fluidez, piezas activas y tácticas claras, sin miedo a las posiciones abiertas, con una técnica muy depurada."),
        ChessMaster(id: "kramnik", name: "Vladímir Kramnik", tagline: "Solidez estratégica",
                    style: "Estratégico y sólido. Prepara cada partida al detalle, prefiere estructuras seguras (como la Defensa Berlinesa) y gana por comprensión posicional profunda."),
        ChessMaster(id: "nakamura", name: "Hikaru Nakamura", tagline: "Rey del blitz",
                    style: "Práctico y agresivo, con muchísima intuición táctica. Plantea problemas al rival, juega rápido, tiende trampas y no teme los riesgos."),
        ChessMaster(id: "polgar", name: "Judit Polgár", tagline: "Táctica sin miedo",
                    style: "Agresiva y táctica. Busca posiciones abiertas, ataca el enroque rival con decisión y calcula con valentía."),
        ChessMaster(id: "lasker", name: "Emanuel Lasker", tagline: "El psicólogo",
                    style: "Combativo y psicológico. Elige la jugada más incómoda para el rival, no el mejor movimiento teórico; defiende con tenacidad y se crece en la dificultad."),
        ChessMaster(id: "steinitz", name: "Wilhelm Steinitz", tagline: "El padre del ajedrez moderno",
                    style: "Posicional y de principios. Acumula pequeñas ventajas, defiende con firmeza y ataca solo cuando la posición lo justifica."),
        ChessMaster(id: "botvinnik", name: "Mijaíl Botvinnik", tagline: "El patriarca",
                    style: "Científico y metódico. Prepara planes estratégicos claros, juega con disciplina y convierte la ventaja con técnica rigurosa."),
        ChessMaster(id: "caruana", name: "Fabiano Caruana", tagline: "Preparación profunda",
                    style: "Preciso y muy bien preparado. Juega la jugada más exacta, presiona con calma y rara vez deja escapar una ventaja."),
        ChessMaster(id: "firouzja", name: "Alireza Firouzja", tagline: "Ambición joven",
                    style: "Agresivo y ambicioso. Busca la iniciativa desde el principio, lleva el juego a posiciones afiladas y calcula con atrevimiento.")
    ]

    public static func master(id: String) -> ChessMaster? { all.first { $0.id == id } }
}

// MARK: - El tablero como imagen

/// El tablero dibujado como una foto: es lo que ve Gemma antes de decidir.
public enum ChessBoardImage {
    public static func png(of position: ChessPosition, lastMove: ChessMove? = nil, size: Int = 720) -> Data? {
        let margin = CGFloat(size) * 0.05
        let square = (CGFloat(size) - margin * 2) / 8
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let light = CGColor(red: 0.93, green: 0.88, blue: 0.76, alpha: 1)
        let dark = CGColor(red: 0.58, green: 0.43, blue: 0.30, alpha: 1)
        let highlight = CGColor(red: 1.0, green: 0.86, blue: 0.2, alpha: 0.55)
        func rect(file: Int, rank: Int) -> CGRect {
            // Las blancas abajo: el rango 0 es la fila de abajo (el origen del contexto está abajo a la izquierda).
            CGRect(x: margin + CGFloat(file) * square, y: margin + CGFloat(rank) * square, width: square, height: square)
        }
        for rank in 0..<8 {
            for file in 0..<8 {
                context.setFillColor((file + rank) % 2 == 0 ? dark : light)
                context.fill(rect(file: file, rank: rank))
                let index = ChessSquare.make(file: file, rank: rank)
                if let lastMove, index == lastMove.from || index == lastMove.to {
                    context.setFillColor(highlight)
                    context.fill(rect(file: file, rank: rank))
                }
            }
        }
        let labelFont = CTFontCreateWithName("Helvetica-Bold" as CFString, margin * 0.55, nil)
        for index in 0..<8 {
            let letter = String(UnicodeScalar(UInt8(97 + index)))
            draw(letter, font: labelFont, color: CGColor(gray: 0.9, alpha: 1), in: context,
                 center: CGPoint(x: margin + (CGFloat(index) + 0.5) * square, y: margin / 2))
            draw(String(index + 1), font: labelFont, color: CGColor(gray: 0.9, alpha: 1), in: context,
                 center: CGPoint(x: margin / 2, y: margin + (CGFloat(index) + 0.5) * square))
        }
        let pieceFont = CTFontCreateWithName("Apple Symbols" as CFString, square * 0.82, nil)
        let glyphs = ["♟", "♞", "♝", "♜", "♛", "♚"]
        for index in 0..<64 {
            guard let piece = position[index] else { continue }
            let center = CGPoint(x: margin + (CGFloat(ChessSquare.file(index)) + 0.5) * square,
                                 y: margin + (CGFloat(ChessSquare.rank(index)) + 0.5) * square)
            let white = piece.color == .white
            draw(glyphs[piece.kind.rawValue], font: pieceFont, color: white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.06, alpha: 1),
                 stroke: white ? CGColor(gray: 0.05, alpha: 1) : CGColor(gray: 0.85, alpha: 1), in: context, center: center)
        }
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Dibuja un texto centrado en un punto. Con `stroke`, cada glifo se pinta como una forma (relleno y contorno), así las
    /// piezas salen del color pedido sea cual sea la fuente.
    private static func draw(_ text: String, font: CTFont, color: CGColor, stroke: CGColor? = nil, in context: CGContext, center: CGPoint) {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return }
        var box = CGRect.null
        var paths: [(CGPath, CGPoint)] = []
        var origin = CGPoint.zero
        for glyph in glyphs {
            guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
            paths.append((path, origin))
            box = box.union(path.boundingBoxOfPath.offsetBy(dx: origin.x, dy: origin.y))
            var advance = CGSize.zero
            var single = glyph
            CTFontGetAdvancesForGlyphs(font, .horizontal, &single, &advance, 1)
            origin.x += advance.width
        }
        guard !box.isNull else { return }
        context.saveGState()
        context.translateBy(x: center.x - box.midX, y: center.y - box.midY)
        for (path, offset) in paths {
            context.saveGState()
            context.translateBy(x: offset.x, y: offset.y)
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath(using: .evenOdd)
            if let stroke {
                context.addPath(path)
                context.setStrokeColor(stroke)
                context.setLineWidth(max(1, CTFontGetSize(font) * 0.012))
                context.strokePath()
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
}
