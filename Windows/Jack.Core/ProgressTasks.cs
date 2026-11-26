using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Jack.Core;

/// Trabajo largo que un agente comunica a Jack: una descarga, un clon, cargar un modelo, una compilación…
/// Cada tarea es un archivo JSON en la carpeta de progreso de su conversación, escrito por `jack-progress` o por
/// cualquier script que el agente escriba. Las claves son snake_case y todas son opcionales salvo el nombre del
/// archivo, que es el id.
public enum ProgressStatus { Running, Paused, Done, Failed, Cancelled, Interrupted }

public sealed record ProgressTask
{
    /// Único entre conversaciones: `<conversación>/<id de la tarea>`.
    public string Id => ConversationId.ToString("D").ToUpperInvariant() + "/" + TaskId;
    public string TaskId { get; set; }
    public Guid ConversationId { get; set; }
    public string Title { get; set; }
    /// `download`, `model` o `task`; solo cambia el icono.
    public string Kind { get; set; }
    public ProgressStatus Status { get; set; }
    public double? Fraction { get; set; }
    public double? Completed { get; set; }
    public double? Total { get; set; }
    /// `bytes` para tamaños; cualquier otra cosa, o nada, se muestra como cuenta, como `objects` o `files`.
    public string? Unit { get; set; }
    /// Unidades por segundo, como las informa o mide Jack.
    public double? Speed { get; set; }
    /// Tiempo restante, como lo informa o estima Jack.
    public TimeSpan? Eta { get; set; }
    /// Lo que la tarea hace ahora, como la fase de un clon.
    public string? Detail { get; set; }
    /// Filas extra que el agente quiere mostrar, en orden.
    public List<ProgressField> Fields { get; set; }
    public string? File { get; set; }
    public string? Command { get; set; }
    /// Proceso al que señalar. Una tarea escrita por `jack-progress run` es `Controllable`: SIGUSR1 la pausa,
    /// SIGUSR2 la reanuda y SIGTERM la cancela. Cualquier otro pid solo recibe SIGTERM.
    public int? Pid { get; set; }
    public bool Controllable { get; set; }
    public string? Message { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }

    public bool IsActive => Status is ProgressStatus.Running or ProgressStatus.Paused;
    public bool IsFinished => !IsActive;
    /// Bytes, para que la barra pueda decir "2,1 GB de 4,7 GB".
    public bool IsBytes => ProgressFormat.IsBytes(Unit);
    /// La fracción a dibujar: la informada o la derivada de las cantidades.
    public double? Progress
    {
        get
        {
            if (Fraction is { } fraction) return Math.Min(1, Math.Max(0, fraction));
            if (Completed is { } completed && Total is { } total && total > 0) return Math.Min(1, Math.Max(0, completed / total));
            return null;
        }
    }

    public ProgressTask(string taskId, Guid conversationId, string title, string kind = "task", ProgressStatus status = ProgressStatus.Running,
        DateTimeOffset? startedAt = null, DateTimeOffset? updatedAt = null)
    {
        TaskId = taskId;
        ConversationId = conversationId;
        Title = title;
        Kind = kind;
        Status = status;
        Fields = [];
        Controllable = false;
        UpdatedAt = updatedAt ?? DateTimeOffset.UtcNow;
        StartedAt = startedAt ?? UpdatedAt;
    }

