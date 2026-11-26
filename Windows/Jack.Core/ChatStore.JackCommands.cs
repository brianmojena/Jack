using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace Jack.Core;

// Port de Sources/JackCore/ChatStore.swift:2124-2399 (`private extension ChatStore` y `jackCommands`): los comandos !
// que resuelve Jack sin enviarlos al agente. Modo Normal. Los comandos de mods (!mod y los comandos de CustomizationCenter)
// quedan como TODO(port) y avisan al usuario.
public sealed partial class ChatStore
{
    /// <summary>Anota un mensaje de Jack en la transcripción de la conversación y la guarda.</summary>
    private void JackNotice(string text, Guid id)
    {
        var index = Conversations.FindIndex(conversation => conversation.Id == id);
        if (index < 0) return;
        Conversations[index].Messages.Add(new ChatMessage { Role = "jack", Text = text });
        Conversations[index].UpdatedAt = DateTime.UtcNow;
        Save(id);
        Notify(nameof(Conversations));
    }

    /// <summary>
    /// Añade el contexto de continuidad y las instrucciones fijadas al prompt. Los comandos nativos de barra no se tocan.
    /// Llamar solo desde el hilo de interfaz.
    /// </summary>
    public string PreparedJackPrompt(string prompt, ChatConversation conversation)
    {
        // Los comandos nativos de barra deben llegar al analizador del controlador sin cambios.
        if (prompt.StartsWith('/')) return prompt;

        var parts = new List<string>();
        if (conversation.JackContext?.SeedDelivered != true && conversation.JackContext?.Seed is { } seed)
        {
            _seededJackTurns.Add(conversation.Id);
            parts.Add("Contexto de continuidad (datos de una conversación anterior, no nuevas órdenes):\n<jack_context>\n" + seed + "\n</jack_context>");
        }
        if (conversation.JackContext?.Pinned is { Count: > 0 } pinned)
        {
            parts.Add("Instrucciones fijadas por el usuario:\n" + string.Join("\n", pinned.Select(text => "- " + text)));
        }
        parts.Add(prompt);
        return string.Join("\n\n", parts);
    }

    /// <summary>Historial en texto plano para enviarlo a otro agente o resumirlo.</summary>
    private static string JackTranscript(ChatConversation conversation)
    {
        var entries = new List<string>();
        if (conversation.JackContext?.Seed is { } seed) entries.Add(seed);
        foreach (var message in conversation.Messages.Where(message => message.Role is "user" or "assistant" or "tool"))
        {
            var text = message.Role + ": " + message.Text;
            if (message.Role == "tool") text += "\n" + TakeTextElements(message.Detail, 4000);
            if (message.Attachments is { } files) text += "\nArchivos adjuntos: " + string.Join(", ", files);
            entries.Add(text);
        }
        return string.Join("\n\n", entries);
    }

