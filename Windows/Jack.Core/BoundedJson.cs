using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jack.Core;

// Port de `func boundedJSON` de Sources/JackCore/StellarOllama.swift: JSON con las claves ordenadas, cortado a 64 KB.
public static class BoundedJson
{
    public const int DefaultLimit = 64 * 1024;

    private static readonly JsonSerializerOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>Serializa `value` con las claves ordenadas; si pasa de `limit` bytes UTF-8, lo corta y lo avisa.</summary>
    public static string Format(JsonNode? value, int limit = DefaultLimit)
    {
        var text = Sorted(value)?.ToJsonString(Options) ?? "null";
        var data = Encoding.UTF8.GetBytes(text);
        if (data.Length <= limit) return text;
        // Retrocede hasta un límite de carácter para no partir una secuencia UTF-8.
        var end = limit;
        while (end > 0 && (data[end] & 0xC0) == 0x80) end--;
        return Encoding.UTF8.GetString(data, 0, end) + "\n… output truncated at 64 KB";
    }

    /// <summary>Copia del árbol con las claves de cada objeto en orden (`.sortedKeys` de Swift: orden ordinal).</summary>
    public static JsonNode? Sorted(JsonNode? node) => node switch
    {
        JsonObject obj => SortedObject(obj),
        JsonArray array => SortedArray(array),
        null => null,
        _ => node.DeepClone(),
    };

    private static JsonObject SortedObject(JsonObject obj)
    {
        var result = new JsonObject();
        foreach (var pair in obj.OrderBy(p => p.Key, StringComparer.Ordinal)) result[pair.Key] = Sorted(pair.Value);
        return result;
    }

    private static JsonArray SortedArray(JsonArray array)
    {
        var result = new JsonArray();
        foreach (var item in array) result.Add(Sorted(item));
        return result;
    }
}
