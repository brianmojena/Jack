import AppKit
import Combine
import JackCore
import SwiftUI
import UserNotifications

/// Battery saver: the main window closes, Jack leaves the Dock and lives in the menu bar, showing
/// the agents at work and notifying when one finishes, fails or needs permission.
@MainActor
final class BatterySaver: ObservableObject {
    @Published private(set) var isOn = false
    /// Reopens the main window. Registered by a view that has SwiftUI's `openWindow`, since AppKit
    /// callbacks such as notification clicks have none.
    var openMainWindow: (() -> Void)?
    private weak var store: ChatStore?
    private var watching: AnyCancellable?

    func enter(store: ChatStore) {
        guard !isOn else { return }
        self.store = store
        isOn = true
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.jack?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        watch(store)
    }

    /// Back to the full window, optionally on `conversation`.
    func exit(showing conversation: UUID? = nil) {
        if let conversation { store?.select(conversation) }
        guard isOn else { NSApp.activate(); return }
        isOn = false
        watching = nil
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate()
    }

    private func watch(_ store: ChatStore) {
        var previous = store.statuses
        watching = store.$statuses
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] statuses in
                guard let self, let store else { return }
                for (id, status) in statuses where status != previous[id] {
                    // Sub-agents report to their agent, which keeps working: only top-level agents notify.
                    guard let conversation = store.conversations.first(where: { $0.id == id }), conversation.parentID == nil else { continue }
                    let wasWorking = previous[id] == .running || previous[id] == .queued
                    switch status {
                    case .idle where wasWorking: self.notify(conversation, title: "Terminó: \(conversation.title)", body: conversation.preview ?? "")
                    case .failed: self.notify(conversation, title: "Falló: \(conversation.title)", body: conversation.messages.last { $0.role == "error" }?.text ?? "")
                    case .waiting: self.notify(conversation, title: "Necesita tu permiso: \(conversation.title)",
                                               body: store.approvals[id]?.first?.title ?? "El agente espera tu respuesta.")
                    default: break
                    }
                }
                previous = statuses
            }
    }

    private func notify(_ conversation: ChatConversation, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.userInfo = ["conversation": conversation.id.uuidString]
        UNUserNotificationCenter.jack?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension UNUserNotificationCenter {
    /// Nil outside an app bundle (`swift run`), where asking for the center throws.
    static var jack: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }
}

/// The menu bar icon: Jack's leaf, with the number of agents at work.
struct BatterySaverLabel: View {
    @ObservedObject var store: ChatStore
    let saver: BatterySaver
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let working = store.statuses.values.filter(\.isActive).count
        HStack(spacing: 3) {
            Image(systemName: "leaf.fill")
            if working > 0 { Text("\(working)").monospacedDigit() }
        }
        .onAppear { saver.openMainWindow = { openWindow(id: "main") } }
    }
}

/// The menu bar panel: agents at work, each opening Jack on its chat.
struct BatterySaverMenu: View {
    @ObservedObject var store: ChatStore
    let saver: BatterySaver
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = store.conversations.filter { store.statuses[$0.id]?.isActive == true }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill").foregroundStyle(JackPalette.green)
                Text("Modo ahorro de batería").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if active.isEmpty {
                Text("Ningún agente trabajando. Te aviso cuando alguno termine o necesite tu permiso.")
                    .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(active) { conversation in
                            BatterySaverRow(conversation: conversation, status: store.statuses[conversation.id] ?? .idle) {
                                open(conversation.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            }

            Divider()
            HStack {
                Button("Abrir Jack") { open(nil) }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 320)
        .onAppear { saver.openMainWindow = { openWindow(id: "main") } }
    }

    private func open(_ conversation: UUID?) {
        saver.openMainWindow = { openWindow(id: "main") }
        saver.exit(showing: conversation)
    }
}

private struct BatterySaverRow: View {
    let conversation: ChatConversation
    let status: ChatStatus
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StatusDot(status: status)
                ProviderMark(provider: conversation.provider, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title).font(.system(size: 12.5)).lineLimit(1)
                    Text("\(URL(fileURLWithPath: conversation.projectPath).lastPathComponent) · \(status.title)")
                        .font(.system(size: 11)).foregroundStyle(status == .waiting ? JackPalette.amber : JackPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
