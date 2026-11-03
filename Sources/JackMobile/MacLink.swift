import Foundation
import Network
import Security

/// La conexión con la Mac por Jack Remote: lo único que hace la Mac por el iPhone es ejecutar los agentes (Claude Code, Codex,
/// OpenCode…) y las peticiones a sus modelos (Ollama y los CLI con que piensan los personajes). Aquí se encuentran las Macs de
/// la red local, se empareja con el código que enseña Jack en la Mac, se recibe la lista de agentes y se les escribe. La oficina
/// (qué hace cada personaje) la decide el iPhone: `MacLink` es su `OfficeHost`, como `ChatStore` en la Mac.
@MainActor final class MacLink: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    struct Found: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
    }

    @Published private(set) var state = State.idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var agents: [JackRemote.AgentSummary] = [] { didSet { rebuild() } }
    @Published private(set) var projects: [String] = []
    @Published private(set) var providers: [JackRemote.ProviderOptions] = []
    /// Mensajes de los agentes abiertos (los que se están mirando).
    @Published private(set) var transcripts: [String: [JackRemote.Message]] = [:] { didSet { rebuild() } }
    @Published private(set) var approvals: [String: [JackRemote.Approval]] = [:]
    /// El agente que se mira («Ver pantalla»), los leídos aquí y el último error.
    @Published private(set) var selectedID: UUID?
    /// Cuándo se leyó cada agente aquí (su `updatedAt` de entonces): si después contesta otra vez, vuelve a estar sin leer.
    @Published private(set) var read: [String: Double] = [:] { didSet { rebuild() } }
    /// Los agentes como chats de Jack, para la oficina (se rehacen solo cuando cambia algo: la oficina los lee en cada fotograma).
    private(set) var conversations: [ChatConversation] = []
    private(set) var statuses: [UUID: ChatStatus] = [:]
    @Published private(set) var errorMessage: String?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var replies: [String: CheckedContinuation<JackRemote.Event, Never>] = [:]
    private var opened: Set<String> = []
    /// Los agentes que se siguen sin mirarlos: los más recientes, para que cada personaje cuente lo que hace el suyo.
    private var followed: Set<String> = []
    private var relays: [String: OllamaRelay] = [:]
    private static let followedCount = 10
    /// La última Mac con la que se emparejó, para volver sola al abrir la app.
    private static let lastMacKey = "macLinkLastMac"

    init() {
        // Gemma (Ollama) y los modelos con que piensan los personajes los pone la Mac.
        StellarTransport.remote = { [weak self] path, body, timeout in
            guard let self else { throw MacLinkError(message: "No hay conexión con la Mac.") }
            return try await self.ollama(path: path, body: body, timeout: timeout)
        }
        OfficeBrain.askCLI = { [weak self] provider, model, system, prompt in
            guard let self else { throw MacLinkError(message: "No hay conexión con la Mac.") }
            return try await self.think(provider: provider, model: model, system: system, prompt: prompt)
        }
    }

    var isConnected: Bool { if case .connected = state { true } else { false } }
    var lastMac: String? { UserDefaults.standard.string(forKey: Self.lastMacKey) }

    // MARK: - Buscar y conectar

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: JackRemote.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Found(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.found = found
                // La Mac de la última vez aparece: se conecta sola con su código guardado.
                if case .idle = self.state, let last = self.lastMac, let mac = found.first(where: { $0.name == last }),
                   let code = MacLinkKeychain.code(for: last) {
                    self.connect(to: mac, code: code)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func connect(to mac: Found, code: String) {
        connection?.cancel()
        buffer = Data()
        state = .connecting(mac.name)
        let connection = NWConnection(to: mac.endpoint, using: JackRemote.parameters(pairingCode: code))
        connection.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in self?.connectionChanged(update, mac: mac, code: code) }
        }
        self.connection = connection
        connection.start(queue: .main)
        receive(on: connection)
        // Con un código equivocado el TLS no termina nunca de abrir.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, case .connecting(let name) = self.state, name == mac.name else { return }
            self.connection?.cancel()
            self.state = .failed("No se pudo conectar con \(mac.name). Revisa el código en Jack (Ajustes › Jack Remote).")
        }
    }

    func disconnect(forget: Bool) {
        connection?.cancel()
        connection = nil
        if forget, let last = lastMac {
            MacLinkKeychain.remove(for: last)
            UserDefaults.standard.removeObject(forKey: Self.lastMacKey)
        }
        agents = []
        state = .idle
        failRelays("Se cerró la conexión con la Mac.")
    }

    private func connectionChanged(_ update: NWConnection.State, mac: Found, code: String) {
        switch update {
        case .ready:
            MacLinkKeychain.set(code, for: mac.name)
            UserDefaults.standard.set(mac.name, forKey: Self.lastMacKey)
            state = .connected(mac.name)
            send(.init(type: .hello))
            send(.init(type: .list))
            for agent in opened.union(followed) { send(.init(type: .open, agent: agent)) }
        case .failed(let error):
            state = .failed("Se perdió la conexión con \(mac.name): \(error.localizedDescription)")
            failRelays("Se perdió la conexión con la Mac.")
            scheduleReconnect(mac: mac, code: code)
        case .cancelled:
            if case .connected = state { state = .idle }
        default:
            break
        }
    }

    private func scheduleReconnect(mac: Found, code: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .failed = self.state else { return }
            if let again = self.found.first(where: { $0.name == mac.name }) { self.connect(to: again, code: code) }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data {
                    self.buffer.append(data)
                    for line in JackRemote.takeLines(from: &self.buffer) {
                        if let event = try? JSONDecoder().decode(JackRemote.Event.self, from: line) { self.handle(event) }
                    }
                }
                if !isComplete, error == nil { self.receive(on: connection) }
            }
        }
    }

    // MARK: - Mensajes

    private func send(_ request: JackRemote.Request) {
        connection?.send(content: JackRemote.encodeLine(request), completion: .idempotent)
    }

    /// Manda una petición y espera su respuesta (`ok` o `error`).
    private func request(_ request: JackRemote.Request, timeout: Duration = .seconds(20)) async -> JackRemote.Event {
        guard isConnected else { return .init(type: .error, text: "No hay conexión con la Mac.") }
        return await withCheckedContinuation { continuation in
            replies[request.id] = continuation
            send(request)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.replies.removeValue(forKey: request.id)?.resume(returning: .init(type: .error, text: "La Mac no contestó."))
            }
        }
    }

    private func handle(_ event: JackRemote.Event) {
        if let id = event.id, relays[id] != nil { return relay(event, id: id) }
        if let id = event.id, event.type == .ok || event.type == .error, let reply = replies.removeValue(forKey: id) {
            reply.resume(returning: event)
        }
        switch event.type {
        case .agents:
            agents = event.agents ?? agents
            projects = event.projects ?? projects
            providers = event.providers ?? providers
            follow()
        case .transcript:
            if let agent = event.agent { transcripts[agent] = event.messages ?? [] }
        case .messages:
            guard let agent = event.agent else { break }
            var list = transcripts[agent] ?? []
            for message in event.messages ?? [] {
                if let index = list.firstIndex(where: { $0.id == message.id }) { list[index] = message } else { list.append(message) }
            }
            transcripts[agent] = list
        case .state:
            if let agent = event.agent {
                approvals[agent] = event.approvals ?? []
                if let summary = event.summary, let index = agents.firstIndex(where: { $0.id == agent }) { agents[index] = summary }
            }
        case .hello, .ok, .error, .ollama:
            break
        }
    }

    /// Sigue los agentes más recientes (y deja los que ya no lo son), para tener lo que dicen sin abrir su chat.
    private func follow() {
        let recent = Set(agents.filter { $0.parent == nil }.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.followedCount).map(\.id))
        for agent in recent.subtracting(followed) where !opened.contains(agent) { send(.init(type: .open, agent: agent)) }
        for agent in followed.subtracting(recent) where !opened.contains(agent) { send(.init(type: .close, agent: agent)) }
        followed = recent
    }

    // MARK: - Lo que se le pide a la Mac

    /// Empieza a recibir los mensajes de un agente (mientras se mira su chat).
    func open(_ agent: String) {
        opened.insert(agent)
        send(.init(type: .open, agent: agent))
    }

    func close(_ agent: String) {
        opened.remove(agent)
        if !followed.contains(agent) { send(.init(type: .close, agent: agent)) }
    }

    /// Un agente nuevo en una carpeta que Jack ya conoce (vacía: la elige Jack según el encargo); devuelve su id o el error.
    func create(task: String, project: String, provider: String, model: String?) async -> Result<String, MacLinkError> {
        let reply = await request(.init(type: .create, text: task, project: project, provider: provider, model: model))
        if reply.type == .ok, let agent = reply.agent { return .success(agent) }
        return .failure(MacLinkError(message: reply.text ?? "No se pudo crear el agente."))
    }

    func write(_ text: String, to agent: String) async -> String? {
        let reply = await request(.init(type: .send, agent: agent, text: text))
        return reply.type == .error ? (reply.text ?? "No se pudo enviar.") : nil
    }

    func stop(_ agent: String) async {
        _ = await request(.init(type: .stop, agent: agent))
    }

    func respond(_ agent: String, approval: String, choice: String) async {
        _ = await request(.init(type: .respond, agent: agent, approval: approval, choice: choice))
    }

    private func rebuild() {
        conversations = agents.compactMap { agent in
            guard let id = UUID(uuidString: agent.id) else { return nil }
            var conversation = ChatConversation(
                id: id, title: agent.title, projectPath: agent.project,
                provider: ChatProvider(rawValue: agent.provider) ?? .codex, model: agent.model,
                messages: (transcripts[agent.id] ?? []).map { ChatMessage(id: $0.id, role: $0.role, text: $0.text, detail: $0.detail, status: $0.status) },
                updatedAt: Date(timeIntervalSince1970: agent.updatedAt))
            conversation.preview = agent.preview
            conversation.hasUnread = agent.unread && read[agent.id] != agent.updatedAt
            conversation.parentID = agent.parent.flatMap(UUID.init(uuidString:))
            return conversation
        }
        statuses = Dictionary(agents.compactMap { agent in UUID(uuidString: agent.id).map { ($0, ChatStatus(rawValue: agent.status) ?? .idle) } },
                              uniquingKeysWith: { first, _ in first })
    }

    /// El agente que se mira: se siguen sus mensajes.
    func select(_ id: UUID) {
        selectedID = id
        open(id.uuidString)
    }

    func markRead(_ agent: String, _ isRead: Bool) {
        read[agent] = isRead ? agents.first { $0.id == agent }?.updatedAt : nil
    }

    func fail(_ message: String) {
        errorMessage = message
    }

    func configure(_ agent: String, model: String, effort: String) async -> String? {
        let reply = await request(.init(type: .configure, agent: agent, model: model, effort: effort))
        return reply.type == .error ? (reply.text ?? "No se pudo cambiar el modelo.") : nil
    }

    // MARK: - Modelos de la Mac

    /// Una petición a Ollama hecha por la Mac: llega primero el estado HTTP y luego la respuesta línea a línea.
    private func ollama(path: String, body: Data?, timeout: TimeInterval) async throws -> StellarTransport.Response {
        guard isConnected else { throw MacLinkError(message: "Conecta el iPhone con Jack en la Mac para que piensen los personajes.") }
        let request = JackRemote.Request(type: .ollama, path: path, body: body.flatMap { String(data: $0, encoding: .utf8) }, timeout: timeout)
        let (lines, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let id = request.id
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.relays.removeValue(forKey: id) } }
        let status = try await withCheckedThrowingContinuation { status in
            relays[id] = OllamaRelay(status: status, lines: continuation)
            send(request)
        }
        return StellarTransport.Response(status: status, lines: lines)
    }

    private func relay(_ event: JackRemote.Event, id: String) {
        guard let relay = relays[id] else { return }
        switch event.type {
        case .ollama:
            if let status = event.status { relay.status?.resume(returning: status); relay.status = nil }
            if let text = event.text { relay.lines.yield(text) }
        case .ok:
            relays[id] = nil
            relay.status?.resume(returning: 0)
            relay.lines.finish()
        case .error:
            relays[id] = nil
            let error = MacLinkError(message: event.text ?? "Ollama no respondió en la Mac.")
            if let status = relay.status { status.resume(throwing: error) } else { relay.lines.finish(throwing: error) }
        default:
            break
        }
    }

    private func failRelays(_ message: String) {
        let pending = relays
        relays = [:]
        for relay in pending.values {
            let error = MacLinkError(message: message)
            if let status = relay.status { status.resume(throwing: error) } else { relay.lines.finish(throwing: error) }
        }
    }

    /// Lo que piensa un personaje con Claude Code, Codex u OpenCode: una consulta suelta que hace el CLI de la Mac.
    private func think(provider: ChatProvider, model: String, system: String, prompt: String) async throws -> String {
        guard isConnected else { throw MacLinkError(message: "Conecta el iPhone con Jack en la Mac para que piensen los personajes.") }
        let reply = await request(.init(type: .think, text: prompt, provider: provider.rawValue, model: model, body: system), timeout: .seconds(200))
        guard reply.type == .ok, let text = reply.text else { throw MacLinkError(message: reply.text ?? "La Mac no contestó.") }
        return text
    }
}

/// Una petición a Ollama en marcha: el estado HTTP (hasta que llega) y las líneas de la respuesta.
private final class OllamaRelay {
    var status: CheckedContinuation<Int, Error>?
    let lines: AsyncThrowingStream<String, Error>.Continuation

    init(status: CheckedContinuation<Int, Error>, lines: AsyncThrowingStream<String, Error>.Continuation) {
        self.status = status
        self.lines = lines
    }
}

struct MacLinkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// El código de emparejamiento de cada Mac, en el llavero del iPhone.
enum MacLinkKeychain {
    private static func query(_ mac: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.jack.mobile.mac", kSecAttrAccount as String: mac]
    }

    static func code(for mac: String) -> String? {
        var request = query(mac)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ code: String, for mac: String) {
        SecItemDelete(query(mac) as CFDictionary)
        var item = query(mac)
        item[kSecValueData as String] = Data(code.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove(for mac: String) {
        SecItemDelete(query(mac) as CFDictionary)
    }
}