    /// Lee un archivo de tarea con tolerancia: los agentes los escriben a mano, así que los tipos mal escritos se ignoran en lugar de fallar.
    public ProgressTask(JsonElement json, string taskId, Guid conversationId, DateTimeOffset modified)
    {
        var root = json;

        JsonElement? Member(string key) =>
            root.ValueKind == JsonValueKind.Object && root.TryGetProperty(key, out var value) && value.ValueKind != JsonValueKind.Null ? value : null;

        // JSON booleans no son porcentajes; un número en texto sí se acepta.
        double? Number(string key)
        {
            if (Member(key) is not { } value) return null;
            double? result = null;
            if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number)) result = number;
            else if (value.ValueKind == JsonValueKind.String && ProgressParser.Number(value.GetString() ?? "") is { } parsed) result = parsed;
            return result is { } finite && double.IsFinite(finite) ? finite : null;
        }

        string? Text(string key)
        {
            if (Member(key) is not { } value) return null;
            var text = value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Number => value.GetRawText(),
                JsonValueKind.True => "1",
                JsonValueKind.False => "0",
                _ => null,
            };
            return text is null || string.IsNullOrWhiteSpace(text) ? null : text;
        }

        DateTimeOffset? Date(string key) => Number(key) is { } seconds ? FromUnixSeconds(seconds) : null;

        TaskId = taskId;
        ConversationId = conversationId;
        Title = Text("title") ?? (Text("command") is { } command80 ? Prefix(command80, 80) : null) ?? taskId;
        Kind = Text("kind") ?? "task";
        Status = Text("status") is { } raw && StatusFromRaw(raw) is { } parsedStatus ? parsedStatus : ProgressStatus.Running;
        Fraction = Number("fraction") ?? (Number("percent") is { } percent ? (double?)(percent / 100) : null);
        Completed = Number("completed");
        Total = Number("total");
        Unit = Text("unit");
        Speed = Number("speed");
        Eta = Number("eta") is { } etaSeconds ? ToTimeSpan(etaSeconds) : null;
        Detail = Text("detail");
        Fields = [];
        if (Member("fields") is { ValueKind: JsonValueKind.Object } fieldObject)
        {
            var names = fieldObject.EnumerateObject().Select(property => property.Name).ToList();
            names.Sort(StringComparer.Ordinal);
            Fields = names.Select(name => new ProgressField(name, DisplayValue(fieldObject.GetProperty(name)))).ToList();
        }
        else if (Member("fields") is { ValueKind: JsonValueKind.Array } rows && rows.EnumerateArray().All(row => row.ValueKind == JsonValueKind.Array))
        {
            Fields = rows.EnumerateArray()
                .Select(row => row.EnumerateArray().ToArray())
                .Where(pair => pair.Length == 2)
                .Select(pair => new ProgressField(DisplayValue(pair[0]), DisplayValue(pair[1])))
                .ToList();
        }
        File = Text("file");
        Command = Text("command");
        Pid = Number("pid") is { } pidValue && Math.Round(pidValue, MidpointRounding.AwayFromZero) is var rounded
            && rounded >= int.MinValue && rounded <= int.MaxValue ? (int)rounded : null;
        Controllable = Member("controllable") is { ValueKind: JsonValueKind.True };
        Message = Text("message");
        UpdatedAt = Date("updated_at") ?? modified;
        StartedAt = Date("started_at") ?? UpdatedAt;
        FinishedAt = Date("finished_at");
    }

    private static ProgressStatus? StatusFromRaw(string raw) => raw switch
    {
        "running" => ProgressStatus.Running,
        "paused" => ProgressStatus.Paused,
        "done" => ProgressStatus.Done,
        "failed" => ProgressStatus.Failed,
        "cancelled" => ProgressStatus.Cancelled,
        "interrupted" => ProgressStatus.Interrupted,
        _ => null,
    };

    /// Valor de un campo tal como se mostraría al interpolarlo: los booleanos son `1` o `0`, como NSNumber.
    private static string DisplayValue(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString() ?? "",
        JsonValueKind.Number => value.GetRawText(),
        JsonValueKind.True => "1",
        JsonValueKind.False => "0",
        JsonValueKind.Null => "",
        _ => value.GetRawText(),
    };

    private static string Prefix(string value, int count) => value.Length <= count ? value : value[..count];

    /// Segundos desde 1970. Fechas fuera de rango no son válidas.
    private static DateTimeOffset? FromUnixSeconds(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < -62_135_596_800 || seconds > 253_402_300_799) return null;
        return DateTimeOffset.UnixEpoch.AddSeconds(seconds);
    }

    private static TimeSpan? ToTimeSpan(double seconds)
    {
        if (!double.IsFinite(seconds) || Math.Abs(seconds) > TimeSpan.MaxValue.TotalSeconds) return null;
        return TimeSpan.FromSeconds(seconds);
    }
}

