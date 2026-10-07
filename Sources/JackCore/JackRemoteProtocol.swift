import CryptoKit
import Foundation
import Network

/// Wire format of Jack Remote, shared by Jack (server) and Pixel on the iPhone (client).
/// This file only needs Foundation, CryptoKit and Network, so Pixel carries an identical copy.
///
/// Transport: TCP + TLS with a pre-shared key derived from the pairing code, so only a paired device can
/// connect and the traffic is encrypted. Advertised on Bonjour as `_jack._tcp` and listening on a fixed port
/// so it can also be reached by address (e.g. over Tailscale).
///
/// Framing: one JSON object per line, in both directions, over one long-lived connection. The client sends
/// requests with an `id`; the server answers with events that echo it and pushes the rest unprompted.
public enum JackRemote {
    public static let serviceType = "_jack._tcp"
    public static let port: UInt16 = 47825
    public static let version = 1
    /// Longest line either side accepts.
    public static let maxLine = 2_000_000
    /// Messages sent when an agent is opened; the client keeps what it receives afterwards.
    public static let transcriptWindow = 80
    public static let maxTextLength = 16_000
    public static let maxDetailLength = 1_500

    /// 16 characters from an unambiguous alphabet (~79 bits), shown as "XXXX-XXXX-XXXX-XXXX".
    /// Longer than Pixel's: whoever holds it can make Jack's agents run commands on the Mac.
    public static func newPairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let chars = (0..<16).map { _ in alphabet.randomElement()! }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// Case- and dash-insensitive, so "k7pq-3xma…" and "K7PQ3XMA…" pair the same.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func isValid(_ code: String) -> Bool { normalize(code).count == 16 }

    public static func parameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = "JackRemote"
        let key = SymmetricKey(data: Data(normalize(pairingCode).utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                pskData as __DispatchData,
                                                identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    // MARK: - Messages

    public struct Request: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Handshake: the server answers `hello`.
            case hello
            /// Sends the agent list now and again whenever it changes.
            case list
            /// Sends an agent's latest messages and keeps pushing what changes.
            case open
            /// Stops pushing an agent.
            case close
            case send, stop, respond, answer, create
        }
        public var id: String
        public var type: Kind
        /// Agent UUID.
        public var agent: String?
        /// Message for `send` or first message for `create`.
        public var text: String?
        public var approval: String?
        /// "allow", "deny" or one of the approval's choice ids.
        public var choice: String?
        /// Why a permission was denied.
        public var reason: String?
        public var answers: [String: String]?
        /// Project folder for `create`; it must be one Jack already knows.
        public var project: String?
        /// Provider raw value for `create` (`codex`, `claude`, `opencode`, `stellar`).
        public var provider: String?
        public var interrupting: Bool?

        public init(id: String = UUID().uuidString, type: Kind, agent: String? = nil, text: String? = nil,
                    approval: String? = nil, choice: String? = nil, reason: String? = nil,
                    answers: [String: String]? = nil, project: String? = nil, provider: String? = nil,
                    interrupting: Bool? = nil) {
            self.id = id; self.type = type; self.agent = agent; self.text = text; self.approval = approval
            self.choice = choice; self.reason = reason; self.answers = answers; self.project = project
            self.provider = provider; self.interrupting = interrupting
        }
    }

    public struct Event: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Answer to `hello`: `name`, `host`, `version`.
            case hello
            /// The whole agent list, with the folders `create` accepts.
            case agents
            /// An agent's messages from scratch; the client drops what it had.
            case transcript
            /// Messages that are new or changed; the client replaces by id or appends.
            case messages
            /// An agent's summary and open permission requests.
            case state
            /// Request done. `agent` carries the id of an agent `create` made.
            case ok
            case error
        }
        public var type: Kind
        /// The request this answers; nil for pushes.
        public var id: String?
        public var agent: String?
        public var text: String?
        public var name: String?
        public var host: String?
        public var version: Int?
        public var agents: [AgentSummary]?
        public var projects: [String]?
        public var messages: [Message]?
        public var summary: AgentSummary?
        public var approvals: [Approval]?
        /// Messages the user wrote that wait until the agent reads them.
        public var waiting: [String]?

        public init(type: Kind, id: String? = nil, agent: String? = nil, text: String? = nil, name: String? = nil,
                    host: String? = nil, version: Int? = nil, agents: [AgentSummary]? = nil, projects: [String]? = nil,
                    messages: [Message]? = nil, summary: AgentSummary? = nil, approvals: [Approval]? = nil,
                    waiting: [String]? = nil) {
            self.type = type; self.id = id; self.agent = agent; self.text = text; self.name = name; self.host = host
            self.version = version; self.agents = agents; self.projects = projects; self.messages = messages
            self.summary = summary; self.approvals = approvals; self.waiting = waiting
        }
    }

    public struct AgentSummary: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var project: String
        public var provider: String
        public var model: String
        /// `idle`, `queued`, `running`, `waiting` or `failed`.
        public var status: String
        public var preview: String
        /// Seconds since 1970.
        public var updatedAt: Double
        public var unread: Bool
        /// Permission requests and questions open now.
        public var pending: Int
        /// The agent that delegated this one, if any.
        public var parent: String?

        public init(id: String, title: String, project: String, provider: String, model: String, status: String,
                    preview: String, updatedAt: Double, unread: Bool, pending: Int, parent: String?) {
            self.id = id; self.title = title; self.project = project; self.provider = provider; self.model = model
            self.status = status; self.preview = preview; self.updatedAt = updatedAt; self.unread = unread
            self.pending = pending; self.parent = parent
        }
    }

    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// `user`, `assistant`, `tool`, `jack` or `error`.
        public var role: String
        public var text: String
        public var detail: String
        public var status: String
        public init(id: String, role: String, text: String, detail: String = "", status: String = "") {
            self.id = id; self.role = role; self.text = text; self.detail = detail; self.status = status
        }
    }

    public struct Approval: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String
        public var tool: String?
        /// A plan to review: `detail` is Markdown and `choices` replace allowing and denying.
        public var isPlan: Bool
        public var choices: [Choice]
        public var questions: [Question]
        public init(id: String, title: String, detail: String, tool: String? = nil, isPlan: Bool = false,
                    choices: [Choice] = [], questions: [Question] = []) {
            self.id = id; self.title = title; self.detail = detail; self.tool = tool; self.isPlan = isPlan
            self.choices = choices; self.questions = questions
        }
    }

    public struct Choice: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public struct Question: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var header: String
        public var question: String
        public var options: [QuestionOption]
        public var isSecret: Bool
        public var multiSelect: Bool
        public init(id: String, header: String, question: String, options: [QuestionOption] = [],
                    isSecret: Bool = false, multiSelect: Bool = false) {
            self.id = id; self.header = header; self.question = question; self.options = options
            self.isSecret = isSecret; self.multiSelect = multiSelect
        }
    }

    public struct QuestionOption: Codable, Equatable, Sendable {
        public var label: String
        public var description: String
        public init(label: String, description: String) { self.label = label; self.description = description }
    }

    // MARK: - Framing

    public static func encodeLine<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Splits complete lines off the front of `buffer`.
    public static func takeLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
