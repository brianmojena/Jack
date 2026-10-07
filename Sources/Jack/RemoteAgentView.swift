import AppKit
import JackCore
import SwiftUI

/// Last SSH destination used for a new agent, so repeating with the same machine is one tap.
enum LastRemote {
    static var destination: String {
        get { UserDefaults.standard.string(forKey: "lastRemoteDestination") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastRemoteDestination") }
    }
    static var path: String {
        get { UserDefaults.standard.string(forKey: "lastRemotePath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastRemotePath") }
    }
}

/// Builds a valid endpoint from draft fields, or nil when incomplete.
/// An empty folder means automatic discovery when the agent is created.
func remoteEndpoint(enabled: Bool, destination: String, remotePath: String) -> ChatRemoteEndpoint? {
    let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard enabled,
          !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          path.isEmpty || path.hasPrefix("/") else { return nil }
    return ChatRemoteEndpoint(destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                              remotePath: path.isEmpty ? nil : path)
}

/// Destination (`usuario@ip`) and remote folder fields. Once destination is filled it checks the
/// connection by itself; when the machine rejects our keys it asks for the password once,
/// installs this Mac's key and remembers the machine. Shared by the new-agent composer
/// and the per-conversation panel.
struct RemoteEndpointForm: View {
    @Binding var destination: String
    @Binding var remotePath: String
    @State private var status: Status = .idle
    @State private var password = ""
    @State private var saved = SavedRemotes.load()
    @State private var keychainPassword = ""

    private enum Status: Equatable {
        case idle, checking, ready(String), needsKey, installing, failed(String)
    }

