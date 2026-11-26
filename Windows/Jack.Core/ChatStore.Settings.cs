using System.Linq;
using System.IO;
using System.Threading.Tasks;

namespace Jack.Core;

// Port de Sources/JackCore/ChatStore.swift: ajustes de agente, modos, modelos y comandos de proveedor
// (ChatStore.swift:959-1052 y 1626-1747). Modo Normal, proveedor Claude Code. Lo que depende de otros proveedores,
// de la ventana Light, de SSH o de mods queda marcado como TODO(port).
public sealed partial class ChatStore
{
    /// <summary>Cambia modelo y esfuerzo. No hace nada mientras el agente trabaja o tiene mensajes en cola, como en Swift.</summary>
    public void UpdateSettings(Guid id, string model, string effort)
    {
        var index = Conversations.FindIndex(conversation => conversation.Id == id);
        if (index < 0 || IsBusy(id)) return;

        var provider = Conversations[index].Provider;
        var trimmed = model.Trim();
        var selected = trimmed.Length == 0 ? provider.DefaultModel() : trimmed;
        // TODO(port): Stellar canonicaliza el id con StellarModels.canonicalID (ChatStore.swift:1627-1629); fuera de alcance.
        // TODO(port): OpenCode borra la variante al cambiar de modelo (ChatStore.swift:1634); fuera de alcance.

        // Un modelo distinto puede tener otra ventana de contexto; la siguiente petición la informa.
        if (Conversations[index].Model != selected && Conversations[index].ContextUsage is { } usage) usage.Window = null;
        Conversations[index].Model = selected;
        Conversations[index].Effort = Clamp(effort, SupportedEfforts(provider, selected));
        RememberModel(selected, provider);
        Save(id);
        Notify(nameof(Conversations));
    }

    /// <summary>Carpetas extra del agente; surte efecto en su siguiente turno.</summary>
    public void UpdateDirectories(Guid id, IReadOnlyList<string> directories)
    {
        var index = Conversations.FindIndex(conversation => conversation.Id == id);
        if (index < 0) return;
        Conversations[index].ExtraDirectories = directories.Count == 0 ? null : directories.ToList();
        Save(id);
        Notify(nameof(Conversations));
    }

    /// <summary>Variante de OpenCode. Solo OpenCode la usa; se conserva la firma para no romper a los llamadores.</summary>
    // TODO(port): OpenCode fuera de alcance (ChatStore.swift:1659-1665); este método queda sin efecto para Claude.
    public void UpdateVariant(Guid id, string? variant, IReadOnlyList<string> supported)
    {
        var index = Conversations.FindIndex(conversation => conversation.Id == id);
        if (IsBusy(id) || index < 0 || Conversations[index].Provider != ChatProvider.OpenCode) return;
        if (variant is not null && !supported.Contains(variant)) return;
        Conversations[index].Variant = variant;
        Save(id);
        Notify(nameof(Conversations));
    }

    /// <summary>Cambia el modo de permisos. Un agente que mantiene su proceso vivo lo cambia en mitad del turno.</summary>
    public void UpdateMode(Guid id, string? mode, IReadOnlyList<ChatRunMode> supported)
    {
        // Como en Swift, con mensajes en cola no se cambia el modo; con un turno en marcha, solo si el driver lo admite.
        if (_queue.Any(entry => entry.Item1 == id)) return;
        var index = Conversations.FindIndex(conversation => conversation.Id == id);
        if (index < 0) return;
        if (mode is not null && !supported.Any(choice => choice.Id == mode)) return;

        if (_runs.ContainsKey(id))
        {
            if (!_drivers.TryGetValue(id, out var driver) || !driver.KeepsAlive || !driver.SetMode(mode ?? "manual")) return;
        }

        Conversations[index].Mode = mode;
        Save(id);
        Notify(nameof(Conversations));
    }

    /// <summary>Si el modo de permisos puede cambiar mientras el agente trabaja.</summary>
    public bool ChangesModeLive(Guid id)
    {
        if (!_runs.ContainsKey(id)) return true;
        return _drivers.TryGetValue(id, out var driver) && driver.KeepsAlive;
    }

    /// <summary>Mayús+Tab: el siguiente de los modos cotidianos de Claude Code (manual, aceptar ediciones, plan).</summary>
    public void CycleMode(Guid id)
    {
        var conversation = Conversations.FirstOrDefault(item => item.Id == id);
        if (conversation is null || conversation.Provider != ChatProvider.Claude) return;

        string[] cycle = ["manual", "acceptEdits", "plan"];
        // IndexOf devuelve -1 si el modo no está en el ciclo; entonces el siguiente es el primero, como en Swift.
        var next = cycle[(Array.IndexOf(cycle, conversation.Mode ?? "manual") + 1) % cycle.Length];
        UpdateMode(id, next, ChatRunMode.Choices(ChatProvider.Claude));
    }