public sealed record ProgressField(string Name, string Value);

/// Dónde viven las tareas y cómo encuentran los agentes al ayudante.
public static class ProgressFiles
{
    public const string DirectoryKey = "JACK_PROGRESS_DIR";
    public const string HelperKey = "JACK_PROGRESS";
    public const string HelperName = "jack-progress";

    public static Uri Root => new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jack", "Progress"));

    public static Uri DirectoryFor(Guid conversation) => new(Path.Combine(Root.LocalPath, conversation.ToString("D").ToUpperInvariant()));

    /// `jack-progress`, que se distribuye junto al ejecutable de Jack.
    public static Uri? HelperUri { get; } = FindHelper();

    public static bool IsAvailable => HelperUri is not null;

    private static Uri? FindHelper()
    {
        var fileName = HelperName + ".exe";
        foreach (var directory in new[] { AppContext.BaseDirectory, Path.GetDirectoryName(Environment.ProcessPath) })
        {
            if (string.IsNullOrEmpty(directory)) continue;
            var path = Path.Combine(directory, fileName);
            if (File.Exists(path)) return new Uri(path);
        }
        return null;
    }

    /// Carpeta con solo los lanzadores del ayudante, para ponerla en el PATH de los agentes sin el ejecutable de la app.
    /// En Windows los lanzadores son `.cmd`; el ejecutable se llama por su ruta real.
    private static readonly Lazy<Uri?> ShimDirectory = new(CreateShimDirectory);

