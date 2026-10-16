import JackCore
import SwiftUI

/// Both offices are explicit Normal-mode interfaces. Merely opening settings in Light never mounts either scene.
struct OfficePresentationPicker: View {
    @AppStorage(InterfaceStyle.key) private var style = InterfaceStyle.basic

    var body: some View {
        Picker("Vista de la oficina", selection: Binding(get: { style.isOffice ? style : .office }, set: { style = $0 })) {
            Text("2D").tag(InterfaceStyle.office2D)
            Text("3D").tag(InterfaceStyle.office)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 100)
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .help("Cambiar entre Oficina 2D y Oficina 3D")
    }
}

struct Office2DInterfaceView<Content: View>: View {
    @ObservedObject var store: ChatStore
    let batterySaver: BatterySaver
    let sidebarVisible: Bool
    let onShowSidebar: () -> Void
    @ViewBuilder var screenContent: (OfficePanelTarget) -> Content
    @State private var screen: Screen?

    private struct Screen: Identifiable {
        let id = UUID()
        var target: OfficePanelTarget
    }

    var body: some View {
        Office2DView(store: store, batterySaver: batterySaver, sidebarVisible: sidebarVisible, suspended: screen != nil,
                     onShowSidebar: onShowSidebar, onNew: {
            screen = Screen(target: .newAgent(slot: nil, token: UUID(), provider: nil, model: nil))
        }, onOpen: { id in
            store.setUnread(id, false)
            screen = Screen(target: .agent(id))
        })
        .sheet(item: $screen) { presented in
            VStack(spacing: 0) {
                HStack {
                    Label("Oficina 2D", systemImage: "building.2.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Volver a la oficina") { screen = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                screenContent(screen?.target ?? presented.target)
            }
            .frame(minWidth: 720, idealWidth: 980, minHeight: 560, idealHeight: 740)
            .background(JackPalette.canvas)
        }
        .onChange(of: store.selectedID) { _, id in
            // The existing start form creates and selects the conversation. Keep its chat inside the office.
            if let id, let screen, case .newAgent = screen.target {
                self.screen?.target = .agent(id)
            }
        }
    }
}
