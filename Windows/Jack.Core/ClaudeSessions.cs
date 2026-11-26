using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using static Jack.Core.ClaudeJsonFields;

namespace Jack.Core;

// Port de Sources/JackCore/ClaudeSessions.swift (modo Normal, proveedor Claude Code).
// Lee las sesiones que Claude Code guarda en %USERPROFILE%\.claude\projects (o CLAUDE_CONFIG_DIR\projects).
// Las fechas son UTC. Como en Swift, la lectura es síncrona.

/// <summary>Sesión de Claude Code guardada por la CLI, tal como la lista `claude --resume`.</summary>
public sealed record ClaudeSessionSummary
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string ProjectPath { get; init; }
    public required DateTime UpdatedAt { get; init; }
    /// <summary>Alias del modelo (p. ej. "opus") si la app de Claude lo registró.</summary>
    public string? Model { get; init; }
    /// <summary>Quién inició la sesión: "cli" en una terminal, "claude-desktop" en la app de Claude, "sdk-…" para otros programas (Jack incluido).</summary>
    public string? Entrypoint { get; init; }
}

/// <summary>Lo que la app de Claude guarda de una de sus sesiones de Claude Code (la transcripción es de la CLI).</summary>
internal sealed record ClaudeDesktopSession(string? Title, string? Model, bool Hidden);

/// <summary>
/// Piezas de otros archivos Swift que esta lectura necesita y que todavía no están portadas.
/// Se inyectan desde fuera hasta que existan sus equivalentes en C#.
/// </summary>
public static class ClaudeSessionDependencies
{
    // Enlazadas con ClaudeProtocol (texto de un tool_result y herramientas ocultas) y con BoundedJson (JSON acotado a 64 KB).
    // Siguen siendo sustituibles para las comprobaciones.
    public static Func<JsonNode?, string> ResultText { get; set; } = ClaudeProtocol.ResultText;

    public static IReadOnlySet<string> HiddenTools { get; set; } = ClaudeProtocol.HiddenTools;

    public static Func<JsonNode?, string> BoundedJson { get; set; } = value => Jack.Core.BoundedJson.Format(value);
}

/// <summary>Lectura de las sesiones de Claude Code (`~/.claude/projects`), para continuarlas en Jack o en la terminal.</summary>
public static class ClaudeSessions
{
    private const int HeadBytes = 96 * 1024;
    private const int TailBytes = 192 * 1024;
    private const int DetailLimit = 65_536;

    /// <summary>Carpeta de configuración de Claude Code: CLAUDE_CONFIG_DIR, o %USERPROFILE%\.claude.</summary>
    public static string ConfigDirectory
    {
        get
        {
            var fromEnvironment = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            return string.IsNullOrEmpty(fromEnvironment)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude")
                : fromEnvironment;
        }
    }

    /// <summary>Carpeta de proyectos de Claude Code.</summary>
    public static string Root => Path.Combine(ConfigDirectory, "projects");

