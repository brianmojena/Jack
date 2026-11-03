import CryptoKit
import Foundation
import Network

/// CodeOS (modo Normal): las Macs de un mismo grupo se encuentran por Bonjour (`_jackquota._tcp`) y se cuentan el estado de sus perfiles.
/// Las conexiones van cifradas con una clave compartida derivada del código del grupo (TLS-PSK): sin el código no se entra. Cada Mac
/// escucha y, además, se conecta a cada una de las otras para enviarles sus mensajes, una línea de JSON cada uno.
@MainActor public final class QuotaNetwork {
    public static let serviceType = "_jackquota._tcp"

    public static func newGroupCode() -> String { JackRemote.newPairingCode() }
    public static func normalize(_ code: String) -> String { JackRemote.normalize(code) }

    static func parameters(groupCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = "JackQuota"
        let key = SymmetricKey(data: Data(normalize(groupCode).utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Lo que se recibe de otra Mac.
    public var onMessage: (QuotaMessage) -> Void = { _ in }
    /// Cuando se conecta una Mac nueva: es el momento de contarle el estado propio.
    public var onPeerReady: () -> Void = {}
    public private(set) var peerCount = 0

    private let instance: String
    private let queue = DispatchQueue(label: "dev.jack.quota")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var outgoing: [String: NWConnection] = [:]
    private var ready: Set<String> = []
    private var inbound: [ObjectIdentifier: (NWConnection, Data)] = [:]

    public init(instance: String) { self.instance = instance }

    public func start(groupCode: String) {
        stop()
        let params = Self.parameters(groupCode: groupCode)
        do {
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: instance, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            return
        }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results, params: params) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for connection in outgoing.values { connection.cancel() }
        for (connection, _) in inbound.values { connection.cancel() }
        outgoing = [:]; ready = []; inbound = [:]
        peerCount = 0
    }

    /// Envía un mensaje a todas las Macs conectadas.
    public func send(_ message: QuotaMessage) {
        guard let data = try? JSONEncoder.quota.encode(message) else { return }
        let line = data + Data("\n".utf8)
        for (name, connection) in outgoing where ready.contains(name) {
            connection.send(content: line, completion: .contentProcessed { _ in })
        }
    }

    // MARK: Conexiones

    private func found(_ results: Set<NWBrowser.Result>, params: NWParameters) {
        var names = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name != instance else { continue }
            names.insert(name)
            guard outgoing[name] == nil else { continue }
            let connection = NWConnection(to: result.endpoint, using: params)
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.outgoingChanged(name, state) }
            }
            outgoing[name] = connection
            connection.start(queue: queue)
        }
        // A peer that vanished from Bonjour is dropped, and found again if it comes back.
        for name in outgoing.keys where !names.contains(name) {
            outgoing[name]?.cancel()
            outgoing[name] = nil
            ready.remove(name)
        }
        peerCount = ready.count
    }

    private func outgoingChanged(_ name: String, _ state: NWConnection.State) {
        switch state {
        case .ready:
            ready.insert(name)
            peerCount = ready.count
            onPeerReady()
        case .failed, .cancelled:
            ready.remove(name)
            if outgoing[name] != nil { outgoing[name]?.cancel(); outgoing[name] = nil }
            peerCount = ready.count
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        inbound[id] = (connection, Data())
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.inbound[id] = nil }
                if case .cancelled = state { self?.inbound[id] = nil }
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.inbound[id] != nil else { return }
                if let data, !data.isEmpty { self.consume(data, id: id) }
                if isComplete || error != nil {
                    connection.cancel()
                    self.inbound[id] = nil
                } else {
                    self.receive(on: connection, id: id)
                }
            }
        }
    }

    private func consume(_ data: Data, id: ObjectIdentifier) {
        guard var entry = inbound[id] else { return }
        entry.1.append(data)
        // A hostile peer cannot make the buffer grow without end.
        if entry.1.count > 256 * 1024 { entry.0.cancel(); inbound[id] = nil; return }
        while let newline = entry.1.firstIndex(of: 0x0A) {
            let line = entry.1[entry.1.startIndex..<newline]
            entry.1 = Data(entry.1[entry.1.index(after: newline)...])
            if let message = try? JSONDecoder.quota.decode(QuotaMessage.self, from: line) { onMessage(message) }
        }
        inbound[id] = entry
    }
}

extension JSONEncoder {
    static let quota: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    static let quota: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
