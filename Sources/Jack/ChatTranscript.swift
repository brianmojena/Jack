import JackCore
import SwiftUI

/// An agent's messages, following it to the end until the user scrolls up.
/// Equatable on what it shows, so an agent streaming in another chat or pane does not redraw this one;
/// its scroll state is its own, so scrolling never re-renders the window.
struct ChatTranscript: View, Equatable {
    let conversation: ChatConversation
    let active: Bool
    let monospaced: Bool
    let ice: Bool
    let onPrompt: (String) -> Void
    @State private var visibleCount = 100
    /// The user scrolled up; the chat stops following until they return to the end.
    @State private var unfollowed = false
    /// The user is dragging, flicking or wheeling the transcript; only they can stop the chat from following.
    @State private var userScrolling = false

    private static let bottomID = "jack-chat-bottom"

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Arrays and strings compare their storage first, so an untouched chat costs almost nothing.
        lhs.conversation.id == rhs.conversation.id && lhs.conversation.messages == rhs.conversation.messages
            && lhs.active == rhs.active && lhs.monospaced == rhs.monospaced && lhs.ice == rhs.ice
            && lhs.conversation.provider == rhs.conversation.provider && lhs.conversation.model == rhs.conversation.model
            && lhs.conversation.effort == rhs.conversation.effort && lhs.conversation.projectPath == rhs.conversation.projectPath
    }

    var body: some View {
        let conversation = conversation
        let width = MainWindowView.columnWidth
        ScrollViewReader { proxy in
            ScrollView {
                // A plain stack, not a lazy one: while the agent streams, the chat keeps scrolling itself to the end,
                // and a LazyVStack then sometimes had no row created in view, leaving the chat blank until the user
                // scrolled. Only the last 100 messages are shown, and rows are Equatable, so the cost stays small.
                VStack(alignment: .leading, spacing: 0) {
                    if conversation.messages.isEmpty {
                        // Only on an empty chat: any row above the messages kept the bottom-anchored lazy stack
                        // from drawing the rows in view.
                        ConversationHeader(conversation: conversation).equatable()
                        ConversationWelcome(conversation: conversation, onPrompt: onPrompt)
                            .padding(.top, 40)
                    } else {
                        let start = max(0, conversation.messages.count - visibleCount)
                        if start > 0 {
                            Button("Cargar mensajes anteriores") { visibleCount += 100 }
                                .font(.system(size: 11, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(JackPalette.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 16)
                        }
                        let lastID = conversation.messages.last?.id
                        ForEach(start..<conversation.messages.count, id: \.self) { index in
                            let message = conversation.messages[index]
                            ChatMessageRow(
                                message: message,
                                provider: conversation.provider,
                                projectPath: conversation.projectPath,
                                isStreaming: active && message.id == lastID,
                                topSpacing: index == start ? 0 : ChatRowSpacing.between(conversation.messages[index - 1].role, message.role),
                                monospaced: monospaced
                            )
                            .equatable()
                            .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 18).padding(.bottom, 20)
            }
            .defaultScrollAnchor(.bottom)
            // Only the follow flag crosses into view state, and only when it flips.
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                ChatScrollMetrics(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                                  visible: geometry.containerSize.height,
                                  // Ice's composer floats over the end of the chat: its inset is part of the scrollable range.
                                  distanceToBottom: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY)
            } action: { old, new in
                var follow = !unfollowed
                if new.distanceToBottom < 24 {
                    follow = true
                } else if userScrolling, new.offset < old.offset - 0.5 {
                    // Only the user scrolling back stops the chat from following; SwiftUI also moves the offset
                    // when it measures rows above, and that used to leave the chat stuck mid-conversation.
                    follow = false
                }
                if follow == unfollowed { unfollowed = !follow }
                if !userScrolling, new.distanceToBottom < -1 {
                    // The content shrank (a reply rewritten shorter, a panel below gone, a row smaller than
                    // estimated) and left the view past the last line, showing a blank chat until the next scroll.
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else if follow, new.distanceToBottom > 0.5, new.content != old.content || new.visible != old.visible {
                    // New text, a tool row or a panel below the chat: stay on the agent's last line.
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onScrollPhaseChange { _, phase in
                let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if scrolling != userScrolling { userScrolling = scrolling }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                if !unfollowed { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.id) { _, _ in
                // Another agent took this chat: start at its end, with its newest messages.
                unfollowed = false
                visibleCount = 100
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // A second scroll after the first layout makes the rows in view appear.
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                ZStack {
                    if unfollowed {
                        Button {
                            unfollowed = false
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        } label: {
                            Label("Volver a la conversación", systemImage: "arrow.down")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .jackGlass(in: Capsule(), basic: JackPalette.panelStrong, interactive: true)
                                .overlay { if !ice { Capsule().strokeBorder(JackPalette.hairline) } }
                                .shadow(color: .black.opacity(ice ? 0 : 0.15), radius: 6, y: 2)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: unfollowed)
            }
        }
    }
}

private struct ChatScrollMetrics: Equatable {
    let offset: CGFloat
    let content: CGFloat
    let visible: CGFloat
    let distanceToBottom: CGFloat
}

/// The top of a transcript, like a CLI's banner: who the agent is, its model and its folder.
private struct ConversationHeader: View, Equatable {
    let conversation: ChatConversation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation.provider == rhs.conversation.provider && lhs.conversation.model == rhs.conversation.model
            && lhs.conversation.effort == rhs.conversation.effort && lhs.conversation.projectPath == rhs.conversation.projectPath
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            providerGlyph(conversation.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.provider.title).font(.mono(12.5, weight: .semibold))
                Text([conversation.model.isEmpty ? "Modelo por defecto" : conversation.model, conversation.effort].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.mono(12)).foregroundStyle(JackPalette.muted)
                Text((conversation.projectPath as NSString).abbreviatingWithTildeInPath)
                    .font(.mono(12)).foregroundStyle(JackPalette.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
}

private struct ConversationWelcome: View {
    let conversation: ChatConversation
    let onPrompt: (String) -> Void
    private let suggestions: [(symbol: String, text: String)] = [
        ("doc.text.magnifyingglass", "Resume este proyecto"),
        ("arrow.triangle.branch", "Revisa los cambios recientes"),
        ("list.bullet.clipboard", "Ayúdame a planificar el siguiente paso"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                providerGlyph(conversation.provider, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿Qué hacemos hoy?").font(.system(size: 22, weight: .semibold))
                    Text("\(conversation.provider.title) está listo en \(URL(fileURLWithPath: conversation.projectPath).lastPathComponent).")
                        .font(.system(size: 13)).foregroundStyle(JackPalette.muted)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    if index > 0 { Divider().padding(.leading, 40) }
                    Button { onPrompt(suggestion.text) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: suggestion.symbol).foregroundStyle(JackPalette.accent).frame(width: 18)
                            Text(suggestion.text).font(.system(size: 13))
                            Spacer()
                            Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(JackPalette.faint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5))
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
