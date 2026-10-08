import JackCore
import SwiftUI

/// A tab in one of Jack's strips: icon, title and a close button shown on hover or selection.
struct StripTab<Icon: View, Title: View>: View {
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    var width: CGFloat? = nil
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 7) {
            icon.fixedSize()
            title
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.primary : JackPalette.muted)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(hovering && !selected ? JackPalette.panelStrong : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .foregroundStyle(JackPalette.muted)
            .opacity(selected || hovering ? 1 : 0)
            .help("Cerrar pestaña")
        }
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(minWidth: width ?? 120, idealWidth: width ?? 180, maxWidth: width ?? 200, maxHeight: .infinity)
        .background { if selected { selectionBackground } }
        .overlay(alignment: .top) { if selected && style == .basic { Rectangle().fill(JackPalette.accent).frame(height: 1.5) } }
        .overlay(alignment: .trailing) { if style == .basic { Rectangle().fill(JackPalette.hairline).frame(width: 1) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Basic joins the selected tab to the chat below; Ice floats it as a glass lozenge.
    @ViewBuilder private var selectionBackground: some View {
        if style == .basic {
            JackPalette.canvas
        } else {
            Color.clear
                .jackGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), basic: .clear)
                .padding(.vertical, 5).padding(.horizontal, 2)
        }
    }
}

struct StripIconButton: View {
    let symbol: String
    var active = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5))
                .frame(width: 28, height: 26)
                .background(active ? JackPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.primary : JackPalette.muted)
        .help(help)
    }
}

struct AgentTabModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let provider: ChatProvider
    let status: ChatStatus
    let unread: Bool
}

