import Combine
import Foundation
import Network
import Security

/// The pairing code of Jack Remote, kept in this Mac's own keychain (never in preferences).
public enum JackRemoteKeychain {
    static let service = "dev.jack.remote-code"
    static let account = "pairing"

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func code() -> String? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setCode(_ code: String) {
        SecItemDelete(query() as CFDictionary)
        var item = query()
        item[kSecValueData as String] = Data(code.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Lets Pixel on the iPhone drive Jack's agents: see them, read what they do, write to them and answer their
/// permission requests. Off by default and only ever started in Normal mode. While nobody is connected it costs
/// a listening socket: Jack does not even watch its chats for changes.
@MainActor public final class JackRemoteServer: ObservableObject {
    public enum Status: Equatable { case off, starting, ready, failed(String) }
    public static let maxClients = 4

    @Published public private(set) var status: Status = .off
    @Published public private(set) var pairingCode = ""
    @Published public private(set) var clientCount = 0
    /// The port the listener got; differs from the requested one only when that was 0.
    public private(set) var listeningPort: UInt16?

    fileprivate weak var store: ChatStore?
    private let requestedPort: UInt16
    private let advertises: Bool
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: JackRemoteSession] = [:]
    private var storeObserver: AnyCancellable?
    private var refreshScheduled = false
    /// Tests run without the keychain and without Bonjour.
    private let usesKeychain: Bool

    /// `port` 0 lets the system choose one. A given `pairingCode` replaces the keychain's.
    public init(store: ChatStore, port: UInt16 = JackRemote.port, advertises: Bool = true, pairingCode: String? = nil) {
        self.store = store
        self.requestedPort = port
        self.advertises = advertises
        self.usesKeychain = pairingCode == nil
        if let pairingCode { self.pairingCode = pairingCode }
    }

    /// Reads the code from the keychain, or makes the first one.
    public func loadCode() {
        guard pairingCode.isEmpty else { return }
        if let saved = JackRemoteKeychain.code(), JackRemote.isValid(saved) {
            pairingCode = saved
        } else {
            pairingCode = JackRemote.newPairingCode()
            JackRemoteKeychain.setCode(pairingCode)
        }
    }

    public func apply(enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    public func start() {
        // Jack Remote is a Normal mode feature: Light never listens.
        guard listener == nil, let store, !store.lightModeEnabled else { return }
        if usesKeychain { loadCode() }
        status = .starting
        do {
            let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
            let listener = try NWListener(using: JackRemote.parameters(pairingCode: pairingCode), on: port)
            if advertises {
                listener.service = NWListener.Service(name: Host.current().localizedName, type: JackRemote.serviceType)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener else { return }
                    self.listenerChanged(state, of: listener)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        for session in sessions.values { session.close() }
        sessions = [:]
        updateClients()
        status = .off
    }

    /// A new code unpairs every device that used the old one.
    public func regenerateCode() {
        let wasRunning = listener != nil
        if wasRunning { stop() }
        pairingCode = JackRemote.newPairingCode()
        if usesKeychain { JackRemoteKeychain.setCode(pairingCode) }
        if wasRunning { start() }
    }

    private func listenerChanged(_ state: NWListener.State, of changed: NWListener) {
        guard changed === listener else { return }
        switch state {
        case .ready:
            listeningPort = changed.port?.rawValue
            status = .ready
        case .failed(let error):
            changed.cancel()
            listener = nil
            listeningPort = nil
            status = .failed(error.localizedDescription)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, sessions.count < Self.maxClients else { connection.cancel(); return }
        let session = JackRemoteSession(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    fileprivate func sessionChanged(_ session: JackRemoteSession) {
        if session.isClosed { sessions.removeValue(forKey: ObjectIdentifier(session)) }
        updateClients()
    }

    private func updateClients() {
        let ready = sessions.values.filter(\.isReady).count
        if clientCount != ready { clientCount = ready }
        // Nobody connected: don't watch the chats at all.
        if ready > 0, storeObserver == nil {
            storeObserver = store?.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        } else if ready == 0 {
            storeObserver = nil
        }
    }

    /// Streaming text changes the chats many times a second: pushes go out at most every 250 ms.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.refreshScheduled = false
            for session in self.sessions.values { session.refresh() }
        }
    }

    // MARK: Data for the clients

    fileprivate func summary(of conversation: ChatConversation) -> JackRemote.AgentSummary {
        JackRemote.AgentSummary(
            id: conversation.id.uuidString, title: conversation.title, project: conversation.projectPath,
            provider: conversation.provider.rawValue, model: conversation.model,
            status: (store?.statuses[conversation.id] ?? .idle).rawValue,
            preview: conversation.preview ?? "", updatedAt: conversation.updatedAt.timeIntervalSince1970,
            unread: conversation.hasUnread == true, pending: store?.approvals[conversation.id]?.count ?? 0,
            parent: conversation.parentID?.uuidString)
    }

    /// Model, effort and mode of an agent with the options each offers. Bypass is never offered:
    /// a remote device must not be able to turn every permission request off.
    fileprivate func config(of conversation: ChatConversation) -> JackRemote.Config {
        guard let store else {
            return JackRemote.Config(model: conversation.model, effort: conversation.effort, mode: conversation.mode ?? "",
                                     models: [], efforts: [], modes: [], canChangeModel: false, canChangeMode: false)
        }
        let provider = conversation.provider
        return JackRemote.Config(
            model: conversation.model, effort: conversation.effort, mode: conversation.mode ?? "",
            models: store.modelChoices(for: provider).map { JackRemote.Choice(id: $0.id, title: $0.title) },
            efforts: provider == .opencode ? [] : store.supportedEfforts(provider: provider, model: conversation.model),
            modes: ChatRunMode.choices(for: provider).map { JackRemote.Choice(id: $0.id, title: $0.title) },
            canChangeModel: provider != .opencode && !store.isBusy(conversation.id),
            canChangeMode: store.changesModeLive(conversation.id))
    }

    /// What each provider offers for a new agent.
    fileprivate func providerOptions() -> [JackRemote.ProviderOptions] {
        guard let store else { return [] }
        return ChatProvider.allCases.filter { $0 != .opencode }.map { provider in
            JackRemote.ProviderOptions(
                id: provider.rawValue, title: provider.title, defaultModel: provider.defaultModel,
                models: store.modelChoices(for: provider).map { JackRemote.Choice(id: $0.id, title: $0.title) },
                modes: ChatRunMode.choices(for: provider).map { JackRemote.Choice(id: $0.id, title: $0.title) })
        } + [JackRemote.ProviderOptions(id: ChatProvider.opencode.rawValue, title: ChatProvider.opencode.title,
                                         defaultModel: "", models: [], modes: [])]
    }

    /// Folders of the agents Jack already has: the only ones a remote device may start a new agent in.
    fileprivate func knownProjects() -> [String] {
        var seen = Set<String>()
        return (store?.conversations ?? []).map(\.projectPath).filter {
            $0.hasPrefix("/") && $0 != ProjectLocator.unplacedFolder && seen.insert($0).inserted
        }
    }

    fileprivate static func wire(_ message: ChatMessage) -> JackRemote.Message {
        JackRemote.Message(id: message.id, role: message.role, text: clip(message.text, JackRemote.maxTextLength),
                           detail: clip(message.detail, JackRemote.maxDetailLength), status: message.status)
    }

    fileprivate static func wire(_ approval: ChatApproval) -> JackRemote.Approval {
        JackRemote.Approval(
            id: approval.id, title: approval.title, detail: clip(approval.detail, JackRemote.maxTextLength),
            tool: approval.tool, isPlan: approval.isPlan,
            choices: approval.choices.map { JackRemote.Choice(id: $0.id, title: $0.title) },
            questions: approval.questions.map { question in
                JackRemote.Question(
                    id: question.id, header: question.header, question: question.question,
                    options: (question.options ?? []).map { JackRemote.QuestionOption(label: $0.label, description: $0.description) },
                    isSecret: question.isSecret == true, multiSelect: question.multiSelect == true)
            })
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let head = text.prefix(limit)
        return head.endIndex == text.endIndex ? text : String(head) + "…"
    }
}

public extension ChatStore {
    /// The remote server, created the first time something asks for it.
    var remote: JackRemoteServer {
        if let remoteServer { return remoteServer }
        let server = JackRemoteServer(store: self)
        remoteServer = server
        return server
    }

    /// Starts or stops Jack Remote. Light never starts it, and turning it off doesn't create it.
    func applyRemote(enabled: Bool) {
        guard enabled, !lightModeEnabled else { remoteServer?.stop(); return }
        remote.apply(enabled: true)
    }
}

/// One connected device.
@MainActor private final class JackRemoteSession {
    private struct Sent {
        var ids: [String] = []
        var hashes: [String: Int] = [:]
        var summary: JackRemote.AgentSummary?
        var approvals: [JackRemote.Approval] = []
        var waiting: [String] = []
        var config: JackRemote.Config?
    }

    private let connection: NWConnection
    private unowned let server: JackRemoteServer
    private let queue = DispatchQueue(label: "dev.jack.remote.connection")
    private let outstanding = ByteCounter()
    private var lines: AsyncStream<Data>.Continuation?
    private(set) var isReady = false
    private(set) var isClosed = false
    private var watchingList = false
    private var lastAgents: [JackRemote.AgentSummary]?
    private var lastProjects: [String] = []
    private var lastProviders: [JackRemote.ProviderOptions] = []
    private var opened: [UUID: Sent] = [:]

    init(connection: NWConnection, server: JackRemoteServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        lines = continuation
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        connection.start(queue: queue)
        Self.receive(connection, LineBuffer(), continuation) { [weak self] in
            Task { @MainActor in self?.close() }
        }
        Task { [weak self] in
            for await line in stream { self?.handle(line) }
        }
        // A device that never finishes the handshake must not hold one of the few slots.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.isReady == false { self?.close() }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        lines?.finish()
        connection.cancel()
        server.sessionChanged(self)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            server.sessionChanged(self)
        case .failed, .cancelled:
            close()
        default:
            break
        }
    }

    private nonisolated static func receive(_ connection: NWConnection, _ buffer: LineBuffer,
                                            _ continuation: AsyncStream<Data>.Continuation,
                                            onClose: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data {
                buffer.data.append(data)
                for line in JackRemote.takeLines(from: &buffer.data) { continuation.yield(line) }
            }
            if isComplete || error != nil || buffer.data.count > JackRemote.maxLine {
                continuation.finish()
                onClose()
            } else {
                receive(connection, buffer, continuation, onClose: onClose)
            }
        }
    }

    func send(_ event: JackRemote.Event) {
        guard !isClosed else { return }
        let data = JackRemote.encodeLine(event)
        // A device that stops reading would make Jack hold its pushes forever.
        guard outstanding.add(data.count) < 8_000_000 else { close(); return }
        connection.send(content: data, completion: .contentProcessed { [outstanding] _ in outstanding.add(-data.count) })
    }

    // MARK: Requests

    private func handle(_ line: Data) {
        guard let request = try? JSONDecoder().decode(JackRemote.Request.self, from: line) else {
            send(.init(type: .error, text: "Petición no válida."))
            return
        }
        guard let store = server.store else { return }
        switch request.type {
        case .hello:
            send(.init(type: .hello, id: request.id, name: Host.current().localizedName ?? "Mac",
                       host: ProcessInfo.processInfo.hostName, version: JackRemote.version))
        case .list:
            watchingList = true
            lastAgents = nil
            pushList(store)
            send(.init(type: .ok, id: request.id))
        case .open:
            guard let id = agentID(request, store, reply: true) else { return }
            opened[id] = Sent()
            pushAgent(id, store)
            send(.init(type: .ok, id: request.id, agent: id.uuidString))
        case .close:
            if let id = request.agent.flatMap(UUID.init(uuidString:)) { opened.removeValue(forKey: id) }
            send(.init(type: .ok, id: request.id))
        case .send:
            guard let id = agentID(request, store, reply: true) else { return }
            let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 20_000 else { return fail(request, "Mensaje vacío o demasiado largo.") }
            guard store.canSend(to: id) else { return fail(request, "Jack no admite mensajes ahora.") }
            store.send(text, to: id, interrupting: request.interrupting == true)
            send(.init(type: .ok, id: request.id))
        case .stop:
            guard let id = agentID(request, store, reply: true) else { return }
            store.stop(id)
            send(.init(type: .ok, id: request.id))
        case .respond:
            guard let id = agentID(request, store, reply: true) else { return }
            guard let approval = request.approval, let choice = request.choice,
                  store.approvals[id]?.contains(where: { $0.id == approval }) == true else {
                return fail(request, "Esa petición ya no está abierta.")
            }
            store.respond(conversationID: id, approvalID: approval, choice: choice, message: request.reason)
            send(.init(type: .ok, id: request.id))
        case .answer:
            guard let id = agentID(request, store, reply: true) else { return }
            guard let approval = request.approval, let answers = request.answers,
                  store.approvals[id]?.contains(where: { $0.id == approval }) == true else {
                return fail(request, "Esa pregunta ya no está abierta.")
            }
            store.answer(conversationID: id, approvalID: approval, answers: answers)
            send(.init(type: .ok, id: request.id))
        case .create:
            create(request, store)
        case .configure:
            configure(request, store)
        case .rename:
            guard let id = agentID(request, store, reply: true) else { return }
            let title = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return fail(request, "Escribe un nombre.") }
            store.rename(id, title: title)
            send(.init(type: .ok, id: request.id))
        }
    }

    private func configure(_ request: JackRemote.Request, _ store: ChatStore) {
        guard let id = agentID(request, store, reply: true),
              let conversation = store.conversations.first(where: { $0.id == id }) else { return }
        if request.model != nil || request.effort != nil {
            guard conversation.provider != .opencode else { return fail(request, "El modelo de OpenCode se cambia en Jack.") }
            guard !store.isBusy(id) else { return fail(request, "Cambia el modelo cuando el agente termine.") }
            let model = request.model ?? conversation.model
            guard store.modelChoices(for: conversation.provider).contains(where: { $0.id == model }) else { return fail(request, "Modelo desconocido.") }
            let efforts = store.supportedEfforts(provider: conversation.provider, model: model)
            if let effort = request.effort, !efforts.contains(effort) { return fail(request, "Ese esfuerzo no existe en este modelo.") }
            store.updateSettings(id: id, model: model, effort: request.effort ?? conversation.effort)
        }
        if let mode = request.mode {
            let supported = ChatRunMode.choices(for: conversation.provider)
            guard supported.contains(where: { $0.id == mode }) else { return fail(request, "Ese modo no existe en este agente.") }
            store.updateMode(id: id, mode: mode, supported: supported)
            guard store.conversations.first(where: { $0.id == id })?.mode == mode else {
                return fail(request, "El agente no admite cambiar de modo ahora.")
            }
        }
        send(.init(type: .ok, id: request.id))
    }

    private func create(_ request: JackRemote.Request, _ store: ChatStore) {
        let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return fail(request, "Escribe la tarea del agente.") }
        guard let provider = request.provider.flatMap(ChatProvider.init(rawValue:)) else { return fail(request, "Proveedor desconocido.") }
        // Only folders Jack already works in: a remote device never reaches the rest of the disk.
        guard let project = request.project, server.knownProjects().contains(project) else { return fail(request, "Esa carpeta no es de ningún agente de Jack.") }
        if let model = request.model, !store.modelChoices(for: provider).contains(where: { $0.id == model }) {
            return fail(request, "Modelo desconocido.")
        }
        if let mode = request.mode, !ChatRunMode.choices(for: provider).contains(where: { $0.id == mode }) {
            return fail(request, "Ese modo no existe en este proveedor.")
        }
        guard let id = store.create(projectPath: project, provider: provider, model: request.model,
                                    effort: request.effort ?? "high", select: false) else { return fail(request, "No se pudo crear el agente.") }
        if let mode = request.mode { store.updateMode(id: id, mode: mode, supported: ChatRunMode.choices(for: provider)) }
        store.send(text, to: id)
        send(.init(type: .ok, id: request.id, agent: id.uuidString))
    }

    private func agentID(_ request: JackRemote.Request, _ store: ChatStore, reply: Bool) -> UUID? {
        guard let id = request.agent.flatMap(UUID.init(uuidString:)), store.conversations.contains(where: { $0.id == id }) else {
            if reply { fail(request, "El agente ya no existe.") }
            return nil
        }
        return id
    }

    private func fail(_ request: JackRemote.Request, _ message: String) {
        send(.init(type: .error, id: request.id, text: message))
    }

    // MARK: Pushes

    /// Sends what changed since the last push; called while the chats change.
    func refresh() {
        guard isReady, !isClosed, let store = server.store else { return }
        if watchingList { pushList(store) }
        for id in Array(opened.keys) { pushAgent(id, store) }
    }

    private func pushList(_ store: ChatStore) {
        let agents = store.conversations.map(server.summary(of:))
        let projects = server.knownProjects()
        let providers = server.providerOptions()
        guard agents != lastAgents || projects != lastProjects || providers != lastProviders else { return }
        lastAgents = agents
        lastProjects = projects
        lastProviders = providers
        send(.init(type: .agents, agents: agents, projects: projects, providers: providers))
    }

    private func pushAgent(_ id: UUID, _ store: ChatStore) {
        guard var sent = opened[id] else { return }
        guard let conversation = store.conversations.first(where: { $0.id == id }) else {
            opened.removeValue(forKey: id)
            send(.init(type: .error, agent: id.uuidString, text: "El agente ya no existe."))
            return
        }
        let summary = server.summary(of: conversation)
        // An idle agent that looks the same has nothing new; skipping avoids reading its transcript from disk.
        if sent.summary != nil, summary.status == "idle", summary == sent.summary { return }

        // Reasoning blocks stay on the Mac: they are noisy and often empty.
        let window = store.transcript(of: id).filter { $0.role != "reasoning" }
            .suffix(JackRemote.transcriptWindow).map(JackRemoteServer.wire)
        let hashes = Dictionary(window.map { ($0.id, Self.hash($0)) }, uniquingKeysWith: { _, last in last })
        if sent.ids.isEmpty || window.isEmpty || !window.contains(where: { $0.id == sent.ids.last }) {
            // First push, or the transcript was replaced (compaction, import): start over.
            if !sent.ids.isEmpty || !window.isEmpty || sent.summary == nil {
                send(.init(type: .transcript, agent: id.uuidString, messages: window))
            }
        } else {
            let changed = window.filter { sent.hashes[$0.id] != hashes[$0.id] }
            if !changed.isEmpty { send(.init(type: .messages, agent: id.uuidString, messages: changed)) }
        }
        sent.ids = window.map(\.id)
        sent.hashes = hashes

        let approvals = (store.approvals[id] ?? []).map(JackRemoteServer.wire)
        let waiting = (store.waiting[id] ?? []).map(\.text)
        let config = server.config(of: conversation)
        if summary != sent.summary || approvals != sent.approvals || waiting != sent.waiting || config != sent.config {
            send(.init(type: .state, agent: id.uuidString, summary: summary, approvals: approvals, waiting: waiting, config: config))
        }
        sent.config = config
        sent.summary = summary
        sent.approvals = approvals
        sent.waiting = waiting
        opened[id] = sent
    }

    private static func hash(_ message: JackRemote.Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.text)
        hasher.combine(message.detail)
        hasher.combine(message.status)
        return hasher.finalize()
    }
}

/// Bytes read from one connection, touched only by its receive callback.
private final class LineBuffer: @unchecked Sendable {
    var data = Data()
}

/// Bytes handed to the network and not yet sent.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func add(_ amount: Int) -> Int {
        lock.withLock { value += amount; return value }
    }
}
