import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lo único que cambia entre la Mac y el iPhone al mover la cámara de la oficina: el resto (tocar o pulsar un personaje, arrastrar
/// para girar, pellizcar para acercar) son gestos de SwiftUI que valen igual con ratón, trackpad o dedos.
///
/// - Mac: la rueda del ratón acerca y aleja, las flechas desplazan y, con Mayúsculas, arrastrar desplaza en vez de girar.
/// - iPhone: arrastrar con dos dedos desplaza.
enum OfficeInput {
    /// Arrastrar desplaza la escena en vez de girarla (en la Mac, con Mayúsculas pulsada).
    @MainActor static var panModifierHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
}

extension View {
    /// La rueda del ratón y las flechas del teclado (solo en la Mac).
    @ViewBuilder func officePointerControls(camera: OfficeCamera) -> some View {
        #if os(macOS)
        background(OfficeScrollZoom(onZoom: { camera.zoom(by: $0) }, onPan: { camera.pan(right: $0, forward: $1) }))
        #else
        self
        #endif
    }

    /// El arrastre con dos dedos (solo en el iPhone): desplaza la escena.
    @ViewBuilder func officeTouchControls(camera: OfficeCamera) -> some View {
        #if os(iOS)
        gesture(OfficeTwoFingerPan { dx, dy in camera.pan(right: -Float(dx) * 0.0022, forward: Float(dy) * 0.0022) })
        #else
        self
        #endif
    }
}

#if os(macOS)
/// La rueda del ratón (y el desplazamiento con dos dedos) sobre la escena acercan y alejan la cámara; las flechas del
/// teclado la desplazan por la sala (izquierda y derecha a los lados, arriba y abajo hacia el fondo y hacia delante).
struct OfficeScrollZoom: NSViewRepresentable {
    let onZoom: (Float) -> Void
    let onPan: (Float, Float) -> Void

    func makeNSView(context: Context) -> NSView { MonitorView(onZoom: onZoom, onPan: onPan) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? MonitorView)?.onZoom = onZoom
        (view as? MonitorView)?.onPan = onPan
    }

    private final class MonitorView: NSView {
        var onZoom: (Float) -> Void
        var onPan: (Float, Float) -> Void
        private var monitor: Any?
        private var keys: Any?

        init(onZoom: @escaping (Float) -> Void, onPan: @escaping (Float, Float) -> Void) {
            self.onZoom = onZoom
            self.onPan = onPan
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
            guard window != nil else { return }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Solo en la ventana de la oficina y sin estar escribiendo: en el chat de abajo las flechas mueven el cursor.
                guard let self, event.window === self.window, !(self.window?.firstResponder is NSText),
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                let step: Float = 0.06
                switch event.keyCode {
                case 123: self.onPan(-step, 0)
                case 124: self.onPan(step, 0)
                case 125: self.onPan(0, -step)
                case 126: self.onPan(0, step)
                default: return event
                }
                return nil
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      !self.isOverScrollable(event) else { return event }
                self.onZoom(Float(exp(-event.scrollingDeltaY * 0.01)))
                return nil
            }
        }

        /// El cursor está sobre algo que se desplaza por sí mismo (una lista, un chat, un editor de texto que cuelgan sobre la escena):
        /// la rueda es suya, no de la cámara. Las vistas de SwiftUI con desplazamiento son `NSScrollView` por dentro.
        private func isOverScrollable(_ event: NSEvent) -> Bool {
            var view = window?.contentView?.hitTest(event.locationInWindow)
            while let current = view {
                if current is NSScrollView || current is NSTextView { return true }
                view = current.superview
            }
            return false
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keys { NSEvent.removeMonitor(keys) }
        }
    }
}
#else
/// Arrastrar con dos dedos: UIKit lo distingue del arrastre de un dedo (que gira la cámara) y del pellizco (que acerca).
struct OfficeTwoFingerPan: UIGestureRecognizerRepresentable {
    let onPan: (CGFloat, CGFloat) -> Void

    final class Coordinator { var last = CGPoint.zero }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let point = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began: context.coordinator.last = .zero
        case .changed:
            onPan(point.x - context.coordinator.last.x, point.y - context.coordinator.last.y)
            context.coordinator.last = point
        default: break
        }
    }
}
#endif
