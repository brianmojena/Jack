using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jack.Core;

// Port de Sources/JackCore/ChatModels.swift (modo Normal).
// Los structs de Swift son records (valor); las listas se comparan por referencia, no por contenido.

/// <summary>Proveedor de agente. El nombre serializado es el rawValue de Swift (minúsculas).</summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ChatProvider
{
    [JsonStringEnumMemberName("codex")] Codex,
    [JsonStringEnumMemberName("claude")] Claude,
    [JsonStringEnumMemberName("opencode")] OpenCode,
    [JsonStringEnumMemberName("stellar")] Stellar,
    [JsonStringEnumMemberName("antigravity")] Antigravity,
    [JsonStringEnumMemberName("qoder")] Qoder
}

/// <summary>Métodos de <see cref="ChatProvider"/> (las propiedades de Swift no existen en enums de C#).</summary>
public static class ChatProviderExtensions
{
    public static string Title(this ChatProvider provider) => provider switch
    {
        ChatProvider.Codex => "Codex",
        ChatProvider.Claude => "Claude Code",
        ChatProvider.OpenCode => "OpenCode",
        ChatProvider.Stellar => "Stellar Code",
        ChatProvider.Antigravity => "Antigravity",
        ChatProvider.Qoder => "Qoder",
        _ => throw new ArgumentOutOfRangeException(nameof(provider))
    };

    /// <summary>El comando que Jack busca en disco. La mayoría usa el rawValue; Antigravity instala `agy`.</summary>
    public static string ExecutableName(this ChatProvider provider) => provider switch
    {
        ChatProvider.Antigravity => "agy",
        ChatProvider.Qoder => "qodercli",
        _ => provider.ToString().ToLowerInvariant()
    };

    /// <summary>Proveedores que Jack solo ofrece en la ventana Normal. Light conserva su conjunto original.</summary>
    public static bool IsNormalOnly(this ChatProvider provider) => provider is ChatProvider.Antigravity or ChatProvider.Qoder;

    /// <summary>Agente propio de Jack; ejecuta modelos locales y no necesita ejecutable.</summary>
    public static bool IsBuiltIn(this ChatProvider provider) => provider == ChatProvider.Stellar;

    /// <summary>Se muestra en sus tarjetas mientras se construye.</summary>
    public static bool IsBeta(this ChatProvider provider) => provider == ChatProvider.Stellar;

    public static string DefaultModel(this ChatProvider provider) => provider switch
    {
        ChatProvider.Codex => "gpt-6-luna",
        ChatProvider.Claude => "sonnet",
        _ => ""
    };
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ChatStatus
{
    [JsonStringEnumMemberName("idle")] Idle,
    [JsonStringEnumMemberName("queued")] Queued,
    [JsonStringEnumMemberName("running")] Running,
    [JsonStringEnumMemberName("waiting")] Waiting,
    [JsonStringEnumMemberName("failed")] Failed
}

public sealed record ChatMessage
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public required string Role { get; set; }
    public required string Text { get; set; }
    public string Detail { get; set; } = "";
    public string Status { get; set; } = "";
    /// <summary>Rutas de los archivos que el usuario adjuntó a este mensaje.</summary>
    public List<string>? Attachments { get; set; }
}

public sealed record ChatApproval
{
    public required string Id { get; set; }
    public required string Title { get; set; }
    public required string Detail { get; set; }
    public List<ChatInputQuestion> Questions { get; set; } = [];
    /// <summary>El tool que pregunta, cuando <see cref="Detail"/> es su entrada en JSON, para previsualizarla como en la transcripción.</summary>
    public string? Tool { get; set; }
    /// <summary>Formas de responder además de permitir una vez y rechazar, como "permitir siempre".</summary>
    public List<ChatApprovalChoice> Choices { get; set; } = [];
    /// <summary>Un plan a revisar: <see cref="Detail"/> es Markdown y <see cref="Choices"/> sustituyen a permitir y rechazar.</summary>
    public bool IsPlan { get; set; }
}

public sealed record ChatApprovalChoice
{
    public required string Id { get; set; }
    public required string Title { get; set; }
}

/// <summary>
/// Mensaje escrito mientras el agente trabaja. Espera hasta que el agente lo lea: los agentes que aceptan
/// mensajes a mitad de turno lo reciben al instante y lo leen al terminar su paso actual; los demás, al acabar el turno.
/// </summary>
public sealed record ChatQueuedMessage
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public required string Text { get; set; }
    public List<string> Attachments { get; set; } = [];
    /// <summary>Ya entregado al agente, que lo conserva hasta leerlo.</summary>
    public bool Sent { get; set; }
}

