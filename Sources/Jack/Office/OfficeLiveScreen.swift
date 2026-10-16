import AppKit
import SwiftUI

/// Lo que se ve en el monitor de un puesto en modo «En vivo»: la vista real del chat (la misma de «Ver pantalla»), montada
/// en una ventana invisible fuera de la pantalla y fotografiada cada poco para usarla de textura.
///
/// `ImageRenderer` no dibuja las piezas de AppKit (el desplazamiento, el cuadro de texto), así que se fotografía la vista ya
/// montada con `cacheDisplay`, como haría una captura.
@MainActor final class OfficeLiveScreen {
    private let window: NSWindow
    private let host: NSHostingView<AnyView>
    /// El chat que muestra ahora, para no volver a montarlo si no cambia.
    private(set) var conversation: UUID?

    init(size: CGSize) {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = host
    }

    deinit {
        MainActor.assumeIsolated { window.close() }
    }

    /// Monta el chat de `id` con `content`, solo si no es el que ya muestra.
    func show(_ id: UUID, _ content: @autoclosure () -> AnyView) {
        guard conversation != id else { return }
        conversation = id
        host.rootView = content()
    }

    /// Cambia el tamaño en puntos con el que se monta la vista (el de la vista real al mirar el monitor de cerca).
    func resize(to size: CGSize) {
        guard host.frame.size != size else { return }
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
    }

    /// Una foto de lo que se ve ahora.
    func snapshot() -> CGImage? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}
