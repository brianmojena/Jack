import Foundation

/// Oficina 3D (modo Normal): un dibujo para la pizarra, en SVG. Lo que escribe el modelo no se fía: se lee como XML, solo se
/// conservan las formas básicas (nada de scripts, imágenes, textos, filtros ni referencias de fuera) y se puede pedir por pasos,
/// con cada vez más elementos, para ir enseñándolo como si se dibujara.
public struct OfficeSketch: Equatable, Sendable {
    /// Qué es, en pocas palabras («un pulpo con sombrero»).
    public var title: String
    /// El SVG ya saneado, con su `viewBox`.
    public let source: String
    /// Cuántas formas tiene (los elementos de primer nivel que se dibujan).
    public let shapeCount: Int
    /// La foto de internet que lo inspiró (cómo se llama el archivo), si hubo.
    public var inspiration: String?

    public enum Failure: Error, Equatable {
        case notSVG
        case tooLarge
        case empty
    }

    /// Lo que se dibuja; el resto de lo que se acepta (`defs`, degradados) se queda siempre.
    private static let drawable: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "g"]
    private static let allowed: Set<String> = drawable.union(["svg", "defs", "linearGradient", "radialGradient", "stop", "clipPath"])
    private static let namespace = "http://www.w3.org/2000/svg"
    static let sizeLimit = 120_000
    static let shapeLimit = 140

    private init(title: String, source: String, shapeCount: Int) {
        self.title = title
        self.source = source
        self.shapeCount = shapeCount
    }

    /// Lee la respuesta del modelo: un título opcional (lo que haya antes del `<svg`) y el SVG.
    public static func parse(_ raw: String) throws -> OfficeSketch {
        guard let start = raw.range(of: "<svg", options: .caseInsensitive),
              let end = raw.range(of: "</svg>", options: [.caseInsensitive, .backwards]), start.lowerBound < end.upperBound else { throw Failure.notSVG }
        let svg = String(raw[start.lowerBound..<end.upperBound])
        guard svg.utf8.count <= sizeLimit else { throw Failure.tooLarge }
        // Sin definiciones de tipo ni entidades: nada que expandir ni que cargar de fuera.
        guard !svg.contains("<!") else { throw Failure.notSVG }
        guard let document = try? XMLDocument(xmlString: svg, options: [.nodeLoadExternalEntitiesNever]), let root = document.rootElement(),
              root.name == "svg" else { throw Failure.notSVG }
        clean(root)
        let canvas = canvasSize(of: root)
        // El lienzo siempre con su tamaño explícito (así se sabe su proporción al dibujarlo) y el espacio de nombres de SVG.
        for name in ["viewBox", "width", "height", "style", "class"] { root.removeAttribute(forName: name) }
        let size = ["viewBox": "0 0 \(number(canvas.width)) \(number(canvas.height))", "width": number(canvas.width), "height": number(canvas.height)]
        for (name, value) in size {
            if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode { root.addAttribute(attribute) }
        }
        if root.uri == nil, let declaration = XMLNode.namespace(withName: "", stringValue: namespace) as? XMLNode {
            root.addNamespace(declaration)
        }
        let count = shapes(in: root).count
        guard count > 0 else { throw Failure.empty }
        guard count <= shapeLimit else { throw Failure.tooLarge }
        let prefix = String(raw[raw.startIndex..<start.lowerBound])
        return OfficeSketch(title: title(from: prefix), source: root.xmlString(options: [.nodeCompactEmptyElement]), shapeCount: count)
    }

    /// El SVG en `steps` pasos (o menos, si tiene menos formas): cada uno añade formas al anterior y el último es el dibujo entero.
    public func progressive(steps: Int) -> [String] {
        guard let document = try? XMLDocument(xmlString: source, options: []), let root = document.rootElement() else { return [source] }
        let all = Self.shapes(in: root)
        let count = max(1, min(steps, all.count))
        var frames: [String] = []
        for step in 1...count {
            let keep = Int((Double(all.count) * Double(step) / Double(count)).rounded(.up))
            guard let copy = document.copy() as? XMLDocument, let copyRoot = copy.rootElement() else { continue }
            for shape in Self.shapes(in: copyRoot).dropFirst(keep) { shape.detach() }
            frames.append(copyRoot.xmlString(options: [.nodeCompactEmptyElement]))
        }
        return frames.isEmpty ? [source] : frames
    }

    /// Ancho y alto del lienzo: los del `viewBox` si es razonable; si no, 800 × 500.
    private static func canvasSize(of root: XMLElement) -> (width: Double, height: Double) {
        let parts = (root.attribute(forName: "viewBox")?.stringValue ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        if parts.count == 4, parts[0] == 0, parts[1] == 0, parts[2] > 10, parts[3] > 10, parts[2] < 20_000, parts[3] < 20_000 {
            return (parts[2], parts[3])
        }
        return (800, 500)
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Quita lo que no se admite: elementos que no son formas, atributos de eventos y enlaces a otra cosa que no sea el propio SVG.
    private static func clean(_ element: XMLElement) {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else {
                if child.kind != .text && child.kind != .comment { child.detach() }
                continue
            }
            if allowed.contains(child.name ?? "") {
                clean(child)
            } else {
                child.detach()
            }
        }
        for attribute in element.attributes ?? [] {
            let name = (attribute.name ?? "").lowercased()
            let value = (attribute.stringValue ?? "").lowercased()
            let external = name == "href" || name.hasSuffix(":href")
            // Solo se admiten referencias a algo del propio SVG (`url(#degradado)`).
            let remote = value.contains("url(") && !value.contains("url(#")
            if name.hasPrefix("on") || remote || value.contains("javascript:") || (external && !value.hasPrefix("#")) {
                attribute.detach()
            }
        }
    }

    private static func shapes(in root: XMLElement) -> [XMLElement] {
        (root.children ?? []).compactMap { $0 as? XMLElement }.filter { drawable.contains($0.name ?? "") }
    }

    /// El título de lo que escribió el modelo antes del SVG: «Título: un pulpo con sombrero» → «un pulpo con sombrero».
    static func title(from prefix: String) -> String {
        var text = prefix.replacingOccurrences(of: "```xml", with: "").replacingOccurrences(of: "```svg", with: "").replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        text = lines.first ?? ""
        for label in ["título:", "titulo:", "title:", "dibujo:"] where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“”'*`#: ")).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 70 ? String(text.prefix(69)) + "…" : text
    }

    // MARK: - Dibujos de reserva

    /// Un dibujo que no necesita al modelo: para cuando no hay conexión o lo que contestó no sirve.
    public static func fallback(excluding last: String? = nil) -> OfficeSketch {
        let options = fallbacks.filter { $0.title != last }
        let chosen = options.randomElement() ?? fallbacks[0]
        // Los de reserva están escritos a mano y bien formados.
        let svg = "<svg viewBox=\"0 0 800 500\" xmlns=\"http://www.w3.org/2000/svg\" fill=\"none\" stroke=\"#222\" stroke-width=\"7\" "
            + "stroke-linecap=\"round\" stroke-linejoin=\"round\">\(chosen.shapes)</svg>"
        return (try? parse("\(chosen.title)\n\(svg)")) ?? OfficeSketch(title: chosen.title, source: svg, shapeCount: 1)
    }

    static let fallbacks: [(title: String, shapes: String)] = [
        ("un cohete rumbo a la luna", """
                <circle cx="620" cy="130" r="70" stroke="#fb8c00"/>
        <path d="M580 110 q20 -15 40 0" stroke="#fb8c00" stroke-width="5"/>
        <path d="M330 390 L330 190 Q400 60 470 190 L470 390 Z" stroke="#1e66f5"/>
        <circle cx="400" cy="230" r="34" stroke="#222"/>
        <path d="M330 330 L270 410 L330 390" stroke="#e53935"/>
        <path d="M470 330 L530 410 L470 390" stroke="#e53935"/>
        <path d="M360 400 Q400 480 440 400" stroke="#fb8c00"/>
        <path d="M385 410 Q400 450 415 410" stroke="#e53935" stroke-width="5"/>
        <path d="M120 90 l16 0 M128 82 l0 16" stroke="#8e44ad" stroke-width="5"/>
        <path d="M180 300 l12 0 M186 294 l0 12" stroke="#8e44ad" stroke-width="5"/>
        <path d="M700 330 l14 0 M707 323 l0 14" stroke="#8e44ad" stroke-width="5"/>
        """),
        ("una casita con un árbol y sol", """
                <path d="M60 430 L740 430" stroke="#2e9e44"/>
        <path d="M220 430 L220 250 L360 150 L500 250 L500 430" stroke="#222"/>
        <path d="M190 262 L360 135 L530 262" stroke="#e53935"/>
        <path d="M330 430 L330 340 L390 340 L390 430" stroke="#8e44ad"/>
        <rect x="415" y="275" width="55" height="55" stroke="#1e66f5"/>
        <path d="M442 275 L442 330 M415 302 L470 302" stroke="#1e66f5" stroke-width="4"/>
        <path d="M620 430 L620 320" stroke="#8d5524"/>
        <circle cx="620" cy="280" r="55" stroke="#2e9e44"/>
        <circle cx="130" cy="100" r="42" stroke="#fb8c00"/>
        <path d="M130 30 l0 18 M130 152 l0 18 M60 100 l18 0 M182 100 l18 0 M80 50 l12 12 M168 138 l12 12 M180 50 l-12 12 M92 138 l-12 12" stroke="#fb8c00" stroke-width="5"/>
        """),
        ("un pez entre burbujas", """
                <path d="M200 250 Q330 110 480 250 Q330 390 200 250 Z" stroke="#1e66f5"/>
        <path d="M480 250 L580 170 L560 250 L580 330 Z" stroke="#fb8c00"/>
        <circle cx="270" cy="230" r="12" stroke="#222"/>
        <path d="M240 290 Q270 310 300 290" stroke="#e53935" stroke-width="5"/>
        <path d="M340 160 Q380 110 410 175" stroke="#8e44ad" stroke-width="5"/>
        <circle cx="150" cy="140" r="22" stroke="#1e66f5" stroke-width="5"/>
        <circle cx="105" cy="90" r="14" stroke="#1e66f5" stroke-width="5"/>
        <circle cx="170" cy="70" r="9" stroke="#1e66f5" stroke-width="5"/>
        <path d="M80 450 Q100 380 120 450 M130 450 Q155 360 180 450" stroke="#2e9e44"/>
        <path d="M600 450 Q630 380 660 450 M670 450 Q695 390 720 450" stroke="#2e9e44"/>
        """),
        ("un velero en alta mar", """
                <path d="M250 340 L550 340 L490 410 L310 410 Z" stroke="#8d5524"/>
        <path d="M400 340 L400 90" stroke="#222"/>
        <path d="M400 100 L400 320 L560 320 Z" stroke="#e53935"/>
        <path d="M390 130 L390 320 L260 320 Z" stroke="#1e66f5"/>
        <path d="M400 90 L450 105 L400 120" stroke="#fb8c00"/>
        <path d="M80 440 Q130 410 180 440 T280 440 T380 440 T480 440 T580 440 T680 440 T740 440" stroke="#1e66f5"/>
        <circle cx="660" cy="110" r="38" stroke="#fb8c00"/>
        <path d="M90 130 q30 -30 60 0 q30 -30 60 0" stroke="#8e44ad" stroke-width="5"/>
        """),
        ("un gato con ganas de siesta", """
                <path d="M250 400 Q230 250 330 230 L330 160 L380 205 Q420 195 460 205 L510 160 L510 230 Q610 250 590 400 Z" stroke="#fb8c00"/>
        <path d="M320 275 Q340 290 360 275 M460 275 Q480 290 500 275" stroke="#222" stroke-width="6"/>
        <path d="M405 305 L420 320 L435 305 Z" stroke="#e53935" stroke-width="5"/>
        <path d="M300 310 L360 320 M300 335 L360 328 M480 320 L540 310 M480 328 L540 335" stroke="#222" stroke-width="4"/>
        <path d="M590 390 Q690 380 680 300 Q675 260 720 270" stroke="#fb8c00"/>
        <path d="M630 110 l30 0 l-30 36 l30 0 M690 70 l24 0 l-24 28 l24 0" stroke="#1e66f5" stroke-width="5"/>
        """),
    ]
}
