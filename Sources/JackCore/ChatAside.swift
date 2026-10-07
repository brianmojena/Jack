import Foundation

/// A quick question about a conversation, like `/btw` in Claude Code: it is answered from a throwaway copy of the
/// agent's session, so the agent is not interrupted and neither the question nor the answer enter its history.
public struct ChatAside: Identifiable, Equatable {
    public let id: UUID
    public let question: String
    public var answer = ""
    public var finished = false
    public var error: String?
}

/// The aside of each conversation. Kept apart from `ChatStore` so the streamed answer only redraws its own card.
@MainActor public final class ChatAsides: ObservableObject {
    @Published public private(set) var items: [UUID: ChatAside] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Replaces the conversation's previous aside, as Claude Code shows one at a time.
    public func ask(_ question: String, about conversation: ChatConversation) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = conversation.id
        tasks.removeValue(forKey: id)?.cancel()
        let aside = ChatAside(id: UUID(), question: text)
        items[id] = aside
        tasks[id] = Task { [weak self] in
            do {
                let answer = try await ChatAsideService.ask(text, about: conversation) { partial in
                    guard let self, self.items[id]?.id == aside.id else { return }
                    self.items[id]?.answer = partial
                }
                guard let self, self.items[id]?.id == aside.id else { return }
                self.items[id]?.answer = answer
                self.items[id]?.finished = true
            } catch {
                guard let self, !Task.isCancelled, self.items[id]?.id == aside.id else { return }
                self.items[id]?.error = error.localizedDescription
                self.items[id]?.finished = true
            }
            if let self, self.items[id]?.id == aside.id { self.tasks[id] = nil }
        }
    }

    public func dismiss(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        items.removeValue(forKey: id)
    }

    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}

enum ChatAsideService {
    static let timeout: Duration = .seconds(180)

    static func prompt(_ question: String) -> String {
        """
        [Pregunta al margen] El usuario te hace una pregunta rápida aparte, sin interrumpir la tarea en curso. \
        Respóndela de forma breve con lo que ya sabes de esta conversación. No uses herramientas, no modifiques \
        archivos y no continúes la tarea.

        \(question)
        """
    }

