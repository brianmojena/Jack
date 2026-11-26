using System.Globalization;
using System.Text.Json;

namespace Jack.Core;

// Port de Sources/JackCore/ChatStore.swift, líneas 28-260 (estado), init (259-286) y la parte de estado del modo Normal
// con Claude Code: uso de cuotas, creación, selección, transcripciones, renombrado, fijados, borrado y guardado.
//
// Convenciones:
//  * Cada campo privado tiene el nombre Swift con prefijo `_` (`queue` -> `_queue`).
//  * Cada @Published es una propiedad PascalCase. Las que se reasignan tienen setter privado que llama a Notify().
//    Las colecciones que Swift muta en sitio se exponen como vista de solo lectura; quien las modifique debe llamar
//    después a Notify(nameof(Propiedad)).
//  * Persistencia: ChatArchive es asíncrono. El índice se lee una vez en el constructor (como el init de Swift) con
//    Task.Run, para no bloquear el contexto de interfaz. Las transcripciones se leen en segundo plano y vuelven al
//    hilo de interfaz con RunOnUi. Los errores de escritura llegan a ErrorMessage.
//  * Guardar clona la conversación (y sus mensajes) antes de encolar la escritura: así una mutación posterior no
//    altera lo que se serializa, igual que el tipo por valor de Swift.
public sealed partial class ChatStore
{
    /// <summary>Longitud máxima de un título (Swift: prefix(120)).</summary>
    private const int TitleLimit = 120;

    /// <summary>Longitud máxima de la respuesta que devuelve <see cref="LastReplyOf"/> (Swift: prefix(24_000)).</summary>
    private const int ReplyLimit = 24_000;

    /// <summary>Chats que pueden fijarse a la vez.</summary>
    public const int MaxPinned = 5;

    // ===== Fuera de alcance: enganches pendientes (no portados en este archivo) =====
    // TODO(port): modo Light (lightModeEnabled, lightMaxConcurrent, lightWindowVisible, lightDetailsVisible, setLightMode,
    //   setLightConcurrency, setLightWindowVisible, setLightDetailsVisible, bufferLight) viene de ChatStore.swift:51-54 y 297-377.
    // TODO(port): modelos de Antigravity y Qoder (antigravityModels, qoderModels, sus tareas y errores) viene de ChatStore.swift:86-106 y 380-439.
    // TODO(port): Antigravity: terminal y propiedad de sesiones (claimAntigravitySessionForTerminal...) viene de ChatStore.swift:857-955.
    // TODO(port): Stellar, modelos locales y nube (localModels, loadingLocalModels, knownCloudModelIDs, linkedCloudModelIDs,
    //   loadStellarModels, inspectLinkedCloud*) viene de ChatStore.swift:40-42, 57-62 y 1283-1338.
    // TODO(port): Codex (codexModels) viene de ChatStore.swift:84.
    // TODO(port): colocación de agentes sin carpeta (locating, locateProject, locateDeadline, locateTasks, knownProjects)
    //   viene de ChatStore.swift:236-248 y 548-762.
    // TODO(port): SSH/remoto (ChatRemoteEndpoint en create, remoteServer, updateRemote) viene de ChatStore.swift:165-166, 521-522 y 1651-1658.
    // TODO(port): imágenes (imageRequests, endedImages, imageGenerationSupported, requestImage...) viene de ChatStore.swift:230-231 y 248-255, 1588-1613.
    // TODO(port): delegación (delegatedWaits, beginDelegatedWait/endDelegatedWait, bridge, delegationEnabled) viene de ChatStore.swift:162-164, 257 y 1937-1943.
    // TODO(port): monitores y bibliotecas (artifacts, notebooks, schedules, progress, servers, artifactRevealRequest) viene de ChatStore.swift:167-229.
    // TODO(port): asides y diagramas de flujo (asides, flowDiagramStates, makeFlowDiagramState) viene de ChatStore.swift:38-39 y 43-45.
    // TODO(port): mejora de nombres con IA (improvingChatNames, chatNameImprovementTask) viene de ChatStore.swift:46-47 y 1481-1565.
    // TODO(port): personalización (customization, customizationCenter, customTerminalCommandRequest) viene de ChatStore.swift:73-75 y 109-138.

    // ===== Estado publicado =====

    private List<ChatConversation> _conversations = new();

    /// <summary>
    /// Conversaciones; las nuevas van primero. Equivale a `conversations`. Es la lista viva del store: quien la modifique
    /// llama después a Notify(nameof(Conversations)).
    /// </summary>
    public List<ChatConversation> Conversations => _conversations;

    private Guid? _selectedID;

    /// <summary>Conversación seleccionada. Equivale a `selectedID`.</summary>
    public Guid? SelectedId
    {
        get => _selectedID;
        private set { _selectedID = value; Notify(); }
    }

    /// <summary>La conversación seleccionada, o null. Equivale a `selectedConversation`.</summary>
    public ChatConversation? SelectedConversation => _conversations.FirstOrDefault(conversation => conversation.Id == _selectedID);

    private readonly Dictionary<Guid, ChatStatus> _statuses = new();

    /// <summary>Estado de cada agente.</summary>
    public Dictionary<Guid, ChatStatus> Statuses => _statuses;

    private readonly Dictionary<Guid, List<ChatApproval>> _approvals = new();

    /// <summary>Aprobaciones pendientes por conversación.</summary>
    public Dictionary<Guid, List<ChatApproval>> Approvals => _approvals;

    private readonly Dictionary<Guid, List<ChatQueuedMessage>> _waiting = new();