public sealed record ChatInputQuestion
{
    public required string Id { get; set; }
    public required string Header { get; set; }
    public required string Question { get; set; }
    public List<ChatInputOption>? Options { get; set; }
    public bool? IsSecret { get; set; }
    /// <summary>Se pueden elegir varias opciones; la respuesta las une con ", ".</summary>
    public bool? MultiSelect { get; set; }
}

public sealed record ChatInputOption
{
    public required string Label { get; set; }
    public required string Description { get; set; }
}

public sealed record ChatConversation
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "Nuevo agente";
    public string ProjectPath { get; set; } = "";
    public ChatProvider Provider { get; set; } = ChatProvider.Codex;
    public string Model { get; set; } = "";
    public string Effort { get; set; } = "high";
    public string? Variant { get; set; }
    public string? Mode { get; set; }
    public JackContextSettings? JackContext { get; set; }
    [JsonPropertyName("sessionID")]
    public string? SessionId { get; set; }
    public List<ChatMessage> Messages { get; set; } = [];
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    public ChatTokenUsage? TokenUsage { get; set; }
    /// <summary>Cuánto se llenó la ventana de contexto del modelo tras la última petición.</summary>
    public ChatContextUsage? ContextUsage { get; set; }
    /// <summary>Resumen corto del último turno, guardado en el índice para que la barra lateral funcione sin cargar transcripciones.</summary>
    public string? Preview { get; set; }
    /// <summary>El último turno terminó mientras la conversación no estaba seleccionada.</summary>
    public bool? HasUnread { get; set; }
    /// <summary>Cuándo el usuario la fijó arriba de la barra lateral; como máximo <c>ChatStore.maxPinned</c> chats están fijados.</summary>
    public DateTime? PinnedAt { get; set; }
    /// <summary>Marcada por el usuario como algo a retomar: la barra lateral muestra un punto brillante.</summary>
    public bool? IsPending { get; set; }
    /// <summary>El agente que la delegó a través de Jack, si lo hay.</summary>
    [JsonPropertyName("parentID")]
    public Guid? ParentId { get; set; }
    /// <summary>Carpetas fuera del proyecto que el agente también puede leer y editar.</summary>
    public List<string>? ExtraDirectories { get; set; }
    /// <summary>Traída de Claude Code sin su historial, que se lee de la sesión la primera vez que se abre.</summary>
    public bool? PendingClaudeHistory { get; set; }
    /// <summary>Ejecuta este agente en otra máquina por SSH en lugar de localmente. Solo Claude Code lo admite.</summary>
    public ChatRemoteEndpoint? Remote { get; set; }

    public ChatConversation() { }

    public ChatConversation(string projectPath, ChatProvider provider = ChatProvider.Codex, string? model = null)
    {
        ProjectPath = projectPath;
        Provider = provider;
        Model = model ?? provider.DefaultModel();
    }

    /// <summary>Carpetas extra, sin el proyecto en sí ni duplicados.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> AdditionalDirectories
    {
        get
        {
            var seen = new HashSet<string> { ProjectPath };
            return (ExtraDirectories ?? Enumerable.Empty<string>()).Where(directory => directory.Length > 0 && seen.Add(directory)).ToList();
        }
    }
}

/// <summary>
/// Dónde corre un agente de Claude Code que no está en este equipo: Jack lo abre por SSH y reenvía su stdio,
/// así el protocolo stream-json no cambia. Un túnel inverso permite al agente remoto alcanzar las herramientas
/// de delegación de Jack. Sin <see cref="RemotePath"/>, Jack descubre los proyectos remotos como lo hace en local.
/// </summary>
public sealed record ChatRemoteEndpoint
{
    /// <summary>Destino SSH: <c>usuario@equipo</c>, una IP o un alias de <c>~/.ssh/config</c>.</summary>
    public required string Destination { get; set; }
    /// <summary>Puerto SSH; null usa el predeterminado (22).</summary>
    public int? SshPort { get; set; }
    /// <summary>Carpeta de trabajo en el equipo remoto, donde corre <c>claude</c>. Null hasta resolverla.</summary>
    public string? RemotePath { get; set; }

    /// <summary>Listo para usar: hay un destino. La carpeta puede resolverse después, automáticamente.</summary>
    [JsonIgnore]
    public bool IsValid => !string.IsNullOrWhiteSpace(Destination);

    /// <summary>Si la carpeta remota ya se conoce (fijada a mano o descubierta).</summary>
    [JsonIgnore]
    public bool IsResolved => (RemotePath ?? "").StartsWith('/');

    [JsonIgnore]
    public string DisplayName => Destination.Trim();
}

