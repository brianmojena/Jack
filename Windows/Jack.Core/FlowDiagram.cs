using System.ComponentModel;
using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jack.Core;

/// Diagrama de flujo generado a partir de una pregunta del usuario. Codable en Swift: aquí, System.Text.Json con las mismas claves.
public sealed record FlowDiagram
{
    public enum Kind { Start, Process, Decision, End }

    public sealed record Node
    {
        public Node() { }

        [SetsRequiredMembers]
        public Node(string id, string label, Kind kind)
        {
            Id = id;
            Label = label;
            Kind = kind;
        }

        public required string Id { get; set; }
        public required string Label { get; set; }
        public required Kind Kind { get; set; }
    }

    public sealed record Edge
    {
        public Edge() { }

        [SetsRequiredMembers]
        public Edge(string from, string to, string? label = null)
        {
            From = from;
            To = to;
            Label = label;
        }

        /// Calculado, no se serializa (como en Swift, donde `id` no es una propiedad almacenada).
        [JsonIgnore]
        public string Id => $"{From}>{To}:{Label ?? ""}";

        public required string From { get; set; }
        public required string To { get; set; }
        public string? Label { get; set; }
    }

    public FlowDiagram() { }

    [SetsRequiredMembers]
    public FlowDiagram(string title, List<Node> nodes, List<Edge> edges)
    {
        Title = title;
        Nodes = nodes;
        Edges = edges;
    }

    public required string Title { get; set; }
    public required List<Node> Nodes { get; set; }
    public required List<Edge> Edges { get; set; }

    public const int MaxResponseBytes = 24_000;
    public const int MaxNodes = 24;
    public const int MaxEdges = 48;