    /// <summary>
    /// Modelos del selector: los usados recientemente, los de las conversaciones del proveedor, el predeterminado y el catálogo.
    /// Para Claude, las versiones detectadas en las sesiones más recientes se mezclan con el catálogo.
    /// </summary>
    public IReadOnlyList<ChatModelChoice> ModelChoices(ChatProvider provider)
    {
        // TODO(port): catálogos de Codex, OpenCode, Stellar, Antigravity y Qoder (ChatStore.swift:1689-1718) no portados.
        var catalog = provider == ChatProvider.Claude ? ClaudeModelCatalog() : new List<ChatModelChoice>();

        var ids = RecentModelsFor(provider)
            .Concat(Conversations.Where(conversation => conversation.Provider == provider).Select(conversation => conversation.Model))
            .Append(provider.DefaultModel())
            .Concat(catalog.Select(choice => choice.Id))
            .ToList();

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var choices = new List<ChatModelChoice>();
        foreach (var id in ids)
        {
            if (!seen.Add(id)) continue;
            choices.Add(catalog.FirstOrDefault(choice => choice.Id == id)
                ?? new ChatModelChoice(id, null, null, ChatModelChoice.FallbackEfforts(provider, id)));
        }
        return choices;
    }

    /// <summary>Niveles de esfuerzo que admite un modelo; si no está en el catálogo, los del proveedor para ese id.</summary>
    public IReadOnlyList<string> SupportedEfforts(ChatProvider provider, string model)
    {
        // TODO(port): catálogos de Codex, Antigravity y Qoder (ChatStore.swift:1732-1735) no portados.
        var catalog = new List<ChatModelChoice>();
        if (provider == ChatProvider.Claude)
        {
            catalog.AddRange(ChatModelChoice.ClaudeCatalog);
            catalog.AddRange(ChatModelChoice.ClaudeExact);
        }
        return catalog.FirstOrDefault(choice => choice.Id == model)?.Efforts ?? ChatModelChoice.FallbackEfforts(provider, model);
    }

    /// <summary>
    /// Conserva el esfuerzo guardado cuando el modelo no tiene niveles, para que volver a un modelo con niveles lo restaure.
    /// Si el esfuerzo no está soportado, usa "high" o el último nivel disponible.
    /// </summary>
    public static string Clamp(string effort, IReadOnlyList<string> supported) =>
        supported.Count == 0 || supported.Contains(effort)
            ? effort
            : supported.Contains("high") ? "high" : supported[^1];

    /// <summary>Recuerda el modelo como reciente del proveedor (máximo 8) y lo guarda en las preferencias.</summary>
    private void RememberModel(string model, ChatProvider provider)
    {
        // TODO(port): el caso de Stellar en modo Light (no recordar modelos de la nube) viene de ChatStore.swift:1741; Light fuera de alcance.
        var values = RecentModelsFor(provider).Where(value => value != model).Prepend(model).Take(8).ToList();
        RecentModels[provider] = values;
        _preferences?.SetStringArray("recentModels." + ProviderRawValue(provider), values);
        Notify(nameof(RecentModels));
    }

    /// <summary>Comandos de barra del proveedor para la conversación, o null si todavía no se han cargado.</summary>
    public IReadOnlyList<ChatCommand>? CommandsFor(ChatConversation conversation) =>
        Commands.TryGetValue(CommandKey(conversation.Provider, conversation.ProjectPath), out var list) ? list : null;

    /// <summary>Si la lista de comandos de la conversación se está leyendo.</summary>
    public bool IsLoadingCommands(ChatConversation conversation) =>
        LoadingCommands.Contains(CommandKey(conversation.Provider, conversation.ProjectPath));

    /// <summary>Motivo por el que no se pudieron leer los comandos, o null.</summary>
    public string? CommandError(ChatConversation conversation) =>
        CommandErrors.TryGetValue(CommandKey(conversation.Provider, conversation.ProjectPath), out var error) ? error : null;

