import AppKit
import SwiftUI

@main
struct BuildCloudApp: App {
    @StateObject private var model = ServerModel()

    init() {
        // Lets `swift run BuildCloudApp` show a regular window outside an .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("BuildCloud", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 640, height: 560)

        MenuBarExtra("BuildCloud", systemImage: model.isRunning ? "shippingbox.fill" : "shippingbox") {
            MenuContent().environmentObject(model)
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var model: ServerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        Text(model.shareURL)
        Divider()
        Button("Abrir BuildCloud") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Abrir web", action: model.openWeb).disabled(!model.isRunning)
        Button(model.isRunning ? "Detener servidor" : "Iniciar servidor") { model.isRunning ? model.stop() : model.start() }
        Divider()
        Button("Salir") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