    private static readonly JsonSerializerOptions DecodingOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };

    public static FlowDiagram Parse(string response)
    {
        if (Encoding.UTF8.GetByteCount(response) > MaxResponseBytes) throw new FlowDiagramException(FlowDiagramError.OutputTooLarge);
        var text = response.Trim();
        string json;
        if (text.StartsWith("```", StringComparison.Ordinal))
        {
            var firstNewline = text.IndexOf('\n');
            var fence = text.LastIndexOf("```", StringComparison.Ordinal);
            if (firstNewline < 0 || fence < 0 || fence <= firstNewline) throw new FlowDiagramException(FlowDiagramError.InvalidJSON);
            json = text[(firstNewline + 1)..fence].Trim();
        }
        else
        {
            json = text;
        }

        FlowDiagram? diagram;
        try
        {
            diagram = JsonSerializer.Deserialize<FlowDiagram>(json, DecodingOptions);
        }
        catch (JsonException)
        {
            throw new FlowDiagramException(FlowDiagramError.InvalidJSON);
        }
        // Las propiedades `required` no se comprueban con nulos explícitos: `null` en JSON llegaría como nulo real.
        if (diagram is null
            || diagram.Title is null
            || diagram.Nodes is null
            || diagram.Edges is null
            || diagram.Nodes.Any(node => node is null || node.Id is null || node.Label is null)
            || diagram.Edges.Any(edge => edge is null || edge.From is null || edge.To is null))
        {
            throw new FlowDiagramException(FlowDiagramError.InvalidJSON);
        }
        diagram.Validate();
        return diagram;
    }

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Title)
            || Encoding.UTF8.GetByteCount(Title) > 160
            || !HasNoControlCharacters(Title)
            || Nodes.Count < 3 || Nodes.Count > MaxNodes
            || Edges.Count < 2 || Edges.Count > MaxEdges)
        {
            throw Invalid();
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in Nodes)
        {
            if (!ValidID(node.Id)
                || !ids.Add(node.Id)
                || string.IsNullOrWhiteSpace(node.Label)
                || Encoding.UTF8.GetByteCount(node.Label) > 180
                || !HasNoForbiddenTextControls(node.Label))
            {
                throw Invalid();
            }
        }
        if (Nodes.Count(node => node.Kind == Kind.Start) != 1 || !Nodes.Any(node => node.Kind == Kind.End)) throw Invalid();

        var byId = Nodes.ToDictionary(node => node.Id, StringComparer.Ordinal);
        var edgeIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var edge in Edges)
        {
            if (!byId.ContainsKey(edge.From)
                || !byId.ContainsKey(edge.To)
                || (edge.Label is { } label && (Encoding.UTF8.GetByteCount(label) > 100 || !HasNoForbiddenTextControls(label)))
                || !edgeIds.Add(edge.Id))
            {
                throw Invalid();
            }
        }

        var start = Nodes.First(node => node.Kind == Kind.Start).Id;
        if (Edges.Any(edge => edge.To == start) || Edges.Any(edge => byId[edge.From].Kind == Kind.End)) throw Invalid();

        foreach (var decision in Nodes.Where(node => node.Kind == Kind.Decision))
        {
            var branches = Edges.Where(edge => edge.From == decision.Id).ToList();
            var labels = branches
                .Where(edge => edge.Label is not null)
                .Select(edge => edge.Label!.Trim().ToLowerInvariant())
                .ToList();
            if (branches.Count < 2
                || labels.Count != branches.Count
                || labels.Any(label => label.Length == 0)
                || labels.Distinct(StringComparer.Ordinal).Count() < 2
                || branches.Select(branch => branch.To).Distinct(StringComparer.Ordinal).Count() < 2)
            {
                throw Invalid();
            }
        }

        var adjacency = Edges
            .GroupBy(edge => edge.From)
            .ToDictionary(group => group.Key, group => group.Select(edge => edge.To).ToList(), StringComparer.Ordinal);
        var reverse = Edges
            .GroupBy(edge => edge.To)
            .ToDictionary(group => group.Key, group => group.Select(edge => edge.From).ToList(), StringComparer.Ordinal);
        var ends = Nodes.Where(node => node.Kind == Kind.End).Select(node => node.Id).ToList();
        var canReachEnd = new HashSet<string>(StringComparer.Ordinal);
        foreach (var end in ends) canReachEnd.UnionWith(Reachable(end, reverse));
        if (!Reachable(start, adjacency).SetEquals(ids) || !canReachEnd.SetEquals(ids)) throw Invalid();
    }

    /// Vista en capas por anchura. Las aristas que vuelven a capas anteriores se conservan como bucles en Mermaid y en la vista nativa.
    public IReadOnlyList<IReadOnlyList<Node>> Layers
    {
        get
        {
            var start = Nodes.FirstOrDefault(node => node.Kind == Kind.Start);
            if (start is null) return [Nodes.ToList()];
            var adjacency = Edges
                .GroupBy(edge => edge.From)
                .ToDictionary(group => group.Key, group => group.Select(edge => edge.To).ToList(), StringComparer.Ordinal);
            var depth = new Dictionary<string, int>(StringComparer.Ordinal) { [start.Id] = 0 };
            var queue = new Queue<string>();
            queue.Enqueue(start.Id);
            while (queue.Count > 0)
            {
                var id = queue.Dequeue();
                if (!adjacency.TryGetValue(id, out var targets)) continue;
                foreach (var target in targets)
                {
                    if (depth.ContainsKey(target)) continue;
                    depth[target] = depth[id] + 1;
                    queue.Enqueue(target);
                }
            }
            var maxDepth = depth.Values.DefaultIfEmpty(0).Max();
            var layers = new List<IReadOnlyList<Node>>();
            for (var layer = 0; layer <= maxDepth; layer++)
            {
                layers.Add(Nodes.Where(node => depth.TryGetValue(node.Id, out var nodeDepth) && nodeDepth == layer).ToList());
            }
            return layers;
        }
    }

    public string Mermaid
    {
        get
        {
            var lines = new List<string> { "flowchart TD", $"%% {MermaidText(Title)}" };
            var safeIds = Nodes
                .Select((node, index) => (node.Id, Safe: $"n{index}"))
                .ToDictionary(pair => pair.Id, pair => pair.Safe, StringComparer.Ordinal);
            foreach (var node in Nodes)
            {
                var label = MermaidText(node.Label);
                var id = safeIds[node.Id];
                lines.Add(node.Kind switch
                {
                    Kind.Start or Kind.End => $"    {id}([\"{label}\"])",
                    Kind.Process => $"    {id}[\"{label}\"]",
                    _ => $"    {id}{{\"{label}\"}}",
                });
            }
            foreach (var edge in Edges)
            {
                var fromId = safeIds[edge.From];
                var toId = safeIds[edge.To];
                lines.Add(edge.Label is { Length: > 0 } label
                    ? $"    {fromId} -->|\"{MermaidText(label)}\"| {toId}"
                    : $"    {fromId} --> {toId}");
            }
            return string.Join("\n", lines);
        }
    }

    private static bool ValidID(string value) =>
        value.Length > 0
        && Encoding.UTF8.GetByteCount(value) <= 32
        && value.All(character => character is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '_');

    private static bool IsControl(Rune rune)
    {
        var category = Rune.GetUnicodeCategory(rune);
        return category is UnicodeCategory.Control or UnicodeCategory.Format;
    }

    private static bool HasNoControlCharacters(string value) => !value.EnumerateRunes().Any(IsControl);

    private static bool HasNoForbiddenTextControls(string value) =>
        !value.EnumerateRunes().Any(rune => IsControl(rune) && rune.Value != '\n' && rune.Value != '\r');

    private static HashSet<string> Reachable(string start, IReadOnlyDictionary<string, List<string>> adjacency)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal) { start };
        var queue = new Queue<string>();
        queue.Enqueue(start);
        while (queue.Count > 0)
        {
            var node = queue.Dequeue();
            if (!adjacency.TryGetValue(node, out var next)) continue;
            foreach (var candidate in next)
            {
                if (seen.Add(candidate)) queue.Enqueue(candidate);
            }
        }
        return seen;
    }

    private static string MermaidText(string raw)
    {
        var builder = new StringBuilder(raw.Length);
        foreach (var character in raw)
        {
            builder.Append(character switch
            {
                '\n' or '\r' => " ",
                '"' => "#quot;",
                '#' => "#35;",
                '&' => "#38;",
                '<' => "#60;",
                '>' => "#62;",
                '[' => "#91;",
                ']' => "#93;",
                '{' => "#123;",
                '}' => "#125;",
                '\\' => "#92;",
                '`' => "#96;",
                '|' => "#124;",
                _ => character.ToString(),
            });
        }
        return builder.ToString();
    }

    private static FlowDiagramException Invalid() => new(FlowDiagramError.InvalidGraph);
}

