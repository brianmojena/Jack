import SwiftUI

/// Window actions exposed to the menu bar, so every shortcut also appears in the "Agentes" menu.
struct JackActions {
    var newAgent: () -> Void
    var move: (Int) -> Void
    var selectIndex: (Int) -> Void
    var nextAttention: () -> Void
    var focusComposer: () -> Void
    var focusSearch: () -> Void
    var toggleUnread: () -> Void
    var toggleTerminal: () -> Void
    var toggleBrowser: () -> Void
    var hasSelection: Bool
    var agentCount: Int
}

extension FocusedValues {
    @Entry var jackActions: JackActions?
}

struct JackCommands: Commands {
    @FocusedValue(\.jackActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nuevo agente…") { actions?.newAgent() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
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
            Button("Mostrar u ocultar terminal") { actions?.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(actions?.hasSelection != true)
            Button("Mostrar u ocultar navegador") { actions?.toggleBrowser() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true)
        }
    }
}