public sealed record ChatRunMode
{
    public required string Id { get; set; }
    public required string Title { get; set; }

    /// <summary>
    /// <c>bypassPermissions</c> de Claude Code: ejecuta cada herramienta sin preguntar. Se ofrece solo en la
    /// ventana Normal, tras una confirmación, y nunca forma parte del ciclo de Mayús+Tab.
    /// </summary>
    public static readonly ChatRunMode Bypass = Of("bypassPermissions", "Bypass");

    public static IReadOnlyList<ChatRunMode> Choices(ChatProvider provider) => provider switch
    {
        ChatProvider.Codex => [Of("default", "Normal"), Of("plan", "Plan"), Of("auto", "Auto")],
        ChatProvider.Claude => [Of("manual", "Manual"), Of("plan", "Plan"), Of("auto", "Auto"), Of("acceptEdits", "Aceptar ediciones"), Of("dontAsk", "Sin preguntas")],
        ChatProvider.OpenCode => [],
        ChatProvider.Stellar => [Of("manual", "Manual"), Of("acceptEdits", "Aceptar ediciones"), Of("auto", "Auto")],
        ChatProvider.Antigravity => [Of("plan", "Plan"), Of("accept-edits", "Aceptar ediciones"), Of("auto", "Auto")],
        ChatProvider.Qoder => [Of("manual", "Manual"), Of("plan", "Plan"), Of("acceptEdits", "Aceptar ediciones"), Of("auto", "Auto"), Of("dontAsk", "Sin preguntas")],
        _ => throw new ArgumentOutOfRangeException(nameof(provider))
    };

    private static ChatRunMode Of(string id, string title) => new() { Id = id, Title = title };
}

// Eventos de un proveedor. En Swift eran casos de un enum con valores asociados; aquí, records que heredan de ChatEvent.
public abstract record ChatEvent;
public sealed record SessionEvent(string SessionId) : ChatEvent;
public sealed record TextEvent(string Id, string Text, bool Replace) : ChatEvent;
public sealed record ToolEvent(string Id, string Title, string Detail, string Status) : ChatEvent;
public sealed record ReasoningEvent(string Id, string Text, bool Replace) : ChatEvent;
public sealed record ToolOutputEvent(string Id, string Text) : ChatEvent;
public sealed record UsageEvent(ProviderUsage Usage) : ChatEvent;
public sealed record TokensEvent(ChatTokenUsage Usage) : ChatEvent;
/// <summary>Tokens en la ventana de contexto tras la última petición; cualquiera de los dos valores puede ser desconocido.</summary>
public sealed record ContextEvent(int? Used, int? Window) : ChatEvent;
public sealed record CommandsEvent(IReadOnlyList<ChatCommand> Commands) : ChatEvent;
public sealed record SuggestionEvent(string Text) : ChatEvent;
public sealed record ApprovalEvent(ChatApproval Approval) : ChatEvent;
public sealed record ApprovalResolvedEvent(string Id) : ChatEvent;
/// <summary>El agente cambió su propio modo de permisos, p. ej. tras aprobar un plan del usuario.</summary>
public sealed record ModeEvent(string Mode) : ChatEvent;
/// <summary>El agente leyó un mensaje en cola; <c>Text</c> es lo que recibió.</summary>
public sealed record DeliveredEvent(string Id, string Text) : ChatEvent;
public sealed record CompletedEvent : ChatEvent;
public sealed record FailureEvent(string Message) : ChatEvent;

public sealed record UsageWindow
{
    public required string Id { get; set; }
    public required string Title { get; set; }
    public double? UsedPercent { get; set; }
    public DateTime? ResetsAt { get; set; }
    public DateTime ObservedAt { get; set; } = DateTime.UtcNow;

    [JsonIgnore]
    public double? RemainingPercent
    {
        get
        {
            if (ResetsAt is { } resetsAt && resetsAt <= DateTime.UtcNow) return null;
            if (UsedPercent is not { } used) return null;
            return Math.Max(0, Math.Min(100, 100 - used));
        }
    }
}

public sealed record ProviderUsage
{
    public required ChatProvider Provider { get; set; }
    public List<UsageWindow> Windows { get; set; } = [];
    public string Note { get; set; } = "";
    public bool IsCached { get; set; }
}

public sealed record ChatTokenUsage
{
    public int Input { get; set; }
    public int Output { get; set; }
    public int Cached { get; set; }
    public int Reasoning { get; set; }
    [JsonPropertyName("costUSD")]
    public double? CostUsd { get; set; }
}

public sealed record ChatContextUsage
{
    public required int Used { get; set; }
    public int? Window { get; set; }

