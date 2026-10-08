import JackCore
import SwiftUI
import UserNotifications

@main
struct JackApp: App {
    /// `JACK_DATA_DIR` runs a build on a copy of the chats, beside the installed Jack.
    @StateObject private var store = ChatStore(archive: ChatArchive(directory: ProcessInfo.processInfo.environment["JACK_DATA_DIR"].map { URL(fileURLWithPath: $0) }), lightMode: UserDefaults.standard.bool(forKey: "lightModeEnabled"))
    @AppStorage("lightModeEnabled") private var lightMode = false
    @NSApplicationDelegateAdaptor(JackAppDelegate.self) private var appDelegate
    @StateObject private var batterySaver = BatterySaver()
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        Window("Jack", id: "main") {
            Group {
                if lightMode {
                    LightWindowView(store: store, memory: appDelegate.memory)
                } else {
                    MainWindowView(store: store, workspace: appDelegate.workspace, memory: appDelegate.memory, batterySaver: batterySaver, updateChecker: updateChecker)
                }
            }
                .onAppear {
                    appDelegate.store = store
                    appDelegate.batterySaver = batterySaver
                    store.imageGenerationSupported = ImagePlaygroundSupport.isAvailable
                }
                .onChange(of: lightMode, initial: true) { _, enabled in
                    if enabled { appDelegate.workspace.suspendTerminalInterface() }
                    store.setLightMode(enabled)
                    store.applyRemote(enabled: UserDefaults.standard.bool(forKey: "jackRemoteEnabled"))
                }
                .task(id: lightMode) {
                    // Light never looks for updates; Normal checks at launch and every few hours.
                    guard !lightMode else { updateChecker.stop(); return }
                    updateChecker.start()
                    await store.refreshUsage()
                    // Codex's quota only changes when asked for; Claude Code reports its own as it works.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(600))
                        guard !Task.isCancelled else { return }
                        await store.refreshUsage([.codex])
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { JackCommands() }

        Settings {
            SettingsView(store: store, updateChecker: updateChecker)
        }

        MenuBarExtra(isInserted: Binding(get: { batterySaver.isOn }, set: { _ in })) {
            BatterySaverMenu(store: store, saver: batterySaver)
        } label: {
            BatterySaverLabel(store: store, saver: batterySaver)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class JackAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: ChatStore?
    weak var batterySaver: BatterySaver?
    /// Terminals, browsers and the simulator outlive the window, so battery saver can close it without
    /// killing a dev server running in a terminal.
    let workspace = WorkspaceSessions()
    /// Unsent messages and attachments, kept while the window is closed.
    let memory = WindowMemory()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.jack?.delegate = self
    }

    /// In battery saver the window is closed on purpose: Jack keeps running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { batterySaver?.isOn != true }

    /// Opening Jack again (Finder, Spotlight) leaves battery saver.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let batterySaver, batterySaver.isOn else { return true }
        batterySaver.exit()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace.terminateAll()
        store?.shutdown()
        return .terminateNow
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification opens Jack on that agent's chat.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["conversation"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if store?.lightModeEnabled == true {
                if let id { store?.select(id) }
                for window in NSApp.windows where window.isMiniaturized { window.deminiaturize(nil) }
                NSApp.activate()
            } else {
                batterySaver?.exit(showing: id)
            }
        }
    }
}

/// What the main window keeps for when it opens again.
@MainActor
final class WindowMemory {
    var drafts: [UUID: String] = [:]
    var attachments: [UUID: [String]] = [:]
}
