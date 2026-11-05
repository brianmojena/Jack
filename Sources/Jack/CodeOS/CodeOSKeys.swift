import AppKit
import SwiftUI

/// What a key press means to the console. Keyboard only: there is no controller support.
enum CodeOSKey {
    case left, right, up, down, confirm, back, controlCenter, previousCategory, nextCategory, fullScreen, generate, remove, showAll, toggleHidden, quota, toggleActive, requestQuota, accept, decline, groupCode, changeProfile, newProject, explore
}

/// Reads the keyboard through an app-level monitor, so the window does not depend on SwiftUI's focus
/// (which was not delivering keys). While a text field is being edited only Esc and the control center pass.
/// With `commandOnly` (inside a project, where the terminal and the chat own the keyboard) a console command needs ⌘.
struct CodeOSKeyCatcher: NSViewRepresentable {
    let commandOnly: Bool
    let handler: (CodeOSKey) -> Bool

    func makeNSView(context: Context) -> CatcherView { CatcherView(commandOnly: commandOnly, handler: handler) }
    func updateNSView(_ view: CatcherView, context: Context) {
        view.handler = handler
        view.commandOnly = commandOnly
    }

    final class CatcherView: NSView {
        var handler: (CodeOSKey) -> Bool
        var commandOnly: Bool
        private var monitor: Any?

        init(commandOnly: Bool, handler: @escaping (CodeOSKey) -> Bool) {
            self.commandOnly = commandOnly
            self.handler = handler
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            // A binary launched outside an app bundle (swift run, a debug build) starts as a background process that never gets the keyboard.
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, !event.isARepeat || Self.repeats(event) else { return event }
                let typing = self.window?.firstResponder is NSText
                guard let key = Self.key(for: event, typing: typing, commandOnly: self.commandOnly) else { return event }
                return MainActor.assumeIsolated { self.handler(key) } ? nil : event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Holding an arrow keeps scrolling the shelf; Return and Esc fire once.
        private static func repeats(_ event: NSEvent) -> Bool { [123, 124, 125, 126].contains(event.keyCode) }

        private static func key(for event: NSEvent, typing: Bool, commandOnly: Bool) -> CodeOSKey? {
            let command = event.modifierFlags.contains(.command)
            if command {
                if event.charactersIgnoringModifiers == "k" { return .controlCenter }
                // ⌃⌘F, the system's own shortcut, for full screen when the plain F belongs to the terminal.
                if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers?.lowercased() == "f" { return .fullScreen }
                if event.charactersIgnoringModifiers == "u", !event.modifierFlags.contains(.shift) { return .quota }
                // ⌘⇧H ("Home") goes back to the shelf even while typing in the chat; ⌘⎋ does too.
                if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "h" { return .back }
                return event.keyCode == 53 ? .back : nil
            }
            // Jack's composer uses Esc and Tab itself, so while typing only ⌘K and ⌘⇧H belong to the console.
            if typing || commandOnly { return nil }
            switch event.keyCode {
            case 53: return .back
            case 48: return .controlCenter
            default: break
            }
            switch event.keyCode {
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            case 36, 76: return .confirm
            case 51, 117: return .remove
            case 49: return .explore
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "q": return .previousCategory
                case "e": return .nextCategory
                case "f": return .fullScreen
                case "g": return .generate
                case "v": return .showAll
                case "h": return .toggleHidden
                case "u": return .quota
                case "a": return .toggleActive
                case "r": return .requestQuota
                case "y": return .accept
                case "n": return .newProject
                case "c": return .groupCode
                case "p": return .changeProfile
                default: return nil
                }
            }
        }
    }
}

enum CodeOSWindow {
    /// The window has no title bar, so it must be allowed to enter full screen explicitly; otherwise the green button
    /// shows "+" and `toggleFullScreen` only zooms it. SwiftUI sets its own behaviour late, so this runs right before toggling.
    @MainActor static func toggleFullScreen(_ window: NSWindow) {
        window.collectionBehavior.subtract([.fullScreenNone, .fullScreenAuxiliary, .fullScreenDisallowsTiling])
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.styleMask.insert(.resizable)
        window.toggleFullScreen(nil)
    }
}

