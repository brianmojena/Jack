using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jack.Core;

/// Una opción del selector de modelo: identificador, título visible, subtítulo y niveles de esfuerzo.
public sealed class ChatModelChoice : IEquatable<ChatModelChoice>
{
    public ChatModelChoice(string id, string? title = null, string? subtitle = null, IReadOnlyList<string>? efforts = null)
    {
        Id = id;
        Title = title ?? (id.Length == 0 ? "Predeterminado" : id);
        Subtitle = subtitle;
        Efforts = efforts ?? new[] { "low", "medium", "high" };
    }

    public string Id { get; set; }
    public string Title { get; set; }
    public string? Subtitle { get; set; }
    public IReadOnlyList<string> Efforts { get; set; }

    public bool Equals(ChatModelChoice? other) =>
        other is not null && Id == other.Id && Title == other.Title && Subtitle == other.Subtitle && Efforts.SequenceEqual(other.Efforts);

    public override bool Equals(object? obj) => Equals(obj as ChatModelChoice);

    public override int GetHashCode() => HashCode.Combine(Id, Title, Subtitle);

    public static readonly IReadOnlyList<ChatModelChoice> ClaudeCatalog =
    [
        new ChatModelChoice("fable", "Fable 5.1", "El más capaz", ClaudeEfforts("fable")),
        new ChatModelChoice("opus", "Opus 5.5", "Muy capaz", ClaudeEfforts("opus")),
        new ChatModelChoice("sonnet", "Sonnet 5.5", "Equilibrado", ClaudeEfforts("sonnet")),
        new ChatModelChoice("haiku", "Haiku 4.5", "Rápido y económico", ClaudeEfforts("haiku")),
    ];

    /// Antigravity acepta estos niveles con `--effort`; el modelo elegido decide cuáles implementa.
    public static readonly IReadOnlyList<string> AntigravityEfforts = ["low", "medium", "high", "xhigh", "max"];

    /// Niveles de razonamiento que acepta `qodercli`; el modelo elegido decide cuáles implementa.
    public static readonly IReadOnlyList<string> QoderEfforts = ["low", "medium", "high", "xhigh", "max"];

    /// Los modelos exactos de Claude por familia, del más nuevo al más antiguo. Los alias de arriba significan
    /// "el último de la familia"; estos fijan una versión (`claude --model claude-opus-4-8`). Solo modo Normal.
    public static readonly IReadOnlyList<(string Family, IReadOnlyList<ChatModelChoice> Models)> ClaudeVersions =
    [
        ("Fable", Versions(("claude-fable-5-1", "Fable 5.1"), ("claude-fable-5", "Fable 5"))),
        ("Opus", Versions(("claude-opus-5-5", "Opus 5.5"), ("claude-opus-5", "Opus 5"), ("claude-opus-4-8", "Opus 4.8"),
            ("claude-opus-4-7", "Opus 4.7"), ("claude-opus-4-6", "Opus 4.6"), ("claude-opus-4-5", "Opus 4.5"))),
        ("Sonnet", Versions(("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-sonnet-5", "Sonnet 5"), ("claude-sonnet-4-6", "Sonnet 4.6"),
            ("claude-sonnet-4-5-20250929", "Sonnet 4.5"))),
        ("Haiku", Versions(("claude-haiku-5-5", "Haiku 5.5"), ("claude-haiku-4-5-20251001", "Haiku 4.5"))),
    ];

    public static IReadOnlyList<ChatModelChoice> ClaudeExact => ClaudeVersions.SelectMany(version => version.Models).ToList();

    /// Niveles que Claude Code acepta con `--effort` para un alias o un id completo de modelo.
    /// Haiku 4.x y los modelos anteriores a Opus 4.5 rechazan el esfuerzo; Opus 4.5 no tiene xhigh/max; la familia 4.6 no tiene xhigh.
    /// Haiku 5+ admite niveles de esfuerzo.
    public static IReadOnlyList<string> ClaudeEfforts(string model)
    {
        var id = model.ToLowerInvariant();
        string[] unsupported = ["haiku-4", "claude-3", "sonnet-4-5", "sonnet-4-0", "sonnet-4-2", "opus-4-0", "opus-4-1", "opus-4-2"];
        if (unsupported.Any(fragment => id.Contains(fragment))) return Array.Empty<string>();
        // Caso especial: el alias "haiku" sin versión no admite esfuerzo (compatibilidad con Haiku 4.x).
        if (id == "haiku") return Array.Empty<string>();
        if (id.Contains("opus-4-5")) return new[] { "low", "medium", "high" };
        if (id.Contains("opus-4-6") || id.Contains("sonnet-4-6")) return new[] { "low", "medium", "high", "max" };
        return new[] { "low", "medium", "high", "xhigh", "max" };
    }