    private static Uri? CreateShimDirectory()
    {
        if (HelperUri is not { } helper) return null;
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jack", "bin");
        var quoted = "\"" + helper.LocalPath + "\"";
        // `jack-servers` es el comando `servers` del ayudante con un nombre que los agentes recuerdan.
        var launchers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [HelperName] = quoted + " %*",
            ["jack-servers"] = quoted + " servers %*",
        };
        try
        {
            Directory.CreateDirectory(directory);
            foreach (var (name, line) in launchers)
            {
                var launcher = Path.Combine(directory, name + ".cmd");
                var script = "@echo off\r\n" + line + "\r\n";
                if (File.Exists(launcher) && File.ReadAllText(launcher) == script) continue;
                File.WriteAllText(launcher, script);
            }
            return new Uri(directory);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// Variables que recibe todo proceso de agente, para que sus comandos puedan informar a esta conversación.
    public static IReadOnlyDictionary<string, string> EnvironmentFor(Guid conversation)
    {
        var directory = DirectoryFor(conversation).LocalPath;
        try
        {
            Directory.CreateDirectory(directory);
        }
        catch (Exception)
        {
            // Como en Swift (`try?`): sin carpeta, el agente simplemente no verá tareas.
        }
        var environment = new Dictionary<string, string>(StringComparer.Ordinal) { [DirectoryKey] = directory };
        if (HelperUri is { } helper)
        {
            environment[HelperKey] = helper.LocalPath;
            if (ShimDirectory.Value is { } shim)
                environment["PATH"] = shim.LocalPath + Path.PathSeparator + ChildPath();
        }
        return environment;
    }

    // TODO(port): ExecutableResolver.childEnvironment() viene de ExecutableResolver.swift. Mientras tanto, el PATH del proceso.
    private static string ChildPath() => Environment.GetEnvironmentVariable("PATH") ?? "";

    /// Indica a todo agente cómo mostrar progreso en Jack.
    public const string Instructions = """
Jack shows native progress bars for long-running work, in this chat and in its Downloads panel. Use them instead of writing your own progress-bar scripts.
- Wrap any command that takes more than a few seconds and prints progress (downloads with curl, wget, aria2c, huggingface-cli, ollama pull, brew or pip; git clone and fetch; rsync; loading a model; long builds) in `jack-progress run --title "<short title in the user's language>" -- <command>`. It keeps the command's output and exit status, and Jack shows the percentage, size, speed and time left. Add `--kind download` or `--kind model` when it fits, `--file <path>` when the command writes one file, so the user can open it and Jack can follow its size, and `--total <bytes>` when you know the final size and the command prints no progress.
- For work you track yourself, such as a script or a loop, call `jack-progress set --id <id> --title "<title>" --fraction <0-1>` as it advances (optionally `--completed <n> --total <n> --unit <unit>`, `--detail "<text>"`, `--field "Name=Value"` and `--pid <pid>` so the user can cancel it), then `jack-progress done --id <id>`, or `jack-progress done --id <id> --failed "<reason>"`.
- If a command may outlive your tool's timeout, run it in the background; its bar keeps updating on its own.
- If `jack-progress` is not on PATH, call it as "$JACK_PROGRESS".
""";

    // TODO(port): helperInstructions añade ServerScanner.instructions (ServerScanner.swift) tras una línea en blanco.
    // Hasta portar ServerScanner solo se exponen las instrucciones de progreso.
    public static string HelperInstructions => Instructions;

    /// Escribe un archivo de tarea de forma atómica, para que Jack nunca lea la mitad.
    public static void Write(IReadOnlyDictionary<string, object?> value, Uri url)
    {
        var path = url.LocalPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        // Como `.sortedKeys` de Swift; aquí solo se ordenan las claves de primer nivel.
        var sorted = new SortedDictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (key, item) in value) sorted[key] = item;
        var data = JsonSerializer.SerializeToUtf8Bytes(sorted);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, data);
        File.Move(temporary, path, overwrite: true);
    }

    /// Nombres de archivo admitidos: letras, dígitos, puntos, guiones y guiones bajos.
    public static string SanitizedID(string value)
    {
        var builder = new StringBuilder();
        foreach (var rune in value.ToLowerInvariant().EnumerateRunes())
        {
            var isAllowed = rune.Value < 128 && (char.IsAsciiLetterOrDigit((char)rune.Value) || rune.Value is '-' or '_' or '.');
            builder.Append(isAllowed ? rune.ToString() : "-");
        }
        var collapsed = string.Join("-", builder.ToString().Split('-', StringSplitOptions.RemoveEmptyEntries));
        var trimmed = collapsed.Trim('.', '-');
        if (trimmed.Length > 60) trimmed = trimmed[..60];
        return trimmed.Length == 0 ? "task" : trimmed;
    }
}

/// Lo que dice una línea de salida de un comando sobre su progreso.
public sealed record ProgressReading
{
    public double? Fraction { get; set; }
    public double? Completed { get; set; }
    public double? Total { get; set; }
    public string? Unit { get; set; }
    public double? Speed { get; set; }
    public TimeSpan? Eta { get; set; }
    public string? Phase { get; set; }
}

/// Lee las líneas de progreso de herramientas comunes (curl, aria2c, git, wget, rsync, tqdm, ollama, pip…) y, en su
/// defecto, cualquier línea con un porcentaje o un "hecho/total" de tamaño.
public static class ProgressParser
{
    public static ProgressReading? Parse(string line)
    {
        var text = StripANSI(line).Trim();
        if (text.Length == 0 || text.Length >= 600) return null;
        var reading = Curl(text) ?? Aria2(text) ?? Git(text) ?? Generic(text);
        if (reading is null) return null;
        // Las velocidades siempre se leen como bytes por segundo, aunque la línea no dé tamaños.
        if (reading.Speed is not null && reading.Unit is null) reading.Unit = "bytes";
        return reading;
    }

