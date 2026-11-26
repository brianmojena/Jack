using Jack.Core;

namespace Jack.Core.Checks;

// Prueba real y opcional (`--live-claude`): un turno mínimo contra el Claude Code instalado, con el driver C#.
// Consume una petición pequeña de la cuenta del usuario, por eso no forma parte de las comprobaciones normales.
public static class LiveClaude
{
    /// <summary>Un turno completo a través de ChatStore: crear, enviar, esperar y leer la transcripción.</summary>
    public static async Task RunStoreAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "jack-livestore-" + Guid.NewGuid().ToString("N")[..8]);
        var project = Path.Combine(root, "proyecto");
        Directory.CreateDirectory(project);
        try
        {
            var store = new ChatStore(new ChatArchive(Path.Combine(root, "datos")), new MemoryPreferences());
            var id = store.Create(project, ChatProvider.Claude, effort: "low") ?? throw new InvalidOperationException("No se pudo crear la conversación.");
            store.Send("Responde únicamente con la palabra OK.", id);

            var deadline = DateTime.UtcNow.AddSeconds(120);
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(500);
                var status = store.Statuses.TryGetValue(id, out var s) ? s : ChatStatus.Idle;
                if (status == ChatStatus.Failed) throw new InvalidOperationException("El store marcó la conversación como fallida: " + store.ErrorMessage);
                var transcript = store.TranscriptOf(id);
                if (status == ChatStatus.Idle && transcript.Any(m => m.Role == "assistant" && m.Text.Contains("OK", StringComparison.OrdinalIgnoreCase)))
                {
                    Console.WriteLine("Transcripción: " + string.Join(" | ", transcript.Select(m => m.Role + ": " + m.Text.Trim())));
                    store.Shutdown();
                    Console.WriteLine("ChatStore en vivo: correcto.");
                    return;
                }
            }
            store.Shutdown();
            throw new InvalidOperationException("ChatStore no completó el turno en 120 s.");
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
    }

    public static async Task RunAsync()
    {
        var folder = Path.Combine(Path.GetTempPath(), "jack-live-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        try
        {
            var conversation = new ChatConversation(folder, ChatProvider.Claude) { Effort = "low" };
            var driver = ChatDriverFactory.Make(ChatProvider.Claude);
            var text = new System.Text.StringBuilder();
            var failure = (string?)null;
            var completed = false;
            var kinds = new List<string>();

            void OnEvent(ChatEvent e)
            {
                lock (kinds) kinds.Add(e.GetType().Name);
                switch (e)
                {
                    case TextEvent t: if (t.Replace) text.Clear(); text.Append(t.Text); break;
                    case FailureEvent f: failure = f.Message; break;
                    case CompletedEvent: completed = true; break;
                }
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            var run = driver.RunAsync(conversation, "Responde únicamente con la palabra OK.", OnEvent);
            var finished = await Task.WhenAny(run, Task.Delay(Timeout.Infinite, timeout.Token).ContinueWith(_ => { }));
            if (finished != run) { driver.Close(); throw new InvalidOperationException("Claude Code no respondió en 120 s."); }
            await run;
            driver.Close();

            Console.WriteLine("Eventos: " + string.Join(", ", kinds.Distinct()));
            Console.WriteLine("Respuesta: " + text.ToString().Trim());
            if (failure != null) throw new InvalidOperationException("El driver informó un fallo: " + failure);
            if (!completed) throw new InvalidOperationException("No llegó el evento de turno completado.");
            if (!text.ToString().Contains("OK", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("La respuesta no contiene OK.");
            Console.WriteLine("Claude Code en vivo: correcto.");
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch { }
        }
    }
}