/// Capas de arriba abajo, con carriles de retorno ortogonales a la izquierda de cada nodo.
public sealed class FlowDiagramLayout
{
    public readonly record struct Point(double X, double Y);

    public readonly record struct Frame(double X, double Y, double Width, double Height)
    {
        public double MaxX => X + Width;
        public double MaxY => Y + Height;
        public double MidX => X + Width / 2;
        public double MidY => Y + Height / 2;
    }

    public sealed record EdgeRoute(IReadOnlyList<Point> Points, Point LabelPoint);

    public IReadOnlyDictionary<string, Frame> Frames { get; }
    public IReadOnlyDictionary<string, EdgeRoute> ReturnRoutes { get; }
    public (double Width, double Height) Size { get; }

    public FlowDiagramLayout(FlowDiagram graph, double nodeWidth = 224, double nodeHeight = 82, double columnGap = 52, double rowGap = 96, double laneGap = 24)
    {
        var layers = graph.Layers;
        var rows = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var row = 0; row < layers.Count; row++)
        {
            foreach (var node in layers[row]) rows[node.Id] = row;
        }
        int RowOf(string id) => rows.TryGetValue(id, out var row) ? row : 0;

        var returns = graph.Edges.Where(edge => RowOf(edge.To) <= RowOf(edge.From)).ToList();
        var left = 24 + returns.Count * laneGap;
        var columnCount = Math.Max(1, layers.Select(layer => layer.Count).DefaultIfEmpty(1).Max());

        var frames = new Dictionary<string, Frame>(StringComparer.Ordinal);
        for (var row = 0; row < layers.Count; row++)
        {
            var nodes = layers[row];
            var offset = (columnCount - nodes.Count) * (nodeWidth + columnGap) / 2;
            for (var column = 0; column < nodes.Count; column++)
            {
                frames[nodes[column].Id] = new Frame(
                    left + offset + column * (nodeWidth + columnGap),
                    24 + row * (nodeHeight + rowGap),
                    nodeWidth,
                    nodeHeight);
            }
        }

        var routes = new Dictionary<string, EdgeRoute>(StringComparer.Ordinal);
        for (var index = 0; index < returns.Count; index++)
        {
            var edge = returns[index];
            if (!frames.TryGetValue(edge.From, out var source) || !frames.TryGetValue(edge.To, out var target)) continue;
            var laneX = 12 + index * laneGap;
            var bottomPort = source.MaxY + 18;
            var topPort = target.Y - 18;
            var points = new List<Point>
            {
                new(source.MidX, source.MaxY),
                new(source.MidX, bottomPort),
                new(laneX, bottomPort),
                new(laneX, topPort),
                new(target.MidX, topPort),
                new(target.MidX, target.Y),
            };
            routes[edge.Id] = new EdgeRoute(points, new Point(laneX, (bottomPort + topPort) / 2));
        }