    /// `  45  100M   45 45.2M    0     0  10.1M      0  0:00:09  0:00:04  0:00:05 10.3M`
    internal static ProgressReading? Curl(string text)
    {
        var columns = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (columns.Length != 12) return null;
        if (!TryDouble(columns[0], out var percent) || !(percent >= 0 && percent <= 100)) return null;
        if (!long.TryParse(columns[2], out _) || !long.TryParse(columns[4], out _)) return null;
        if (!columns[8..11].All(column => column.Contains(':'))) return null;
        var total = Bytes(columns[1]);
        var reading = new ProgressReading
        {
            Completed = Bytes(columns[3]),
            Unit = "bytes",
            Speed = Bytes(columns[11]),
            Eta = Duration(columns[10]),
        };
        if (total is { } size && size > 0)
        {
            reading.Total = size;
            reading.Fraction = percent / 100;
        }
        return reading;
    }

    /// `[#2089b0 1.2MiB/10MiB(12%) CN:1 DL:3.1MiB ETA:3s]`
    internal static ProgressReading? Aria2(string text)
    {
        var match = Groups(Aria2Pattern, text);
        if (match is null) return null;
        var reading = new ProgressReading
        {
            Completed = BytesOf(match[1]),
            Total = BytesOf(match[2]),
            Unit = "bytes",
            Fraction = ParseDouble(match[3]) is { } percent ? (double?)(percent / 100) : null,
        };
        reading.Speed = Groups(Aria2Speed, text)?[1] is { } speed ? Bytes(speed) : null;
        reading.Eta = Groups(Aria2ETA, text)?[1] is { } eta ? Duration(eta) : null;
        return reading;
    }

    /// `Receiving objects:  45% (450/1000), 1.20 MiB | 2.30 MiB/s`
    internal static ProgressReading? Git(string text)
    {
        var match = Groups(GitPattern, text);
        if (match is null || ParseDouble(match[2]) is not { } percent) return null;
        var phase = match[1] ?? "";
        if (phase.StartsWith("remote: ", StringComparison.Ordinal)) phase = phase[8..];
        var counts = string.Join("/", new[] { match[3], match[4] }.OfType<string>());
        var reading = new ProgressReading
        {
            Fraction = percent / 100,
            Phase = string.Join(" ", new[] { phase, counts }.Where(part => part.Length > 0)),
        };
        if (BytesOf(match[5]) is { } received)
        {
            reading.Completed = received;
            reading.Unit = "bytes";
        }
        reading.Speed = BytesOf(match[6]);
        return reading;
    }

    internal static ProgressReading? Generic(string text)
    {
        var reading = new ProgressReading();
        Match? percent = null;
        var percentMatch = PercentPattern.Match(text);
        if (percentMatch.Success && percentMatch.Groups[1].Success
            && Number(percentMatch.Groups[1].Value) is { } value && value >= 0 && value <= 100)
        {
            reading.Fraction = value / 100;
            percent = percentMatch;
        }
        var pair = Groups(PairPattern, text);
        if (pair is not null && BytesOf(pair[1]) is { } done && BytesOf(pair[2]) is { } total && total > 0 && done <= total * 1.01)
        {
            reading.Completed = done;
            reading.Total = total;
            reading.Unit = "bytes";
        }
        else if (Groups(SharedUnitPair, text) is { } shared && shared[3] is { } unit
            && shared[1] is { } doneText && Bytes(doneText + unit) is { } sharedDone
            && shared[2] is { } totalText && Bytes(totalText + unit) is { } sharedTotal && sharedTotal > 0 && sharedDone <= sharedTotal * 1.01)
        {
            // pip: `2.1/4.7 MB`
            reading.Completed = sharedDone;
            reading.Total = sharedTotal;
            reading.Unit = "bytes";
        }
        if (reading.Fraction is null && reading.Total is null) return null;
        reading.Speed = Groups(SpeedPattern, text)?[1] is { } speedText ? Bytes(speedText) : null;
        var etaText = Groups(EtaPattern, text)?[1] ?? Groups(TqdmETA, text)?[1] ?? Groups(TrailingDuration, text)?[1] ?? Groups(BareClock, text)?[1];
        reading.Eta = etaText is null ? null : Duration(etaText);
        // El texto antes del porcentaje dice qué avanza, como `pulling 8eeb52dfb3bb` o un nombre de archivo.
        if (percent is not null)
        {
            var before = TrimPhase(text[..percent.Index]);
            if (before.Length >= 3 && before.Length <= 70 && before.Any(char.IsLetter) && before.IndexOfAny(BarCharacters) < 0)
                reading.Phase = before;
        }
        return reading;
    }