    [JsonIgnore]
    public double? Fraction
    {
        get
        {
            if (Window is not int window || window <= 0) return null;
            return Math.Min(1.0, (double)Used / window);
        }
    }
}

/// <summary>Comando de barra que el proveedor ejecuta por sí mismo, como <c>/compact</c> o una skill.</summary>
public sealed record ChatCommand
{
    public required string Name { get; set; }
    public string Description { get; set; } = "";
    public string ArgumentHint { get; set; } = "";

    [JsonIgnore]
    public string Id => Name;

    /// <summary>Separa <c>/nombre argumentos</c> en sus partes; cualquier otra cosa es un prompt normal.</summary>
    public static (string Name, string Arguments)? Parse(string prompt)
    {
        if (!prompt.StartsWith('/')) return null;
        var body = prompt[1..];
        var nameLength = 0;
        while (nameLength < body.Length && !char.IsWhiteSpace(body[nameLength])) nameLength++;
        var name = body[..nameLength];
        if (name.Length == 0 || name.Contains('/')) return null;
        return (name, body[nameLength..].Trim());
    }
}

/// <summary>
/// Protocolo del controlador de un agente (<c>ChatDriver</c> en Swift; ahí solo estaba disponible en macOS).
/// Los métodos con valor por defecto son las implementaciones de la extensión Swift.
/// </summary>
public interface IChatDriver
{
    Task RunAsync(ChatConversation conversation, string prompt, Action<ChatEvent> onEvent);

    /// <summary>Ejecuta un turno con las herramientas de delegación de Jack, para los proveedores que las admiten.</summary>
    // TODO(port): ChatDelegation viene de AgentBridge.swift.
    Task RunAsync(ChatConversation conversation, string prompt, ChatDelegation? delegation, Action<ChatEvent> onEvent) =>
        RunAsync(conversation, prompt, onEvent);

    Task RespondAsync(string approvalId, bool allow);

    /// <summary>Responde con una de las <c>Choices</c> de la aprobación, "allow" o "deny"; <paramref name="message"/> indica al agente por qué se rechazó.</summary>
    Task RespondAsync(string approvalId, string choice, string? message) =>
        RespondAsync(approvalId, choice != "deny");

    Task AnswerAsync(string approvalId, IReadOnlyDictionary<string, string> answers) =>
        Task.FromException(new NotSupportedException("Este proveedor no admite preguntas interactivas."));

    /// <summary>Termina el turno actual; los controladores que mantienen vivo a su agente lo interrumpen en lugar de terminar el proceso.</summary>
    void Stop();

    /// <summary>El proceso del agente sobrevive a cada turno: el controlador se reutiliza y el agente puede iniciar turnos por sí mismo.</summary>
    bool KeepsAlive => false;

    /// <summary>Un controlador de un solo uso detenido sigue ocupando su hueco hasta que el protocolo confirma la interrupción.</summary>
    bool AwaitsStopAcknowledgement => false;

    /// <summary><paramref name="idle"/> recibe eventos entre turnos; <paramref name="unprompted"/> se llama cuando el agente inicia un turno por sí mismo, que consume <see cref="FollowAsync"/>.</summary>
    void Observe(Action<ChatEvent> idle, Action unprompted) { }

    Task FollowAsync(Action<ChatEvent> onEvent) => Task.CompletedTask;

    /// <summary>Entrega al agente un mensaje para leer al terminar su paso actual; <see cref="DeliveredEvent"/> avisa cuando lo hace. Devuelve false si el controlador no puede.</summary>
    bool Inject(ChatQueuedMessage message, ChatConversation conversation) => false;

    /// <summary>Retira un mensaje entregado con <see cref="Inject"/>. Devuelve false si el agente ya lo leyó.</summary>
    Task<bool> WithdrawAsync(string messageId) => Task.FromResult(false);

    /// <summary>Si el agente aún tiene este mensaje sin leer.</summary>
    bool IsQueued(string messageId) => false;

    /// <summary>Interrumpe el turno; con <paramref name="keepingQueued"/> el agente lee después sus mensajes en cola en lugar de descartarlos.</summary>
    void Stop(bool keepingQueued) => Stop();

    /// <summary>Cambia el modo de permisos, incluso a mitad de un turno. Devuelve false si el controlador no puede.</summary>
    bool SetMode(string mode) => false;

    /// <summary>Termina el proceso del agente.</summary>
    void Close() => Stop();

    /// <summary>Solo Light cambia la vida en reposo; el trabajo pendiente o en segundo plano debe seguir vivo.</summary>
    void SetEnergySaving(bool enabled) { }
}

