import SwiftUI

/// La oficina a pantalla completa en el iPhone: la misma interfaz que en la Mac (`OfficeInterfaceView`), con la Mac de
/// `MacLink` como quien da los agentes. Todo lo de la oficina pasa aquí; solo los agentes y los modelos corren en la Mac.
struct MobileOfficeView: View {
    @StateObject private var link = MacLink()
    @State private var connecting = false

    var body: some View {
        OfficeInterfaceView(store: link, sidebarVisible: true, onShowSidebar: {}) { target in
            if case .agent(let id) = target { MobileChatView(link: link, agent: id.uuidString) }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topLeading) { macButton.padding(.top, 10).padding(.leading, 12) }
        .sheet(isPresented: $connecting) { MobileConnectView(link: link) }
        .onAppear { link.startBrowsing() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Mac

    private var macButton: some View {
        Button { connecting = true } label: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusTitle).font(.footnote.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusTitle: String {
        switch link.state {
        case .idle: "Conectar con la Mac"
        case .connecting(let name): "Conectando con \(name)…"
        case .connected(let name): name
        case .failed: "Sin conexión"
        }
    }

    private var statusColor: Color {
        switch link.state {
        case .connected: .green
        case .connecting: .yellow
        case .idle, .failed: .red
        }
    }
}

// MARK: - Conectar

/// Las Macs con Jack de la red local; la primera vez se escribe el código que Jack enseña en Ajustes › Jack Remote.
struct MobileConnectView: View {
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: MacLink.Found?
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch link.state {
                    case .connected(let name):
                        Label("Conectado a \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Desconectar") { link.disconnect(forget: false) }
                        Button("Olvidar esta Mac", role: .destructive) { link.disconnect(forget: true) }
                    case .connecting(let name):
                        Label("Conectando con \(name)…", systemImage: "hourglass")
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    case .idle:
                        Text("Elige tu Mac. En ella, Jack tiene que tener Jack Remote encendido (Ajustes › Jack Remote).")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Macs en la red") {
                    if link.found.isEmpty {
                        HStack { ProgressView(); Text("Buscando…").foregroundStyle(.secondary) }
                    }
                    ForEach(link.found) { mac in
                        Button { chosen = mac; code = MacLinkKeychain.code(for: mac.name) ?? "" } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                    }
                }
                if let chosen {
                    Section("Código de \(chosen.name)") {
                        TextField("XXXX-XXXX-XXXX-XXXX", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button("Conectar") { link.connect(to: chosen, code: code) }
                            .disabled(!JackRemote.isValid(code))
                    }
                }
            }
            .navigationTitle("Tu Mac")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .onChange(of: link.state) { _, state in if case .connected = state { dismiss() } }
        }
    }
}

// MARK: - Chat con el agente

/// Lo que dice el agente (en la Mac) y lo que se le escribe; también sus permisos pendientes. Es lo que se ve en su monitor
/// al pulsar «Ver pantalla».
struct MobileChatView: View {
    @ObservedObject var link: MacLink
    let agent: String
    @State private var text = ""
    @State private var error: String?

    private var messages: [JackRemote.Message] { (link.transcripts[agent] ?? []).filter { !$0.text.isEmpty } }
    private var summary: JackRemote.AgentSummary? { link.agents.first { $0.id == agent } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in bubble(message).id(message.id) }
                        ForEach(link.approvals[agent] ?? []) { approval in approvalCard(approval) }
                    }
                    .padding()
                }
                .onChange(of: messages.last?.id) { _, last in if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(summary?.title ?? "Agente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if summary.map({ ChatStatus(rawValue: $0.status)?.isActive == true }) == true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Detener", systemImage: "stop.circle") { Task { await link.stop(agent) } }
                    }
                }
            }
        }
        .onAppear { link.open(agent) }
        .onDisappear { link.close(agent) }
    }

    private func bubble(_ message: JackRemote.Message) -> some View {
        let mine = message.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if message.role == "tool" {
                    Label(message.text, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(message.text).font(.callout).textSelection(.enabled)
                }
            }
            .padding(10)
            .background(mine ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(message.role == "error" ? 0.35 : 0.15),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func approvalCard(_ approval: JackRemote.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            if !approval.detail.isEmpty { Text(approval.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8) }
            HStack {
                let choices = approval.choices.isEmpty ? [JackRemote.Choice(id: "allow", title: "Permitir"), JackRemote.Choice(id: "deny", title: "Denegar")] : approval.choices
                ForEach(choices) { choice in
                    Button(choice.title) { Task { await link.respond(agent, approval: approval.id, choice: choice.id) } }
                        .buttonStyle(.borderedProminent)
                        .tint(choice.id == "deny" ? .red : .accentColor)
                }
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                TextField("Escribe al agente…", text: $text, axis: .vertical).lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let message = text
                    text = ""
                    Task { error = await link.write(message, to: agent) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }
}