    // MARK: Valores

    /// "45.2M", "1.2MiB", "2,1 GB", "512", "10k": bytes. Los prefijos sin `B` y `iB` son binarios; `kB`, `MB`… son decimales.
    public static double? Bytes(string text)
    {
        var match = Groups(SizePattern, MarkdownBlock.TrimHorizontal(text));
        if (match is null || match[1] is not { } number || Number(number) is not { } value) return null;
        var prefix = (match[2] ?? "").ToUpperInvariant();
        var binary = match[3] is { Length: > 0 } || match[4] is null or { Length: 0 };
        var power = prefix switch
        {
            "" => 0,
            "K" => 1,
            "M" => 2,
            "G" => 3,
            "T" => 4,
            "P" => 5,
            _ => -1,
        };
        if (power < 0) return null;
        return value * Math.Pow(binary ? 1024 : 1000, power);
    }

    /// "0:00:05", "01:30", "1m2s", "3s", "1h 2m", "2.5s": duración. Valores desconocidos como "--:--:--" son nulos.
    public static TimeSpan? Duration(string text)
    {
        var value = MarkdownBlock.TrimHorizontal(text);
        if (value.Length == 0 || value.Contains('-') || value.Contains('?')) return null;
        if (value.Contains(':'))
        {
            var parts = value.Split(':', StringSplitOptions.RemoveEmptyEntries).Select(ParseDouble).ToArray();
            if (parts.Length > 3 || parts.Any(part => part is null)) return null;
            var seconds = parts.Aggregate(0.0, (sum, part) => sum * 60 + part!.Value);
            return ToSpan(seconds);
        }
        var total = 0.0;
        var matched = false;
        foreach (Match match in DurationPart.Matches(value))
        {
            if (ParseDouble(match.Groups[1].Value) is not { } amount) return null;
            if (!Units.TryGetValue(match.Groups[2].Value.ToLowerInvariant(), out var scale)) return null;
            total += amount * scale;
            matched = true;
        }
        return matched ? ToSpan(total) : null;
    }

    /// Acepta "1.5", "1,5" y "1,234,567" (miles).
    public static double? Number(string text)
    {
        var value = MarkdownBlock.TrimHorizontal(text);
        value = ThousandsPattern.IsMatch(value) ? value.Replace(",", "") : value.Replace(",", ".");
        return ParseDouble(value);
    }

    public static string StripANSI(string text) =>
        text.Contains('\u001B') ? AnsiPattern.Replace(text, "") : text;

    // MARK: Patrones

    private const string Size = @"\d+(?:[.,]\d+)*\s?[KMGTP]?i?B?";
    private static readonly char[] BarCharacters = "█▏▕▌▍▎▉▊▋".ToCharArray();

    private static Regex Compile(string pattern, bool caseInsensitive = true) =>
        new(pattern, caseInsensitive ? RegexOptions.IgnoreCase | RegexOptions.CultureInvariant : RegexOptions.CultureInvariant);