    /// Convierte un id completo de Claude en un título legible con versión, p. ej. "claude-opus-5-5" -> "Opus 5.5".
    /// Si no lo reconoce, devuelve el id tal cual.
    public static string ClaudeTitle(string model)
    {
        var id = model.ToLowerInvariant();
        if (id == "fable" || id.Contains("fable-5-1")) return "Fable 5.1";
        if (id == "opus" || id.Contains("opus-5-5")) return "Opus 5.5";
        if (id == "opus-4-6" || id.Contains("opus-4-6")) return "Opus 4.6";
        if (id == "opus-4-5" || id.Contains("opus-4-5")) return "Opus 4.5";
        if (id.Contains("opus")) return "Opus";
        if (id == "sonnet" || id.Contains("sonnet-5-5")) return "Sonnet 5.5";
        if (id == "sonnet-4-6" || id.Contains("sonnet-4-6")) return "Sonnet 4.6";
        if (id == "sonnet-4-5" || id.Contains("sonnet-4-5")) return "Sonnet 4.5";
        if (id.Contains("sonnet")) return "Sonnet";
        if (id == "haiku" || id.Contains("haiku-4-5")) return "Haiku 4.5";
        if (id.Contains("haiku")) return "Haiku";
        return model;
    }

    /// Niveles de esfuerzo para un modelo fuera del catálogo del proveedor, como uno escrito a mano.
    public static IReadOnlyList<string> FallbackEfforts(ChatProvider provider, string model) => provider switch
    {
        ChatProvider.Claude => ClaudeEfforts(model),
        ChatProvider.Codex => new[] { "low", "medium", "high" },
        ChatProvider.OpenCode or ChatProvider.Stellar => Array.Empty<string>(),
        ChatProvider.Antigravity => AntigravityEfforts,
        ChatProvider.Qoder => QoderEfforts,
        _ => Array.Empty<string>(),
    };

    public static string EffortTitle(string effort) => effort switch
    {
        "minimal" => "Mínimo",
        "low" => "Bajo",
        "medium" => "Medio",
        "high" => "Alto",
        "xhigh" => "Muy alto",
        "max" => "Máximo",
        _ => Capitalized(effort),
    };

    /// Equivalente a `String.capitalized` de Swift: mayúscula al inicio de cada palabra y minúsculas en el resto.
    private static string Capitalized(string text)
    {
        var chars = text.ToCharArray();
        var startOfWord = true;
        for (var index = 0; index < chars.Length; index++)
        {
            var character = chars[index];
            chars[index] = startOfWord ? char.ToUpperInvariant(character) : char.ToLowerInvariant(character);
            startOfWord = !char.IsLetter(character);
        }
        return new string(chars);
    }

    private static IReadOnlyList<ChatModelChoice> Versions(params (string Id, string Title)[] models) =>
        models.Select(model => new ChatModelChoice(model.Id, model.Title, null, ClaudeEfforts(model.Id))).ToList();
}

/// Catálogos de modelos de Codex, Antigravity, Qoder y OpenCode, y su lectura desde las CLI.
/// En Swift esta parte solo compilaba en macOS; aquí se portan las funciones puras y las que leen archivos del perfil del usuario.
public static class ChatModelCatalog
{
    /// Última lectura del catálogo, para que el selector abra con modelos antes de que `agy models` responda.
    public const string AntigravityModelsCacheKey = "antigravityModelsCache";
    public const string QoderModelsCacheKey = "qoderModelsCache";

    private static readonly Dictionary<string, string> QoderSubtitles = new()
    {
        ["Auto"] = "Elige el modelo por ti",
        ["Ultimate"] = "El más capaz",
        ["Fast"] = "Rápido",
        ["Efficient"] = "Económico",
    };

    /// Lee la lista de modelos de la CLI: una línea `slug<TAB>título` por modelo. No inicia ninguna inferencia.
    public static IReadOnlyList<ChatModelChoice> ParseAntigravityModels(string output)
    {
        var models = new List<ChatModelChoice>();
        foreach (var line in Lines(output))
        {
            var parts = line.Split('\t', 2);
            var slug = parts[0].Trim(' ', '\t');
            if (slug.Length == 0 || slug.Contains(' ') || slug.StartsWith("No ", StringComparison.Ordinal)) continue;
            var title = parts.Length > 1 ? parts[1].Trim(' ', '\t') : slug;
            models.Add(new ChatModelChoice(slug, title.Length == 0 ? slug : title, null, ChatModelChoice.AntigravityEfforts));
        }
        return models;
    }

