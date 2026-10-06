import JackCore
import SwiftUI

@main
struct JackApp: App {
    @StateObject private var store = ChatStore()
    @NSApplicationDelegateAdaptor(JackAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Jack", id: "main") {
            MainWindowView(store: store)
                
                .onAppear { appDelegate.store = store }
                .task { await store.refreshUsage() }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { JackCommands() }

        Settings {
            SettingsView(store: store)
        }
    }
}

@MainActor
final class JackAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ChatStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.shutdown()
        return .terminateNow
    }
}