        Frames = frames;
        ReturnRoutes = routes;
        Size = (
            left + columnCount * (nodeWidth + columnGap) - columnGap + 24,
            24 + Math.Max(1, layers.Count) * (nodeHeight + rowGap) - rowGap + 24);
    }
}

public enum FlowDiagramError
{
    InvalidJSON,
    InvalidGraph,
    InvalidQuestion,
    OutputTooLarge,
    RequestTooLarge,
    RepairTooLarge,
    Timeout,
    Cancelled,
    CloudOnly,
    Authentication,
    CloudUnavailable,
}

public static class FlowDiagramErrorMessages
{
    /// Texto que se muestra al usuario para cada error.
    public static string Description(this FlowDiagramError error) => error switch
    {
        FlowDiagramError.InvalidJSON => "La respuesta no era un JSON válido de diagrama. Puedes reintentar.",
        FlowDiagramError.InvalidGraph => "El modelo devolvió un diagrama incompleto o con conexiones inválidas. Puedes reintentar.",
        FlowDiagramError.InvalidQuestion => "Escribe una pregunta de hasta 4.000 bytes para generar el diagrama.",
        FlowDiagramError.OutputTooLarge => "La respuesta del modelo superó el límite de tamaño del diagrama. Prueba una pregunta más concreta.",
        FlowDiagramError.RequestTooLarge => "La pregunta y las instrucciones ocupan más que la ventana disponible del modelo. Acorta la pregunta e inténtalo de nuevo.",
        FlowDiagramError.RepairTooLarge => "La respuesta inválida y el contexto no caben juntos en la ventana del modelo para repararla. Regenera con una pregunta más concreta.",
        FlowDiagramError.Timeout => "Ollama Cloud tardó demasiado en generar el diagrama. Puedes reintentar.",
        FlowDiagramError.Cancelled => "La generación se canceló al cambiar el modo o cerrar la conversación.",
        FlowDiagramError.CloudOnly => "Elige un modelo de Ollama Cloud validado para generar diagramas.",
        FlowDiagramError.Authentication => "Ollama no autorizó la solicitud. Abre Ollama e inicia sesión con `ollama signin`.",
        FlowDiagramError.CloudUnavailable => "Ollama Cloud no está disponible. Revisa tu cuenta, conexión y cuota, y vuelve a intentarlo.",
        _ => "Error desconocido al generar el diagrama.",
    };
}

/// Error de generación de diagramas. El mensaje es el texto que se muestra al usuario.
public sealed class FlowDiagramException(FlowDiagramError error) : Exception(error.Description())
{
    public FlowDiagramError Error { get; } = error;
}

public sealed record FlowDiagramContextMessage(string Role, string Content);

public static class FlowDiagramContext
{
    public const int MaxBytes = 6_000;
    public const int MaxMessages = 8;

    // TODO(port): la versión de Swift recibe [ChatMessage] (ChatModels.swift) y usa message.role/message.text.
    // Quien llame debe convertir cada mensaje a FlowDiagramContextMessage(role, text) en el mismo orden.
    /// Los mensajes visibles más recientes (usuario y asistente), en orden cronológico, sin pasar de `maxBytes` en total.
    public static List<FlowDiagramContextMessage> RecentVisible(IReadOnlyList<FlowDiagramContextMessage> messages, int maxBytes = MaxBytes)
    {
        var remaining = Math.Max(0, maxBytes);
        var collected = new List<FlowDiagramContextMessage>();
        for (var index = messages.Count - 1; index >= 0; index--)
        {
            var message = messages[index];
            if (message.Role is not ("user" or "assistant") || message.Content.Length == 0) continue;
            if (remaining <= 0 || collected.Count >= MaxMessages) break;
            var content = PrefixUtf8(message.Content, remaining);
            if (content.Length == 0) continue;
            collected.Add(new FlowDiagramContextMessage(message.Role, content));
            remaining -= Encoding.UTF8.GetByteCount(content);
        }
        collected.Reverse();
        return collected;
    }