/// <summary>Comandos locales de Jack; los comandos de barra del proveedor conservan su propio enrutado.</summary>
public sealed record JackContextSettings
{
    public string? Seed { get; set; }
    public bool? SeedDelivered { get; set; }
    public List<string> Pinned { get; set; } = [];
    public int? AutoThreshold { get; set; }
    public int? AutoTarget { get; set; }
    public int? Budget { get; set; }
    public int Spent { get; set; }
    public bool BudgetWarned { get; set; }
}

public sealed record JackCommandTemplate
{
    public required string Name { get; set; }
    public required string Prompt { get; set; }
}

public static class JackCommandCatalog
{
    public static IReadOnlyList<ChatCommand> Builtins { get; } =
    [
        Command("btw", "Pregunta al margen sin interrumpir al agente ni entrar en su historial (⌥↩)", "pregunta"),
        Command("compact", "Reduce el contexto mediante un resumen; conserva el historial", "8000"),
        Command("autocompact", "Compacta antes del siguiente mensaje al superar el umbral", "30000 8000 | off"),
        Command("contexto", "Muestra contexto y presupuesto"),
        Command("fijar", "Conserva instrucciones en futuras sesiones", "texto | listar | quitar número"),
        Command("resumen", "Resume decisiones, avances y pendientes"),
        Command("checkpoint", "Guarda una copia o restaura en otra conversación", "nombre | restaurar nombre"),
        Command("rama", "Crea una conversación independiente con el contexto actual", "nombre"),
        Command("traspasar", "Prepara un resumen para otro modelo o proveedor", "codex | claude | opencode (opcional)"),
        Command("plan", "Activa Plan y prepara la tarea", "tarea"),
        Command("revisar", "Revisa los cambios del proyecto", "instrucciones opcionales"),
        Command("presupuesto", "Avisa al acercarse al presupuesto de tokens", "20000 | off"),
        Command("comandos", "Lista, crea o elimina plantillas personales", "crear nombre texto | eliminar nombre"),
        Command("mod", "Crea, instala o lista mods con el agente de código", "crear descripción | instalar ruta.json | listar")
    ];

    public static IReadOnlyList<JackCommandTemplate> Defaults { get; } =
    [
        Template("revisar-pr", "Revisa los cambios actuales como una pull request: errores, regresiones y pruebas que faltan. No modifiques archivos. {{args}}"),
        Template("documentar", "Documenta los cambios actuales siguiendo el estilo del proyecto. {{args}}"),
        Template("preparar-release", "Prepara una propuesta de notas de versión y una lista de pasos para publicar; no publiques ni despliegues. {{args}}")
    ];

    /// <summary>Un comando Jack empieza por <c>!</c> (no <c>!!</c>); el nombre se pasa a minúsculas.</summary>
    public static (string Name, string Arguments)? Parse(string text)
    {
        if (!text.StartsWith('!') || text.StartsWith("!!", StringComparison.Ordinal)) return null;
        var body = text[1..];
        var nameLength = 0;
        while (nameLength < body.Length && !char.IsWhiteSpace(body[nameLength])) nameLength++;
        var name = body[..nameLength];
        return (name.ToLowerInvariant(), body[nameLength..].Trim());
    }

    /// <summary>Estimación aproximada: un token por cada cuatro bytes UTF-8, con mínimo 1.</summary>
    public static int EstimatedTokens(string text) => Math.Max(1, (Encoding.UTF8.GetByteCount(text) + 3) / 4);

    private static ChatCommand Command(string name, string description, string argumentHint = "") =>
        new() { Name = name, Description = description, ArgumentHint = argumentHint };

    private static JackCommandTemplate Template(string name, string prompt) => new() { Name = name, Prompt = prompt };
}

/// <summary>Fechas con el Codable por defecto de Swift: segundos desde el 1-1-2001 UTC.</summary>
internal sealed class ChatDateConverter : JsonConverter<DateTime>
{
    private static readonly DateTime ReferenceDate = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        ReferenceDate.AddSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
        writer.WriteNumberValue((value.ToUniversalTime() - ReferenceDate).TotalSeconds);
}

/// <summary>UUID como en Swift: texto en mayúsculas.</summary>
internal sealed class ChatGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString() ?? throw new JsonException("El UUID no puede estar vacío."));

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>Opciones JSON compatibles con el formato Codable de Swift para los modelos de chat.</summary>
public static class ChatJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            // Swift omite las propiedades opcionales en nil (encodeIfPresent).
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };
        options.Converters.Add(new JsonStringEnumConverter());
        options.Converters.Add(new ChatDateConverter());
        options.Converters.Add(new ChatGuidConverter());
        return options;
    }
}
