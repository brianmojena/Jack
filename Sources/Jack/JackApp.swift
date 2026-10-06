import JackCore
import SwiftUI

@main
struct JackApp: App {
    /// `JACK_DATA_DIR` runs a build on a copy of the chats, beside the installed Jack.
    @StateObject private var store = ChatStore(archive: ChatArchive(directory: ProcessInfo.processInfo.environment["JACK_DATA_DIR"].map { URL(fileURLWithPath: $0) }))
    @NSApplicationDelegateAdaptor(JackAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Jack", id: "main") {
            MainWindowView(store: store)
                
                .onAppear {
                    appDelegate.store = store
                    store.imageGenerationSupported = ImagePlaygroundSupport.isAvailable
                }
                .task {
                    await store.refreshUsage()
                    // Codex's quota only changes when asked for; Claude Code reports its own as it works.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(600))
                        await store.refreshUsage([.codex])
                    }
                }
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
