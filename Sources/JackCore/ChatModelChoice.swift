import Foundation

public struct ChatModelChoice: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var efforts: [String]
    public init(id: String, title: String? = nil, efforts: [String] = ["low", "medium", "high"]) {
        self.id = id; self.title = title ?? (id.isEmpty ? "Predeterminado" : id); self.efforts = efforts
    }
}

public extension ChatModelChoice {
    static let claudeCatalog = [
        ChatModelChoice(id: "fable", title: "Fable", efforts: claudeEfforts(for: "fable")),
        ChatModelChoice(id: "opus", title: "Opus", efforts: claudeEfforts(for: "opus")),
        ChatModelChoice(id: "sonnet", title: "Sonnet", efforts: claudeEfforts(for: "sonnet")),
        ChatModelChoice(id: "haiku", title: "Haiku", efforts: claudeEfforts(for: "haiku")),
    ]
    /// Levels Claude Code accepts for `--effort` with an alias or full model id.
    /// Haiku and models before Opus 4.5 reject effort; Opus 4.5 lacks xhigh/max; the 4.6 family lacks xhigh.
    static func claudeEfforts(for model: String) -> [String] {
        let id = model.lowercased()
        let unsupported = ["haiku", "claude-3", "sonnet-4-5", "sonnet-4-0", "sonnet-4-2", "opus-4-0", "opus-4-1", "opus-4-2"]
        if unsupported.contains(where: id.contains) { return [] }
        if id.contains("opus-4-5") { return ["low", "medium", "high"] }
        if id.contains("opus-4-6") || id.contains("sonnet-4-6") { return ["low", "medium", "high", "max"] }
        return ["low", "medium", "high", "xhigh", "max"]
    }
    /// Efforts for a model outside the provider's catalog, such as one typed by hand.
    static func fallbackEfforts(provider: ChatProvider, model: String) -> [String] {
        switch provider {
        case .claude: claudeEfforts(for: model)
        case .codex: ["low", "medium", "high"]
        case .opencode, .stellar: []
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
    // Reuse the CLI's local catalog: opening the picker never starts an agent.
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
