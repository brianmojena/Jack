import Combine
import Foundation
import Network
import Security

/// Loopback HTTP API so a script can message a Jack Bot agent, run one of its routines and read the answer.
/// It listens only while some agent has "scripts" on, and its URL and token live in files only this user can read.
@MainActor public final class BotAPI {
    /// Messages and routine runs one agent accepts from scripts in an hour, so a looping script cannot spend the user's quota.
    public static let runsPerHour = 30
    private weak var store: ChatStore?
    private let directory: URL
    private var listener: NWListener?
    private var starting = false
    var port: UInt16?
    var token = ""
    private var sent: [UUID: [Date]] = [:]
    private var deliveries: [String: Delivery] = [:]
    private var retryKeys: [String: String] = [:]
    private var observer: AnyCancellable?

    private struct Delivery {
        var conversationID: UUID
        var finished: [String: Any]?
    }

    init(store: ChatStore, directory: URL) {
        self.store = store; self.directory = directory
    }

    /// Follows the agents: starts when one allows scripts, stops when none does.
    func observe(_ bots: BotStore) {
        observer = bots.$agents.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
    }

    public func refresh() {
        guard let store, !store.lightModeEnabled, store.bots.agents.contains(where: \.allowScripts) else { stop(); return }
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            parameters.acceptLocalOnly = true
            let listener = try NWListener(using: parameters)
            self.listener = listener
            token = Self.newToken()
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                HTTPConnection(connection) { request in
                    guard let self else { return .status(503) }
                    return await self.handle(request)
                }.start()
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            store.errorMessage = "No se pudo abrir la API local de Jack Bot: \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil; port = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("url"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("token"))
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            self.port = port
            do {
                try writePrivate("url", "http://127.0.0.1:\(port)")
                try writePrivate("token", token)
            } catch { store?.errorMessage = "No se pudieron escribir los datos de la API local: \(error.localizedDescription)" }
        case .failed, .cancelled:
            listener?.cancel(); listener = nil; port = nil
        default: break
        }
    }

    /// Owner-only: the folder is 0700 and each file 0600.
    private func writePrivate(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(name).path
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString + UUID().uuidString }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Requests

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        func fail(_ status: Int, _ message: String) -> HTTPResponse { .json(["ok": false, "error": message], status: status) }
        // A web page can reach loopback, so these two checks come before the token is even read.
        guard request.headers["origin"] == nil else { return fail(403, "Requests from a browser page are refused.") }
        guard let port, let host = request.headers["host"], host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return fail(403, "Unexpected Host header.")
        }
        let authorization = request.headers["authorization"] ?? ""
        guard authorization.hasPrefix("Bearer "), Self.sameText(String(authorization.dropFirst(7)), token) else { return fail(401, "Invalid token.") }
        guard let store, !store.lightModeEnabled else { return fail(503, "Jack Bot is not available.") }

        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let parts = path.split(separator: "/").map(String.init)
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, parts.count, parts.first, parts.count > 1 ? parts[1] : "") {
        case ("GET", 2, "v1", "agents"):
            return .json(["ok": true, "agents": store.bots.agents.filter(\.allowScripts).map { agent in
                ["id": agent.id.uuidString.lowercased(), "name": agent.name, "provider": agent.provider.rawValue,
                 "busy": agent.conversationID.map(store.isBusy) ?? false] as [String: Any]
            }])
        case ("POST", 4, "v1", "agents") where parts[3] == "messages":
            return send(body["message"] as? String ?? "", key: body["id"] as? String, to: parts[2], routine: nil, store: store)
        case ("POST", 6, "v1", "agents") where parts[3] == "routines" && parts[5] == "run":
            return send(body["payload"] as? String ?? "", key: body["id"] as? String, to: parts[2], routine: parts[4], store: store)
        case ("GET", 3, "v1", "deliveries"):
            guard let delivery = deliveries[parts[2]] else { return fail(404, "Unknown delivery.") }
            return .json(["ok": true, "delivery_id": parts[2]].merging(status(of: parts[2], delivery, store: store)) { $1 })
        default:
            return fail(404, "Unknown route.")
        }
    }

    private func send(_ text: String, key: String?, to reference: String, routine: String?, store: ChatStore) -> HTTPResponse {
        func fail(_ status: Int, _ message: String) -> HTTPResponse { .json(["ok": false, "error": message], status: status) }
        let found = store.bots.agents(matching: reference)
        guard found.count == 1, let agent = found.first else { return fail(404, found.isEmpty ? "No agent matches “\(reference)”." : "“\(reference)” matches several agents; use the id.") }
        guard agent.allowScripts else { return fail(403, "Local scripts is off for \(agent.name).") }
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let routine {
            let routines = store.bots.routines(of: agent.id).filter { $0.id.uuidString.lowercased().hasPrefix(routine.lowercased()) || $0.name.lowercased() == routine.lowercased() }
            guard routines.count == 1, let found = routines.first else { return fail(404, "No unique routine matches “\(routine)”.") }
            message = message.isEmpty ? found.instruction : found.instruction + "\n\n" + message
        }
        guard !message.isEmpty else { return fail(400, "The message is empty.") }
        // The same retry key returns the earlier delivery instead of sending twice.
        if let key, let earlier = retryKeys["\(agent.id)|\(key)"], deliveries[earlier] != nil {
            return .json(["ok": true, "delivery_id": earlier, "status": "duplicate"], status: 202)
        }
        let now = Date()
        let recent = (sent[agent.id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < Self.runsPerHour else { return fail(429, "\(agent.name) already received \(Self.runsPerHour) messages from scripts this hour.") }
        let wasBusy = agent.conversationID.map(store.isBusy) ?? false
        switch store.sendToBotAgent(message, agent: agent) {
        case .failure(let error): return fail(409, error.message)
        case .success(let conversation):
            sent[agent.id] = recent + [now]
            let id = UUID().uuidString.lowercased()
            deliveries[id] = Delivery(conversationID: conversation)
            if let key { retryKeys["\(agent.id)|\(key)"] = id }
            return .json(["ok": true, "delivery_id": id, "status": wasBusy ? "queued" : "started"], status: 202)
        }
    }

    /// running, waiting (a person must answer), done (with the answer) or failed. Once finished it stays so.
    private func status(of id: String, _ delivery: Delivery, store: ChatStore) -> [String: Any] {
        if let finished = delivery.finished { return finished }
        let conversation = delivery.conversationID
        var result: [String: Any]
        if store.statuses[conversation] == .failed {
            result = ["status": "failed", "error": store.lastError(of: conversation) ?? "The turn failed."]
        } else if store.approvals[conversation]?.isEmpty == false {
            return ["status": "waiting"]
        } else if store.isBusy(conversation) || store.waiting[conversation]?.isEmpty == false {
            return ["status": "running"]
        } else {
            result = ["status": "done", "answer": store.lastReply(of: conversation) ?? ""]
        }
        deliveries[id]?.finished = result
        return result
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
