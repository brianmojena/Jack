using Jack.Core;

namespace Jack.Core.Checks;

/// <summary>
/// Comprobaciones de ChatStore.State.cs: creación, selección, edición, fijados, borrado, transcripciones en disco,
/// importación de sesiones de Claude Code y recarga del store. Usa una carpeta temporal que se borra al final.
/// </summary>
public static class ChatStoreStateChecks
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "jack-state-" + Guid.NewGuid().ToString("N"));
        try
        {
            RunChecks(root);
        }
        finally
        {
            try
            {
                if (Directory.Exists(root)) CheckIo.DeleteDirectory(root);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static void RunChecks(string root)
    {
        var data = Path.Combine(root, "Chats");
        var project = Path.Combine(root, "Proyecto");
        var other = Path.Combine(root, "Otro");
        Directory.CreateDirectory(data);
        Directory.CreateDirectory(project);
        Directory.CreateDirectory(other);
        File.WriteAllText(Path.Combine(data, "commands.json"), "[{\"name\":\"personal\",\"prompt\":\"Texto {{args}}\"}]");

        var preferences = new MemoryPreferences();
        var archive = new ChatArchive(data);
        var store = new ChatStore(archive, preferences);
        Check(store.JackTemplates.Count == 1 && store.JackTemplates[0].Name == "personal", "commands.json se carga al crear el store.");
        Check(store.Conversations.Count == 0, "Sin índice previo no hay conversaciones.");

        // Carpeta inválida: no crea nada y deja un aviso.
        Check(store.Create("relativa", ChatProvider.Claude) is null, "Una ruta relativa no crea conversación.");
        Check(store.ErrorMessage == "Selecciona una carpeta de proyecto válida.", "La carpeta inválida deja un mensaje de error.");

        var first = store.Create(project, ChatProvider.Claude) ?? throw Fail("create no devolvió identificador.");
        Check(store.SelectedId == first, "Crear con select deja la conversación seleccionada.");
        Check(store.Conversations.Count == 1 && store.Conversations[0].Id == first, "La conversación nueva está en la lista.");
        Check(store.Conversations[0].Model == "sonnet", "Claude empieza con su modelo por defecto.");
        Check(store.Conversations[0].Mode == "auto", "Los agentes de Claude empiezan en Auto.");

        // Notificaciones: un cambio avisa a quien escucha.
        var changes = new List<string>();
        store.PropertyChanged += (_, args) => changes.Add(args.PropertyName ?? string.Empty);

        store.Rename(first, "   Revisar   Jack   ");
        Check(store.Conversations[0].Title == "Revisar   Jack", "Renombrar quita los espacios de los extremos.");
        Check(changes.Contains(nameof(ChatStore.Conversations)), "Renombrar avisa del cambio de conversaciones.");
        store.Rename(first, new string('x', 200));
        Check(store.Conversations[0].Title.Length == 120, "El título se recorta a 120 caracteres.");
        store.Rename(first, "   ");
        Check(store.Conversations[0].Title.Length == 120, "Un título vacío se ignora.");

        // Fijados: como máximo cinco a la vez.
        var ids = new List<Guid> { first };
        for (var i = 0; i < 5; i++)
            ids.Add(store.Create(project, ChatProvider.Claude, title: "Chat " + i, select: false) ?? throw Fail("create sin select falló."));
        for (var i = 0; i < 5; i++) Check(store.SetPinned(ids[i], true), "Se pueden fijar cinco chats.");
        Check(!store.SetPinned(ids[5], true), "El sexto chat fijado se rechaza.");
        Check(store.ErrorMessage == "Solo puedes fijar 5 chats. Quita uno para fijar otro.", "El rechazo explica el límite.");
        Check(store.SetPinned(ids[0], false), "Desfijar siempre se permite.");
        Check(store.SetPinned(ids[5], true), "Tras desfijar, se puede fijar otro chat.");

        store.SetUnread(ids[1], true);
        Check(store.Conversations.First(conversation => conversation.Id == ids[1]).HasUnread == true, "Marcar como no leída.");
        store.SetUnread(ids[1], false);
        Check(store.Conversations.First(conversation => conversation.Id == ids[1]).HasUnread is null, "Desmarcar deja el valor por defecto.");
        store.SetPending(ids[2], true);
        Check(store.Conversations.First(conversation => conversation.Id == ids[2]).IsPending == true, "Marcar como pendiente.");

        // Transcripción: se expulsa al cambiar de selección y se recarga desde el disco al volver.
        store.ReplaceTranscript(first, new[]
        {
            new ChatMessage { Role = "user", Text = "hola" },
            new ChatMessage { Role = "assistant", Text = "# Respuesta **clara**" },
        });
        Check(store.Conversations.First(conversation => conversation.Id == first).Preview == "Respuesta clara",
            "La vista previa quita las marcas Markdown.");

        store.Select(ids[1]);
        Check(store.SelectedId == ids[1], "Seleccionar una conversación cargada es inmediato.");
        Check(store.Conversations.First(conversation => conversation.Id == first).Messages.Count == 0,
            "La transcripción inactiva sale de memoria.");
        archive.FlushAsync().GetAwaiter().GetResult();

        store.Select(first);
        WaitUntil(() => store.SelectedId == first && store.Conversations.First(conversation => conversation.Id == first).Messages.Count == 2,
            "la transcripción se recarga desde el disco");
        Check(store.Conversations.First(conversation => conversation.Id == first).Messages[1].Text == "# Respuesta **clara**",
            "La transcripción recargada coincide con la guardada.");

        // Borrado: quita la conversación; si era la seleccionada, la selección pasa a otra.
        store.Remove(ids[3]);
        Check(store.Conversations.All(conversation => conversation.Id != ids[3]), "Borrar quita la conversación.");
        Check(store.SelectedId == first, "Borrar otra conversación no cambia la selección.");
        store.Remove(first);
        WaitUntil(() => store.SelectedId is not null, "al borrar la seleccionada se elige otra");
        Check(store.SelectedId != first, "Al borrar la seleccionada, la selección pasa a otra.");

        store.Rename(ids[2], "Persistido");
        store.SetConcurrency(9);
        Check(store.MaxConcurrent == 9 && preferences.GetInt("maxConcurrentAgents") == 9, "El límite de agentes se guarda.");
        archive.FlushAsync().GetAwaiter().GetResult();

        // Recarga: el índice conserva orden, nombres y fijados, pero no mensajes.
        var currentArchive = new ChatArchive(data);
        var current = new ChatStore(currentArchive, preferences);
        Check(current.ErrorMessage is null, "Recargar el store no deja errores.");
        Check(current.Conversations.Count == store.Conversations.Count, "Recargar conserva el número de conversaciones.");
        Check(current.Conversations.Select(conversation => conversation.Id).SequenceEqual(store.Conversations.Select(conversation => conversation.Id)),
            "Recargar conserva el orden.");
        Check(current.Conversations.First(conversation => conversation.Id == ids[2]).Title == "Persistido",
            "El renombrado sobrevive a la recarga.");
        Check(current.Conversations.Count(conversation => conversation.PinnedAt is not null)
            == store.Conversations.Count(conversation => conversation.PinnedAt is not null),
            "Los fijados sobreviven a la recarga.");
        Check(current.Conversations.All(conversation => conversation.Messages.Count == 0), "El índice no guarda mensajes.");
        Check(current.MaxConcurrent == 9, "El límite de agentes se recupera de las preferencias.");

        // Importación de sesiones de Claude Code: se añaden una vez y su historial se lee al abrirlas.
        var sessionId = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var summary = new ClaudeSessionSummary
        {
            Id = sessionId,
            Title = "Sesión importada",
            ProjectPath = other,
            UpdatedAt = DateTime.UtcNow,
            Model = "opus",
        };
        Check(current.ImportClaudeSessions(new[] { summary }) == 1, "Importar una sesión nueva la añade.");
        Check(current.ImportClaudeSessions(new[] { summary }) == 0, "Importar otra vez no duplica la sesión.");

        var imported = current.Conversations.First(conversation => conversation.SessionId == sessionId);
        current.ReadClaudeSession = _ => (new[] { new ChatMessage { Role = "user", Text = "previo" } }, "opus");
        current.Select(imported.Id);
        WaitUntil(() => current.SelectedId == imported.Id
            && current.Conversations.First(conversation => conversation.Id == imported.Id).PendingClaudeHistory is null,
            "el historial importado se lee al abrir la sesión");
        var importedNow = current.Conversations.First(conversation => conversation.Id == imported.Id);
        Check(importedNow.Messages.Count == 1 && importedNow.Messages[0].Text == "previo", "El historial leído pasa a la transcripción.");
        Check(importedNow.Model == "opus", "El modelo de la sesión se adopta al leer su historial.");

        // Carpeta inexistente: la sesión no se importa.
        var orphan = new ClaudeSessionSummary
        {
            Id = Guid.NewGuid().ToString("D").ToUpperInvariant(),
            Title = "Sin carpeta",
            ProjectPath = Path.Combine(root, "no-existe"),
            UpdatedAt = DateTime.UtcNow,
        };
        Check(current.ImportClaudeSessions(new[] { orphan }) == 0, "Una sesión de una carpeta que ya no existe se omite.");

        currentArchive.FlushAsync().GetAwaiter().GetResult();
        Check(!(current.ErrorMessage?.StartsWith("No se pudo guardar", StringComparison.Ordinal) ?? false),
            "Ninguna escritura del historial falló.");
    }

    /// <summary>Espera, con tiempo límite, a que una condición se cumpla (las lecturas de transcripciones son en segundo plano).</summary>
    private static void WaitUntil(Func<bool> condition, string description)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw Fail("Tiempo agotado esperando: " + description);
            Thread.Sleep(10);
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw Fail(message);
    }

    private static InvalidOperationException Fail(string message) => new("ChatStore (estado): " + message);
}
