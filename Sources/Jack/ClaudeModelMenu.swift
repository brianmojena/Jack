import JackCore
import SwiftUI

/// The Claude Code entries of a model menu: the four families ("the latest of each"), then one submenu per family with its exact
/// versions, then any other model already in use. Normal mode only: Light's menus keep the plain list.
struct ClaudeModelMenuItems: View {
    let choices: [ChatModelChoice]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        ForEach(ChatModelChoice.claudeCatalog) { choice in item(choice, title: choice.title + " · último") }
        Divider()
        ForEach(ChatModelChoice.claudeVersions, id: \.family) { family in
            Menu(family.family + " · versiones") {
                ForEach(family.models) { choice in item(choice, title: choice.title) }
            }
        }
        let known = Set(ChatModelChoice.claudeCatalog.map(\.id) + ChatModelChoice.claudeExact.map(\.id))
        let others = choices.filter { !known.contains($0.id) && !$0.id.isEmpty }
        if !others.isEmpty {
            Divider()
            ForEach(others) { choice in item(choice, title: choice.title) }
        }
    }

    private func item(_ choice: ChatModelChoice, title: String) -> some View {
        Button { pick(choice.id) } label: {
            if choice.id == selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