    /// <summary>Mensajes escritos mientras el agente trabaja, hasta que los lee. Equivale a `waiting`.</summary>
    public Dictionary<Guid, List<ChatQueuedMessage>> Waiting => _waiting;

    private readonly Dictionary<Guid, ChatQueuedMessage> _recalled = new();

    /// <summary>Mensajes en espera que se recuperaron al detener al agente, para que el compositor los restaure.</summary>
    public Dictionary<Guid, ChatQueuedMessage> Recalled => _recalled;

    private readonly Dictionary<Guid, string> _suggestions = new();

    /// <summary>Sugerencia de respuesta por conversación.</summary>
    public Dictionary<Guid, string> Suggestions => _suggestions;

    // TODO(port): asides (ChatAsides) viene de ChatStore.swift:38-39; se declara en su pieza.

    private string? _errorMessage;

    /// <summary>Último error para mostrar al usuario. Equivale a `errorMessage`.</summary>
    public string? ErrorMessage
    {
        get => _errorMessage;
        private set { _errorMessage = value; Notify(); }
    }

    private int _maxConcurrent = 4;

    /// <summary>Límite de agentes que trabajan a la vez. Se guarda como "maxConcurrentAgents".</summary>
    public int MaxConcurrent
    {
        get => _maxConcurrent;
        private set { _maxConcurrent = value; Notify(); }
    }

    /// <summary>Límite efectivo: en el modo Normal es el mismo que <see cref="MaxConcurrent"/>.</summary>
    public int EffectiveMaxConcurrent => _maxConcurrent;

    /// <summary>Agentes con un turno en marcha. Equivale a `activeCount`.</summary>
    public int ActiveCount => _runs.Count;

    private readonly Dictionary<ChatProvider, ProviderUsage> _usage = new();

    /// <summary>Cuotas por proveedor. Hoy solo Claude Code se lee (ver TODO en ChatUsage).</summary>
    public Dictionary<ChatProvider, ProviderUsage> Usage => _usage;

    private readonly Dictionary<Guid, ChatTokenUsage> _tokenUsage = new();

    /// <summary>Tokens consumidos por conversación.</summary>
    public Dictionary<Guid, ChatTokenUsage> TokenUsage => _tokenUsage;

    private bool _refreshingUsage;

    /// <summary>Verdadero mientras se leen las cuotas. Equivale a `refreshingUsage`.</summary>
    public bool RefreshingUsage
    {
        get => _refreshingUsage;
        private set { _refreshingUsage = value; Notify(); }
    }

    private readonly Dictionary<ChatProvider, IReadOnlyList<string>> _recentModels = new();

    /// <summary>Modelos usados recientemente por proveedor. Se guarda como "recentModels.<proveedor>". Settings lo escribe y avisa.</summary>
    public Dictionary<ChatProvider, IReadOnlyList<string>> RecentModels => _recentModels;

    private readonly Dictionary<string, IReadOnlyList<ChatCommand>> _commands = new();

    /// <summary>Comandos de barra por proveedor y proyecto (clave "proveedor|proyecto"); la clave la forma Settings.</summary>
    public Dictionary<string, IReadOnlyList<ChatCommand>> Commands => _commands;

    private readonly HashSet<string> _loadingCommands = new();

    /// <summary>Claves cuyos comandos se están leyendo. Equivale a `loadingCommands`.</summary>
    public HashSet<string> LoadingCommands => _loadingCommands;

    private readonly Dictionary<string, string> _commandErrors = new();

    /// <summary>Por qué no se pudieron leer los comandos de una clave, hasta el siguiente intento.</summary>
    public Dictionary<string, string> CommandErrors => _commandErrors;

    private List<JackCommandTemplate> _jackTemplates = new();

    /// <summary>Plantillas de comandos de Jack (las predeterminadas más las de commands.json). Equivale a `jackTemplates`.</summary>
    public IReadOnlyList<JackCommandTemplate> JackTemplates
    {
        get => _jackTemplates;
        private set { _jackTemplates = value.ToList(); Notify(); }
    }

    private readonly HashSet<Guid> _readingClaudeHistory = new();

    /// <summary>Conversaciones importadas cuyo historial se está leyendo.</summary>
    public IReadOnlySet<Guid> ReadingClaudeHistory => _readingClaudeHistory;

    /// <summary>Lee el historial de una sesión de Claude Code; reemplazable en las comprobaciones (equivale a `readClaudeSession`).</summary>
    public Func<ClaudeSessionSummary, (IReadOnlyList<ChatMessage> Messages, string? Model)> ReadClaudeSession { get; set; } =
        session => ClaudeSessions.Load(session);

