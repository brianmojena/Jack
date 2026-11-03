import Foundation

public struct ChatModelChoice: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var efforts: [String]
    public init(id: String, title: String? = nil, subtitle: String? = nil, efforts: [String] = ["low", "medium", "high"]) {
        self.id = id; self.title = title ?? (id.isEmpty ? "Predeterminado" : id); self.subtitle = subtitle; self.efforts = efforts
    }
}

public extension ChatModelChoice {
    static let claudeCatalog = [
        ChatModelChoice(id: "fable", title: "Fable 5.1", subtitle: "El más capaz", efforts: claudeEfforts(for: "fable")),
        ChatModelChoice(id: "opus", title: "Opus 5.5", subtitle: "Muy capaz", efforts: claudeEfforts(for: "opus")),
        ChatModelChoice(id: "sonnet", title: "Sonnet 5.5", subtitle: "Equilibrado", efforts: claudeEfforts(for: "sonnet")),
        ChatModelChoice(id: "haiku", title: "Haiku 4.5", subtitle: "Rápido y económico", efforts: claudeEfforts(for: "haiku")),
    ]
    /// Antigravity accepts these levels through `--effort`; the selected model decides which it implements.
    static let antigravityEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// Reasoning levels `qodercli` accepts; the selected model decides which it implements.
    static let qoderEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// Levels Claude Code accepts for `--effort` with an alias or full model id.
    /// Haiku 4.x and models before Opus 4.5 reject effort; Opus 4.5 lacks xhigh/max; the 4.6 family lacks xhigh.
    /// Haiku 5+ supports effort levels.
    static func claudeEfforts(for model: String) -> [String] {
        let id = model.lowercased()
        let unsupported = ["haiku-4", "claude-3", "sonnet-4-5", "sonnet-4-0", "sonnet-4-2", "opus-4-0", "opus-4-1", "opus-4-2"]
        if unsupported.contains(where: id.contains) { return [] }
        // Special case: bare "haiku" alias without version context defaults to no effort (for backward compatibility with older Haiku 4.x)
        if id == "haiku" { return [] }
        if id.contains("opus-4-5") { return ["low", "medium", "high"] }
        if id.contains("opus-4-6") || id.contains("sonnet-4-6") { return ["low", "medium", "high", "max"] }
        return ["low", "medium", "high", "xhigh", "max"]
    }
    /// Maps a full Claude model ID to a readable title with version, e.g. "claude-opus-5-5" -> "Opus 5.5".
    /// Falls back to the raw id if not recognized.
    static func claudeTitle(for model: String) -> String {
        let id = model.lowercased()
        if id == "fable" || id.contains("fable-5-1") { return "Fable 5.1" }
        if id == "opus" || id.contains("opus-5-5") { return "Opus 5.5" }
        if id == "opus-4-6" || id.contains("opus-4-6") { return "Opus 4.6" }
        if id == "opus-4-5" || id.contains("opus-4-5") { return "Opus 4.5" }
        if id.contains("opus") { return "Opus" }
        if id == "sonnet" || id.contains("sonnet-5-5") { return "Sonnet 5.5" }
        if id == "sonnet-4-6" || id.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if id == "sonnet-4-5" || id.contains("sonnet-4-5") { return "Sonnet 4.5" }
        if id.contains("sonnet") { return "Sonnet" }
        if id == "haiku" || id.contains("haiku-4-5") { return "Haiku 4.5" }
        if id.contains("haiku") { return "Haiku" }
        return model
    }
    /// Efforts for a model outside the provider's catalog, such as one typed by hand.
    static func fallbackEfforts(provider: ChatProvider, model: String) -> [String] {
        switch provider {
        case .claude: claudeEfforts(for: model)
        case .codex: ["low", "medium", "high"]
        case .opencode, .stellar: []
        case .antigravity: antigravityEfforts
        case .qoder: qoderEfforts
        }
    }
    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "minimal": "Mínimo"
        case "low": "Bajo"
        case "medium": "Medio"
        case "high": "Alto"
        case "xhigh": "Muy alto"
        case "max": "Máximo"
        default: effort.capitalized
        }
    }
}

