import JackCore
import SwiftUI

/// Un trabajo previo que la persona puede retomar.
struct OfficeChat: Identifiable {
    var id: UUID
    var title: String
    var project: String
    var status: ChatStatus
    var current: Bool
}

/// El panel de abajo: el chat con una persona de la oficina. El usuario le habla a ella, no a su agente; ella decide qué
/// encargarle, se lo pasa y cuenta lo que pasa.
struct OfficeColleagueView: View {
    enum Mode { case chat, previous }

    let name: String
    /// El agente que tiene a su cargo, por ejemplo «Claude Code · Haiku».
    let tool: String
    let status: ChatStatus?
    let lines: [OfficeLine]
    let thinking: Bool
    let canViewScreen: Bool
    let working: Bool
    let previous: [OfficeChat]
    @Binding var mode: Mode
    let onSend: (String) -> Void
    let onViewScreen: () -> Void
    let onChoose: (UUID) -> Void
    let onNewJob: () -> Void
    let onStopWork: () -> Void
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            Group {
                switch mode {
                case .chat: transcript
                case .previous: previousList
                }
            }
            .frame(height: 290)
            if mode == .chat { composer }
        }
        .frame(maxWidth: 720)
        .background(JackPalette.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 8)
        .onAppear { focused = true }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 10) {
            OfficeAvatar(name: name, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    if let status {
                        Circle().fill(color(status)).frame(width: 6, height: 6)
                        Text(status.title).foregroundStyle(color(status))
                        Text("·").foregroundStyle(JackPalette.faint)
                    }
                    Text(tool).foregroundStyle(JackPalette.muted).lineLimit(1)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 8)
            if canViewScreen {
                Button(action: onViewScreen) {
                    Label("Ver pantalla", systemImage: "display").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(OfficeHeaderButtonStyle())
                .help("Acercarse a su monitor y ver el trabajo tal cual")
            }
            Menu {
                Button("Empezar un encargo nuevo", systemImage: "sparkles", action: onNewJob)
                Button("Retomar un trabajo previo", systemImage: "clock.arrow.circlepath") { mode = .previous }
                if working {
                    Divider()
                    Button("Terminar de trabajar", systemImage: "moon.zzz", action: onStopWork)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
            }
            .menuStyle(.button).buttonStyle(OfficeHeaderButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help("Más opciones")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(OfficeHeaderButtonStyle()).help("Cerrar")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Chat

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty && !thinking {
                        VStack(spacing: 6) {
                            OfficeAvatar(name: name, size: 38)
                            Text("Cuéntale a \(name) qué necesitas").font(.system(size: 14, weight: .semibold))
                            Text("Se lo encargará a \(tool), te irá contando cómo va y te avisará al terminar.")
                                .font(.system(size: 12)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                    ForEach(lines) { line in row(line).id(line.id) }
                    if thinking { OfficeTyping(name: name).id("typing") }
                    if status == .waiting { waitingNotice.id("waiting") }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lines.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: thinking) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func row(_ line: OfficeLine) -> some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(line.text)
                    .font(.system(size: 13)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(JackPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .person:
            HStack(alignment: .top, spacing: 8) {
                OfficeAvatar(name: name, size: 22)
                Text(line.text)
                    .font(.system(size: 13)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 80)
            }
        case .task:
            OfficeTaskRow(text: line.text, tool: tool).padding(.leading, 30)
        case .note:
            Text(line.text).font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private var waitingNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(JackPalette.amber)
            Text("\(tool) espera tu permiso o una respuesta.").font(.system(size: 12))
            Spacer(minLength: 8)
            Button("Ver pantalla", action: onViewScreen).controlSize(.small)
        }
        .padding(10)
        .background(JackPalette.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Escribe a \(name)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 6)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(canSend ? JackPalette.accent : JackPalette.faint, in: Circle())
            }
            .buttonStyle(.plain).disabled(!canSend).help("Enviar (Enter)")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
    }

    private var canSend: Bool { !thinking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        onSend(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        draft = ""
    }

    // MARK: - Trabajos previos

    private var previousList: some View {
        VStack(spacing: 0) {
            HStack {
                Button { mode = .chat } label: { Label("Volver al chat", systemImage: "chevron.left").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
                Spacer()
                Text("Elige el trabajo que retoma \(name)").font(.system(size: 12, weight: .medium)).foregroundStyle(JackPalette.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if previous.isEmpty {
                        Text("Aún no hay trabajos.").font(.system(size: 12)).foregroundStyle(JackPalette.muted).padding(20)
                    }
                    ForEach(previous) { chat in
                        Button { onChoose(chat.id) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(color(chat.status)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(chat.project).font(.system(size: 11)).foregroundStyle(JackPalette.muted).lineLimit(1)
                                }
                                Spacer()
                                if chat.current { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.accent) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(OfficeRowStyle())
                    }
                }
                .padding(6)
            }
        }
    }

    private func color(_ status: ChatStatus) -> Color {
        switch status {
        case .running: JackPalette.green
        case .waiting, .queued: JackPalette.amber
        case .failed: JackPalette.red
        case .idle: JackPalette.muted
        }
    }
}

/// La inicial de la persona en un círculo naranja, como sus burbujas en la escena.
struct OfficeAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.27), Color(red: 0.96, green: 0.45, blue: 0.09)],
                                       startPoint: .top, endPoint: .bottom), in: Circle())
    }
}

/// Un encargo que la persona pasó a su agente: plegado muestra solo que lo encargó; desplegado, el prompt entero.
private struct OfficeTaskRow: View {
    let text: String
    let tool: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold))
                    Text("Se lo encargó a \(tool)").font(.system(size: 11, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(JackPalette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Ocultar el encargo" : "Ver el encargo que recibió el agente")
            if expanded {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// «Remy está escribiendo…» mientras la persona piensa su respuesta.
private struct OfficeTyping: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            OfficeAvatar(name: name, size: 22)
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle().fill(JackPalette.muted).frame(width: 6, height: 6).opacity(index == step ? 1 : 0.35)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Text("\(name) está pensando…").font(.system(size: 11)).foregroundStyle(JackPalette.faint)
        }
    }
}

private struct OfficeHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(JackPalette.muted)
            .padding(.horizontal, 6).frame(minHeight: 26)
            .background(configuration.isPressed ? JackPalette.panelStrong : JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct OfficeRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? JackPalette.panelStrong : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
