import JackCore
import SwiftUI

/// A tab in one of Jack's strips: icon, title and a close button shown on hover or selection.
struct StripTab<Icon: View, Title: View>: View {
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 7) {
            icon
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
            .foregroundStyle(JackPalette.muted)
            .opacity(selected || hovering ? 1 : 0)
            .help("Cerrar pestaña")
        }
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(minWidth: 120, idealWidth: 180, maxWidth: 200, maxHeight: .infinity)
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
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            StripTab(selected: tab.id == selectedID, onSelect: { onSelect(tab.id) }, onClose: { onClose(tab.id) }) {
                                if tab.status == .idle && !tab.unread {
                                    ProviderMark(provider: tab.provider, size: 12)
                                } else {
                                    StatusDot(status: tab.status, unread: tab.unread)
                                }
                            } title: {
                                Text(tab.title)
                            }
                            .id(tab.id)
                            .help(tab.title)
                        }
                    }
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: tabs.count < 3, vertical: false)
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            StripIconButton(symbol: "plus", help: "Nuevo agente (⌘N)", action: onNew).padding(.horizontal, 4)
            WindowDragArea()
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
    static let width: CGFloat = 154
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        IceTab(tab: tab, selected: tab.id == selectedID, onSelect: { onSelect(tab.id) }, onClose: { onClose(tab.id) })
                            .id(tab.id)
                    }
                }
                .padding(3)
                .jackGlass(in: Capsule(), basic: .clear)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .fixedSize(horizontal: tabs.count < 5, vertical: false)
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
            }
        }
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
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
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
