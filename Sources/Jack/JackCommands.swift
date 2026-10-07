import AppKit
import SwiftUI

/// Window actions exposed to the menu bar, so every shortcut also appears in the "Agentes" menu.
struct JackActions {
    var newAgent: () -> Void
    var resumeClaudeSession: () -> Void
    var move: (Int) -> Void
    var selectIndex: (Int) -> Void
    var nextAttention: () -> Void
    var focusComposer: () -> Void
    var focusSearch: () -> Void
    var toggleUnread: () -> Void
    var toggleTerminal: () -> Void
    var toggleBrowser: () -> Void
    var toggleSimulator: () -> Void
    var toggleGit: () -> Void
    var toggleExplorer: () -> Void
    var toggleSidebar: () -> Void
    var closeTab: () -> Void
    var cyclePane: (Int) -> Void
    var closePanes: () -> Void
    var paneCount: Int
    var enterBatterySaver: () -> Void
    var hasSelection: Bool
    var agentCount: Int
}

extension FocusedValues {
    @Entry var jackActions: JackActions?
}

/// The same persisted switch is available in both window layouts and the app menu.
struct LightModeToggle: View {
    @AppStorage("lightModeEnabled") private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Label("Light", systemImage: "leaf")
                .font(.system(size: 11, weight: .medium))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .accessibilityLabel("Modo Light")
        .help(enabled ? "Desactivar Light y volver al modo Normal (⌃⌘L)" : "Activar el modo Light para ahorrar batería (⌃⌘L)")
    }
}

struct JackCommands: Commands {
    @FocusedValue(\.jackActions) private var actions
    @AppStorage("lightModeEnabled") private var lightMode = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(lightMode ? "Nuevo agente…" : "Nuevo agente") { actions?.newAgent() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
            Button("Retomar sesión de Claude Code…") { actions?.resumeClaudeSession() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        // ⌘W closes the agent's tab, as in a browser; ⇧⌘W closes the window.
        CommandGroup(replacing: .saveItem) {
            Button("Cerrar pestaña") {
                if let actions, actions.hasSelection { actions.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Cerrar ventana") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Toggle("Modo Light", isOn: $lightMode)
                .keyboardShortcut("l", modifiers: [.command, .control])
            Button("Mostrar u ocultar barra lateral") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions == nil || lightMode)
            Button("Mostrar u ocultar archivos") { actions?.toggleExplorer() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true)
            Button("Modo ahorro de batería") { actions?.enterBatterySaver() }
                .keyboardShortcut("b", modifiers: [.command, .control])
                .disabled(actions == nil)
            Divider()
        }
        CommandMenu("Agentes") {
            Button("Agente anterior") { actions?.move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled((actions?.agentCount ?? 0) == 0)
            Button("Agente siguiente") { actions?.move(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled((actions?.agentCount ?? 0) == 0)
            Button("Siguiente que necesita atención") { actions?.nextAttention() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled((actions?.agentCount ?? 0) == 0)
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Agente \(index)") { actions?.selectIndex(index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled((actions?.agentCount ?? 0) < index)
            }
            Divider()
            Button("Escribir mensaje") { actions?.focusComposer() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(actions?.hasSelection != true)
            Button("Buscar agentes") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Marcar como leído / no leído") { actions?.toggleUnread() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true)
            Divider()
            Button("Panel anterior") { actions?.cyclePane(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((actions?.paneCount ?? 0) == 0)
            Button("Panel siguiente") { actions?.cyclePane(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((actions?.paneCount ?? 0) == 0)
            Button("Cerrar paneles") { actions?.closePanes() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled((actions?.paneCount ?? 0) == 0)
            Divider()
            Button("Mostrar u ocultar terminal") { actions?.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(actions?.hasSelection != true || lightMode)
            Button("Mostrar u ocultar navegador") { actions?.toggleBrowser() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true || lightMode)
            Button("Mostrar u ocultar simulador de iOS") { actions?.toggleSimulator() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true || lightMode)
            Button("Mostrar u ocultar Git") { actions?.toggleGit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true || lightMode)
        }
    }
}
