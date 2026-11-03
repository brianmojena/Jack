#if os(macOS)
import AppKit
import Foundation
import JackCore
import WebKit

/// Ejecuta el programa de un cuadro (el JavaScript que escribió el modelo) en una página web oculta y aislada, y devuelve lo que pinta.
///
/// El código no se fía, así que la página no puede hacer nada más que dibujar: política de seguridad que prohíbe cargar o conectar con
/// cualquier cosa, reglas que bloquean todo lo de fuera, almacenamiento que no se guarda, sin ventanas nuevas ni navegación, y un tiempo
/// máximo por llamada (si el programa se cuelga, la página se tira entera).
@MainActor final class OfficeCanvasRunner: NSObject {
    enum Failure: LocalizedError {
        case timeout
        case script(String)
        case blank
        case closed

        var errorDescription: String? {
            switch self {
            case .timeout: "El cuadro tardó demasiado en pintarse."
            case .script(let message): "El programa del cuadro falló: \(message)"
            case .blank: "El programa del cuadro no pintó nada."
            case .closed: "La página del cuadro se cerró."
            }
        }
    }

    /// Lo que se espera, como mucho, a que cargue la página o a que pinte un fotograma.
    private static let timeout = 12.0
    private static let rules = """
    [{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}]
    """

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?

    /// Carga el programa en una página nueva. Falla si la página no carga a tiempo.
    func load(_ program: OfficeCanvasProgram) async throws {
        close()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "JackOfficeCanvas", encodedContentRuleList: Self.rules) {
            configuration.userContentController.add(list)
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: OfficeCanvasProgram.width, height: OfficeCanvasProgram.height), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            view.loadHTMLString(program.html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                guard let self, let loaded = self.loaded else { return }
                self.loaded = nil
                self.close()
                loaded.resume(throwing: Failure.timeout)
            }
        }
    }

    /// El cuadro en el punto `progress` (de 0 a 1).
    func frame(progress: Double) async throws -> CGImage {
        guard let webView else { throw Failure.closed }
        let pending = PendingFrame()
        let result: Any? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            pending.continuation = continuation
            webView.evaluateJavaScript("window.__frame(\(min(max(progress, 0), 1)))") { value, error in
                Task { @MainActor in pending.finish(error.map { .failure($0) } ?? .success(value)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                Task { @MainActor in
                    guard !pending.isFinished else { return }
                    // Un programa que no acaba: se tira la página (y con ella su proceso).
                    self?.close()
                    pending.finish(.failure(Failure.timeout))
                }
            }
        }
        guard let text = result as? String else { throw Failure.script("sin respuesta") }
        if text.hasPrefix("ERR:") { throw Failure.script(String(text.dropFirst(4).prefix(160))) }
        guard let comma = text.firstIndex(of: ","), let data = Data(base64Encoded: String(text[text.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.script("imagen no válida")
        }
        return image
    }

    /// Comprueba que el programa carga y que, terminado, pinta algo: devuelve ese último fotograma.
    func validate(_ program: OfficeCanvasProgram) async throws -> CGImage {
        try await load(program)
        let image = try await frame(progress: 1)
        guard !Self.isBlank(image) else { throw Failure.blank }
        return image
    }

    func close() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        if let loaded {
            self.loaded = nil
            loaded.resume(throwing: Failure.closed)
        }
    }

    /// Todo (casi) igual al blanco con que se prepara el lienzo.
    static func isBlank(_ image: CGImage) -> Bool {
        let width = 32, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var painted = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] < 245 || pixels[index + 1] < 245 || pixels[index + 2] < 245 { painted += 1 }
        return painted < width * height / 50
    }
}

/// La respuesta que se espera de la página: llega una vez, ya sea el fotograma o el aviso de que tardó demasiado.
@MainActor private final class PendingFrame {
    var continuation: CheckedContinuation<Any?, Error>?
    var isFinished: Bool { continuation == nil }

    func finish(_ outcome: Result<Any?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: outcome)
    }
}

extension OfficeCanvasRunner: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Solo la página que se acaba de cargar; ningún enlace ni redirección.
        decisionHandler(navigationAction.request.url?.scheme == "about" || navigationAction.request.url == nil ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}
#endif