    // TODO(port): StellarTools.prefixUTF8 viene de StellarCode.swift. Copia local hasta portar StellarTools;
    // Swift recorre Characters (grafemas) y aquí se recorren runas Unicode.
    /// El prefijo de `value` que cabe en `bytes` bytes UTF-8, sin cortar ningún carácter a la mitad.
    public static string PrefixUtf8(string value, int bytes)
    {
        var builder = new StringBuilder();
        var used = 0;
        foreach (var rune in value.EnumerateRunes())
        {
            var size = rune.Utf8SequenceLength;
            if (used + size > bytes) break;
            builder.Append(rune.ToString());
            used += size;
        }
        return builder.ToString();
    }
}

/// Función que genera un diagrama para una pregunta. Sustituye a FlowDiagramService.generate hasta portar el módulo Stellar.
public delegate Task<FlowDiagram> FlowDiagramGenerate(
    string modelID,
    string question,
    IReadOnlyList<FlowDiagramContextMessage> context,
    Func<bool> allowed,
    CancellationToken cancellation);

public sealed class FlowDiagramService
{
    public const int MaxQuestionBytes = 4_000;
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(50);

    // TODO(port): FlowDiagramService.generate y su flujo generateChecked/request/repair dependen de
    // StellarModel, StellarServer, StellarMessage, StellarChunk, StellarModels, StellarClient (StellarOllama.swift).
    // Pendiente de portar el módulo Stellar. Lo que ya está aquí: presupuestos de contexto, prompts y mapeo de errores.

    /// Instrucción de reparación cuando la primera respuesta no pasa la validación.
    public const string RepairInstruction = "La respuesta anterior falló la validación JSON del diagrama (esquema y estructura del grafo). Corrige el JSON para cumplir el esquema original, con IDs únicos, referencias válidas, inicio y finales alcanzables, y ramas de decisión etiquetadas a destinos distintos. Devuelve solo el JSON; no añadas hechos ni cambies la intención.";

    /// Prompt del sistema. El parámetro `language` se conserva como en Swift, aunque el texto no lo usa.
    public static string SystemPrompt(string language) => """
You generate a flow diagram for the user's explicit question. Reply in the same language as that question. Use only the question and visible conversation context supplied; you have no repository or file access and must not invent repository facts. Return only JSON with this schema: {"title":"...","nodes":[{"id":"start","label":"...","kind":"start|process|decision|end"}],"edges":[{"from":"start","to":"step1","label":"optional branch label"}]}. Include exactly one start and at least one end, concise process nodes, and edges that represent the real order, branches, and loops. Each decision must have at least two distinct, labeled outgoing branches to distinct destinations. Preserve meaningful loops. Keep every node reachable from start and able to reach at least one end. Use 3–24 nodes and at most 48 edges. Node IDs may contain only ASCII letters, digits, and underscore. Do not add Markdown fences or commentary.
""";

    /// Bytes de contexto que caben tras reservar tokens para la respuesta y la pregunta.
    public static int ContextBudget(int contextLength, int questionBytes)
    {
        var reservedTokens = Math.Min(3_000, Math.Max(800, contextLength / 4));
        return Math.Max(0, Math.Min(FlowDiagramContext.MaxBytes, (contextLength - reservedTokens) * 3 - questionBytes - 1_500));
    }

    /// Bytes máximos de la entrada completa (sistema, contexto y pregunta).
    public static int MaxInputBytes(int contextLength) => Math.Max(0, (contextLength - 800) * 3);

    /// Mensajes más recientes (usuario y asistente, hasta ocho) que caben en `limit` bytes, en orden cronológico.
    public static List<FlowDiagramContextMessage> BoundContext(IEnumerable<FlowDiagramContextMessage> context, int limit)
    {
        var remaining = Math.Max(0, limit);
        var result = new List<FlowDiagramContextMessage>();
        var visible = context.Where(message => message.Role is "user" or "assistant").TakeLast(FlowDiagramContext.MaxMessages).ToList();
        for (var index = visible.Count - 1; index >= 0 && remaining > 0; index--)
        {
            var content = FlowDiagramContext.PrefixUtf8(visible[index].Content, remaining);
            if (content.Length == 0) continue;
            result.Add(new FlowDiagramContextMessage(visible[index].Role, content));
            remaining -= Encoding.UTF8.GetByteCount(content);
        }
        result.Reverse();
        return result;
    }