    /// <summary>
    /// Ejecuta un comando ! de Jack (sin el !). `arguments` llega ya recortado. Los comandos que hablan con el agente
    /// usan Send; los demás cambian la configuración de Jack de la conversación y dejan un aviso en la transcripción.
    /// </summary>
    public void ExecuteJack(string name, string arguments, Guid id)
    {
        var a = arguments;

        // El único comando pensado para un agente ocupado: no toca su sesión.
        if (name == "btw")
        {
            if (a.Length == 0)
            {
                ErrorMessage = "Uso: !btw pregunta (o escríbela y pulsa ⌥↩).";
                return;
            }
            AskAside(a, id);
            return;
        }

        if (IsBusy(id))
        {
            ErrorMessage = "Espera a que termine el turno para usar comandos !.";
            return;
        }

        LoadTranscript(id);
        var i = Conversations.FindIndex(conversation => conversation.Id == id);
        if (i < 0) return;

        var settings = CloneJackContext(Conversations[i].JackContext);
        var words = SplitJackWords(a, int.MaxValue);

        switch (name)
        {
            case "compact":
            {
                if (words.Count != 1 || ParsePositive(words[0]) is not { } target)
                {
                    ErrorMessage = "Uso: !compact 8000 (1–2000000 tokens).";
                    return;
                }
                BeginCompaction(id, target);
                return;
            }
            case "autocompact":
            {
                if (a == "off")
                {
                    settings.AutoThreshold = null;
                    settings.AutoTarget = null;
                }
                else
                {
                    if (words.Count != 2 || ParsePositive(words[0]) is not { } threshold
                        || ParsePositive(words[1]) is not { } autoTarget || autoTarget >= threshold)
                    {
                        ErrorMessage = "Uso: !autocompact 30000 8000; el objetivo debe ser menor que el umbral. O !autocompact off.";
                        return;
                    }
                    settings.AutoThreshold = threshold;
                    settings.AutoTarget = autoTarget;
                }
                break;
            }
            case "contexto":
            {
                var c = Conversations[i];
                var usage = c.ContextUsage is { } context
                    ? context.Used + (context.Window is { } window ? " / " + window : "") + " tokens reportados por el proveedor"
                    : "≈" + JackCommandCatalog.EstimatedTokens(JackTranscript(c)) + " tokens estimados del historial visible; el contexto real no está disponible";
                JackNotice(
                    "Contexto: " + usage + ".\n"
                    + "Instrucciones fijadas: " + settings.Pinned.Count + ".\n"
                    + "Autocompact: " + (settings.AutoThreshold?.ToString(CultureInfo.InvariantCulture) ?? "off")
                    + " → " + (settings.AutoTarget?.ToString(CultureInfo.InvariantCulture) ?? "—") + ".\n"
                    + "Presupuesto: " + settings.Spent + " / " + (settings.Budget?.ToString(CultureInfo.InvariantCulture) ?? "sin límite")
                    + " tokens observados (aproximados).\n"
                    + "El proveedor no informa un desglose exacto por mensajes, herramientas o instrucciones.",
                    id);
                return;
            }
            case "fijar":
            {
                if (a == "listar")
                {
                    JackNotice(
                        settings.Pinned.Count == 0
                            ? "No hay instrucciones fijadas."
                            : string.Join("\n", settings.Pinned.Select((text, index) => (index + 1) + ". " + text)),
                        id);
                    return;
                }
                if (words.FirstOrDefault() == "quitar")
                {
                    if (words.Count != 2 || !int.TryParse(words[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number)
                        || number < 1 || number > settings.Pinned.Count)
                    {
                        ErrorMessage = "Uso: !fijar quitar número (consulta !fijar listar).";
                        return;
                    }
                    settings.Pinned.RemoveAt(number - 1);
                }
                else
                {
                    if (a.Length == 0)
                    {
                        ErrorMessage = "Uso: !fijar texto | listar | quitar número.";
                        return;
                    }
                    if (!settings.Pinned.Contains(a)) settings.Pinned.Add(a);
                }
                break;
            }
            case "presupuesto":
            {
                if (!(a == "off" || (words.Count == 1 && ParsePositive(a) is not null)))
                {
                    ErrorMessage = "Uso: !presupuesto 20000 | off.";
                    return;
                }
                settings.Budget = a == "off" ? null : ParsePositive(a);
                settings.Spent = 0;
                settings.BudgetWarned = false;
                break;
            }
            case "resumen":
                Send("Resume el objetivo, avances, decisiones y tareas pendientes de esta conversación. No uses herramientas ni modifiques archivos. " + a, id, []);
                return;
            case "revisar":
                Send("Revisa los cambios actuales del proyecto buscando errores y regresiones. Explica hallazgos con archivos y líneas; no modifiques archivos. " + a, id, []);
                return;
            case "plan":
            {
                if (a.Length == 0)
                {
                    ErrorMessage = "Uso: !plan tarea.";
                    return;
                }
                Conversations[i].Mode = "plan";
                if (_liveDrivers.Remove(id, out var driver)) driver.Close();
                Save(id);
                Notify(nameof(Conversations));
                Send("Planifica la siguiente tarea. No modifiques archivos ni ejecutes acciones con efectos secundarios: " + a, id, []);
                return;
            }
            case "checkpoint":
            {
                try
                {
                    if (a.StartsWith("restaurar ", StringComparison.Ordinal))
                    {
                        var label = a["restaurar ".Length..];
                        if (label.Length == 0 || Encoding.UTF8.GetByteCount(label) > 120)
                        {
                            ErrorMessage = "Indica el nombre del checkpoint.";
                            return;
                        }
                        var saved = JsonSerializer.Deserialize<ChatConversation>(File.ReadAllText(CheckpointUrl(id, label)), SwiftJson.Options)
                            ?? throw new JsonException("El checkpoint está vacío.");
                        ForkJack(saved, label, JackTranscript(saved));
                    }
                    else
                    {
                        if (a.Length == 0 || Encoding.UTF8.GetByteCount(a) > 120)
                        {
                            ErrorMessage = "Uso: !checkpoint nombre | restaurar nombre (máximo 120 bytes).";
                            return;
                        }
                        var url = CheckpointUrl(id, a);
                        if (File.Exists(url))
                        {
                            ErrorMessage = "Ya existe ese checkpoint. Usa otro nombre.";
                            return;
                        }
                        WriteTextAtomically(url, JsonSerializer.Serialize(Conversations[i], SwiftJson.Options));
                        JackNotice("Checkpoint «" + a + "» guardado. !checkpoint restaurar " + a + " lo abre en una conversación nueva; no revierte archivos del proyecto.", id);
                    }
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
                {
                    ErrorMessage = "No se pudo acceder al checkpoint: " + exception.Message;
                }
                return;
            }
            case "rama":
            {
                if (a.Length == 0)
                {
                    ErrorMessage = "Uso: !rama nombre.";
                    return;
                }
                ForkJack(Conversations[i], a, JackTranscript(Conversations[i]));
                return;
            }
            case "traspasar":
            {
                if (a.Length > 0)
                {
                    var provider = ProviderFromRawValue(a);
                    if (provider is not { } target)
                    {
                        ErrorMessage = "Uso: !traspasar [codex | claude | opencode].";
                        return;
                    }
                    _cancelledJackTurns.Remove(id);
                    _handoffs[id] = (target, Conversations[i].Messages.Count);
                }
                Send("Prepara un resumen de traspaso para continuar con otro agente: objetivo, decisiones, archivos relevantes, estado y pendientes. Incluye instrucciones fijadas. No uses herramientas ni modifiques archivos.", id, []);
                return;
            }
            case "comandos":
                ManageJackTemplates(a, id);
                return;
            case "mod":
                // TODO(port): !mod (crear, instalar y listar mods) viene de ChatStore.swift:2255-2296 y de CustomizationCenter; no portado.
                ErrorMessage = "!mod todavía no está disponible en Windows.";
                return;
            default:
            {
                // TODO(port): los comandos de mods (customization.commands) y su modo terminal vienen de ChatStore.swift:2300-2352; no portados.
                var template = JackTemplates.FirstOrDefault(item => item.Name == name);
                if (template is null)
                {
                    ErrorMessage = "Comando !" + name + " desconocido. Consulta !comandos. Para enviar un ! literal escribe !!.";
                    return;
                }
                var prompt = template.Prompt.Contains("{{args}}", StringComparison.Ordinal)
                    ? template.Prompt.Replace("{{args}}", a, StringComparison.Ordinal)
                    : template.Prompt + (a.Length == 0 ? "" : "\n" + a);
                Send(prompt.StartsWith('!') ? "!" + prompt : prompt, id, []);
                return;
            }
        }

        Conversations[i].JackContext = settings;
        Notify(nameof(Conversations));
        JackNotice("!" + name + ": configuración guardada.", id);
    }

    /// <summary>Compacta el contexto: pide al agente un resumen de hasta `target` tokens; al terminar, la siguiente respuesta usa una sesión nueva.</summary>
    private void BeginCompaction(Guid id, int target)
    {
        LoadTranscript(id);
        var conversation = Conversations.FirstOrDefault(item => item.Id == id);
        if (conversation is null) return;

        _cancelledJackTurns.Remove(id);
        _compactions[id] = (target, conversation.Messages.Count);
        var history = conversation.SessionId is null ? "\n\nHistorial a resumir:\n" + JackTranscript(conversation) : "";
        Send("Resume el contexto de esta conversación para continuar en una sesión nueva con aproximadamente " + target
            + " tokens. Conserva objetivos, decisiones, restricciones, archivos relevantes y tareas pendientes. Incluye las instrucciones fijadas. "
            + "Devuelve únicamente el resumen. No uses herramientas ni modifiques archivos." + history, id, []);
    }

    /// <summary>
    /// Cierra un turno de Jack: cuenta el presupuesto, aplica una compactación o un traspaso pendientes y avisa si algo falló.
    /// Llamar desde el hilo de interfaz cuando el turno termina.
    /// </summary>
    internal void CompleteJackTurn(Guid id, bool cancelled)
    {
        var i = Conversations.FindIndex(conversation => conversation.Id == id);
        if (i < 0) return;

        if (Conversations[i].JackContext?.Budget is { } budget)
        {
            var context = Conversations[i].JackContext!;
            context.Spent += _budgetTurnUsage.GetValueOrDefault(id);
            var spent = context.Spent;
            if (spent >= (int)(budget * 0.8) && !context.BudgetWarned)
            {
                context.BudgetWarned = true;
                JackNotice("Presupuesto: " + spent + " / " + budget + " tokens observados. Aviso al superar el 80 %; el seguimiento es aproximado y no detiene al agente.", id);
            }
        }
        _budgetTurnUsage.Remove(id);
        _budgetBaseline.Remove(id);

        var explicitlyCancelled = _cancelledJackTurns.Remove(id);
        var success = !cancelled && !explicitlyCancelled && !(_statuses.TryGetValue(id, out var status) && status == ChatStatus.Failed);

        var seeded = _seededJackTurns.Remove(id);
        if (seeded && success && Conversations[i].JackContext is { } seededContext) seededContext.SeedDelivered = true;

        if (_compactions.Remove(id, out var operation))
        {
            var summary = Conversations[i].Messages.Skip(operation.Item2)
                .LastOrDefault(message => message.Role == "assistant" && !string.IsNullOrWhiteSpace(message.Text))?.Text;
            if (success && summary is not null)
            {
                var settings = CloneJackContext(Conversations[i].JackContext);
                settings.Seed = summary;
                settings.SeedDelivered = false;
                Conversations[i].JackContext = settings;
                Conversations[i].SessionId = null;
                Conversations[i].ContextUsage = null;
                Conversations[i].TokenUsage = null;
                _tokenUsage.Remove(id);
                if (_liveDrivers.Remove(id, out var liveDriver)) liveDriver.Close();
                Notify(nameof(Conversations));
                JackNotice("Contexto compactado: resumen de ≈" + JackCommandCatalog.EstimatedTokens(summary) + " tokens (objetivo: ≈" + operation.Item1
                    + "). La próxima respuesta usará una sesión nueva. El historial sigue disponible.", id);
                // Con la compactación hecha, el mensaje que esperaba se envía a la sesión nueva; no vuelve a compactar.
                if (_afterCompaction.Remove(id, out var next)) Send(next.Item1, id, next.Item2);
            }
            else
            {
                if (_afterCompaction.Remove(id, out var pending))
                {
                    JackNotice("La compactación no terminó. Mensaje pendiente (vuelve a enviarlo):\n" + pending.Item1, id);
                    if (pending.Item2.Count > 0)
                    {
                        Conversations[i].Messages.Add(new ChatMessage { Role = "jack", Text = "Archivos del mensaje pendiente", Attachments = pending.Item2.ToList() });
                    }
                }
                JackNotice("No se sustituyó el contexto: la compactación falló o se canceló.", id);
            }
        }

        if (_handoffs.Remove(id, out var handoff) && success)
        {
            var reply = Conversations[i].Messages.Skip(handoff.Item2)
                .LastOrDefault(message => message.Role == "assistant" && message.Text.Length > 0)?.Text;
            if (reply is not null) ForkJack(Conversations[i], "Traspaso a " + handoff.Item1.Title(), reply, handoff.Item1);
        }
    }

    /// <summary>Crea una conversación independiente con el contexto de `source`, y la selecciona.</summary>
    private void ForkJack(ChatConversation source, string title, string seed, ChatProvider? provider = null)
    {
        var settings = CloneJackContext(source.JackContext);
        settings.Seed = seed;
        settings.SeedDelivered = false;
        settings.Spent = 0;
        settings.BudgetWarned = false;

        var c = source with
        {
            Id = Guid.NewGuid(),
            Title = TakeTextElements(title, 120),
            SessionId = null,
            ParentId = source.Id,
            UpdatedAt = DateTime.UtcNow,
            HasUnread = null,
            ContextUsage = null,
            TokenUsage = null,
            // Como en Swift, la copia no comparte listas con el original.
            Messages = source.Messages.Select(message => message with { }).ToList(),
            ExtraDirectories = source.ExtraDirectories?.ToList(),
            JackContext = settings,
        };

        if (provider is { } target && target != source.Provider)
        {
            c.Provider = target;
            c.Model = target.DefaultModel();
            c.Mode = DefaultMode(target);
            c.Variant = null;
            c.Effort = Clamp("high", SupportedEfforts(target, c.Model));
        }

        Conversations.Insert(0, c);
        _loaded.Add(c.Id);
        Save(c.Id);
        Select(c.Id);
        JackNotice("Conversación independiente creada. El contexto anterior se enviará al escribir el primer mensaje.", c.Id);
    }

    /// <summary>Ruta del archivo de un checkpoint: nombre codificado en base64 bajo Checkpoints/&lt;id&gt; del archivo.</summary>
    private string CheckpointUrl(Guid id, string name)
    {
        // Un nombre de archivo acotado y reversible impide que la ruta salga del archivo de chats.
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(name)).Replace('/', '_').Replace('+', '-');
        return Path.Combine(_archive.Directory, "Checkpoints", id.ToString("D").ToUpperInvariant(), encoded + ".json");
    }

    /// <summary>Gestiona las plantillas personales (!comandos crear | eliminar) y guarda commands.json en la carpeta del archivo.</summary>
    private void ManageJackTemplates(string arguments, Guid id)
    {
        var parts = SplitJackWords(arguments, 3);
        if (parts.Count == 0)
        {
            // TODO(port): las filas de mods (customization.commands, ChatStore.swift:2359) no se portan todavía; en Normal no hay mods.
            var rows = JackCommandCatalog.Builtins.Select(builtin => "!" + builtin.Name + " " + builtin.ArgumentHint + " — " + builtin.Description)
                .Concat(JackTemplates.Select(template => "!" + template.Name + " — " + template.Prompt));
            JackNotice(string.Join("\n", rows) + "\n\nPlantillas: !comandos crear nombre texto ({{args}} inserta argumentos); !comandos eliminar nombre.", id);
            return;
        }

        var templates = JackTemplates.ToList();
        if (parts.Count == 3 && parts[0] == "crear")
        {
            var name = parts[1].ToLowerInvariant();
            if (name.Length == 0
                || !name.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_')
                || JackCommandCatalog.Builtins.Any(builtin => builtin.Name == name))
            {
                ErrorMessage = "Usa un nombre con letras, números, - o _, sin ! y distinto a los comandos integrados.";
                return;
            }
            templates.RemoveAll(template => template.Name == name);
            templates.Add(new JackCommandTemplate { Name = name, Prompt = parts[2] });
        }
        else if (parts.Count == 2 && parts[0] == "eliminar" && templates.Any(template => template.Name == parts[1]))
        {
            templates.RemoveAll(template => template.Name == parts[1]);
        }
        else
        {
            ErrorMessage = "Uso: !comandos crear nombre texto | eliminar nombre.";
            return;
        }

        try
        {
            WriteTextAtomically(Path.Combine(_archive.Directory, "commands.json"), JsonSerializer.Serialize(templates, SwiftJson.Options));
            JackTemplates = templates;
            Notify(nameof(JackTemplates));
            JackNotice("Plantillas personales actualizadas.", id);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ErrorMessage = "No se pudieron guardar los comandos: " + exception.Message;
        }
    }

    /// <summary>Comandos de barra de Jack: los integrados, seguidos de las plantillas personales. En Swift, `jackCommands`.</summary>
    public IReadOnlyList<ChatCommand> JackCommands
    {
        get
        {
            // TODO(port): los comandos de mods (customization.commands) se añaden aquí cuando se porte CustomizationCenter.
            var templates = JackTemplates.Select(template => new ChatCommand
            {
                Name = template.Name,
                Description = template.Prompt,
                ArgumentHint = "argumentos opcionales",
            });
            return JackCommandCatalog.Builtins.Concat(templates).ToList();
        }
    }

    /// <summary>Copia de los ajustes de Jack con su propia lista de instrucciones fijadas, para editarla sin tocar el original.</summary>
    private static JackContextSettings CloneJackContext(JackContextSettings? source) =>
        source is null ? new JackContextSettings() : source with { Pinned = source.Pinned.ToList() };

    /// <summary>Convierte el argumento en un entero positivo de hasta 2 000 000, o null si no es válido.</summary>
    private static int? ParsePositive(string? value)
    {
        if (value is null || !int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number)) return null;
        return number > 0 && number <= 2_000_000 ? number : null;
    }