    private static readonly Regex AnsiPattern = Compile(@"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])");
    private static readonly Regex SizePattern = Compile(@"^(\d+(?:[.,]\d+)*)\s?([KMGTP]?)(i?)(B?)$");
    private static readonly Regex Aria2Pattern = Compile(@"#[0-9a-f]+\s+(\d+(?:\.\d+)?[KMGTP]?i?B)/(\d+(?:\.\d+)?[KMGTP]?i?B)\((\d{1,3})%\)");
    private static readonly Regex Aria2Speed = Compile(@"\bDL:(\d+(?:\.\d+)?[KMGTP]?i?B)");
    private static readonly Regex Aria2ETA = Compile(@"\bETA:(\w+)");
    private static readonly Regex GitPattern = Compile(@"^((?:remote: )?[A-Z][A-Za-z ]+):\s+(\d{1,3})% \((\d+)/(\d+)\)(?:,\s*(\d+(?:\.\d+)?\s?[KMGT]?i?B)(?:\s*\|\s*(\d+(?:\.\d+)?\s?[KMGT]?i?B)/s)?)?");
    private static readonly Regex PercentPattern = Compile(@"(?<![\d.,])(\d{1,3}(?:[.,]\d+)?)\s?%");
    private static readonly Regex PairPattern = Compile(@"(\d+(?:[.,]\d+)*\s?[KMGTP]i?B?|\d+(?:[.,]\d+)*\s?B)\s?/\s?(\d+(?:[.,]\d+)*\s?[KMGTP]i?B?|\d+(?:[.,]\d+)*\s?B)\b");
    private static readonly Regex SharedUnitPair = Compile(@"(?<![\d.,])(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)\s?([KMGT]i?B)\b");
    private static readonly Regex SpeedPattern = Compile("(" + Size + @")/s\b");
    private static readonly Regex EtaPattern = Compile(@"\b(?:ETA|left|remaining|restante)[:\s]+((?:\d+(?:\.\d+)?\s?(?:d|h|min|m|s)\s?)+|\d+(?::\d+){1,2})");
    private static readonly Regex TqdmETA = Compile(@"<(\d+(?::\d+){1,2})[,\]]");
    /// El tiempo restante de ollama, `1m2s`, al final de la línea; solo en minúsculas, para que `100M` no se lea como minutos.
    private static readonly Regex TrailingDuration = Compile(@"\s((?:\d+h)?(?:\d+m)?\d+s|\d+h(?:\d+m)?)\s*$", caseInsensitive: false);
    /// El tiempo restante de rsync: `0:00:05` por sí solo.
    private static readonly Regex BareClock = Compile(@"(?:^|\s)(\d{1,2}:\d{2}:\d{2})(?:\s|$)");
    private static readonly Regex DurationPart = Compile(@"(\d+(?:\.\d+)?)\s?(ms|min|d|h|m|s)");
    private static readonly Regex ThousandsPattern = Compile(@"^\d{1,3}(,\d{3})+(\.\d+)?$", caseInsensitive: false);

    private static readonly Dictionary<string, double> Units = new(StringComparer.Ordinal)
    {
        ["d"] = 86_400,
        ["h"] = 3_600,
        ["m"] = 60,
        ["min"] = 60,
        ["s"] = 1,
        ["ms"] = 0.001,
    };

    private static string?[]? Groups(Regex regex, string text)
    {
        var match = regex.Match(text);
        if (!match.Success) return null;
        var result = new string?[match.Groups.Count];
        for (var index = 0; index < result.Length; index++)
            result[index] = match.Groups[index].Success ? match.Groups[index].Value : null;
        return result;
    }

    private static double? BytesOf(string? text) => text is null ? null : Bytes(text);

