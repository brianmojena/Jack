using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Jack.Core;

/// Detecta las versiones de Claude a partir de las transcripciones de sesión: lee las sesiones más recientes,
/// extrae los ids completos de modelo y construye el catálogo con las versiones detectadas.
public static class ClaudeModelDetector
{
    private static readonly string[] Families = ["fable", "opus", "sonnet", "haiku"];

    // Solo el final de cada sesión: los mensajes del asistente más nuevos llevan el modelo en uso y las sesiones pueden ser grandes.
    private const int TailBytes = 192 * 1024;

    // TODO(port): DetectModels(from: sessionsRoot, maxSessionsToScan: 20) viene de ClaudeSessions.swift (ClaudeSessions.root,
    // ClaudeSessions.list(limit:root:) y ClaudeSessions.folderName(for:)). Cuando exista ClaudeSessions.cs, el llamador
    // le pasa a DetectModelsFromFiles las rutas `<root>/<folderName>/<id>.jsonl` de las sesiones más recientes.

    /// Lee la cola de cada archivo de sesión (JSONL) y devuelve, por familia (fable, opus, sonnet, haiku), la versión más alta encontrada.
    /// Devuelve también las familias desconocidas que aparecen en ids que no se pueden interpretar. Los archivos ilegibles se omiten.
    public static (IReadOnlyList<ChatModelChoice> Detected, IReadOnlyList<string> UnknownFamilies) DetectModelsFromFiles(IEnumerable<string> sessionFiles)
    {
        var modelsByFamily = new Dictionary<string, (string FullId, (int Major, int Minor, int Patch) Version)>();
        var unknownFamilies = new HashSet<string>();

        foreach (var sessionFile in sessionFiles)
        {
            var data = ReadTail(sessionFile);
            if (data is null) continue;

            foreach (var line in ParseLines(data))
            {
                if (line["message"] is not JsonObject message) continue;
                if (message["model"] is not JsonValue modelValue || !modelValue.TryGetValue<string>(out var fullId)) continue;

                // Interpreta el id del modelo y extrae familia y versión.
                if (ParseModelId(fullId) is { } parsed)
                {
                    // Conserva la versión más alta de cada familia.
                    if (modelsByFamily.TryGetValue(parsed.Family, out var existing))
                    {
                        if (CompareVersions(parsed.Version, existing.Version) > 0)
                        {
                            modelsByFamily[parsed.Family] = (fullId, parsed.Version);
                        }
                    }
                    else
                    {
                        modelsByFamily[parsed.Family] = (fullId, parsed.Version);
                    }
                }
                else
                {
                    // Familia para los ids que no se pueden interpretar.
                    foreach (var knownFamily in Families)
                    {
                        if (fullId.Contains(knownFamily, StringComparison.Ordinal))
                        {
                            unknownFamilies.Add(knownFamily);
                            break;
                        }
                    }
                }
            }
        }

        // Catálogo con las familias detectadas, en el orden fijo de Families (el mismo orden que en Swift).
        var detected = new List<ChatModelChoice>();
        foreach (var family in Families)
        {
            if (!modelsByFamily.TryGetValue(family, out var info)) continue;
            detected.Add(new ChatModelChoice(
                family,
                BuildTitle(family, info.Version),
                SubtitleForFamily(family),
                ChatModelChoice.ClaudeEfforts(info.FullId)));
        }

        return (detected, unknownFamilies.ToList());
    }

    /// Interpreta un id como "claude-opus-5-5" y devuelve familia y versión semántica.
    /// Si reconoce la familia pero no la versión, devuelve (familia, 0.0.0). Si no reconoce ninguna familia, devuelve null.
    public static (string Family, (int Major, int Minor, int Patch) Version)? ParseModelId(string id)
    {
        var lower = id.ToLowerInvariant();

        foreach (var family in Families)
        {
            if (!lower.Contains(family, StringComparison.Ordinal)) continue;

            // Versiones como "fable-5-1" u "opus-4-6"; un sufijo de fecha ("-20250929") se ignora.
            var match = Regex.Match(lower, family + "-([0-9]+)-([0-9]+)(?:-[0-9]+)?");
            if (match.Success
                && int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var major)
                && int.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var minor))
            {
                return (family, (major, minor, 0));
            }
            // Se reconoce la familia aunque no se pueda leer la versión.
            return (family, (0, 0, 0));
        }
        return null;
    }

    /// Lee la cola del archivo. Null si no se puede abrir o leer (equivale a `try? handle.readToEnd()` que devuelve nil en Swift).
    private static byte[]? ReadTail(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var size = stream.Length;
            stream.Seek(size > TailBytes ? size - TailBytes : 0, SeekOrigin.Begin);
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            return memory.ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// Divide el JSONL por `\n` y conserva las líneas que son un objeto JSON. La primera línea de una cola cortada suele ser inválida y se omite.
    private static List<JsonObject> ParseLines(byte[] data)
    {
        var objects = new List<JsonObject>();
        var start = 0;
        while (start < data.Length)
        {
            var end = Array.IndexOf(data, (byte)'\n', start);
            if (end < 0) end = data.Length;
            if (end > start && TryParseObject(Encoding.UTF8.GetString(data, start, end - start)) is { } line)
            {
                objects.Add(line);
            }
            start = end + 1;
        }
        return objects;
    }

    private static JsonObject? TryParseObject(string text)
    {
        try
        {
            return JsonNode.Parse(text) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// Título legible con familia y versión, p. ej. "Opus 5.5". Sin versión conocida devuelve solo la familia con mayúscula.
    private static string BuildTitle(string family, (int Major, int Minor, int Patch) version)
    {
        var capitalized = char.ToUpperInvariant(family[0]) + family[1..];
        if (version.Major == 0 && version.Minor == 0) return capitalized;
        return $"{capitalized} {version.Major}.{version.Minor}";
    }

    /// Subtítulo en español para cada familia.
    private static string? SubtitleForFamily(string family) => family.ToLowerInvariant() switch
    {
        "fable" => "El más capaz",
        "opus" => "Muy capaz",
        "sonnet" => "Equilibrado",
        "haiku" => "Rápido y económico",
        _ => null,
    };

    /// Compara dos versiones: > 0 si v1 es mayor, 0 si son iguales, < 0 si v1 es menor.
    private static int CompareVersions((int Major, int Minor, int Patch) v1, (int Major, int Minor, int Patch) v2)
    {
        if (v1.Major != v2.Major) return v1.Major - v2.Major;
        if (v1.Minor != v2.Minor) return v1.Minor - v2.Minor;
        return v1.Patch - v2.Patch;
    }
}