    /// <summary>
    /// Lee los comandos del proveedor una vez por proyecto. Un fallo no se recuerda como lista vacía: la siguiente llamada lo vuelve a intentar.
    /// Solo se llama desde el hilo de interfaz.
    /// </summary>
    public void LoadCommands(ChatConversation conversation)
    {
        var provider = conversation.Provider;
        var projectPath = conversation.ProjectPath;
        var key = CommandKey(provider, projectPath);
        if (Commands.ContainsKey(key) || LoadingCommands.Contains(key)) return;

        LoadingCommands.Add(key);
        CommandErrors.Remove(key);
        Notify(nameof(LoadingCommands));
        Notify(nameof(CommandErrors));

        var loader = _loadCommandList;
        var deadline = CommandDeadline;
        var started = DateTime.UtcNow;

        _ = Task.Run(async () =>
        {
            var list = new List<ChatCommand>();
            string? failure = null;
            try
            {
                // El plazo no depende de la CLI: un proceso que nunca cierra su salida no debe dejar "Cargando comandos…" para siempre.
                list = (await loader(provider, projectPath).WaitAsync(deadline)).ToList();
            }
            catch (TimeoutException)
            {
                failure = $"{provider.Title()} tardó más de {(int)deadline.TotalSeconds} s en informar de sus comandos.";
            }
            catch (Exception exception)
            {
                failure = exception.Message;
            }
            var seconds = (DateTime.UtcNow - started).TotalSeconds;
            RunOnUi(() => FinishLoadCommands(key, provider, projectPath, list, failure, seconds));
        });
    }

    /// <summary>Anota el resultado de la lectura de comandos; se ejecuta en el hilo de interfaz.</summary>
    private void FinishLoadCommands(string key, ChatProvider provider, string projectPath, List<ChatCommand> list, string? failure, double seconds)
    {
        LoadingCommands.Remove(key);
        if (list.Count == 0 && failure is null) failure = $"{provider.Title()} no informó de ningún comando.";

        if (failure is not null)
        {
            CommandErrors[key] = failure;
            LogCommandIssue($"comandos de {provider.Title()} en {projectPath}: {failure}");
        }
        else if (!Commands.ContainsKey(key) || list.Count > 0)
        {
            Commands[key] = list;
        }

        // Las lecturas lentas dejan rastro, para distinguir una CLI lenta de una bloqueada.
        if (seconds > 10) LogCommandIssue($"comandos de {provider.Title()} en {projectPath}: {(int)seconds} s");

        Notify(nameof(Commands));
        Notify(nameof(LoadingCommands));
        Notify(nameof(CommandErrors));
    }

    /// <summary>Clave del diccionario de comandos: proveedor y ruta del proyecto, como en Swift.</summary>
    private static string CommandKey(ChatProvider provider, string projectPath) => ProviderRawValue(provider) + "|" + projectPath;

    /// <summary>Nombre del proveedor tal como lo guarda Swift (rawValue): en minúsculas.</summary>
    private static string ProviderRawValue(ChatProvider provider) => provider.ToString().ToLowerInvariant();

    /// <summary>Recientes del proveedor, sin fallar si todavía no hay ninguno.</summary>
    private IEnumerable<string> RecentModelsFor(ChatProvider provider) =>
        RecentModels.TryGetValue(provider, out var values) ? values : Enumerable.Empty<string>();

    /// <summary>Catálogo de Claude: versiones detectadas (o el catálogo) más los modelos exactos. Solo modo Normal.</summary>
    private List<ChatModelChoice> ClaudeModelCatalog()
    {
        if (_detectedClaudeModels is null)
        {
            // Las versiones detectadas van primero; las familias que no aparecen en las sesiones se completan con el catálogo.
            var detected = DetectClaudeModels();
            var merged = detected.ToList();
            foreach (var fallback in ChatModelChoice.ClaudeCatalog)
            {
                if (!detected.Any(choice => choice.Id == fallback.Id)) merged.Add(fallback);
            }
            _detectedClaudeModels = merged;
        }

        var catalog = (_detectedClaudeModels ?? ChatModelChoice.ClaudeCatalog).ToList();
        catalog.AddRange(ChatModelChoice.ClaudeExact);
        return catalog;
    }

    /// <summary>
    /// Versiones de Claude que aparecen en las 20 sesiones más recientes (ClaudeModelDetector.detectModels de Swift).
    /// La ruta de cada sesión se reconstruye como `Root\carpeta\id.jsonl`; hay que verificarla con una instalación real.
    /// </summary>
    private static IReadOnlyList<ChatModelChoice> DetectClaudeModels()
    {
        try
        {
            var files = ClaudeSessions.ListRecent(null, 20)
                .Select(session => Path.Combine(ClaudeSessions.Root, ClaudeSessions.FolderName(session.ProjectPath), session.Id + ".jsonl"))
                .ToList();
            return ClaudeModelDetector.DetectModelsFromFiles(files).Detected;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>Lee los comandos de la CLI en segundo plano y deja los errores en el registro de comandos.</summary>
    private static void LogCommandIssue(string message)
    {
        // TODO(port): JackLog.write viene de JackLog.swift; aún no portado. Mientras tanto, va a la salida de depuración.
        System.Diagnostics.Debug.WriteLine("[Jack] " + message);
    }
}