    /// Bytes que ocupan los mensajes en la petición (rol y contenido, más 12 de sobrecarga por mensaje).
    public static int MessageBytes(IEnumerable<FlowDiagramContextMessage> messages) =>
        messages.Sum(message => Encoding.UTF8.GetByteCount(message.Role) + Encoding.UTF8.GetByteCount(message.Content) + 12);

    /// Traduce un error de red o de servicio al error que ve el usuario. Las llamadas canceladas son `Cancelled`.
    public static FlowDiagramException Normalize(Exception error)
    {
        if (error is FlowDiagramException known) return known;
        if (error is OperationCanceledException) return new FlowDiagramException(FlowDiagramError.Cancelled);
        return new FlowDiagramException(SafeError(error));
    }

    internal static FlowDiagramError SafeError(Exception error)
    {
        // Equivalente a los códigos de URLError de Swift: sin conexión, host no encontrado, tiempo agotado, conexión perdida.
        if (error is HttpRequestException or SocketException or TimeoutException) return FlowDiagramError.CloudUnavailable;
        var detail = error.Message.ToLowerInvariant();
        if (new[] { "401", "403", "unauthorized", "authentication", "not signed in", "signin" }.Any(detail.Contains))
            return FlowDiagramError.Authentication;
        if (new[] { "quota", "rate limit", "usage limit", "insufficient balance" }.Any(detail.Contains))
            return FlowDiagramError.CloudUnavailable;
        if (new[] { "404", "not found", "no such model", "does not exist" }.Any(detail.Contains))
            return FlowDiagramError.CloudOnly;
        return FlowDiagramError.CloudUnavailable;
    }
}

/// Estado de la vista de diagramas. Notifica cambios con INotifyPropertyChanged, sin dependencias de UI.
/// Las continuaciones de las tareas no vuelven al hilo de la interfaz: la capa de UI debe despachar al suyo.
public sealed class FlowDiagramState : INotifyPropertyChanged
{
    private string question = "";
    private string selectedModelID = "";
    private FlowDiagram? graph;
    private string? graphQuestion;
    private bool isGenerating;
    private string? error;
    private Guid requestID = Guid.NewGuid();
    private CancellationTokenSource? cancellation;

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Question
    {
        get => question;
        set => SetField(ref question, value);
    }

    public string SelectedModelID
    {
        get => selectedModelID;
        set => SetField(ref selectedModelID, value);
    }

    public FlowDiagram? Graph
    {
        get => graph;
        private set => SetField(ref graph, value);
    }

    public string? GraphQuestion
    {
        get => graphQuestion;
        private set => SetField(ref graphQuestion, value);
    }

    public bool IsGenerating
    {
        get => isGenerating;
        private set => SetField(ref isGenerating, value);
    }

    public string? Error
    {
        get => error;
        private set => SetField(ref error, value);
    }

    public void Generate(string modelID, IReadOnlyList<FlowDiagramContextMessage> context, Func<bool> allowed, FlowDiagramGenerate generate)
    {
        if (IsGenerating) return;
        var currentQuestion = Question;
        var id = Guid.NewGuid();
        requestID = id;
        Error = null;
        IsGenerating = true;
        var source = new CancellationTokenSource();
        cancellation = source;
        _ = RunAsync(id, modelID, currentQuestion, context, allowed, generate, source.Token);
    }

    public void Cancel()
    {
        requestID = Guid.NewGuid();
        cancellation?.Cancel();
        cancellation = null;
        IsGenerating = false;
    }

    internal void Fail(string message)
    {
        Error = message;
    }

    private async Task RunAsync(
        Guid id,
        string modelID,
        string currentQuestion,
        IReadOnlyList<FlowDiagramContextMessage> context,
        Func<bool> allowed,
        FlowDiagramGenerate generate,
        CancellationToken token)
    {
        try
        {
            var result = await generate(modelID, currentQuestion, context, allowed, token);
            if (requestID != id) return;
            if (!allowed())
            {
                Cancel();
                return;
            }
            Graph = result;
            GraphQuestion = currentQuestion;
            IsGenerating = false;
        }
        catch (Exception failure)
        {
            if (requestID != id) return;
            IsGenerating = false;
            if (!token.IsCancellationRequested && allowed()) Error = FlowDiagramService.Normalize(failure).Message;
        }
    }

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
