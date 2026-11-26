using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jack.Core;

/// <summary>
/// Equivalente a UserDefaults de Swift: preferencias sencillas clave/valor. Las claves son las mismas que en Swift
/// (por ejemplo "maxConcurrentAgents", "recentModels.claude", "delegationEnabled").
/// </summary>
public interface IPreferences
{
    string? GetString(string key);
    int? GetInt(string key);
    bool? GetBool(string key);
    IReadOnlyList<string>? GetStringArray(string key);
    void SetString(string key, string? value);
    void SetInt(string key, int? value);
    void SetBool(string key, bool? value);
    void SetStringArray(string key, IEnumerable<string>? value);
}

/// <summary>Preferencias en memoria. Para las comprobaciones y como valor por defecto sin disco.</summary>
public class MemoryPreferences : IPreferences
{
    private readonly Dictionary<string, object> _values = new();
    private readonly object _lock = new();

    private T? Get<T>(string key) { lock (_lock) return _values.TryGetValue(key, out var v) && v is T t ? t : default; }
    private void Set(string key, object? value)
    {
        lock (_lock) { if (value == null) _values.Remove(key); else _values[key] = value; }
        Changed();
    }

    /// <summary>Gancho para las subclases que persisten: se llama tras cada escritura.</summary>
    protected virtual void Changed() { }

    protected void Load(IEnumerable<KeyValuePair<string, object>> values)
    {
        lock (_lock) foreach (var pair in values) _values[pair.Key] = pair.Value;
    }

    protected Dictionary<string, object> Snapshot() { lock (_lock) return new Dictionary<string, object>(_values); }

    public string? GetString(string key) => Get<string>(key);
    public int? GetInt(string key) => Get<int?>(key) is { } i ? i : (Get<long?>(key) is { } l ? (int)l : null);
    public bool? GetBool(string key) => Get<bool?>(key);
    public IReadOnlyList<string>? GetStringArray(string key) => Get<string[]>(key);
    public void SetString(string key, string? value) => Set(key, value);
    public void SetInt(string key, int? value) => Set(key, value.HasValue ? value.Value : null);
    public void SetBool(string key, bool? value) => Set(key, value.HasValue ? value.Value : null);
    public void SetStringArray(string key, IEnumerable<string>? value) => Set(key, value?.ToArray());
}

/// <summary>Preferencias guardadas en %APPDATA%\Jack\preferences.json (o JACK_DATA_DIR), con escritura atómica.</summary>
public sealed class JsonPreferences : MemoryPreferences
{
    private readonly string _path;

    public JsonPreferences(string? path = null)
    {
        _path = path ?? Path.Combine(JackDataPaths.ApplicationData(), "preferences.json");
        try
        {
            if (!File.Exists(_path)) return;
            if (JsonNode.Parse(File.ReadAllText(_path)) is not JsonObject root) return;
            var loaded = new List<KeyValuePair<string, object>>();
            foreach (var pair in root)
            {
                switch (pair.Value)
                {
                    case JsonArray array: loaded.Add(new(pair.Key, array.Select(n => n?.GetValue<string>() ?? "").ToArray())); break;
                    case JsonValue value when value.TryGetValue<bool>(out var b): loaded.Add(new(pair.Key, b)); break;
                    case JsonValue value when value.TryGetValue<int>(out var i): loaded.Add(new(pair.Key, (int?)i)); break;
                    case JsonValue value when value.TryGetValue<string>(out var s): loaded.Add(new(pair.Key, s)); break;
                }
            }
            Load(loaded);
        }
        catch (Exception)
        {
            // Un archivo ilegible se trata como vacío; el siguiente guardado lo reemplaza.
        }
    }

    protected override void Changed()
    {
        try
        {
            var root = new JsonObject();
            foreach (var pair in Snapshot())
            {
                root[pair.Key] = pair.Value switch
                {
                    string s => JsonValue.Create(s),
                    bool b => JsonValue.Create(b),
                    int i => JsonValue.Create(i),
                    string[] array => new JsonArray(array.Select(a => (JsonNode?)JsonValue.Create(a)).ToArray()),
                    _ => null,
                };
            }
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temporary, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception)
        {
            // Las preferencias no deben tumbar la aplicación si el disco falla.
        }
    }
}