    /// The answer so far is passed to `partial` while it streams; returns the whole answer.
    /// `instructions` replaces the side-question wrapper, for other one-off questions such as choosing a project.
    @MainActor
    static func ask(_ question: String, about conversation: ChatConversation, instructions: String? = nil, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        let provider = conversation.provider
        let prompt = instructions ?? prompt(question)
        if provider == .stellar { return try await StellarAside.ask(question, prompt: prompt, about: conversation, partial: partial) }
        // Each provider's executable is named after it.
        guard let executable = ExecutableResolver.resolve(provider.rawValue, override: UserDefaults.standard.string(forKey: "providerExecutablePath.\(provider.rawValue)")) else {
            throw AsideError.failure("No se encontró \(provider.rawValue). Instálalo o indica su ruta en Ajustes.")
        }
        let child = try StructuredChild(executable: executable, arguments: arguments(conversation, prompt: prompt), directory: conversation.projectPath)
        child.closeInput()
        let timer = Task { try? await Task.sleep(for: timeout); if !Task.isCancelled { child.terminate() } }
        defer { timer.cancel() }
        var parser = Parser(provider: provider)
        do {
            try await withTaskCancellationHandler {
                for try await line in child.lines {
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if parser.consume(object) { partial(parser.answer) }
                    // Some CLIs linger after the turn, e.g. Codex refreshing its model list.
                    if parser.done { break }
                }
            } onCancel: { child.terminate() }
        } catch {}
        child.terminate()
        await child.waitForExit()
        if provider == .opencode { await deleteForks(parser.sessions.subtracting([conversation.sessionID ?? ""]), executable: executable, directory: conversation.projectPath) }
        try Task.checkCancellation()
        if let failure = parser.failure { throw AsideError.failure(failure) }
        let answer = parser.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw AsideError.failure(await child.failureDescription(default: "\(provider.title) no respondió a la pregunta al margen."))
        }
        return answer
    }

    static func arguments(_ conversation: ChatConversation, prompt: String) -> [String] {
        let session = conversation.sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let model = conversation.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch conversation.provider {
        case .claude:
            // The prompt goes first: `--tools` takes a list and would swallow it.
            // Without tools its MCP servers are of no use, and starting them takes seconds.
            var args = [prompt, "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages", "--no-session-persistence", "--strict-mcp-config"]
            if let session { args += ["--resume", session, "--fork-session"] }
            if !model.isEmpty { args += ["--model", model] }
            if ChatModelChoice.claudeEfforts(for: model).contains("low") { args += ["--effort", "low"] }
            return args + ["--tools", ""]
        case .codex:
            var args = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check"]
            if !model.isEmpty { args += ["--model", model] }
            if !conversation.effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(conversation.effort)\""] }
            if let session { return args + ["fork", session, "--ephemeral", prompt] }
            return args + ["--ephemeral", prompt]
        case .opencode:
            var args = ["run", "--pure", "--format", "json"]
            if model.contains("/") { args += ["--model", model] }
            if let variant = conversation.variant, !variant.isEmpty { args += ["--variant", variant] }
            if let session { args += ["--session", session, "--fork"] }
            return args + [prompt]
        case .stellar:
            return []
        }
    }

    /// OpenCode has no ephemeral runs, so the copies it saved are deleted once answered.
    private static func deleteForks(_ sessions: Set<String>, executable: String, directory: String) async {
        for session in sessions where !session.isEmpty {
            guard let child = try? StructuredChild(executable: executable, arguments: ["session", "delete", session], directory: directory) else { continue }
            child.closeInput()
            do { for try await _ in child.lines {} } catch {}
            await child.waitForExit()
        }
    }

    struct Parser {
        let provider: ChatProvider
        private var parts: [(id: String, text: String)] = []
        private(set) var failure: String?
        private(set) var done = false
        private(set) var sessions = Set<String>()

        init(provider: ChatProvider) { self.provider = provider }

        var answer: String { parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }

        /// Returns whether the answer changed.
        mutating func consume(_ object: [String: Any]) -> Bool {
            let type = object["type"] as? String
            switch provider {
            case .claude:
                if type == "stream_event", let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                   let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    return append(text, to: "stream:\(event["index"] as? Int ?? 0)")
                }
                if type == "assistant", let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                    guard !text.isEmpty else { return false }
                    // The complete message replaces what streamed for it.
                    let id = message["id"] as? String ?? UUID().uuidString
                    parts.removeAll { $0.id.hasPrefix("stream:") }
                    return set(text, for: id)
                }
                if type == "result" { done = true }
                if type == "result", object["is_error"] as? Bool == true || (object["subtype"] as? String).map({ $0 != "success" }) == true {
                    failure = object["result"] as? String ?? (object["errors"] as? [String])?.joined(separator: "\n") ?? "Claude Code no pudo responder."
                }
                return false
            case .codex:
                if type == "item.completed", let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    return set(text, for: item["id"] as? String ?? UUID().uuidString)
                }
                if type == "turn.completed" || type == "turn.failed" { done = true }
                if type == "turn.failed" { failure = (object["error"] as? [String: Any])?["message"] as? String ?? "Codex no pudo responder." }
                if type == "error", let message = object["message"] as? String { failure = message }
                return false
            case .opencode, .stellar:
                if let session = object["sessionID"] as? String { sessions.insert(session) }
                if type == "text", let part = object["part"] as? [String: Any], let text = part["text"] as? String {
                    return set(text, for: part["id"] as? String ?? UUID().uuidString)
                }
                if type == "step_finish", (object["part"] as? [String: Any])?["reason"] as? String == "stop" { done = true }
                if type == "error" {
                    done = true
                    let error = object["error"] as? [String: Any]
                    failure = (error?["data"] as? [String: Any])?["message"] as? String ?? error?["message"] as? String ?? "OpenCode no pudo responder."
                }
                return false
            }
        }

        private mutating func set(_ text: String, for id: String) -> Bool {
            if let index = parts.firstIndex(where: { $0.id == id }) {
                guard parts[index].text != text else { return false }
                parts[index].text = text
            } else { parts.append((id, text)) }
            return true
        }

        private mutating func append(_ text: String, to id: String) -> Bool {
            if let index = parts.firstIndex(where: { $0.id == id }) { parts[index].text += text } else { parts.append((id, text)) }
            return !text.isEmpty
        }
    }

    enum AsideError: LocalizedError {
        case failure(String)
        var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
    }
}
