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
        if args.count >= 2, args[1] == "sessions" {
            // Lists Claude Code's saved sessions and reads the newest, as "Retomar sesión" does.
            let sessions = ClaudeSessions.list(projectPath: args.count > 2 ? args[2] : nil, limit: 5)
            for session in sessions { print("\(session.updatedAt.formatted()) · \(session.id) · \(session.title) · \(session.projectPath)") }
            if let first = sessions.first {
                let loaded = ClaudeSessions.load(first)
                print("LOADED \(loaded.messages.count) messages, model \(loaded.model ?? "-"): " + loaded.messages.prefix(6).map { "[\($0.role)] \($0.text.prefix(40))" }.joined(separator: " | "))
            }
            return
        }
        if args.count >= 2, args[1] == "live" {
            await live(project: FileManager.default.currentDirectoryPath); return
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
        defer { timeout.cancel(); driver.close() }
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
                    case .approvalResolved, .reasoning, .toolOutput, .usage, .tokens, .context, .commands, .mode, .delivered: break
                    }
                }
                print("REPLY: \(String(output.prefix(300)))")
                guard output.contains("JACK_CHAT_OK_731"), sawCompletion, !failure, conversation.sessionID != nil else { failure = true; break }
            } catch { failure = true; print("ERROR: \(error.localizedDescription)"); break }
        }
        print(failure ? "FAIL" : "PASS: structured chat and native session resume")
        if failure { exit(1) }
    }

    /// End-to-end check of a kept-alive Claude Code session through the store: questions, permissions,
    /// a background subagent that reports back in a turn of its own, a message sent mid-turn and an interrupt.
    @MainActor static func live(project: String) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-live-probe-" + UUID().uuidString)
        let store = ChatStore(archive: ChatArchive(directory: folder), preferences: nil)
        guard let id = store.create(projectPath: project, provider: .claude, model: "haiku", effort: "low") else { print("FAIL: create"); exit(1) }
        var answered = Set<String>()
        func status() -> ChatStatus { store.statuses[id] ?? .idle }
        func pump() {
            for approval in store.approvals[id] ?? [] where answered.insert(approval.id).inserted {
                if !approval.questions.isEmpty {
                    print("QUESTION \(approval.questions.map(\.question)) multi=\(approval.questions.map { $0.multiSelect ?? false })")
                    store.answer(conversationID: id, approvalID: approval.id, answers: Dictionary(uniqueKeysWithValues: approval.questions.map { ($0.id, $0.options?.first?.label ?? "sí") }))
                } else {
                    print("PERMISSION \(approval.title) tool=\(approval.tool ?? "-") choices=\(approval.choices.map(\.title)) plan=\(approval.isPlan)")
                    store.respond(conversationID: id, approvalID: approval.id, choice: approval.isPlan ? "plan.acceptEdits" : "allow")
                }
            }
        }
        func wait(until done: () -> Bool, seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                pump()
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        func transcript(_ label: String) {
            let messages = store.conversations.first { $0.id == id }?.messages ?? []
            print("--- \(label): \(messages.count) mensajes")
            for message in messages.suffix(12) {
                print("  [\(message.role)] \(message.text.prefix(80).replacingOccurrences(of: "\n", with: " ")) \(message.status) \(message.detail.suffix(140).replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        var failures: [String] = []

        store.send("Haz esto en orden: 1) usa AskUserQuestion para preguntarme si prefiero rojo o azul. 2) Lanza con la herramienta Agent (subagent_type general-purpose, run_in_background true) un subagente que ejecute con Bash `sleep 6; echo listo-subagente` y devuelva la salida. 3) Sin esperar al subagente, responde solo 'lanzado'.", to: id)
        if !(await wait(until: { status() == .running || status() == .waiting }, seconds: 10)) { failures.append("turn 1 did not start") }
        if !(await wait(until: { status() == .idle || status() == .failed }, seconds: 180)) { failures.append("turn 1 did not end") }
        transcript("turno 1")
        print("MODE \(store.conversations.first { $0.id == id }?.mode ?? "nil")")
        // The subagent finishes after the reply; Claude Code then starts a turn of its own to report it.
        let reported = await wait(until: { status() == .running }, seconds: 90)
        if !reported { failures.append("no unprompted turn after the background subagent") }
        if reported, !(await wait(until: { status() == .idle }, seconds: 120)) { failures.append("unprompted turn did not end") }
        transcript("tras el subagente")

        store.send("Ejecuta con Bash `sleep 4; echo paso-uno` y después dime qué salió.", to: id)
        _ = await wait(until: { status() == .running }, seconds: 10)
        try? await Task.sleep(for: .seconds(2))
        print("CAN SEND WHILE RUNNING \(store.canSend(to: id))")
        store.send("Además, al final añade la palabra PLATANO.", to: id)
        let queuedAtOnce = store.waiting[id]?.first?.sent == true
        print("WAITING \(store.waiting[id]?.count ?? 0) sent=\(queuedAtOnce)")
        if !queuedAtOnce { failures.append("mid-turn message was not handed to Claude Code") }
        if !(await wait(until: { store.waiting[id] == nil }, seconds: 60)) { failures.append("mid-turn message never left the waiting list") }
        if !(await wait(until: { status() == .idle }, seconds: 120)) { failures.append("steered turn did not end") }
        _ = await wait(until: { status() == .idle }, seconds: 30)
        transcript("con mensaje a mitad de turno")
        let steered = store.conversations.first { $0.id == id }?.messages.contains { $0.role == "assistant" && $0.text.contains("PLATANO") } == true
        if !steered { failures.append("mid-turn message was not followed") }

        store.send("Ejecuta con Bash `sleep 30; echo nunca` y espera a que termine.", to: id)
        _ = await wait(until: { (store.conversations.first { $0.id == id }?.messages.last?.role == "tool") }, seconds: 60)
        try? await Task.sleep(for: .seconds(3))
        store.send("Esto no debería leerlo", to: id)
        let stopAt = Date()
        store.stop(id)
        if store.recalled[id]?.text != "Esto no debería leerlo" { failures.append("stopping did not return the waiting message") }
        store.clearRecalled(id)
        if !(await wait(until: { status() == .idle }, seconds: 10)) { failures.append("interrupt did not end the turn") }
        print(String(format: "STOPPED in %.1f s, status \(status())", Date().timeIntervalSince(stopAt)))
        transcript("tras interrumpir")
        store.send("Responde solo: SIGO-AQUI", to: id)
        _ = await wait(until: { status() == .running }, seconds: 10)
        if !(await wait(until: { status() == .idle }, seconds: 60)) { failures.append("turn after interrupt did not end") }
        let alive = store.conversations.first { $0.id == id }?.messages.last { $0.role == "assistant" }?.text.contains("SIGO-AQUI") == true
        if !alive { failures.append("no reply after interrupt") }
        transcript("tras reanudar")
        if store.conversations.first(where: { $0.id == id })?.messages.contains(where: { $0.text == "Esto no debería leerlo" }) == true { failures.append("a recalled message reached the agent") }

        // Ctrl+Enter: interrupt the step in progress and have the agent read the message right away.
        store.send("Ejecuta con Bash `sleep 40; echo nunca` y espera a que termine.", to: id)
        _ = await wait(until: { (store.conversations.first { $0.id == id }?.messages.last?.role == "tool") }, seconds: 60)
        try? await Task.sleep(for: .seconds(2))
        let urgentAt = Date()
        store.send("Olvida el comando. Responde solo: MANZANA", to: id, interrupting: true)
        let read = await wait(until: { store.waiting[id] == nil }, seconds: 20)
        print(String(format: "URGENT read in %.1f s", Date().timeIntervalSince(urgentAt)))
        if !read { failures.append("interrupting did not make the agent read the message") }
        _ = await wait(until: { status() == .running }, seconds: 10)
        if !(await wait(until: { status() == .idle }, seconds: 60)) { failures.append("turn after interrupting did not end") }
        let urgent = store.conversations.first { $0.id == id }?.messages.last { $0.role == "assistant" }?.text.contains("MANZANA") == true
        if !urgent { failures.append("no reply to the interrupting message") }
        transcript("tras interrumpir y enviar")

        let planFile = URL(fileURLWithPath: project).appendingPathComponent("plan-probe.txt")
        try? FileManager.default.removeItem(at: planFile)
        store.updateMode(id: id, mode: "plan", supported: ChatRunMode.choices(for: .claude))
        store.send("Planifica crear el archivo plan-probe.txt con el texto 'hecho'. Presenta el plan con ExitPlanMode y, cuando lo apruebe, créalo.", to: id)
        _ = await wait(until: { status() == .running || status() == .waiting }, seconds: 10)
        if !(await wait(until: { status() == .idle || status() == .failed }, seconds: 180)) { failures.append("plan turn did not end") }
        let mode = store.conversations.first { $0.id == id }?.mode ?? "nil"
        print("MODE AFTER PLAN \(mode) FILE \(FileManager.default.fileExists(atPath: planFile.path))")
        if mode != "acceptEdits" { failures.append("approving the plan did not switch to acceptEdits") }
        if !FileManager.default.fileExists(atPath: planFile.path) { failures.append("plan was not carried out") }
        try? FileManager.default.removeItem(at: planFile)
        transcript("tras el plan")
        store.shutdown()
        print(failures.isEmpty ? "PASS: live Claude Code session" : "FAIL: " + failures.joined(separator: "; "))
        if !failures.isEmpty { exit(1) }
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
