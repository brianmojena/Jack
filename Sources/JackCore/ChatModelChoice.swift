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
    /// The exact Claude models, by family, newest first. The aliases above always mean "the latest of the family"; these pin one version
    /// (`claude --model claude-opus-4-8`). Normal mode only: Light keeps the four aliases.
    static let claudeVersions: [(family: String, models: [ChatModelChoice])] = [
        ("Fable", [("claude-fable-5-1", "Fable 5.1"), ("claude-fable-5", "Fable 5")]),
        ("Opus", [("claude-opus-5-5", "Opus 5.5"), ("claude-opus-5", "Opus 5"), ("claude-opus-4-8", "Opus 4.8"), ("claude-opus-4-7", "Opus 4.7"),
                  ("claude-opus-4-6", "Opus 4.6"), ("claude-opus-4-5", "Opus 4.5")]),
        ("Sonnet", [("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-sonnet-5", "Sonnet 5"), ("claude-sonnet-4-6", "Sonnet 4.6"),
                    ("claude-sonnet-4-5-20250929", "Sonnet 4.5")]),
        ("Haiku", [("claude-haiku-5-5", "Haiku 5.5"), ("claude-haiku-4-5-20251001", "Haiku 4.5")])
    ].map { family, models in (family, models.map { ChatModelChoice(id: $0.0, title: $0.1, efforts: claudeEfforts(for: $0.0)) }) }
    static var claudeExact: [ChatModelChoice] { claudeVersions.flatMap(\.models) }
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

#if os(macOS)
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
#endif

public struct OpenCodeProviderModels: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var models: [ChatModelChoice]
}
public struct OpenCodeCatalog {
    public var providers: [OpenCodeProviderModels]
    public var modes: [ChatRunMode]
}