    public static IReadOnlyList<string> EncodeAntigravityModels(IEnumerable<ChatModelChoice> models) =>
        models.Select(model => model.Id + "\t" + model.Title).ToList();

    public static IReadOnlyList<ChatModelChoice> DecodeAntigravityModels(IEnumerable<string> lines)
    {
        var models = new List<ChatModelChoice>();
        foreach (var line in lines)
        {
            var parts = line.Split('\t', 2);
            var id = parts[0];
            if (id.Length == 0 || id.Contains(' ')) continue;
            var title = parts.Length > 1 ? parts[1].Trim(' ', '\t') : id;
            models.Add(new ChatModelChoice(id, title.Length == 0 ? id : title, null, ChatModelChoice.AntigravityEfforts));
        }
        return models;
    }

    /// La CLI guarda en sus propios ajustes el modelo con el que arranca; Jack lo muestra junto a "Predeterminado".
    public static async Task<string?> AntigravityDefaultTitleAsync(string? path = null)
    {
        path ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini", "antigravity-cli", "settings.json");
        try
        {
            if (!File.Exists(path)) return null;
            var root = JsonNode.Parse(await File.ReadAllTextAsync(path)) as JsonObject;
            if (root?["model"] is not JsonValue value || !value.TryGetValue<string>(out var model)) return null;
            var title = model.Trim();
            return title.Length == 0 ? null : title;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    /// `qodercli --list-models` imprime una cabecera `MODEL` y luego un nombre por línea; ese nombre es también lo que recibe `-m`.
    public static IReadOnlyList<ChatModelChoice> ParseQoderModels(string output)
    {
        var models = new List<ChatModelChoice>();
        foreach (var line in Lines(output))
        {
            var name = line.Trim();
            if (name.Length == 0 || name == "MODEL" || name.Contains(' ')) continue;
            models.Add(new ChatModelChoice(name, null, QoderSubtitles.GetValueOrDefault(name), ChatModelChoice.QoderEfforts));
        }
        return models;
    }

    public static IReadOnlyList<string> EncodeQoderModels(IEnumerable<ChatModelChoice> models) => models.Select(model => model.Id).ToList();

    /// Volver a leer los nombres guardados restaura los subtítulos, que no se almacenan.
    public static IReadOnlyList<ChatModelChoice> DecodeQoderModels(IEnumerable<string> lines) => ParseQoderModels(string.Join("\n", lines));

    /// Lee el catálogo local de Codex (`~/.codex/models_cache.json`). Sin archivo o sin formato válido devuelve una lista vacía.
    public static async Task<IReadOnlyList<ChatModelChoice>> CachedCodexAsync(string? path = null)
    {
        path ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "models_cache.json");
        try
        {
            if (!File.Exists(path)) return new List<ChatModelChoice>();
            var root = JsonNode.Parse(await File.ReadAllTextAsync(path)) as JsonObject;
            // Como en Swift, `as? [[String: Any]]`: si un elemento no es objeto, se descarta toda la lista.
            if (root?["models"] is not JsonArray models || models.Any(node => node is not JsonObject))
                return new List<ChatModelChoice>();

            var choices = new List<ChatModelChoice>();
            foreach (var node in models)
            {
                var value = (JsonObject)node!;
                if (JsonString(value["visibility"]) != "list") continue;
                var id = JsonString(value["slug"]);
                if (string.IsNullOrEmpty(id)) continue;

                var efforts = new List<string>();
                if (value["supported_reasoning_levels"] is JsonArray levels && levels.All(level => level is JsonObject))
                {
                    foreach (var level in levels)
                    {
                        var effort = JsonString(((JsonObject)level!)["effort"]);
                        if (effort is not null) efforts.Add(effort);
                    }
                }
                else
                {
                    efforts = new List<string> { "low", "medium", "high" };
                }
                choices.Add(new ChatModelChoice(id, JsonString(value["display_name"]), null, efforts));
            }
            return choices;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new List<ChatModelChoice>();
        }
    }

    // TODO(port): antigravityModels, qoderModels y modelListOutput usan StructuredChild (ChatProcess.swift) y
    // ExecutableResolver.resolve (ExecutableResolver.swift): se portan cuando existan esos tipos en Windows.

    private static IEnumerable<string> Lines(string text) => text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None);

    private static string? JsonString(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}

/// Un proveedor con sus modelos, para el catálogo de OpenCode.
public sealed record OpenCodeProviderModels
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required IReadOnlyList<ChatModelChoice> Models { get; init; }
}

public sealed record OpenCodeCatalog
{
    public required IReadOnlyList<OpenCodeProviderModels> Providers { get; init; }
    public required IReadOnlyList<ChatRunMode> Modes { get; init; }
}
