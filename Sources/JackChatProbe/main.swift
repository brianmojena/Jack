import Foundation
import JackCore

@main struct JackChatProbe {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "delegate" {
            let orchestrator = args.count > 2 ? ChatProvider(rawValue: args[2]) ?? .claude : .claude
            let model = args.count > 3 ? args[3] : (orchestrator == .claude ? "haiku" : orchestrator.defaultModel)
            await delegate(orchestrator: orchestrator, model: model, project: FileManager.default.currentDirectoryPath); return
        }
        if args.count >= 3, args[1] == "usage", let provider = ChatProvider(rawValue: args[2]) {
            // Reads the provider's quota the same way the usage panel does.
            let usage = await ChatUsageService.read(provider)
            for window in usage.windows { print("\(window.title): \(window.usedPercent.map { "\(Int($0)) % usado" } ?? "sin porcentaje") · restante \(window.remainingPercent.map { "\(Int($0)) %" } ?? "-") · reinicia \(window.resetsAt?.formatted() ?? "-")") }
            print("NOTA: \(usage.note) cached=\(usage.isCached)")
            return
        }
        if args.count >= 3, args[1] == "commands", let provider = ChatProvider(rawValue: args[2]) {
            // Lists slash commands without running a turn.
            do {
                let commands = try await ChatCommandService.load(provider, directory: args.count > 3 ? args[3] : FileManager.default.currentDirectoryPath)
                print("COMMANDS \(commands.count): " + commands.prefix(12).map { "/" + $0.name }.joined(separator: " "))
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            return
        }
        if args.count >= 4, args[1] == "run", let provider = ChatProvider(rawValue: args[2]) {
            // Sends each prompt in turn to one conversation and prints what the store would receive.
            var conversation = ChatConversation(projectPath: FileManager.default.currentDirectoryPath, provider: provider, model: ProcessInfo.processInfo.environment["JACK_MODEL"] ?? provider.defaultModel, effort: "low")
            let environment = ProcessInfo.processInfo.environment
            conversation.extraDirectories = environment["JACK_DIRS"]?.split(separator: ":").map(String.init)
            conversation.mode = environment["JACK_MODE"]
            let driver = ChatDriverFactory.make(provider)
            let files = environment["JACK_FILES"]?.split(separator: ":").map(String.init)
            for prompt in args.dropFirst(3) {
                print(">>> \(prompt)")
                conversation.messages = [ChatMessage(role: "user", text: prompt, attachments: files)]
                var text = ""
                do {
                    try await driver.run(conversation: conversation, prompt: prompt) { event in
                        switch event {
                        case .session(let id): conversation.sessionID = id
                        case let .text(_, value, replace): text = replace ? value : text + value
                        case let .context(used, window): print("CONTEXT used=\(used.map(String.init) ?? "-") window=\(window.map(String.init) ?? "-")")
                        case let .tool(_, title, _, status): print("TOOL \(title) \(status)")
                        case .completed: print("COMPLETED")
                        case .failure(let message): print("FAILURE \(message)")
                        default: break
                        }
                    }
                } catch { print("FAIL: \(error.localizedDescription)") }
                print("TEXT: " + String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ "))
            }
            return
        }
        guard args.count >= 2, let provider = ChatProvider(rawValue: args[1]) else {
            print("Usage: JackChatProbe codex|claude|opencode [project] [model]"); exit(2)
        }
        let project = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath
        let model = args.count > 3 ? args[3] : provider.defaultModel
        var conversation = ChatConversation(projectPath: project, provider: provider, model: model)
        let driver = ChatDriverFactory.make(provider)
        var failure = false
        var output = ""
        var sawCompletion = false
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            print("TIMEOUT"); driver.stop()
        }
        defer { timeout.cancel(); driver.stop() }
        for prompt in ["No tools. Reply exactly JACK_CHAT_OK_731.", "No tools. What exact token did I ask you to reply in the previous message? Reply only that token."] {
            output = ""; sawCompletion = false
            do {
                try await driver.run(conversation: conversation, prompt: prompt) { event in
                    switch event {
                    case .session(let id): conversation.sessionID = id; print("SESSION received")
                    case let .text(_, text, replace): if replace { output = text } else { output += text }
                    case .completed: sawCompletion = true
                    case .failure(let message): failure = true; print("ERROR: \(message)")
                    case .approval(let approval):
                        print("APPROVAL received; rejecting smoke-test tools")
                        Task { try? await driver.respond(approvalID: approval.id, allow: false) }
                    case .tool: print("TOOL event")
                    case .approvalResolved, .reasoning, .toolOutput, .usage, .tokens, .context, .commands: break
                    }
                }
                print("REPLY: \(String(output.prefix(300)))")
                guard output.contains("JACK_CHAT_OK_731"), sawCompletion, !failure, conversation.sessionID != nil else { failure = true; break }
            } catch { failure = true; print("ERROR: \(error.localizedDescription)"); break }
        }
        print(failure ? "FAIL" : "PASS: structured chat and native session resume")
        if failure { exit(1) }
    }

    /// End-to-end check of Jack's delegation tools with the real Claude Code CLI as orchestrator.
    @MainActor static func delegate(orchestrator: ChatProvider, model: String, project: String) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-delegate-probe-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        guard let parent = store.create(projectPath: project, provider: orchestrator, model: model, effort: "low") else { print("FAIL: bad project"); exit(1) }
        store.send("Use the jack MCP tools now. 1) create_agent with provider \(orchestrator == .codex ? "claude" : "codex"), title \"Probe\", effort low, task: \"Do not use any tools. Reply exactly SUB_OK_42.\" 2) wait_for_agents. 3) get_agent_result for it. Then reply with only the sub-agent's final reply.", to: parent)
        let deadline = Date().addingTimeInterval(240)
        var seen = Set<String>()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for conversation in store.conversations {
                for approval in store.approvals[conversation.id] ?? [] where seen.insert(approval.id).inserted {
                    print("APPROVAL in \(conversation.provider.title): \(approval.title); denying")
                    store.respond(conversationID: conversation.id, approvalID: approval.id, allow: false)
                }
            }
            if let status = store.statuses[parent], status == .idle || status == .failed, store.conversations.count > 1 || status == .failed { break }
        }
        let parentConversation = store.conversations.first { $0.id == parent }
        for message in parentConversation?.messages ?? [] where message.role == "tool" { print("TOOL: \(message.text) [\(message.status)] \(message.detail.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))") }
        let reply = parentConversation?.messages.last { $0.role == "assistant" }?.text ?? ""
        let child = store.conversations.first { $0.parentID == parent }
        let childReply = child.flatMap { store.lastReply(of: $0.id) } ?? "(none)"
        print("CHILD: \(child.map { "\($0.provider.title) · \($0.title) · \(store.statuses[$0.id] ?? .idle)" } ?? "none")")
        print("CHILD REPLY: \(childReply.prefix(200))")
        print("ORCHESTRATOR REPLY: \(reply.prefix(300))")
        if let error = parentConversation?.messages.last(where: { $0.role == "error" }) { print("ERROR: \(error.text)") }
        print(child != nil && reply.contains("SUB_OK_42") ? "PASS: delegation" : "FAIL")
    }
}