    private static bool TryDouble(string text, out double value) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value);

    private static double? ParseDouble(string? text) =>
        text is not null && TryDouble(text, out var value) ? value : null;

    private static TimeSpan? ToSpan(double seconds)
    {
        if (!double.IsFinite(seconds) || Math.Abs(seconds) > TimeSpan.MaxValue.TotalSeconds) return null;
        return TimeSpan.FromSeconds(seconds);
    }

    /// Recorta puntuación y espacios de la fase, como `trimmingCharacters` con el conjunto de Jack.
    private static string TrimPhase(string value)
    {
        const string punctuation = " :|[]()-=>#.";
        var start = 0;
        var end = value.Length;
        while (start < end && IsPhaseTrim(value[start], punctuation)) start++;
        while (end > start && IsPhaseTrim(value[end - 1], punctuation)) end--;
        return value[start..end];
    }

    private static bool IsPhaseTrim(char character, string punctuation) =>
        punctuation.Contains(character) || character == '\t' || char.GetUnicodeCategory(character) == UnicodeCategory.SpaceSeparator;
}

/// Textos compartidos por las vistas de Jack y los resúmenes del ayudante.
public static class ProgressFormat
{
    public static bool IsBytes(string? unit) => unit is "bytes" or "B";

    public static string Amount(double value, string? unit)
    {
        value = double.IsFinite(value) ? Math.Min(Math.Max(value, -9e18), 9e18) : 0;
        if (IsBytes(unit)) return FormatBytes(value);
        var culture = CultureInfo.CurrentCulture;
        var number = Math.Round(value, MidpointRounding.AwayFromZero) == value
            ? ((long)value).ToString("N0", culture)
            : value.ToString("#,##0.#", culture);
        return unit is null ? number : number + " " + unit;
    }

    public static string Speed(double value, string? unit) => Amount(value, unit) + "/s";

    /// "1 h 5 min", "3 min 12 s", "45 s".
    public static string Duration(TimeSpan span)
    {
        var seconds = span.TotalSeconds;
        // Las estimaciones son absurdas al principio; cualquier cosa de más de un año se muestra como un año.
        var value = (int)Math.Round(Math.Min(Math.Max(0, double.IsFinite(seconds) ? seconds : 0), 31_536_000), MidpointRounding.AwayFromZero);
        var hours = value / 3600;
        var minutes = value % 3600 / 60;
        var rest = value % 60;
        if (hours > 0) return minutes > 0 ? $"{hours} h {minutes} min" : $"{hours} h";
        if (minutes > 0) return minutes < 10 && rest > 0 ? $"{minutes} min {rest} s" : $"{minutes} min";
        return $"{rest} s";
    }

    /// "2,1 GB de 4,7 GB · 45 MB/s · quedan 1 min"
    public static string Summary(ProgressTask task)
    {
        var parts = new List<string>();
        if (task.Completed is { } completed)
        {
            parts.Add(task.Total is { } total
                ? $"{Amount(completed, task.Unit)} de {Amount(total, task.Unit)}"
                : Amount(completed, task.Unit));
        }
        else if (task.Total is { } onlyTotal)
        {
            parts.Add(Amount(onlyTotal, task.Unit));
        }
        if (task.Status == ProgressStatus.Running)
        {
            if (task.Speed is { } speed && speed > 0) parts.Add(Speed(speed, task.Unit));
            if (task.Eta is { } eta && eta.TotalSeconds >= 1) parts.Add("quedan " + Duration(eta));
        }
        return string.Join(" · ", parts);
    }

    /// Bytes con unidades decimales (1 KB = 1000 bytes), como ByteCountFormatter en estilo `.file`.
    private static string FormatBytes(double value)
    {
        var culture = CultureInfo.CurrentCulture;
        if (Math.Abs(value) < 1000) return ((long)value).ToString("N0", culture) + " bytes";
        string[] units = ["KB", "MB", "GB", "TB", "PB", "EB"];
        var scaled = value;
        var index = -1;
        do
        {
            scaled /= 1000;
            index++;
        } while (Math.Abs(scaled) >= 999.95 && index < units.Length - 1);
        var shown = Math.Abs(scaled) < 10
            ? Math.Round(scaled, 1, MidpointRounding.AwayFromZero).ToString("#,##0.#", culture)
            : Math.Round(scaled, 0, MidpointRounding.AwayFromZero).ToString("#,##0", culture);
        return shown + " " + units[index];
    }
}