    /// <summary>
    /// TODO(port): en macOS es ~/Library/Application Support/Claude/claude-code-sessions. En Windows la app de Claude
    /// guarda sus datos bajo %APPDATA%\Claude; la subcarpeta claude-code-sessions no existe en esta máquina, así que
    /// esta ruta es provisional y debe verificarse con una instalación real.
    /// </summary>
    public static string DesktopRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "claude-code-sessions");

    /// <summary>
    /// La CLI nombra la carpeta de cada proyecto con su ruta, cambiando cada carácter que no sea ASCII alfanumérico por "-".
    /// Cada grafema cuenta como un carácter (como un Character de Swift). Ej.: C:\Users\X\proj -> C--Users-X-proj.
    /// </summary>
    public static string FolderName(string projectPath)
    {
        var builder = new StringBuilder(projectPath.Length);
        var enumerator = StringInfo.GetTextElementEnumerator(projectPath);
        while (enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            builder.Append(element.Length == 1 && char.IsAsciiLetterOrDigit(element[0]) ? element[0] : '-');
        }
        return builder.ToString();
    }

    /// <summary>Las sesiones más recientes, de todos los proyectos o de uno.</summary>
    public static IReadOnlyList<ClaudeSessionSummary> ListRecent(string? projectPath = null, int limit = 60, string? root = null)
    {
        root ??= Root;
        var result = new List<ClaudeSessionSummary>();
        foreach (var file in Files(projectPath, root).Take(limit))
        {
            if (Summary(file.FilePath, file.Date, projectPath) is { } summary) result.Add(summary);
        }
        return result;
    }

    /// <summary>
    /// Sesiones que vale la pena traer a Jack: iniciadas por el usuario en una terminal o en la app de Claude desde
    /// <paramref name="since"/> (UTC), en carpetas que aún existen, las más nuevas primero. Los títulos y modelos de la
    /// app de Claude tienen prioridad; se omiten las sesiones archivadas o de sus carpetas temporales, las de
    /// <paramref name="excluding"/> y las de otros programas.
    /// </summary>
    public static IReadOnlyList<ClaudeSessionSummary> ImportCandidates(DateTime since, int limit, IReadOnlySet<string>? excluding = null,
        string? root = null, string? desktopRoot = null)
    {
        root ??= Root;
        desktopRoot ??= DesktopRoot;
        var desktop = DesktopSessions(desktopRoot);
        var found = new List<ClaudeSessionSummary>();
        foreach (var file in Files(null, root))
        {
            if (found.Count >= limit || file.Date < since) break;
            var id = Path.GetFileNameWithoutExtension(file.FilePath);
            desktop.TryGetValue(id, out var app);
            if (excluding?.Contains(id) == true || app?.Hidden == true) continue;
            if (Summary(file.FilePath, file.Date, null) is not { } session) continue;
            if ((session.Entrypoint ?? "").StartsWith("sdk", StringComparison.Ordinal)) continue;
            if (!Directory.Exists(session.ProjectPath)) continue;
            if (app?.Title is { } appTitle) session = session with { Title = TakeGraphemes(appTitle, 120) };
            session = session with { Model = app?.Model };
            found.Add(session);
        }
        return found;
    }

    /// <summary>Carga la conversación de la sesión como la muestra Jack, y el alias del último modelo usado.</summary>
    public static (IReadOnlyList<ChatMessage> Messages, string? Model) Load(ClaudeSessionSummary session, string? root = null)
    {
        var url = Path.Combine(root ?? Root, FolderName(session.ProjectPath), session.Id + ".jsonl");
        byte[] data;
        try
        {
            data = File.ReadAllBytes(url);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (Array.Empty<ChatMessage>(), null);
        }
        var parsed = ParseMessages(data);
        return (parsed.Messages, parsed.Model);
    }

    /// <summary>Alias corto para un nombre de modelo ("claude-opus-5-5" -> "opus").</summary>
    internal static string? Alias(string model) =>
        new[] { "fable", "opus", "sonnet", "haiku" }.FirstOrDefault(alias => model.Contains(alias, StringComparison.Ordinal));

    /// <summary>Lo que escribió el usuario: los comandos de barra se muestran como se escribieron y se omiten los envoltorios de la CLI.</summary>
    internal static string? TypedPrompt(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        if (!trimmed.StartsWith('<')) return trimmed;
        if (Tag("command-name", trimmed) is not { } name) return null;
        var arguments = Tag("command-args", trimmed) ?? "";
        return (name.StartsWith('/') ? name : "/" + name) + (arguments.Length == 0 ? "" : " " + arguments);
    }

    /// <summary>Transcripciones (.jsonl no vacíos) de la carpeta de un proyecto, o de todas. Las más nuevas primero.</summary>
    private static List<(string FilePath, DateTime Date)> Files(string? projectPath, string root)
    {
        IEnumerable<string> folders;
        if (projectPath is not null)
        {
            folders = new[] { Path.Combine(root, FolderName(projectPath)) };
        }
        else
        {
            folders = Directory.Exists(root) ? Directory.EnumerateDirectories(root) : Enumerable.Empty<string>();
        }

        var files = new List<(string FilePath, DateTime Date)>();
        foreach (var folder in folders)
        {
            if (!Directory.Exists(folder)) continue;
            try
            {
                foreach (var path in Directory.EnumerateFiles(folder))
                {
                    if (!string.Equals(Path.GetExtension(path), ".jsonl", StringComparison.Ordinal)) continue;
                    var info = new FileInfo(path);
                    if (info.Length == 0) continue;
                    files.Add((path, info.LastWriteTimeUtc));
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Una carpeta ilegible no impide listar las demás.
            }
        }
        files.Sort((first, second) => second.Date.CompareTo(first.Date));
        return files;
    }

    /// <summary>Lee la app de Claude: sesiones por su id de CLI, recorriendo los .json de forma recursiva.</summary>
    private static Dictionary<string, ClaudeDesktopSession> DesktopSessions(string root)
    {
        var result = new Dictionary<string, ClaudeDesktopSession>(StringComparer.Ordinal);
        if (!Directory.Exists(root)) return result;

        List<string> paths;
        try
        {
            paths = Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories).ToList();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return result;
        }

        foreach (var path in paths)
        {
            if (!string.Equals(Path.GetExtension(path), ".json", StringComparison.Ordinal)) continue;
            JsonObject? value;
            try
            {
                value = JsonSerializer.Deserialize<JsonNode>(File.ReadAllBytes(path)) as JsonObject;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
            {
                continue;
            }
            if (value is null || Str(value, "cliSessionId") is not { } id) continue;

            var cwd = Str(value, "cwd") ?? "";
            var title = Str(value, "title");
            if (string.IsNullOrWhiteSpace(title)) title = null;
            var model = Str(value, "model") is { } rawModel ? Alias(rawModel) : null;
            var hidden = Bool(value, "isArchived") == true
                || cwd.Replace('\\', '/').Contains("/Claude/scratch-workspaces/", StringComparison.Ordinal);
            result[id] = new ClaudeDesktopSession(title, model, hidden);
        }
        return result;
    }

    /// <summary>Título y carpeta desde los extremos del archivo: los títulos se añaden al final y el primer mensaje registra la carpeta de trabajo.</summary>
    private static ClaudeSessionSummary? Summary(string path, DateTime date, string? projectPath)
    {
        byte[] head;
        byte[] tail;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            head = ReadAt(stream, 0, HeadBytes);
            var size = stream.Length;
            var start = size > TailBytes ? size - TailBytes : 0;
            tail = ReadAt(stream, start, (int)(size - start));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        string? custom = null;
        string? generated = null;
        string? lastPrompt = null;
        string? firstPrompt = null;
        string? entrypoint = null;
        var cwd = projectPath;

        foreach (var line in Lines(tail))
        {
            switch (Str(line, "type"))
            {
                case "custom-title":
                    custom = Str(line, "customTitle") ?? custom;
                    break;
                case "ai-title":
                    generated = Str(line, "aiTitle") ?? generated;
                    break;
                case "summary":
                    generated ??= Str(line, "summary");
                    break;
                case "last-prompt":
                    lastPrompt = Str(line, "lastPrompt") ?? lastPrompt;
                    break;
            }
        }
        var title = custom ?? generated;

        foreach (var line in Lines(head))
        {
            cwd ??= Str(line, "cwd");
            entrypoint ??= Str(line, "entrypoint");
            if (firstPrompt is null && Str(line, "type") == "user" && Bool(line, "isMeta") != true
                && Str(Get(line, "message"), "content") is { } headText && !headText.StartsWith('<'))
            {
                firstPrompt = headText;
            }
            if (cwd is not null && firstPrompt is not null && entrypoint is not null) break;
        }

        if (cwd is null || (title ?? firstPrompt ?? lastPrompt) is not { } label) return null;
        var oneLine = TrimBlanks(label.Replace("\n", " "));
        return new ClaudeSessionSummary
        {
            Id = Path.GetFileNameWithoutExtension(path),
            Title = TakeGraphemes(oneLine, 120),
            ProjectPath = cwd,
            UpdatedAt = date,
            Entrypoint = entrypoint,
        };
    }

    /// <summary>Prompts, respuestas, razonamiento y llamadas a herramientas con sus resultados.</summary>
    private static (List<ChatMessage> Messages, string? Model) ParseMessages(byte[] data)
    {
        string? model = null;
        var messages = new List<ChatMessage>();
        var toolIndex = new Dictionary<string, int>(StringComparer.Ordinal);
        var toolInputs = new Dictionary<string, string>(StringComparer.Ordinal);

        foreach (var line in Lines(data))
        {
            if (Bool(line, "isSidechain") == true || Bool(line, "isMeta") == true || Bool(line, "isCompactSummary") == true) continue;
            if (Get(line, "message") is not JsonObject message) continue;
            var uuid = Str(line, "uuid") ?? Guid.NewGuid().ToString("D").ToUpperInvariant();

            switch (Str(line, "type"))
            {
                case "user":
                {
                    if (Str(message, "content") is { } promptText)
                    {
                        if (TypedPrompt(promptText) is { } typed)
                        {
                            messages.Add(new ChatMessage { Id = uuid, Role = "user", Text = typed });
                        }
                        break;
                    }

                    var blocks = Objects(Get(message, "content")).ToList();
                    var typedTexts = blocks
                        .Where(item => Str(item, "type") == "text")
                        .Select(item => Str(item, "text"))
                        .OfType<string>()
                        .Select(TypedPrompt)
                        .OfType<string>();
                    var joined = string.Join("\n", typedTexts);
                    if (joined.Length > 0) messages.Add(new ChatMessage { Id = uuid, Role = "user", Text = joined });

                    foreach (var block in blocks.Where(item => Str(item, "type") == "tool_result"))
                    {
                        var toolUseId = Str(block, "tool_use_id");
                        if (toolUseId is null || !toolIndex.TryGetValue(toolUseId, out var index)) continue;
                        var result = ClaudeSessionDependencies.ResultText(Get(block, "content"));
                        var inputs = toolInputs.TryGetValue(toolUseId, out var storedInput) ? storedInput + "\n" : "";
                        messages[index].Detail = TakeGraphemes(inputs + result, DetailLimit);
                        messages[index].Status = Bool(block, "is_error") == true ? "failed" : "completed";
                    }
                    break;
                }
                case "assistant":
                {
                    if (Str(message, "model") is { } modelName && Alias(modelName) is { } shortName) model = shortName;

                    var items = Objects(Get(message, "content")).ToList();
                    for (var offset = 0; offset < items.Count; offset++)
                    {
                        var block = items[offset];
                        var blockId = uuid + ":" + offset;
                        switch (Str(block, "type"))
                        {
                            case "text":
                                if (Str(block, "text") is { Length: > 0 } replyText)
                                {
                                    messages.Add(new ChatMessage { Id = blockId, Role = "assistant", Text = replyText });
                                }
                                break;
                            case "thinking":
                                if (Str(block, "thinking") is { Length: > 0 } thoughtText)
                                {
                                    messages.Add(new ChatMessage { Id = blockId, Role = "reasoning", Text = thoughtText });
                                }
                                break;
                            case "tool_use":
                            {
                                var toolName = Str(block, "name") ?? "Herramienta";
                                if (ClaudeSessionDependencies.HiddenTools.Contains(toolName)) break;
                                var input = TakeGraphemes(ClaudeSessionDependencies.BoundedJson(Get(block, "input") ?? new JsonObject()), DetailLimit);
                                var toolId = Str(block, "id") ?? blockId;
                                toolIndex[toolId] = messages.Count;
                                toolInputs[toolId] = input;
                                messages.Add(new ChatMessage { Id = toolId, Role = "tool", Text = toolName, Detail = input, Status = "completed" });
                                break;
                            }
                        }
                    }
                    break;
                }
            }
        }
        return (messages, model);
    }

    /// <summary>Texto entre &lt;name&gt; y &lt;/name&gt;, sin espacios en los extremos.</summary>
    private static string? Tag(string name, string text)
    {
        var open = "<" + name + ">";
        var start = text.IndexOf(open, StringComparison.Ordinal);
        if (start < 0) return null;
        var contentStart = start + open.Length;
        var close = text.IndexOf("</" + name + ">", contentStart, StringComparison.Ordinal);
        if (close < 0) return null;
        return text[contentStart..close].Trim();
    }

    /// <summary>Líneas JSON de un bloque de bytes; las líneas cortadas o inválidas se omiten.</summary>
    private static List<JsonObject> Lines(byte[] data)
    {
        var result = new List<JsonObject>();
        var start = 0;
        for (var index = 0; index <= data.Length; index++)
        {
            if (index < data.Length && data[index] != 0x0A) continue;
            if (index > start && ParseObject(data.AsSpan(start, index - start)) is { } line) result.Add(line);
            start = index + 1;
        }
        return result;
    }

    private static JsonObject? ParseObject(ReadOnlySpan<byte> json)
    {
        try
        {
            return JsonSerializer.Deserialize<JsonNode>(json) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static byte[] ReadAt(FileStream stream, long offset, int count)
    {
        stream.Seek(offset, SeekOrigin.Begin);
        var buffer = new byte[count];
        var total = 0;
        while (total < count)
        {
            var read = stream.Read(buffer, total, count - total);
            if (read == 0) break;
            total += read;
        }
        return buffer[..total];
    }

    /// <summary>Los primeros <paramref name="count"/> grafemas (como prefix(_:) de Swift).</summary>
    private static string TakeGraphemes(string text, int count)
    {
        if (text.Length <= count) return text;
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var end = 0;
        for (var taken = 0; taken < count && enumerator.MoveNext(); taken++)
        {
            end = enumerator.ElementIndex + enumerator.GetTextElement().Length;
        }
        return text[..end];
    }

    /// <summary>Recorta espacios y tabulaciones, como trimmingCharacters(in: .whitespaces) de Swift (no recorta saltos de línea).</summary>
    private static string TrimBlanks(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && IsBlank(text[start])) start++;
        while (end > start && IsBlank(text[end - 1])) end--;
        return text[start..end];
    }

    private static bool IsBlank(char character) =>
        character == '\t' || CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.SpaceSeparator;
}

/// <summary>Acceso tolerante a JSON de Claude Code: equivale a los `as? Tipo` de Swift (devuelve null si el tipo no coincide).</summary>
public static class ClaudeJsonFields
{
    public static JsonNode? Get(JsonNode? node, string key) =>
        node is JsonObject obj && obj.TryGetPropertyValue(key, out var value) ? value : null;

    public static string? Str(JsonNode? node, string key) =>
        Get(node, key) is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public static bool? Bool(JsonNode? node, string key) =>
        Get(node, key) is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;

    public static double? Num(JsonNode? node, string key) =>
        Get(node, key) is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;

    public static JsonObject? Obj(JsonNode? node, string key) => Get(node, key) as JsonObject;

    /// <summary>Los elementos que son objetos de un array JSON; si no es array, no hay ninguno.</summary>
    public static IEnumerable<JsonObject> Objects(JsonNode? node) =>
        node is JsonArray array ? array.OfType<JsonObject>() : Enumerable.Empty<JsonObject>();

    /// <summary>Fecha desde un número (segundos desde 1970) o un texto ISO 8601, como `date(_:)` de ChatUsage.swift.</summary>
    public static DateTime? Date(JsonNode? value)
    {
        if (value is not JsonValue json) return null;
        if (json.TryGetValue<double>(out var seconds)) return DateTime.UnixEpoch.AddSeconds(seconds);
        if (json.TryGetValue<string>(out var text)
            && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            return parsed.UtcDateTime;
        }
        return null;
    }
}
