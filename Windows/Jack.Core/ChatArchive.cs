using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jack.Core;

/// Fechas como el Codable por defecto de Swift: segundos desde 2001-01-01 UTC (timeIntervalSinceReferenceDate).
public static class SwiftDate
{
    public static readonly DateTime Reference = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public static DateTime FromSeconds(double seconds) => Reference.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));

    public static double ToSeconds(DateTime value) => (value.ToUniversalTime() - Reference).TotalSeconds;
}

public sealed class SwiftDateConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        SwiftDate.FromSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(SwiftDate.ToSeconds(value));
}

public sealed class SwiftDateOffsetConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        new(SwiftDate.FromSeconds(reader.GetDouble()), TimeSpan.Zero);

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(SwiftDate.ToSeconds(value.UtcDateTime));
}

/// UUID como texto en mayúsculas, igual que `UUID.uuidString` de Swift.
public sealed class SwiftUuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString() ?? throw new JsonException("UUID vacío."));

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// Opciones JSON que reproducen el formato Codable de Swift (JSONEncoder/JSONDecoder por defecto),
/// para poder importar los archivos de la Mac.
public static class SwiftJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            // Swift omite los opcionales nil (encodeIfPresent).
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            WriteIndented = false,
        };
        // Los enums se escriben por rawValue (p. ej. "opencode"; usar [JsonStringEnumMemberName] cuando no coincida).
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        options.Converters.Add(new SwiftDateConverter());
        options.Converters.Add(new SwiftDateOffsetConverter());
        options.Converters.Add(new SwiftUuidConverter());
        return options;
    }
}

/// Escritura atómica: se escribe un archivo temporal junto al destino y después se mueve sobre él.
internal static class AtomicFile
{
    public static async Task WriteBytesAsync(string path, byte[] bytes, CancellationToken cancellationToken = default)
    {
        var temporary = TemporaryPath(path);
        try
        {
            await File.WriteAllBytesAsync(temporary, bytes, cancellationToken);
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            DeleteQuietly(temporary);
            throw;
        }
    }

    public static async Task WriteJsonAsync<T>(string path, T value, JsonSerializerOptions options, CancellationToken cancellationToken = default)
    {
        var temporary = TemporaryPath(path);
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous))
            {
                await JsonSerializer.SerializeAsync(stream, value, options, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            DeleteQuietly(temporary);
            throw;
        }
    }

    private static string TemporaryPath(string path) => path + "." + Guid.NewGuid().ToString("N") + ".tmp";

    private static void DeleteQuietly(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

/// Carpetas de datos de Jack bajo %APPDATA% (equivalente a ~/Library/Application Support en macOS).
public static class JackDataPaths
{
    public static string ApplicationData(params string[] parts)
    {
        var all = new List<string> { Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jack" };
        all.AddRange(parts);
        return Path.Combine(all.ToArray());
    }
}

/// Índice pequeño de metadatos; las transcripciones se leen solo al abrir una conversación.
public sealed class ChatArchive
{
    private readonly object gate = new();
    // Cola de escritura en serie (equivalente a la DispatchQueue "dev.jack.chat.persistence").
    private Task writer = Task.CompletedTask;

    /// Carpeta donde se guardan el índice y las transcripciones. Como en JackApp, JACK_DATA_DIR la sustituye.
    public string Directory { get; }

    public ChatArchive(string? directory = null)
    {
        var fromEnvironment = Environment.GetEnvironmentVariable("JACK_DATA_DIR");
        Directory = directory
            ?? (string.IsNullOrWhiteSpace(fromEnvironment) ? JackDataPaths.ApplicationData("Chats") : fromEnvironment);
    }

    /// Lee el índice. Sin archivo devuelve una lista vacía.
    public async Task<IReadOnlyList<ChatConversation>> LoadIndexAsync(CancellationToken cancellationToken = default)
    {
        var url = Path.Combine(Directory, "index.json");
        if (!File.Exists(url)) return [];
        await using var stream = new FileStream(url, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, FileOptions.Asynchronous);
        var index = await JsonSerializer.DeserializeAsync<List<ChatConversation>>(stream, SwiftJson.Options, cancellationToken);
        return index ?? new List<ChatConversation>();
    }

    /// Lee la transcripción completa. Espera a que las escrituras pendientes terminen; sin archivo devuelve null.
    public async Task<ChatConversation?> LoadAsync(Guid id, CancellationToken cancellationToken = default)
    {
        await FlushAsync();
        var url = TranscriptPath(id);
        if (!File.Exists(url)) return null;
        await using var stream = new FileStream(url, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, FileOptions.Asynchronous);
        return await JsonSerializer.DeserializeAsync<ChatConversation>(stream, SwiftJson.Options, cancellationToken);
    }

    /// Guarda la transcripción (si se indica), el índice sin mensajes y borra la transcripción de `removedId`.
    /// Las escrituras se hacen en orden, en segundo plano. Los errores se devuelven en la tarea.
    /// La instantánea del índice se toma al llamar; `conversation` se serializa más tarde, así que no conviene
    /// modificar sus listas hasta que la tarea termine.
    public Task SaveAsync(IEnumerable<ChatConversation> index, ChatConversation? conversation = null, Guid? removedId = null, CancellationToken cancellationToken = default)
    {
        // Como en Swift: el índice guardado no lleva mensajes.
        var summaries = index.Select(value => value with { Messages = [] }).ToList();
        return Enqueue(async () =>
        {
            System.IO.Directory.CreateDirectory(Directory);
            if (conversation is not null)
                await AtomicFile.WriteJsonAsync(TranscriptPath(conversation.Id), conversation, SwiftJson.Options, cancellationToken);
            await AtomicFile.WriteJsonAsync(Path.Combine(Directory, "index.json"), summaries, SwiftJson.Options, cancellationToken);
            if (removedId is { } removed && File.Exists(TranscriptPath(removed)))
                File.Delete(TranscriptPath(removed));
        });
    }

    /// Espera a que termine todo lo encolado. Nunca lanza: los errores de escritura ya se devolvieron en su tarea.
    public Task FlushAsync()
    {
        Task pending;
        lock (gate) pending = writer;
        return pending.ContinueWith(_ => { }, TaskScheduler.Default);
    }

    private Task Enqueue(Func<Task> work)
    {
        lock (gate)
        {
            // Se continúa aunque la tarea anterior haya fallado, como hace la cola serie de Swift.
            var next = writer.ContinueWith(_ => work(), TaskScheduler.Default).Unwrap();
            writer = next;
            return next;
        }
    }

    private string TranscriptPath(Guid id) => Path.Combine(Directory, id.ToString("D").ToUpperInvariant() + ".json");
}
