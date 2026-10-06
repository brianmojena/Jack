import AppKit
import SwiftUI

/// Centers the traffic lights in Jack's 38-point top strips and keeps them there through
/// resizes and full screen, since the hidden title bar would otherwise leave them higher.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.apply() }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
            apply()
        }

        func apply() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview else { return }
            let height = JackMetrics.stripHeight
            var frame = container.frame
            if frame.height != height || frame.origin.y != window.frame.height - height {
                frame.size.height = height
                frame.origin.y = window.frame.height - height
                container.frame = frame
            }
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = NSPoint(x: 14 + CGFloat(index) * 20, y: ((height - button.frame.height) / 2).rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