enum ChatModelCatalog {
    /// Reuse the CLI's local catalog: opening the picker never starts an agent.
    /// Reads the CLI's own model list: one `slug<TAB>title` line per model. No inference is started.
    static func parseAntigravityModels(_ output: String) -> [ChatModelChoice] {
        output.components(separatedBy: .newlines).compactMap { line -> ChatModelChoice? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let slug = parts.first?.trimmingCharacters(in: .whitespaces), !slug.isEmpty,
                  !slug.contains(" "), !slug.hasPrefix("No ") else { return nil }
            let title = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : slug
            return ChatModelChoice(id: slug, title: title.isEmpty ? slug : title, efforts: ChatModelChoice.antigravityEfforts)
        }
    }
    /// Last catalog read is kept so the picker opens with models before `agy models` answers again.
    static let antigravityModelsCacheKey = "antigravityModelsCache"
    static func encodeAntigravityModels(_ models: [ChatModelChoice]) -> [String] {
        models.map { "\($0.id)\t\($0.title)" }
    }
    static func decodeAntigravityModels(_ lines: [String]) -> [ChatModelChoice] {
        lines.compactMap { line -> ChatModelChoice? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first.map(String.init), !id.isEmpty, !id.contains(" ") else { return nil }
            let title = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : id
            return ChatModelChoice(id: id, title: title.isEmpty ? id : title, efforts: ChatModelChoice.antigravityEfforts)
        }
    }
    /// The CLI stores the model it starts with in its own settings; Jack shows it beside "Predeterminado".
    static func antigravityDefaultTitle(at url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli/settings.json")) -> String? {
        guard let bytes = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let model = root["model"] as? String else { return nil }
        let title = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
    /// Asynchronous because it runs the CLI; callers update their catalog when it returns.
    static func antigravityModels(executable: String, override: String?) async -> [ChatModelChoice] {
        let text = await modelListOutput(executable: executable, override: override, arguments: ["models"])
        return Task.isCancelled ? [] : parseAntigravityModels(text)
    }
    static func qoderModels(executable: String, override: String?) async -> [ChatModelChoice] {
        let text = await modelListOutput(executable: executable, override: override, arguments: ["--list-models"])
        return Task.isCancelled ? [] : parseQoderModels(text)
    }
    private static func modelListOutput(executable: String, override: String?, arguments: [String]) async -> String {
        guard let path = ExecutableResolver.resolve(executable, override: override),
              let child = try? StructuredChild(executable: path, arguments: arguments, directory: NSTemporaryDirectory()) else { return "" }
        child.closeInput()
        let timer = Task { try? await Task.sleep(for: .seconds(30)); if !Task.isCancelled { child.terminate() } }
        var text = ""
        do {
            try await withTaskCancellationHandler {
                for try await line in child.lines {
                    guard text.utf8.count < 256 * 1024 else { break }
                    text += String(decoding: line, as: UTF8.self) + "\n"
                }
            } onCancel: { child.terminate() }
        } catch {}
        timer.cancel()
        if Task.isCancelled { child.terminate() }
        await child.waitForExit()
        return text
    }
    /// `qodercli --list-models` prints a `MODEL` header, then one name per line; the name is also what `-m` takes.
    static func parseQoderModels(_ output: String) -> [ChatModelChoice] {
        let subtitles = ["Auto": "Elige el modelo por ti", "Ultimate": "El más capaz", "Fast": "Rápido", "Efficient": "Económico"]
        return output.components(separatedBy: .newlines).compactMap { line -> ChatModelChoice? in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "MODEL", !name.contains(" ") else { return nil }
            return ChatModelChoice(id: name, subtitle: subtitles[name], efforts: ChatModelChoice.qoderEfforts)
        }
    }
    static let qoderModelsCacheKey = "qoderModelsCache"
    static func encodeQoderModels(_ models: [ChatModelChoice]) -> [String] { models.map(\.id) }
    /// Re-parsing the cached names restores the subtitles, which are not stored.
    static func decodeQoderModels(_ lines: [String]) -> [ChatModelChoice] { parseQoderModels(lines.joined(separator: "\n")) }
    static func cachedCodex(at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")) -> [ChatModelChoice] {
        guard let bytes = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { value in
            guard value["visibility"] as? String == "list", let id = value["slug"] as? String, !id.isEmpty else { return nil }
            let efforts = (value["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? ["low", "medium", "high"]
            return ChatModelChoice(id: id, title: value["display_name"] as? String, efforts: efforts)
        }
    }
}

public struct OpenCodeProviderModels: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var models: [ChatModelChoice]
}
public struct OpenCodeCatalog {
    public var providers: [OpenCodeProviderModels]
    public var modes: [ChatRunMode]
}