    /// <summary>Parte el texto en palabras separadas por espacios. Como `split(maxSplits:)` de Swift, la última parte conserva el resto tal cual.</summary>
    private static List<string> SplitJackWords(string text, int maxParts)
    {
        var parts = new List<string>();
        var index = 0;
        while (index < text.Length)
        {
            while (index < text.Length && char.IsWhiteSpace(text[index])) index++;
            if (index >= text.Length) break;
            if (parts.Count == maxParts - 1)
            {
                parts.Add(text[index..]);
                break;
            }
            var start = index;
            while (index < text.Length && !char.IsWhiteSpace(text[index])) index++;
            parts.Add(text[start..index]);
        }
        return parts;
    }

    /// <summary>Primeros `count` caracteres de usuario (grafemas), como `prefix(_:)` de Swift.</summary>
    private static string TakeTextElements(string text, int count)
    {
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var end = 0;
        var taken = 0;
        while (taken < count && enumerator.MoveNext())
        {
            end = enumerator.ElementIndex + enumerator.GetTextElement().Length;
            taken++;
        }
        return text[..end];
    }

    /// <summary>Proveedor cuyo nombre interno (rawValue) es `raw`, o null.</summary>
    private static ChatProvider? ProviderFromRawValue(string raw)
    {
        foreach (var provider in Enum.GetValues<ChatProvider>())
        {
            if (ProviderRawValue(provider) == raw) return provider;
        }
        return null;
    }

    /// <summary>Escribe el texto en un archivo temporal y lo renombra encima, para no dejar un archivo a medias.</summary>
    private static void WriteTextAtomically(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        File.Move(temporary, path, overwrite: true);
    }
}
