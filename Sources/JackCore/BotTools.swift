import Foundation

/// Tools only a Jack Bot agent sees: talk to its teammates and work in shared channels.
extension AgentBridge {
    static let botTools: [[String: Any]] = [
        tool("bot_list_agents", "List the Jack Bot agents, your teammates, with their ids, folders and whether they are working.", [:], required: []),
        tool("bot_send_message", "Send a message to another Jack Bot agent. It lands in that agent's own conversation and waits there if the agent is working. Set expects_reply when you need an answer: the other agent is told to answer you with bot_send_message.", [
            "agent": ["type": "string", "description": "Name or id of the teammate."],
            "message": ["type": "string"],
            "expects_reply": ["type": "boolean", "description": "Defaults to false."],
        ], required: ["agent", "message"]),
        tool("channel_list", "List the channels you belong to, with their owner, members and state.", [:], required: []),
        tool("channel_history", "Read the latest messages of a channel you belong to.", [
            "channel": ["type": "string", "description": "Name or id of the channel."],
            "limit": ["type": "integer", "description": "How many messages, 1–100. Defaults to 20."],
        ], required: ["channel"]),
        tool("channel_post", "Write in a channel you belong to. Only the channel's owner is told about what the user writes; to bring another member in, delegate explicitly with delegate_to.", [
            "channel": ["type": "string", "description": "Name or id of the channel."],
            "message": ["type": "string"],
            "delegate_to": ["type": "string", "description": "Optional: name or id of a member who must act on this message."],
        ], required: ["channel", "message"]),
    ]

    func botCall(_ name: String, arguments: [String: Any], conversation: ChatConversation, store: ChatStore) -> (String, Bool) {
        let bots = store.bots
        guard let me = bots.agents.first(where: { $0.id == conversation.botAgentID }) else { return ("You are not a Jack Bot agent.", true) }
        func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
        func label(_ id: UUID?) -> String { id.flatMap { id in bots.agents.first { $0.id == id }?.name } ?? (id == nil ? "usuario" : "agente eliminado") }
        func teammate(_ reference: Any?) -> Result<BotAgent, ScheduleCenter.ScheduleError> {
            let text = reference as? String ?? ""
            let found = bots.agents(matching: text)
            guard found.count == 1, let agent = found.first else {
                return .failure(.init(found.isEmpty ? "No Jack Bot agent matches “\(text)”. Use bot_list_agents." : "“\(text)” matches several agents; use the id."))
            }
            return .success(agent)
        }
        func channel(_ reference: Any?) -> Result<BotChannel, ScheduleCenter.ScheduleError> {
            let text = reference as? String ?? ""
            let found = bots.channels(matching: text).filter { $0.memberIDs.contains(me.id) }
            guard found.count == 1, let channel = found.first else {
                return .failure(.init(found.isEmpty ? "No channel of yours matches “\(text)”. Use channel_list." : "“\(text)” matches several channels; use the id."))
            }
            return .success(channel)
        }

        switch name {
        case "bot_list_agents":
            return (bots.agents.map { agent in
                let working = agent.conversationID.map(store.isBusy) ?? false
                return "- \(agent.name) · id \(short(agent.id)) · \(agent.provider.title) · \(URL(fileURLWithPath: agent.projectPath).lastPathComponent)"
                    + (working ? " · working" : "") + (agent.id == me.id ? " · you" : "")
            }.joined(separator: "\n"), false)

        case "bot_send_message":
            let target: BotAgent
            switch teammate(arguments["agent"]) {
            case .success(let agent): target = agent
            case .failure(let error): return (error.message, true)
            }
            guard target.id != me.id else { return ("That is you; write to a teammate.", true) }
            let text = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return ("The message is empty.", true) }
            var note = "Mensaje de «\(me.name)» (agente \(short(me.id))):\n\(text)"
            if arguments["expects_reply"] as? Bool == true { note += "\n\nEspera tu respuesta: contéstale con bot_send_message al agente \(short(me.id))." }
            let wasBusy = target.conversationID.map(store.isBusy) ?? false
            switch store.sendToBotAgent(note, agent: target) {
            case .success: return (wasBusy ? "Queued for \(target.name); it will read it when its current turn ends." : "Sent to \(target.name).", false)
            case .failure(let error): return ("Could not reach \(target.name): \(error.message)", true)
            }

        case "channel_list":
            let mine = bots.channels.filter { $0.memberIDs.contains(me.id) && $0.state != .archived }
            return (mine.isEmpty ? "You are in no channels." : mine.map { channel in
                "- \(channel.name) · id \(short(channel.id)) · owner \(label(channel.ownerID)) · members \(channel.memberIDs.map(label).joined(separator: ", ")) · \(channel.state.rawValue)"
            }.joined(separator: "\n"), false)

        case "channel_history":
            switch channel(arguments["channel"]) {
            case .failure(let error): return (error.message, true)
            case .success(let channel):
                let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 100)
                let lines = channel.messages.suffix(limit).map { "\(label($0.authorID)): \($0.text)" }
                return (lines.isEmpty ? "The channel has no messages yet." : lines.joined(separator: "\n"), false)
            }

        case "channel_post":
            switch channel(arguments["channel"]) {
            case .failure(let error): return (error.message, true)
            case .success(let channel):
                var target: UUID?
                if let reference = arguments["delegate_to"] as? String, !reference.isEmpty {
                    switch teammate(reference) {
                    case .success(let agent): target = agent.id
                    case .failure(let error): return (error.message, true)
                    }
                }
                switch bots.post(arguments["message"] as? String ?? "", from: me.id, inChannel: channel.id, delegateTo: target) {
                case .success(let text): return (text, false)
                case .failure(let error): return (error.message, true)
                }
            }

        default:
            return ("Unknown tool \(name).", true)
        }
    }
}
