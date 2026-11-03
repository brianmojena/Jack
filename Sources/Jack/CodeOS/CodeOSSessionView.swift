import JackCore
import SwiftUI

/// What opens when a tile is chosen: a launch splash like a console game, then the real chat of that project's agent,
/// drawn with Jack's Ice interface and its Liquid Glass tinted with the project's colour.
struct CodeOSSessionView: View {
    @ObservedObject var model: CodeOSModel
    let project: CodeOSProject
    let store: ChatStore
    let workspace: WorkspaceSessions
    let memory: WindowMemory
    let batterySaver: BatterySaver
    let updateChecker: UpdateChecker

    @State private var conversationID: UUID?
    @State private var progress = 0.0

    private var tint: Color { model.tint(project) }
    /// What the glass is tinted with: the project's colour, or neutral.
    private var glass: Color { model.glassTint(project) }
    private var art: CodeOSModel.Art? { model.art[project.id] }

    var body: some View {
        ZStack {
            if let conversationID {
                chat(conversationID).transition(.opacity)
            } else {
                splash.transition(.scale(scale: 1.12).combined(with: .opacity))
            }
        }
        .task(id: "\(project.id)|\(model.agent.rawValue)") { await open() }
    }

    // MARK: Launch splash

    private var splash: some View {
        VStack(spacing: 30) {
            CodeOSArtwork(project: project, art: art, corner: 34)
                .frame(width: 220, height: 220)
                .shadow(color: tint.opacity(0.6), radius: 50)
            Text(project.name).font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
            VStack(spacing: 10) {
                Capsule().fill(.white.opacity(0.18)).frame(width: 300, height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 300 * progress, height: 5) }
                Text("Abriendo \(model.agent.rawValue)…").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: Chat

    /// Jack's own history sidebar and chat, in Ice. Only the glass takes the project's colour: the sidebar pane,
    /// the header pill, the composer and the other glass pieces of the chat.
    private func chat(_ id: UUID) -> some View {
        let pane = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return HStack(spacing: 16) {
            // The glass is a layer behind the sidebar: a list inside a glass view would paint over it.
            ZStack {
                Color.clear.codeOSGlass(tint: glass.opacity(model.neutralGlass ? 0.5 : 0.24), in: pane)
                MainWindowView(store: store, workspace: workspace, memory: memory, batterySaver: batterySaver, updateChecker: updateChecker, embedded: .sidebar,
                               embeddedProjectPath: project.id, onNewChat: { _ = model.conversation(for: project) })
                    .environment(\.jackTint, glass)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    // The pane's rounded corners clip whatever touches the edge: keep the list inside them.
                    .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 14)
            }
            .frame(width: 300)
            .clipShape(pane)
            .overlay(pane.strokeBorder(.white.opacity(0.14), lineWidth: 1))
            // Header, tools bar, chat and panes are one view: the tools act on the panes beside the chat.
            MainWindowView(store: store, workspace: workspace, memory: memory, batterySaver: batterySaver, updateChecker: updateChecker, embedded: .chat,
                           embeddedProjectPath: project.id, embeddedHeader: AnyView(header))
                .environment(\.jackTint, glass)
        }
        .padding(.horizontal, 48)
        .padding(.top, 38)
        .padding(.bottom, 20)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { model.goHome() } label: {
                Label("Inicio", systemImage: "chevron.left").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .codeOSGlass(tint: glass.opacity(model.neutralGlass ? 0.55 : 0.3), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Volver al inicio (⌘⇧H). Centro de control: ⌘K · Cuota: ⌘U")
            CodeOSArtwork(project: project, art: art, corner: 11).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 21, weight: .bold))
                Text(project.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if model.quota.current != nil {
                Group {
                    if !model.quota.active {
                        Label("En pausa", systemImage: "pause.fill")
                    } else if let remaining = model.quota.ownRemaining {
                        Label(remaining <= 0 ? "Sin cuota" : "Tu parte: \(Int(remaining.rounded())) %", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .codeOSGlass(tint: glass.opacity(model.neutralGlass ? 0.55 : 0.3), in: Capsule())
                .onTapGesture { model.toggleQuotaPanel() }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    // MARK: Opening

    /// Shows the splash for a moment, finds or creates the agent's conversation and swaps to the chat.
    private func open() async {
        conversationID = nil
        progress = 0
        withAnimation(.easeInOut(duration: 1.1)) { progress = 1 }
        try? await Task.sleep(for: .milliseconds(1250))
        guard !Task.isCancelled else { return }
        let id = model.conversation(for: project)
        withAnimation(.easeOut(duration: 0.45)) { conversationID = id }
        if id == nil { model.notify("No se pudo abrir \(model.agent.rawValue) en \(project.name).") }
    }
}

extension View {
    /// Liquid Glass tinted with `tint` on macOS 26 and later; a tinted material before.
    @ViewBuilder func codeOSGlass<S: InsettableShape>(tint: Color, in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape).overlay(shape.fill(tint.opacity(0.4)))
        }
    }
}