/// Both appearances use the actual viewport width, rather than changing sizing at a tab count.
/// Tabs first compress together; below a readable width they scroll and expose a tab menu.
private struct AdaptiveAgentTabs: View {
    let tabs: [AgentTabModel]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        GeometryReader { geometry in
            let ice = style == .ice
            let spacing: CGFloat = ice ? 2 : 0
            let inset: CGFloat = ice ? 6 : 0
            let gaps = CGFloat(max(0, tabs.count - 1)) * spacing
            let overflows = CGFloat(tabs.count) * 72 + gaps + inset > geometry.size.width
            let viewport = max(0, geometry.size.width - (overflows ? 28 : 0))
            let width = max(72, min(200, (viewport - gaps - inset) / CGFloat(max(1, tabs.count))))

            if geometry.size.width < 100 {
                // With both side panes open, the traffic lights and tools can leave room
                // for only the selected agent's logo. Keep every tab reachable via the menu.
                tabMenu(compact: true)
                    .frame(width: max(0, geometry.size.width), height: geometry.size.height)
            } else {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: spacing) {
                                ForEach(tabs) { tab in
                                    Group {
                                        if ice {
                                            IceTab(tab: tab, selected: tab.id == selectedID,
                                                   onSelect: { onSelect(tab.id) }, onClose: { onClose(tab.id) })
                                                .frame(width: width)
                                        } else {
                                            StripTab(selected: tab.id == selectedID,
                                                     onSelect: { onSelect(tab.id) }, onClose: { onClose(tab.id) }, icon: {
                                                if tab.status == .idle && !tab.unread {
                                                    ProviderMark(provider: tab.provider, size: 12)
                                                } else {
                                                    StatusDot(status: tab.status, unread: tab.unread)
                                                }
                                            }, title: {
                                                Text(tab.title)
                                            }, width: width)
                                        }
                                    }
                                    .id(tab.id)
                                    .help(tab.title)
                                }
                            }
                            .padding(ice ? 3 : 0)
                            .jackGlass(in: Capsule(), basic: .clear)
                            .frame(height: geometry.size.height)
                        }
                        .scrollIndicators(.never)
                        .frame(width: viewport)
                        .onChange(of: selectedID, initial: true) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onChange(of: geometry.size.width) { _, _ in
                            if let selectedID { proxy.scrollTo(selectedID) }
                        }
                        .onChange(of: tabs.map(\.id)) { _, _ in
                            if let selectedID { proxy.scrollTo(selectedID) }
                        }
                    }
                    if overflows {
                        tabMenu(compact: false).frame(width: 28)
                    }
                }
            }
        }
        .background(WindowDragArea())
    }

    private func tabMenu(compact: Bool) -> some View {
        Menu {
            ForEach(tabs) { tab in
                Button { onSelect(tab.id) } label: {
                    if tab.id == selectedID { Label(tab.title, systemImage: "checkmark") }
                    else { Text(tab.title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if compact, let selected = tabs.first(where: { $0.id == selectedID }) {
                    ProviderMark(provider: selected.provider, size: 12)
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Todas las pestañas (\(tabs.count))")
        .accessibilityLabel("Todas las pestañas")
    }
}

/// Open agents along the top of the chat, plus the switches for the side panes.
struct AgentTabStrip: View, Equatable {
    let tabs: [AgentTabModel]
    let selectedID: UUID?
    let sidebarVisible: Bool
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void
    let onShowSidebar: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabs == rhs.tabs && lhs.selectedID == rhs.selectedID && lhs.sidebarVisible == rhs.sidebarVisible
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarVisible {
                // Room for the traffic lights, then the button that brings the sidebar back.
                Color.clear.frame(width: 76).background(WindowDragArea())
                StripIconButton(symbol: "sidebar.left", help: "Mostrar la barra lateral (⌃⌘S)", action: onShowSidebar)
                    .padding(.trailing, 6)
            }
            AdaptiveAgentTabs(tabs: tabs, selectedID: selectedID, onSelect: onSelect, onClose: onClose)
            StripIconButton(symbol: "plus", help: "Nuevo agente (⌘N)", action: onNew).padding(.horizontal, 4)
            // The pane switches sit on top of this space; see `WorkspaceToggles`.
            Color.clear.frame(width: WorkspaceToggles.width)
        }
        .frame(height: JackMetrics.stripHeight)
        .jackSurface(.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
}

/// Switches for the terminal, browser, simulator and file panes. They observe the agent's tabs,
/// so the highlighted tool follows the tab selected in the pane.
struct WorkspaceToggles: View, Equatable {
    static let width: CGFloat = 182
    @ObservedObject var sessions: WorkspaceSessions
    let conversationID: UUID?
    let paneVisible: Bool
    let explorerVisible: Bool
    let onToggle: (WorkspaceTool) -> Void
    let onToggleExplorer: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversationID == rhs.conversationID && lhs.paneVisible == rhs.paneVisible && lhs.explorerVisible == rhs.explorerVisible
    }

    var body: some View {
        let current = paneVisible ? conversationID.flatMap { sessions.selectedTab(for: $0)?.kind } : nil
        HStack(spacing: 2) {
            StripIconButton(symbol: "apple.terminal", active: current == .terminal, help: "Terminal (⌃`)") { onToggle(.terminal) }
            StripIconButton(symbol: "globe", active: current == .browser, help: "Navegador (⇧⌘B)") { onToggle(.browser) }
            StripIconButton(symbol: "iphone", active: current == .simulator, help: "Simulador de iOS (⇧⌘I)") { onToggle(.simulator) }
            StripIconButton(symbol: "arrow.triangle.branch", active: current == .git, help: "Git (⇧⌘G)") { onToggle(.git) }
            StripIconButton(symbol: "flowchart", active: current == .flow, help: "Diagrama de flujo") { onToggle(.flow) }
            StripIconButton(symbol: "sidebar.right", active: explorerVisible, help: "Archivos del proyecto (⇧⌘E)", action: onToggleExplorer)
        }
        .disabled(conversationID == nil)
        .padding(.trailing, 8)
        .frame(width: Self.width, height: JackMetrics.stripHeight, alignment: .trailing)
    }
}

/// The agents shown as tabs, in order. Selecting an agent anywhere opens its tab.
struct OpenTabs {
    static func decode(_ value: String) -> [UUID] { value.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
    static func encode(_ ids: [UUID]) -> String { ids.map(\.uuidString).joined(separator: ",") }

    /// Adds `id` right after the tab that was selected, so related work stays together.
    static func opening(_ id: UUID, in ids: [UUID], after previous: UUID?) -> [UUID] {
        guard !ids.contains(id) else { return ids }
        var result = ids
        if let previous, let index = result.firstIndex(of: previous) { result.insert(id, at: index + 1) }
        else { result.append(id) }
        return result
    }
}

// MARK: - Ice

/// The terminal, browser, simulator and file switches as native toolbar toggles: macOS draws
/// them as one Liquid Glass group.
struct WorkspaceToolbarButtons: View {
    @ObservedObject var sessions: WorkspaceSessions
    let conversationID: UUID?
    let paneVisible: Bool
    let explorerVisible: Bool
    let onToggle: (WorkspaceTool) -> Void
    let onToggleExplorer: () -> Void

    var body: some View {
        let current = paneVisible ? conversationID.flatMap { sessions.selectedTab(for: $0)?.kind } : nil
        ControlGroup {
            toggle("Terminal", "apple.terminal", on: current == .terminal, help: "Terminal (⌃`)") { onToggle(.terminal) }
            toggle("Navegador", "globe", on: current == .browser, help: "Navegador (⇧⌘B)") { onToggle(.browser) }
            toggle("Simulador", "iphone", on: current == .simulator, help: "Simulador de iOS (⇧⌘I)") { onToggle(.simulator) }
            toggle("Git", "arrow.triangle.branch", on: current == .git, help: "Git (⇧⌘G)") { onToggle(.git) }
            toggle("Flujo", "flowchart", on: current == .flow, help: "Diagrama de flujo") { onToggle(.flow) }
            toggle("Archivos", "sidebar.right", on: explorerVisible, help: "Archivos del proyecto (⇧⌘E)", action: onToggleExplorer)
        }
        .disabled(conversationID == nil)
    }

    private func toggle(_ title: String, _ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) { Label(title, systemImage: symbol) }
            .toggleStyle(.button)
            .help(help)
    }
}

/// Open agents as a Liquid Glass tab bar floating over the top of the chat.
struct IceAgentTabs: View, Equatable {
    let tabs: [AgentTabModel]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabs == rhs.tabs && lhs.selectedID == rhs.selectedID
    }

    var body: some View {
        AdaptiveAgentTabs(tabs: tabs, selectedID: selectedID, onSelect: onSelect, onClose: onClose)
        .frame(height: 32)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct IceTab: View {
    let tab: AgentTabModel
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.status == .idle && !tab.unread {
                ProviderMark(provider: tab.provider, size: 12)
            } else {
                StatusDot(status: tab.status, unread: tab.unread)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).contentShape(Circle())
            }
            .buttonStyle(.plain).fixedSize().foregroundStyle(.secondary)
            .opacity(selected || hovering ? 1 : 0)
            .help("Cerrar pestaña")
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 26)
        .background(selected ? JackPalette.selection : .clear, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