    private var cleanDestination: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var endpoint: ChatRemoteEndpoint {
        ChatRemoteEndpoint(destination: cleanDestination,
                           remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !saved.isEmpty {
                Menu {
                    ForEach(saved) { machine in
                        Button(machine.destination) { choose(machine) }
                    }
                } label: {
                    Label("Máquinas guardadas", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Destino").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    TextField("ruben@192.168.1.193", text: $destination)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                GridRow {
                    Text("Carpeta remota").font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    TextField("Automática", text: $remotePath)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                SecureField("Contraseña del llavero (opcional)", text: $keychainPassword)
                    .textFieldStyle(.roundedBorder).frame(width: 308)
                Text("Si la guardas, Jack desbloquea el llavero de esa máquina cada vez que conecta. Se guarda en el llavero de este Mac.")
                    .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusView
        }
        .onChange(of: keychainPassword) { _, value in
            if !cleanDestination.isEmpty { RemoteKeychain.setPassword(value, for: cleanDestination) }
        }
        // Re-checks 0.8 s after the user stops typing the destination.
        .task(id: cleanDestination) {
            keychainPassword = RemoteKeychain.password(for: cleanDestination) ?? ""
            await autoCheck()
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Comprobando conexión…").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Instalando la clave…").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
            }
        case .ready(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .needsKey:
            VStack(alignment: .leading, spacing: 6) {
                Text("Esa máquina aún no conoce tu clave. Escribe su contraseña una vez: Jack instala la clave y no volverá a pedirla.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecureField("Contraseña de \(cleanDestination)", text: $password)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit { Task { await installKey() } }
                    Button("Instalar clave") { Task { await installKey() } }
                        .disabled(password.isEmpty)
                }
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Text(message).font(.system(size: 11)).foregroundStyle(JackPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reintentar") { Task { await check() } }.font(.system(size: 11))
            }
        }
    }

    private func choose(_ machine: SavedRemote) {
        destination = machine.destination
        if let path = machine.remotePath, remotePath.isEmpty { remotePath = path }
    }

    private func autoCheck() async {
        guard endpoint.isValid, cleanDestination.contains("@") || cleanDestination.contains(".") else {
            status = .idle
            return
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        await check()
    }

    private func check() async {
        let target = endpoint
        guard target.isValid else { return }
        status = .checking
        let result = await Task.detached(priority: .userInitiated) { SSHKeySetup.probe(endpoint: target) }.value
        guard !Task.isCancelled, target.destination == cleanDestination else { return }
        apply(result, for: target)
    }

    private func apply(_ result: SSHProbeResult, for target: ChatRemoteEndpoint) {
        switch result {
        case .ready(let claudePath):
            remember(target)
            status = .ready(claudePath.map { "SSH OK · claude en \($0)." } ?? "SSH OK, pero no hay `claude` en el PATH remoto.")
        case .needsKey:
            status = .needsKey
        case .failed(let message):
            status = .failed(message)
        }
    }

    private func installKey() async {
        let target = endpoint
        let secret = password
        guard target.isValid, !secret.isEmpty else { return }
        status = .installing
        do {
            try await Task.detached(priority: .userInitiated) {
                try SSHKeySetup.installKey(endpoint: target, password: secret)
            }.value
            password = ""
            await check()
        } catch {
            password = ""
            status = .failed(error.localizedDescription)
        }
    }

    /// A machine that answers with key login is kept for next time.
    private func remember(_ target: ChatRemoteEndpoint) {
        SavedRemotes.remember(SavedRemote(destination: target.destination, sshPort: target.sshPort,
                                          remotePath: target.remotePath))
        saved = SavedRemotes.load()
    }
}

/// Toolbar button (Normal mode, Claude Code only) that moves an existing agent to SSH.
/// There is intentionally no equivalent in Light.
struct RemoteAgentButton: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    @State private var showing = false

    var body: some View {
        let remote = conversation.remote
        Button { showing.toggle() } label: {
            Image(systemName: remote == nil ? "server.rack" : "server.rack.fill")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(remote == nil ? JackPalette.muted : JackPalette.accent)
        .help(remote == nil ? "Ejecutar en otra máquina por SSH" : "Remoto: \(remote!.displayName)")
        .accessibilityLabel("Agente remoto por SSH")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            RemoteAgentPanel(store: store, conversation: conversation)
        }
    }
}

private struct RemoteAgentPanel: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    @State private var enabled: Bool
    @State private var destination: String
    @State private var remotePath: String

    init(store: ChatStore, conversation: ChatConversation) {
        self.store = store
        self.conversation = conversation
        let remote = conversation.remote
        _enabled = State(initialValue: remote != nil)
        _destination = State(initialValue: remote?.destination ?? LastRemote.destination)
        _remotePath = State(initialValue: remote?.remotePath ?? LastRemote.path)
    }

    private var busy: Bool {
        guard let status = store.statuses[conversation.id] else { return false }
        return status == .running || status == .queued || status == .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agente remoto (SSH)").font(.headline)
            Toggle("Ejecutar en otra máquina", isOn: $enabled)
                .font(.system(size: 12))
            if enabled {
                RemoteEndpointForm(destination: $destination, remotePath: $remotePath)
            }
            Text("A partir del próximo mensaje. Indica la carpeta remota exacta: la detección automática solo ocurre al crear el agente. Necesita acceso por clave SSH (sin contraseña) y `claude` instalado en la otra máquina. Las herramientas de delegación de Jack llegan por un túnel automático.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if conversation.remote != nil {
                    Button("Volver a local") {
                        store.updateRemote(id: conversation.id, remote: nil)
                    }
                    .disabled(busy)
                }
                Button("Guardar") {
                    if let endpoint = remoteEndpoint(enabled: enabled, destination: destination, remotePath: remotePath) {
                        LastRemote.destination = endpoint.destination
                        LastRemote.path = endpoint.remotePath ?? ""
                    }
                    store.updateRemote(id: conversation.id, remote: remoteEndpoint(enabled: enabled, destination: destination, remotePath: remotePath))
                }
                .disabled(busy || (enabled && remoteEndpoint(enabled: enabled, destination: destination, remotePath: remotePath)?.isResolved != true))
                .help(busy ? "Espera a que el agente termine" : "Guardar configuración remota")
            }
            if busy {
                Text("El agente está trabajando: cambia cuando termine.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.amber)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
