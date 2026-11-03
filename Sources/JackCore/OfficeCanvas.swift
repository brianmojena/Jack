import Foundation

/// Oficina 3D (modo Normal): un cuadro como programa. Lo que escribe el modelo es el código JavaScript de una función `pintar(ctx, w, h, p)`
/// que dibuja en un canvas 2D todo el cuadro «hasta el punto `p`» (de 0 a 1): la app la llama con valores crecientes y enseña cada
/// resultado en la pizarra, y así el cuadro se va pintando. El código no se fía: se comprueba aquí y se ejecuta en una página web aislada
/// (sin red ni almacenamiento, con un tiempo máximo) por `OfficeCanvasRunner`.
public struct OfficeCanvasProgram: Equatable, Sendable {
    /// El cuadro: «La noche estrellada», de Vincent van Gogh.
    public var title: String
    public let code: String
    /// Lo que inspiró el cuadro (la obra), si se buscó.
    public var inspiration: String?

    public enum Failure: Error, Equatable {
        case noCode
        case tooLarge
        case missingFunction
        case forbidden(String)
    }

    /// El lienzo, en píxeles (apaisado, como la pizarra).
    public static let width = 1280
    public static let height = 800
    static let sizeLimit = 60_000
    /// Nombres con los que un programa de pintura no tiene nada que hacer: red, almacenamiento, otros contextos y código dinámico.
    /// La barrera de verdad es la página aislada (ver `html`); esto lo corta antes y da un motivo claro.
    static let forbidden = [
        "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "importScripts", "import", "eval", "Function", "localStorage", "sessionStorage",
        "indexedDB", "navigator", "location", "cookie", "postMessage", "Worker", "SharedArrayBuffer", "WebAssembly", "require", "process",
        "setTimeout", "setInterval", "requestAnimationFrame", "while(true)", "while (true)", "for(;;)", "for (;;)", "</script", "<!--",
    ]

    private init(title: String, code: String) {
        self.title = title
        self.code = code
    }

    /// Lee la respuesta del modelo: un título (lo que haya antes del bloque de código) y el código.
    public static func parse(_ raw: String) throws -> OfficeCanvasProgram {
        var title = ""
        var code = raw
        if let open = raw.range(of: "```") {
            title = String(raw[raw.startIndex..<open.lowerBound])
            var body = String(raw[open.upperBound...])
            if let close = body.range(of: "```", options: .backwards) { body = String(body[body.startIndex..<close.lowerBound]) }
            // La primera línea del bloque puede ser el lenguaje.
            if let newline = body.firstIndex(of: "\n"), ["js", "javascript", "html", "canvas"].contains(body[body.startIndex..<newline].trimmingCharacters(in: .whitespaces).lowercased()) {
                body = String(body[body.index(after: newline)...])
            }
            code = body
        } else if let start = raw.range(of: "function pintar") {
            title = String(raw[raw.startIndex..<start.lowerBound])
            code = String(raw[start.lowerBound...])
        } else {
            throw Failure.noCode
        }
        code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw Failure.noCode }
        guard code.utf8.count <= sizeLimit else { throw Failure.tooLarge }
        guard code.contains("function pintar") || code.contains("pintar =") || code.contains("pintar=") else { throw Failure.missingFunction }
        for word in forbidden where mentions(word, in: code) { throw Failure.forbidden(word) }
        return OfficeCanvasProgram(title: cleanTitle(title), code: code)
    }

    /// Si `word` aparece en `code` como identificador (no dentro de otro, como «important» respecto a «import»).
    static func mentions(_ word: String, in code: String) -> Bool {
        guard let first = word.first, first.isLetter, word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return code.contains(word) }
        var search = code.startIndex..<code.endIndex
        while let found = code.range(of: word, range: search) {
            let before = found.lowerBound == code.startIndex ? nil : code[code.index(before: found.lowerBound)]
            let after = found.upperBound == code.endIndex ? nil : code[found.upperBound]
            let isolated = !(before.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } ?? false)
                && !(after.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } ?? false)
            // Una propiedad con ese nombre (`obj.import`) tampoco es la función global.
            if isolated { return true }
            search = found.upperBound..<code.endIndex
        }
        return false
    }

    /// «Título: «La noche estrellada», de Vincent van Gogh» → «La noche estrellada, de Vincent van Gogh».
    static func cleanTitle(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for label in ["título:", "titulo:", "title:", "cuadro:"] where line.lowercased().hasPrefix(label) { line = String(line.dropFirst(label.count)) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'`: ")).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }

    /// La página donde se ejecuta: un canvas, una política de seguridad que lo prohíbe todo menos ejecutar este script (nada de red,
    /// imágenes ni fuentes de fuera) y `__frame(p)`, que repinta el canvas en blanco con `pintar(ctx, w, h, p)` y devuelve el resultado
    /// como imagen JPEG en base64 (`data:`), o `ERR:` y el motivo.
    public var html: String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:">
        </head><body style="margin:0"><canvas id="c" width="\(Self.width)" height="\(Self.height)"></canvas>
        <script>window.__errors = []; window.onerror = function (message) { window.__errors.push(String(message)); };</script>
        <script>
        \(code)
        </script>
        <script>
        window.__frame = function (p) {
          try {
            if (typeof pintar !== 'function') return 'ERR:' + (window.__errors.join('; ') || 'no hay función pintar');
            var canvas = document.getElementById('c');
            canvas.width = canvas.width;
            var ctx = canvas.getContext('2d');
            ctx.fillStyle = '#ffffff';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            pintar(ctx, canvas.width, canvas.height, p);
            return canvas.toDataURL('image/jpeg', 0.92);
          } catch (e) { return 'ERR:' + e; }
        };
        </script></body></html>
        """
    }
}

/// Lo que se dibuja en la pizarra: un cuadro programado (lo normal) o un dibujo vectorial de reserva, para cuando el modelo no responde
/// o su programa no sirve.
public enum OfficeDrawing: Equatable, Sendable {
    case program(OfficeCanvasProgram)
    case vector(OfficeSketch)

    public var title: String {
        switch self {
        case .program(let program): program.title
        case .vector(let sketch): sketch.title
        }
    }

    /// El cuadro que lo inspiró, si se buscó su imagen en internet.
    public var inspiration: String? {
        switch self {
        case .program(let program): program.inspiration
        case .vector(let sketch): sketch.inspiration
        }
    }
}