    /// <summary>Espera máxima para la lista de comandos de un proveedor (Swift: commandDeadline, 30 s).</summary>
    internal TimeSpan CommandDeadline { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Refresca el caché de cuotas de Claude ejecutando `/usage` en la CLI. Sin implementación, solo se lee el caché.
    /// TODO(port): la implementación de IClaudeUsageRefresher ejecuta `claude --print /usage` y depende de
    /// ExecutableResolver y StructuredChild (ChatProcess), que aún no están enlazados aquí.
    /// </summary>
    internal IClaudeUsageRefresher? ClaudeUsageRefresher { get; set; }

    // ===== Estado interno (campos Swift privados) =====

    private readonly ChatArchive _archive;
    private readonly IPreferences? _preferences;
    private readonly Func<ChatProvider, IChatDriver> _makeDriver;
    private readonly Func<ChatProvider, string, Task<IReadOnlyList<ChatCommand>>> _loadCommandList;

    /// <summary>Transcripciones ya cargadas en memoria.</summary>
    private readonly HashSet<Guid> _loaded = new();

    /// <summary>Agentes mostrados en paneles junto al seleccionado: su transcripción queda cargada.</summary>
    private HashSet<Guid> _paned = new();

    /// <summary>Transcripciones que se están leyendo: id -> si al terminar debe seleccionarse.</summary>
    private readonly Dictionary<Guid, bool> _loadingTranscripts = new();

    /// <summary>Sesiones de Claude Code tomadas por una terminal nativa.</summary>
    private readonly HashSet<Guid> _terminalClaudeSessions = new();

    /// <summary>Cola de mensajes esperando turno: (conversación, prompt).</summary>
    private List<(Guid Id, string Prompt)> _queue = new();

    /// <summary>Turnos en marcha por conversación.</summary>
    private readonly Dictionary<Guid, CancellationTokenSource> _runs = new();

    /// <summary>Generación de cada turno: los eventos y la limpieza pertenecen a un turno concreto.</summary>
    private readonly Dictionary<Guid, Guid> _runGenerations = new();

    /// <summary>Permisos ya resueltos en el turno: un evento duplicado no los vuelve a abrir.</summary>
    private readonly Dictionary<Guid, HashSet<string>> _resolvedApprovalIDs = new();

    /// <summary>Posición del transcrito antes de cada turno, para conservar solo la respuesta de ese turno.</summary>
    private readonly Dictionary<Guid, int> _turnMessageStartIndices = new();

    private readonly HashSet<Guid> _stoppingRuns = new();

    private readonly Dictionary<Guid, IChatDriver> _drivers = new();

    /// <summary>Controladores cuyo agente sigue abierto entre turnos.</summary>
    private readonly Dictionary<Guid, IChatDriver> _liveDrivers = new();

    /// <summary>Eventos pendientes de aplicar por conversación.</summary>
    private readonly Dictionary<Guid, List<ChatEvent>> _pending = new();

    /// <summary>Tarea que aplica los eventos acumulados.</summary>
    private CancellationTokenSource? _flushTask;

    /// <summary>Verdadero tras Shutdown: no se aceptan más turnos.</summary>
    private bool _stopped;

    /// <summary>Última respuesta de cada agente, para que los orquestadores la lean tras expulsar la transcripción.</summary>
    private readonly Dictionary<Guid, string> _lastReplies = new();

    private readonly HashSet<Guid> _seededJackTurns = new();
    private readonly HashSet<Guid> _cancelledJackTurns = new();
    private readonly Dictionary<Guid, (int Target, int FirstMessage)> _compactions = new();
    private readonly Dictionary<Guid, (string, List<string>)> _afterCompaction = new();
    private readonly Dictionary<Guid, (ChatProvider Provider, int FirstMessage)> _handoffs = new();
    private readonly Dictionary<Guid, int> _budgetBaseline = new();
    private readonly Dictionary<Guid, int> _budgetTurnUsage = new();

    /// <summary>Generación de modo: cambia cuando el modo global cambia, para descartar resultados viejos.</summary>
    private int _modeGeneration;

    /// <summary>Modelos de Claude detectados en sesiones recientes, mezclados con el catálogo. Null hasta detectarlos.</summary>
    private List<ChatModelChoice>? _detectedClaudeModels;

    /// <summary>Tarea de refresco de cuotas diferido.</summary>
    private Task? _usageRefresh;

    // TODO(port): modelDiscoveryGeneration, knownProjects, delegatedWaits, codexModels y los modelos de Antigravity/Qoder
    //   no se declaran aquí; están fuera de alcance (ver la lista de arriba).

    // ===== Constructor =====

    /// <summary>
    /// Crea el store. Carga el índice de conversaciones y `commands.json` (equivale al init de Swift).
    /// Las transcripciones se cargan más tarde, al seleccionarlas.
    /// </summary>
    public ChatStore(ChatArchive? archive = null, IPreferences? preferences = null,
        Func<ChatProvider, IChatDriver>? driverFactory = null,
        Func<ChatProvider, string, Task<IReadOnlyList<ChatCommand>>>? commandLoader = null)
    {
        _archive = archive ?? new ChatArchive();
        _preferences = preferences;
        _makeDriver = driverFactory ?? (provider => ChatDriverFactory.Make(provider));
        // TODO(port): ChatCommandService.load viene de ChatCommandService.swift (comandos de barra de cada proveedor).
        // Hasta portarlo, la lectura de comandos falla con un mensaje claro en lugar de quedarse cargando.
        _loadCommandList = commandLoader ?? ((_, _) => Task.FromException<IReadOnlyList<ChatCommand>>(
            new NotSupportedException("La lectura de comandos de barra aún no está portada.")));

        // Plantillas personales de Jack: commands.json es pequeño y se lee una vez, como en Swift.
        _jackTemplates = JackCommandCatalog.Defaults.ToList();
        var templatesPath = Path.Combine(_archive.Directory, "commands.json");
        if (File.Exists(templatesPath))
        {
            try
            {
                _jackTemplates = JsonSerializer.Deserialize<List<JackCommandTemplate>>(File.ReadAllText(templatesPath), SwiftJson.Options)
                    ?? new List<JackCommandTemplate>();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
            {
                ErrorMessage = $"No se pudieron leer los comandos personales: {error.Message}";
            }
        }

        foreach (var provider in Enum.GetValues<ChatProvider>())
        {
            _recentModels[provider] = _preferences?.GetStringArray($"recentModels.{ProviderRawValue(provider)}")?.ToList()
                ?? new List<string>();
        }
        if (_preferences?.GetInt("maxConcurrentAgents") is { } savedMax) _maxConcurrent = Math.Clamp(savedMax, 0, 64);

        try
        {
            // Como en Swift, el índice se carga al crear el store. Se lee en el pool de hilos: ninguna continuación
            // vuelve al contexto de interfaz, así que bloquear aquí no puede interbloquearse.
            var index = Task.Run(() => _archive.LoadIndexAsync()).GetAwaiter().GetResult();
            _conversations = index.ToList();
            foreach (var conversation in _conversations)
            {
                if (conversation.TokenUsage is { } usage) _tokenUsage[conversation.Id] = usage;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            ErrorMessage = $"No se pudo abrir el historial: {error.Message}";
        }
    }

    // ===== Concurrencia y cuotas =====

    /// <summary>Cambia el límite de agentes que trabajan a la vez (0 a 64) y guarda la preferencia.</summary>
    public void SetConcurrency(int count)
    {
        MaxConcurrent = Math.Clamp(count, 0, 64);
        _preferences?.SetInt("maxConcurrentAgents", _maxConcurrent);
        DrainQueue(); // TODO(port): DrainQueue viene de ChatStore.Sending.cs (cola de envío).
    }

    /// <summary>
    /// Lee las cuotas de los proveedores pedidos (Swift: refreshUsage). Hoy solo Claude Code tiene lectura portada.
    /// TODO(port): Codex, OpenCode, Stellar, Antigravity y Qoder se leen en ChatUsage.swift, viene de ChatStore.swift:440-451.
    /// </summary>
    public async Task RefreshUsageAsync(IReadOnlyList<ChatProvider>? providers = null)
    {
        if (_refreshingUsage) return;
        if (providers is not null && !providers.Contains(ChatProvider.Claude)) return;
        RefreshingUsage = true;
        try
        {
            var result = await ChatUsageService.ReadClaudeAsync(ClaudeUsageRefresher);
            RunOnUi(() => MergeUsage(result));
        }
        finally
        {
            RunOnUi(() => RefreshingUsage = false);
        }
    }

    /// <summary>Lee la cuota de un proveedor poco después de uno de sus turnos; varios turnos seguidos generan una sola lectura.</summary>
    private void RefreshUsageSoon(ChatProvider provider)
    {
        if (_usageRefresh is not null || _stopped) return;
        _usageRefresh = RefreshUsageSoonAsync(provider);
    }

    private async Task RefreshUsageSoonAsync(ChatProvider provider)
    {
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (!_stopped) await RefreshUsageAsync(new[] { provider });
        RunOnUi(() => _usageRefresh = null);
    }

    /// <summary>Combina una lectura nueva con la anterior: cada ventana se queda con la observación más reciente.</summary>
    private void MergeUsage(ProviderUsage update)
    {
        if (update.Windows.Count > 0 && _usage.TryGetValue(update.Provider, out var existing))
        {
            var combined = existing.Windows.ToList();
            foreach (var window in update.Windows)
            {
                var position = combined.FindIndex(known => known.Id == window.Id);
                if (position >= 0)
                {
                    if (window.ObservedAt >= combined[position].ObservedAt) combined[position] = window;
                }
                else
                {
                    combined.Add(window);
                }
            }
            _usage[update.Provider] = update with { Windows = combined };
        }
        else if (_usage.TryGetValue(update.Provider, out var previous) && previous.Windows.Count > 0)
        {
            // Una lectura sin ventanas no borra la última conocida; solo cambia la nota.
            _usage[update.Provider] = previous with { Note = update.Note, IsCached = true };
        }
        else
        {
            _usage[update.Provider] = update;
        }
        Notify(nameof(Usage));
    }

    // ===== Valores por defecto =====

    /// <summary>Modo con el que empiezan los agentes nuevos: Auto, salvo en Antigravity, que respeta sus propios ajustes.</summary>
    internal string? DefaultMode(ChatProvider provider)
    {
        if (provider == ChatProvider.Antigravity) return null;
        return ChatRunMode.Choices(provider).Any(mode => mode.Id == "auto") ? "auto" : null;
    }

    /// <summary>Esfuerzo con el que empiezan los agentes nuevos: medio en Claude Code, alto en el resto.</summary>
    public string DefaultEffort(ChatProvider provider) => provider == ChatProvider.Claude ? "medium" : "high";

    // ===== Creación, importación y selección =====

    /// <summary>
    /// Inicia una tarea sin heredar historial, resúmenes ni instrucciones fijadas. La conversación anterior se conserva.
    /// Solo Claude Code.
    /// </summary>
    public Guid? StartFreshTask(Guid id)
    {
        // TODO(port): !isUnplaced(id) viene de ChatStore.swift:495 (colocación de agentes; fuera de alcance).
        if (_stopped || _runs.ContainsKey(id) || _queue.Any(item => item.Id == id)
            || _compactions.ContainsKey(id) || _handoffs.ContainsKey(id)) return null;
        var sourceIndex = IndexOfConversation(id);
        if (sourceIndex < 0) return null;
        var source = _conversations[sourceIndex];
        if (source.Provider != ChatProvider.Claude) return null;

        var fresh = Create(source.ProjectPath, source.Provider, source.Model, source.Effort);
        if (fresh is not { } freshId) return null;
        var freshIndex = IndexOfConversation(freshId);
        if (freshIndex < 0) return null;
        _conversations[freshIndex].ExtraDirectories = source.ExtraDirectories is null ? null : new List<string>(source.ExtraDirectories);
        _conversations[freshIndex].Mode = source.Mode;
        Notify(nameof(Conversations));
        Save(freshId);
        return freshId;
    }

    /// <summary>
    /// Crea una conversación en una carpeta existente. Devuelve su id, o null si la carpeta no sirve.
    /// Como en Swift, con <paramref name="select"/> la deja seleccionada y expulsa las transcripciones inactivas.
    /// </summary>
    public Guid? Create(string projectPath, ChatProvider provider, string? model = null, string? effort = null,
        Guid? parentId = null, string? title = null, bool select = true)
    {
        // En Windows las rutas no empiezan por "/": se acepta cualquier ruta absoluta que exista como carpeta.
        if (!Path.IsPathFullyQualified(projectPath) || !Directory.Exists(projectPath))
        {
            if (select) ErrorMessage = "Selecciona una carpeta de proyecto válida.";
            return null;
        }
        // TODO(port): Stellar (ChatStore.swift:518-526: modelo canónico y primer modelo local) viene de Stellar, fuera de alcance.
        // TODO(port): SSH (ChatStore.swift:521-522, ChatRemoteEndpoint) fuera de alcance.
        // TODO(port): Antigravity y Qoder refrescan sus modelos al crear (ChatStore.swift:540-541), fuera de alcance.
        var conversation = new ChatConversation(projectPath, provider, model);
        conversation.Effort = Clamp(effort ?? DefaultEffort(provider), SupportedEfforts(provider, conversation.Model));
        conversation.Mode = DefaultMode(provider);
        conversation.ParentId = parentId;
        if (title is not null) conversation.Title = PrefixGraphemes(title, TitleLimit);
        if (parentId is null) RememberModel(conversation.Model, provider);

        _conversations.Insert(0, conversation);
        _loaded.Add(conversation.Id);
        if (select)
        {
            SelectedId = conversation.Id;
            _preferences?.SetString("lastProjectPath", projectPath);
        }
        Notify(nameof(Conversations));
        Save(conversation.Id);
        if (select) EvictInactiveTranscripts();
        return conversation.Id;
    }

    /// <summary>
    /// Continúa una sesión iniciada en la terminal de Claude Code: su historial pasa a ser la transcripción y el siguiente
    /// mensaje la retoma. Si la sesión ya está en Jack, se selecciona en lugar de copiarla.
    /// </summary>
    public Guid? ImportClaudeSession(ClaudeSessionSummary session, IReadOnlyList<ChatMessage> messages, string? model = null)
    {
        var existing = _conversations.FirstOrDefault(conversation =>
            conversation.Provider == ChatProvider.Claude && conversation.SessionId == session.Id);
        if (existing is not null)
        {
            Select(existing.Id);
            return existing.Id;
        }
        var created = Create(session.ProjectPath, ChatProvider.Claude, model, title: session.Title);
        if (created is not { } id) return null;
        var index = IndexOfConversation(id);
        if (index < 0) return null;

        var conversation = _conversations[index];
        conversation.SessionId = session.Id;
        conversation.Messages = messages.ToList();
        conversation.UpdatedAt = session.UpdatedAt;
        if (messages.LastOrDefault(message => message.Role == "assistant" && message.Text.Length > 0) is { } last)
            conversation.Preview = PreviewOf(last.Text);
        Notify(nameof(Conversations));
        Save(id);
        return id;
    }

    /// <summary>
    /// Añade sesiones de Claude Code sin leer su historial, que se lee al abrirlas por primera vez. Se omiten las ya
    /// presentes y las carpetas que ya no existen. Devuelve cuántas se añadieron.
    /// </summary>
    public int ImportClaudeSessions(IReadOnlyList<ClaudeSessionSummary> sessions)
    {
        var known = new HashSet<string>(_conversations
            .Where(conversation => conversation.Provider == ChatProvider.Claude)
            .Select(conversation => conversation.SessionId)
            .OfType<string>());
        var added = 0;
        foreach (var session in sessions)
        {
            if (!known.Add(session.Id)) continue;
            if (!Path.IsPathFullyQualified(session.ProjectPath) || !Directory.Exists(session.ProjectPath)) continue;

            var conversation = new ChatConversation(session.ProjectPath, ChatProvider.Claude, session.Model)
            {
                Title = PrefixGraphemes(session.Title, TitleLimit),
                SessionId = session.Id,
                UpdatedAt = session.UpdatedAt,
                PendingClaudeHistory = true,
            };
            conversation.Effort = Clamp(conversation.Effort, SupportedEfforts(ChatProvider.Claude, conversation.Model));
            _conversations.Add(conversation);
            added++;
        }
        if (added > 0)
        {
            Notify(nameof(Conversations));
            Persist(null); // Solo el índice: el historial se leerá al abrir cada sesión.
        }
        return added;
    }

    /// <summary>Lee en segundo plano el historial de una sesión importada en bloque, una sola vez.</summary>
    private void ReadPendingClaudeHistory(Guid id)
    {
        var index = IndexOfConversation(id);
        if (index < 0) return;
        var conversation = _conversations[index];
        if (conversation.PendingClaudeHistory != true || conversation.SessionId is not { } sessionId
            || !_readingClaudeHistory.Add(id)) return;

        var summary = new ClaudeSessionSummary
        {
            Id = sessionId,
            Title = conversation.Title,
            ProjectPath = conversation.ProjectPath,
            UpdatedAt = conversation.UpdatedAt,
        };
        Notify(nameof(ReadingClaudeHistory));
        _ = ReadPendingClaudeHistoryAsync(id, summary, needsArchive: !_loaded.Contains(id));
    }

    private async Task ReadPendingClaudeHistoryAsync(Guid id, ClaudeSessionSummary summary, bool needsArchive)
    {
        var read = ReadClaudeSession;
        IReadOnlyList<ChatMessage> history = Array.Empty<ChatMessage>();
        string? model = null;
        try
        {
            (history, model) = await Task.Run(() => read(summary));
        }
        catch (Exception)
        {
            // Como en Swift, un historial ilegible deja la sesión sin historial: el próximo mensaje la retoma igualmente.
        }

        List<ChatMessage>? stored = null;
        if (needsArchive)
        {
            try
            {
                stored = (await _archive.LoadAsync(id))?.Messages.ToList();
            }
            catch (Exception)
            {
                // Como try? de Swift: sin transcripción guardada, se parte de una lista vacía.
            }
        }

        var historyForUi = history;
        var modelForUi = model;
        RunOnUi(() => ApplyPendingClaudeHistory(id, historyForUi, modelForUi, stored));
    }

    private void ApplyPendingClaudeHistory(Guid id, IReadOnlyList<ChatMessage> history, string? model, List<ChatMessage>? stored)
    {
        _readingClaudeHistory.Remove(id);
        Notify(nameof(ReadingClaudeHistory));
        var index = IndexOfConversation(id);
        if (index < 0) return;
        var conversation = _conversations[index];

        if (stored is not null && !_loaded.Contains(id))
        {
            conversation.Messages = stored;
            _loaded.Add(id);
        }
        // Los mensajes enviados mientras se leía van después del historial.
        var sentSince = conversation.Messages;
        if (history.Count == 0)
        {
            var notice = new ChatMessage
            {
                Role = "jack",
                Text = "No se encontró el historial de esta sesión en Claude Code. El próximo mensaje la retoma igualmente.",
            };
            conversation.Messages = new[] { notice }.Concat(sentSince).ToList();
        }
        else
        {
            conversation.Messages = history.Concat(sentSince).ToList();
        }
        if (sentSince.Count == 0 && model is not null) conversation.Model = model;
        conversation.PendingClaudeHistory = null;
        if (conversation.Preview is null
            && history.LastOrDefault(message => message.Role == "assistant" && message.Text.Length > 0) is { } last)
            conversation.Preview = PreviewOf(last.Text);
        Notify(nameof(Conversations));
        Save(id);
        if (SelectedId != id && !_paned.Contains(id)) EvictInactiveTranscripts();
    }

    /// <summary>Sustituye la transcripción por la sesión tal como la guardó Claude Code, p. ej. tras continuarla en una terminal.</summary>
    public void ReplaceTranscript(Guid id, IReadOnlyList<ChatMessage> messages)
    {
        var index = IndexOfConversation(id);
        if (_runs.ContainsKey(id) || index < 0) return;
        if (_liveDrivers.Remove(id, out var driver)) driver.Close();
        _loaded.Add(id);
        var conversation = _conversations[index];
        conversation.Messages = messages.ToList();
        conversation.PendingClaudeHistory = null;
        if (messages.LastOrDefault(message => message.Role == "assistant" && message.Text.Length > 0) is { } last)
            conversation.Preview = PreviewOf(last.Text);
        conversation.UpdatedAt = DateTime.UtcNow;
        Notify(nameof(Conversations));
        Save(id);
    }

    /// <summary>
    /// Una terminal de Normal puede tomar una sesión de Claude Code inactiva, nunca una con trabajo pendiente.
    /// Cierra el proceso de sus agentes antes de cederla.
    /// </summary>
    public bool ClaimClaudeSessionForTerminal(Guid session)
    {
        if (_stopped || _terminalClaudeSessions.Contains(session)) return false;
        var chatIds = _conversations
            .Where(conversation => conversation.Provider == ChatProvider.Claude
                && Guid.TryParse(conversation.SessionId, out var parsed) && parsed == session)
            .Select(conversation => conversation.Id)
            .ToList();
        var allIdle = chatIds.All(chatId => !_runs.ContainsKey(chatId)
            && !_queue.Any(item => item.Id == chatId)
            && !_compactions.ContainsKey(chatId)
            && !_handoffs.ContainsKey(chatId)
            && (!_waiting.TryGetValue(chatId, out var waiting) || waiting.Count == 0));
        if (!allIdle) return false;
        foreach (var chatId in chatIds)
        {
            if (!CloseSession(chatId)) return false;
        }
        _terminalClaudeSessions.Add(session);
        return true;
    }

    public void ReleaseClaudeSessionFromTerminal(Guid session) => _terminalClaudeSessions.Remove(session);

    /// <summary>Cierra el proceso abierto del agente, p. ej. antes de que la misma sesión continúe en una terminal. Falso mientras trabaja.</summary>
    public bool CloseSession(Guid id)
    {
        if (_runs.ContainsKey(id)) return false;
        if (_liveDrivers.Remove(id, out var driver)) driver.Close();
        return true;
    }

    /// <summary>
    /// Selecciona una conversación. Si su transcripción no está en memoria, se lee en segundo plano y la selección
    /// se completa cuando termina la lectura.
    /// </summary>
    public void Select(Guid id)
    {
        if (IndexOfConversation(id) < 0) return;
        if (_loaded.Contains(id))
        {
            FinishSelect(id);
            return;
        }
        LoadTranscript(id, thenSelect: true);
    }

    /// <summary>Último paso de <see cref="Select"/>: fija la selección, marca como leída y expulsa las transcripciones inactivas.</summary>
    private void FinishSelect(Guid id)
    {
        var index = IndexOfConversation(id);
        if (index < 0) return;
        ReadPendingClaudeHistory(id);
        SelectedId = id;

        var conversation = _conversations[index];
        var changed = false;
        if (conversation.HasUnread == true)
        {
            conversation.HasUnread = null;
            changed = true;
        }
        if (conversation.Preview is null
            && conversation.Messages.LastOrDefault(message => message.Role == "assistant" && message.Text.Length > 0) is { } last)
        {
            conversation.Preview = PreviewOf(last.Text);
            changed = true;
        }
        if (changed)
        {
            Notify(nameof(Conversations));
            Save(id);
        }
        EvictInactiveTranscripts();
    }

    /// <summary>
    /// Carga en segundo plano la transcripción de una conversación que no está en memoria (Swift: loadTranscript).
    /// Si ya se está leyendo, la petición se suma a la lectura en curso.
    /// </summary>
    private void LoadTranscript(Guid id, bool thenSelect = false)
    {
        if (_loaded.Contains(id) || IndexOfConversation(id) < 0) return;
        if (_loadingTranscripts.TryGetValue(id, out var wantsSelect))
        {
            _loadingTranscripts[id] = wantsSelect || thenSelect;
            return;
        }
        _loadingTranscripts[id] = thenSelect;
        _ = LoadTranscriptAsync(id);
    }

    private async Task LoadTranscriptAsync(Guid id)
    {
        ChatConversation? stored = null;
        string? failure = null;
        try
        {
            stored = await _archive.LoadAsync(id);
        }
        catch (Exception error)
        {
            failure = error.Message;
        }
        var loadedFromDisk = stored;
        var loadFailure = failure;
        RunOnUi(() => ApplyLoadedTranscript(id, loadedFromDisk, loadFailure));
    }

    private void ApplyLoadedTranscript(Guid id, ChatConversation? stored, string? failure)
    {
        var thenSelect = _loadingTranscripts.Remove(id, out var wantsSelect) && wantsSelect;
        if (failure is not null && thenSelect)
        {
            // Como en Swift: si no se puede leer, no se selecciona la conversación.
            ErrorMessage = $"No se pudo leer esta conversación: {failure}";
            return;
        }
        var index = IndexOfConversation(id);
        if (index < 0) return; // Se borró mientras se leía.

        if (!_loaded.Contains(id))
        {
            // Los mensajes que llegaron mientras se leía (p. ej. un envío que no esperó la carga) van después de la
            // transcripción guardada; como no estaban en disco, hay que guardarlos ahora.
            var sentWhileLoading = _conversations[index].Messages.Count > 0;
            if (stored is not null) _conversations[index].Messages = stored.Messages.Concat(_conversations[index].Messages).ToList();
            _loaded.Add(id);
            if (sentWhileLoading) Save(id);
        }
        SettleBackground(id);
        ReadPendingClaudeHistory(id);
        Notify(nameof(Conversations));
        if (thenSelect) FinishSelect(id);
    }

    // SettleBackground (settleBackground de Swift) está en ChatStore.Sending.cs; no se duplica aquí.

    // ===== Edición de conversaciones =====

    /// <summary>Renombra una conversación. El título se recorta a 120 caracteres y se ignoran los vacíos.</summary>
    public void Rename(Guid id, string title)
    {
        var text = title.Trim();
        var index = IndexOfConversation(id);
        if (text.Length == 0 || index < 0) return;
        _conversations[index].Title = PrefixGraphemes(text, TitleLimit);
        Notify(nameof(Conversations));
        Save(id);
    }

    /// <summary>
    /// Fija una conversación arriba de la barra lateral. Devuelve false si ya hay <see cref="MaxPinned"/> fijadas.
    /// </summary>
    public bool SetPinned(Guid id, bool pinned)
    {
        var index = IndexOfConversation(id);
        if (index < 0 || (_conversations[index].PinnedAt is not null) == pinned) return true;
        if (pinned)
        {
            if (_conversations.Count(conversation => conversation.PinnedAt is not null) >= MaxPinned)
            {
                ErrorMessage = $"Solo puedes fijar {MaxPinned} chats. Quita uno para fijar otro.";
                return false;
            }
            _conversations[index].PinnedAt = DateTime.UtcNow;
        }
        else
        {
            _conversations[index].PinnedAt = null;
        }
        Notify(nameof(Conversations));
        Save(id);
        return true;
    }

    /// <summary>Marca o desmarca una conversación como pendiente.</summary>
    public void SetPending(Guid id, bool pending)
    {
        var index = IndexOfConversation(id);
        if (index < 0 || (_conversations[index].IsPending == true) == pending) return;
        _conversations[index].IsPending = pending ? true : null;
        Notify(nameof(Conversations));
        Save(id);
    }

    /// <summary>Marca o desmarca una conversación como no leída.</summary>
    public void SetUnread(Guid id, bool unread)
    {
        var index = IndexOfConversation(id);
        if (index < 0 || (_conversations[index].HasUnread == true) == unread) return;
        _conversations[index].HasUnread = unread ? true : null;
        Notify(nameof(Conversations));
        Save(id);
    }

    /// <summary>
    /// Quita una conversación y su transcripción. No se puede mientras trabaja ni si está en cola.
    /// Si era la seleccionada, selecciona la primera que quede.
    /// </summary>
    public void Remove(Guid id)
    {
        if (_runs.ContainsKey(id) || _queue.Any(item => item.Id == id)) return;
        // TODO(port): cancelLocating(id) y flowDiagramStates/asides (ChatStore.swift:1617-1621) fuera de alcance.
        // TODO(port): scheduleCenter?.discardMessages(of: id) viene de ChatStore.swift:1622 (programaciones; fuera de alcance).
        if (_liveDrivers.Remove(id, out var driver)) driver.Close();
        _conversations.RemoveAll(conversation => conversation.Id == id);
        _loaded.Remove(id);
        _statuses.Remove(id);
        _approvals.Remove(id);
        _resolvedApprovalIDs.Remove(id);
        _waiting.Remove(id);
        _recalled.Remove(id);
        _suggestions.Remove(id);
        Notify(nameof(Conversations));
        Notify(nameof(Statuses));
        Notify(nameof(Approvals));
        Notify(nameof(Waiting));
        Notify(nameof(Recalled));
        Notify(nameof(Suggestions));
        Persist(null, removedId: id);
        if (SelectedId == id)
        {
            SelectedId = null;
            if (_conversations.Count > 0) Select(_conversations[0].Id);
        }
    }

    // ===== Transcripciones =====

    /// <summary>
    /// Mensajes de una conversación. Si está cargada, devuelve los que hay en memoria; si no, lee el archivo.
    /// En ese caso bloquea hasta leerlo: úsese fuera del hilo de interfaz (Swift: transcript(of:)).
    /// </summary>
    public IReadOnlyList<ChatMessage> TranscriptOf(Guid id)
    {
        var index = IndexOfConversation(id);
        if (index >= 0 && _loaded.Contains(id)) return _conversations[index].Messages;
        var stored = Task.Run(() => _archive.LoadAsync(id)).GetAwaiter().GetResult();
        if (stored is null) return Array.Empty<ChatMessage>();
        return stored.Messages;
    }

    /// <summary>Última respuesta del agente, recortada a 24.000 caracteres. Equivale a `lastReply(of:)`.</summary>
    public string? LastReplyOf(Guid id)
    {
        if (_lastReplies.TryGetValue(id, out var reply)) return reply;
        var last = TranscriptOf(id).LastOrDefault(message => message.Role == "assistant" && message.Text.Length > 0);
        return last is null ? null : PrefixGraphemes(last.Text, ReplyLimit);
    }

    /// <summary>Texto del último error de la transcripción, si lo hay.</summary>
    internal string? LastErrorOf(Guid id) => TranscriptOf(id).LastOrDefault(message => message.Role == "error")?.Text;

    /// <summary>
    /// Mantiene cargadas las transcripciones de los agentes que se muestran en paneles, sin seleccionarlos.
    /// </summary>
    public void ShowInPanes(IReadOnlyList<Guid> ids)
    {
        _paned = new HashSet<Guid>(ids);
        foreach (var id in ids) LoadTranscript(id);
        EvictInactiveTranscripts();
    }

    /// <summary>
    /// Guarda y libera las transcripciones que no están en uso: ni trabajando, ni en cola, ni seleccionadas, ni en paneles.
    /// </summary>
    private void EvictInactiveTranscripts()
    {
        var protectedIds = new HashSet<Guid>(_runs.Keys);
        protectedIds.UnionWith(_queue.Select(item => item.Id));
        if (_selectedID is { } selected) protectedIds.Add(selected);
        protectedIds.UnionWith(_paned);

        foreach (var evicted in _loaded.Where(loadedId => !protectedIds.Contains(loadedId)).ToList())
        {
            Save(evicted);
            var index = IndexOfConversation(evicted);
            if (index >= 0) _conversations[index].Messages = new List<ChatMessage>();
            _loaded.Remove(evicted);
        }
        Notify(nameof(Conversations));
    }

    // ===== Guardado =====

    /// <summary>Guarda el índice y, si la transcripción está cargada, también la transcripción de esa conversación.</summary>
    private void Save(Guid id)
    {
        var index = IndexOfConversation(id);
        Persist(_loaded.Contains(id) && index >= 0 ? _conversations[index] : null);
    }

    /// <summary>
    /// Encola la escritura en ChatArchive. La copia del índice la toma ChatArchive en este momento; la conversación
    /// se clona aquí. Los errores llegan a <see cref="ErrorMessage"/> desde el hilo de interfaz.
    /// </summary>
    private void Persist(ChatConversation? conversation, Guid? removedId = null)
    {
        var snapshot = conversation is null ? null : CopyForSave(conversation);
        var task = _archive.SaveAsync(_conversations, snapshot, removedId);
        _ = task.ContinueWith(
            finished => RunOnUi(() => ErrorMessage = $"No se pudo guardar el historial: {finished.Exception?.GetBaseException().Message}"),
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted,
            TaskScheduler.Default);
    }

    /// <summary>Copia la conversación con su lista de mensajes y cada mensaje, para serializarla sin carreras.</summary>
    private static ChatConversation CopyForSave(ChatConversation conversation) =>
        conversation with { Messages = conversation.Messages.Select(message => message with { }).ToList() };

    // ===== Utilidades internas =====

    // PreviewOf (preview(of:) de Swift) está en ChatStore.Sending.cs; no se duplica aquí.

    /// <summary>Los primeros <paramref name="count"/> caracteres de texto (grafemas, como Character en Swift).</summary>
    private static string PrefixGraphemes(string text, int count)
    {
        var end = 0;
        var taken = 0;
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (taken < count && elements.MoveNext())
        {
            end = elements.ElementIndex + elements.GetTextElement().Length;
            taken++;
        }
        return text[..end];
    }

    /// <summary>Posición de la conversación en <see cref="Conversations"/>, o -1.</summary>
    private int IndexOfConversation(Guid id) => _conversations.FindIndex(conversation => conversation.Id == id);

    // ProviderRawValue (clave de preferencias de cada proveedor) está en ChatStore.Settings.cs.
}
