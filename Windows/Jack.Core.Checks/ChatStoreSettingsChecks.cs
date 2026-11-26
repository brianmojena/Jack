using Jack.Core;

namespace Jack.Core.Checks;

// Comprobaciones de ChatStore.Settings.cs, ChatStore.JackCommands.cs y ChatCommandService.cs: lo que no necesita un driver.
// Usa una carpeta temporal para ChatArchive y MemoryPreferences. Lanza InvalidOperationException si algo falla.
public static class ChatStoreSettingsChecks
{
    public static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "jack-store-settings-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var archive = new ChatArchive(directory);
        try
        {
            var store = new ChatStore(archive, new MemoryPreferences());
            CheckModelChoices(store);
            CheckSupportedEfforts(store);
            CheckClamp();
            CheckCycleMode(store);
            CheckPreparedJackPrompt(store);
            CheckJackCommands(store, archive);
            CheckCommandService();
        }
        finally
        {
            // Las escrituras del archivo van en segundo plano: esperarlas antes de borrar la carpeta.
            archive.FlushAsync().GetAwaiter().GetResult();
            CheckIo.DeleteDirectory(directory);
        }
    }

    private static void CheckModelChoices(ChatStore store)
    {
        var conversation = AddConversation(store, ChatProvider.Claude);
        store.UpdateSettings(conversation.Id, "claude-opus-4-6", "high");
        Check(conversation.Model == "claude-opus-4-6", "UpdateSettings guarda el modelo elegido.");
        Check(conversation.Effort == "high", "UpdateSettings conserva un esfuerzo soportado.");

        var choices = store.ModelChoices(ChatProvider.Claude);
        Check(choices[0].Id == "claude-opus-4-6", "El modelo elegido recientemente aparece primero.");
        var ids = choices.Select(choice => choice.Id).ToList();
        Check(ids.Distinct().Count() == ids.Count, "Los modelos de Claude no se repiten.");
        Check(ids.Contains("sonnet") && ids.Contains("haiku") && ids.Contains("claude-sonnet-4-5-20250929"),
            "El catálogo de Claude incluye alias y versiones exactas.");
        Check(choices.First(choice => choice.Id == "haiku").Efforts.Count == 0, "Haiku no admite esfuerzo.");
        Check(choices.First(choice => choice.Id == "claude-opus-4-5").Efforts.SequenceEqual(["low", "medium", "high"]),
            "Opus 4.5 tiene low, medium y high.");
    }

    private static void CheckSupportedEfforts(ChatStore store)
    {
        Check(store.SupportedEfforts(ChatProvider.Claude, "sonnet").SequenceEqual(["low", "medium", "high", "xhigh", "max"]),
            "Sonnet (alias) admite los cinco niveles.");
        Check(store.SupportedEfforts(ChatProvider.Claude, "claude-opus-4-5").SequenceEqual(["low", "medium", "high"]),
            "Opus 4.5 no admite xhigh ni max.");
        Check(store.SupportedEfforts(ChatProvider.Claude, "claude-sonnet-4-6").SequenceEqual(["low", "medium", "high", "max"]),
            "Sonnet 4.6 admite max pero no xhigh.");
        Check(store.SupportedEfforts(ChatProvider.Claude, "claude-haiku-4-5-20251001").Count == 0,
            "Haiku 4.5 no admite esfuerzo.");
        Check(store.SupportedEfforts(ChatProvider.Claude, "claude-modelo-nuevo").SequenceEqual(["low", "medium", "high", "xhigh", "max"]),
            "Un modelo de Claude desconocido usa los niveles por defecto.");
        Check(store.SupportedEfforts(ChatProvider.Codex, "gpt-x").SequenceEqual(["low", "medium", "high"]),
            "Codex sin catálogo usa low, medium y high.");
        Check(store.SupportedEfforts(ChatProvider.OpenCode, "").Count == 0, "OpenCode no admite esfuerzo.");
    }

    private static void CheckClamp()
    {
        Check(ChatStore.Clamp("xhigh", ["low", "medium", "high"]) == "high", "Clamp usa high cuando el nivel no existe.");
        Check(ChatStore.Clamp("max", ["low", "medium"]) == "medium", "Clamp usa el último nivel si no hay high.");
        Check(ChatStore.Clamp("max", []) == "max", "Clamp conserva el esfuerzo si el modelo no tiene niveles.");
        Check(ChatStore.Clamp("low", ["low", "high"]) == "low", "Clamp conserva un nivel soportado.");
    }

    private static void CheckCycleMode(ChatStore store)
    {
        var conversation = AddConversation(store, ChatProvider.Claude);
        store.CycleMode(conversation.Id);
        Check(conversation.Mode == "acceptEdits", "Mayús+Tab pasa de manual a aceptar ediciones.");
        store.CycleMode(conversation.Id);
        Check(conversation.Mode == "plan", "Mayús+Tab pasa a plan.");
        store.CycleMode(conversation.Id);
        Check(conversation.Mode == "manual", "Mayús+Tab vuelve a manual.");

        var codex = AddConversation(store, ChatProvider.Codex);
        store.CycleMode(codex.Id);
        Check(codex.Mode is null, "Mayús+Tab solo actúa sobre Claude Code.");
    }

    private static void CheckPreparedJackPrompt(ChatStore store)
    {
        var conversation = new ChatConversation(Path.GetTempPath(), ChatProvider.Claude)
        {
            JackContext = new JackContextSettings { Seed = "resumen previo", Pinned = ["usa pruebas"] },
        };

        var prepared = store.PreparedJackPrompt("hola", conversation);
        Check(prepared.Contains("<jack_context>\nresumen previo\n</jack_context>", StringComparison.Ordinal),
            "El prompt incluye el contexto de continuidad mientras no se haya entregado.");
        Check(prepared.Contains("Instrucciones fijadas por el usuario:\n- usa pruebas", StringComparison.Ordinal),
            "El prompt incluye las instrucciones fijadas.");
        Check(prepared.EndsWith("hola", StringComparison.Ordinal), "El prompt del usuario va al final.");
        Check(store.PreparedJackPrompt("/compact", conversation) == "/compact",
            "Los comandos nativos de barra llegan sin cambios.");

        conversation.JackContext!.SeedDelivered = true;
        Check(!store.PreparedJackPrompt("hola", conversation).Contains("<jack_context>", StringComparison.Ordinal),
            "El contexto de continuidad no se repite una vez entregado.");
    }

    private static void CheckJackCommands(ChatStore store, ChatArchive archive)
    {
        var conversation = AddConversation(store, ChatProvider.Claude);
        var id = conversation.Id;

        store.ExecuteJack("fijar", "usa pruebas", id);
        Check(conversation.JackContext?.Pinned.SequenceEqual(["usa pruebas"]) == true, "/fijar guarda la instrucción.");
        store.ExecuteJack("fijar", "listar", id);
        Check(LastMessage(conversation) == "1. usa pruebas", "/fijar listar numera las instrucciones.");
        store.ExecuteJack("fijar", "quitar 9", id);
        Check(store.ErrorMessage?.StartsWith("Uso: !fijar quitar", StringComparison.Ordinal) == true, "/fijar quitar valida el número.");
        store.ExecuteJack("fijar", "quitar 1", id);
        Check(conversation.JackContext!.Pinned.Count == 0, "/fijar quitar elimina la instrucción.");

        store.ExecuteJack("contexto", "", id);
        Check(LastMessage(conversation).StartsWith("Contexto: ≈", StringComparison.Ordinal),
            "/contexto estima los tokens si el proveedor no informó.");

        store.ExecuteJack("presupuesto", "20000", id);
        Check(conversation.JackContext?.Budget == 20000, "/presupuesto fija el límite.");
        store.ExecuteJack("presupuesto", "x", id);
        Check(store.ErrorMessage?.StartsWith("Uso: !presupuesto", StringComparison.Ordinal) == true, "/presupuesto rechaza un valor inválido.");

        store.ExecuteJack("compact", "abc", id);
        Check(store.ErrorMessage?.StartsWith("Uso: !compact", StringComparison.Ordinal) == true, "/compact valida el objetivo.");

        store.ExecuteJack("comandos", "", id);
        Check(LastMessage(conversation).Contains("!compact", StringComparison.Ordinal)
            && LastMessage(conversation).Contains("!checkpoint", StringComparison.Ordinal), "/comandos lista los integrados.");
        store.ExecuteJack("comandos", "crear mi-plantilla Resume {{args}}", id);
        Check(store.JackTemplates.Any(template => template.Name == "mi-plantilla" && template.Prompt == "Resume {{args}}"),
            "/comandos crear añade una plantilla.");
        Check(File.Exists(Path.Combine(archive.Directory, "commands.json")), "Las plantillas se guardan en commands.json.");
        store.ExecuteJack("comandos", "eliminar mi-plantilla", id);
        Check(!store.JackTemplates.Any(template => template.Name == "mi-plantilla"), "/comandos eliminar quita la plantilla.");

        store.ExecuteJack("checkpoint", "punto", id);
        Check(LastMessage(conversation).StartsWith("Checkpoint «punto» guardado", StringComparison.Ordinal), "/checkpoint guarda una copia.");
        store.ExecuteJack("checkpoint", "punto", id);
        Check(store.ErrorMessage?.StartsWith("Ya existe ese checkpoint", StringComparison.Ordinal) == true, "/checkpoint no sobrescribe.");

        var before = store.Conversations.Count;
        store.ExecuteJack("checkpoint", "restaurar punto", id);
        Check(store.Conversations.Count == before + 1, "/checkpoint restaurar abre una conversación nueva.");
        var restored = store.Conversations[0];
        Check(restored.Title == "punto" && restored.ParentId == id, "La conversación restaurada conserva el nombre y el padre.");

        store.ExecuteJack("rama", "rama-prueba", id);
        Check(store.Conversations[0].Title == "rama-prueba" && store.Conversations[0].ParentId == id, "/rama crea una conversación independiente.");

        Check(store.JackCommands.Any(command => command.Name == "checkpoint") && store.JackCommands.Any(command => command.Name == "mod"),
            "JackCommands incluye los integrados.");
    }

    private static void CheckCommandService()
    {
        var directory = Path.GetTempPath();
        Check(ChatCommandService.LoadAsync(ChatProvider.Stellar, directory).GetAwaiter().GetResult().Count == 0,
            "Stellar no tiene comandos de barra.");

        var threw = false;
        try
        {
            ChatCommandService.LoadAsync(ChatProvider.Antigravity, directory).GetAwaiter().GetResult();
        }
        catch (ChatDriverError)
        {
            threw = true;
        }
        Check(threw, "Antigravity no expone comandos por protocolo y lo indica con un error.");
    }

    private static ChatConversation AddConversation(ChatStore store, ChatProvider provider)
    {
        var conversation = new ChatConversation(Path.GetTempPath(), provider);
        store.Conversations.Add(conversation);
        return conversation;
    }

    private static string LastMessage(ChatConversation conversation) =>
        conversation.Messages.Count == 0 ? "" : conversation.Messages[^1].Text;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
