using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jack.Core;

namespace Jack.Core.Checks;

/// <summary>
/// Comprobaciones de las sesiones de Claude Code, del contenido de artefactos y de la decodificación de cuotas de Claude.
/// Usa una carpeta temporal con historiales .jsonl de ejemplo (formato real de Claude Code) que se borra al final.
/// </summary>
public static class ClaudeSessionsChecks
{
    /// <summary>Ejecuta todas las comprobaciones. Lanza InvalidOperationException si algo falla.</summary>
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "jack-claude-" + Guid.NewGuid().ToString("N"));
        var previousResultText = ClaudeSessionDependencies.ResultText;
        var previousHiddenTools = ClaudeSessionDependencies.HiddenTools;
        var previousBoundedJson = ClaudeSessionDependencies.BoundedJson;
        try
        {
            // Sustitutos de ClaudeProtocol.resultText, ClaudeProtocol.hiddenTools y boundedJSON, que aún no están portados.
            ClaudeSessionDependencies.ResultText = node => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";
            ClaudeSessionDependencies.HiddenTools = new HashSet<string>(StringComparer.Ordinal) { "ToolSearch" };
            ClaudeSessionDependencies.BoundedJson = node => node?.ToJsonString() ?? "null";
            RunChecks(root);
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new InvalidOperationException("ClaudeSessionsChecks: " + error.Message, error);
        }
        finally
        {
            ClaudeSessionDependencies.ResultText = previousResultText;
            ClaudeSessionDependencies.HiddenTools = previousHiddenTools;
            ClaudeSessionDependencies.BoundedJson = previousBoundedJson;
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static void RunChecks(string root)
    {
        var now = DateTime.UtcNow;
        var sessionsRoot = Path.Combine(root, "projects");
        var project = Path.Combine(root, "Proyecto");
        var missing = Path.Combine(root, "Borrado");
        var desktopRoot = Path.Combine(root, "Escritorio");
        Directory.CreateDirectory(project);
        var projectFolder = Path.Combine(sessionsRoot, ClaudeSessions.FolderName(project));
        var missingFolder = Path.Combine(sessionsRoot, ClaudeSessions.FolderName(missing));
        Directory.CreateDirectory(projectFolder);
        Directory.CreateDirectory(missingFolder);

        // Nombres de carpeta como los genera Claude Code.
        Check(ClaudeSessions.FolderName(@"C:\Users\X\proj") == "C--Users-X-proj", "Una ruta de Windows se codifica como la carpeta real de Claude Code.");
        Check(ClaudeSessions.FolderName(@"C:\Program Files\Pencil") == "C--Program-Files-Pencil", "Los espacios se convierten en guiones.");
        Check(ClaudeSessions.FolderName("C:\\a\uD83D\uDE00b") == "C--a-b", "Un grafema no ASCII (emoji) cuenta como un solo guion.");

        // Cuatro sesiones: A (con títulos y conversación completa), B (de un programa SDK), C (con título manual), D (carpeta borrada).
        const string sessionA = "aaaaaaaa-0000-4000-8000-000000000001";
        const string sessionB = "bbbbbbbb-0000-4000-8000-000000000002";
        const string sessionC = "cccccccc-0000-4000-8000-000000000003";
        const string sessionD = "dddddddd-0000-4000-8000-000000000004";
        var fileA = Path.Combine(projectFolder, sessionA + ".jsonl");
        var fileB = Path.Combine(projectFolder, sessionB + ".jsonl");
        var fileC = Path.Combine(projectFolder, sessionC + ".jsonl");
        var fileD = Path.Combine(missingFolder, sessionD + ".jsonl");

        WriteLines(fileA,
            Obj(("type", "user"), ("uuid", "u1"), ("entrypoint", "cli"), ("cwd", project), ("sessionId", sessionA),
                ("timestamp", "2026-11-23T10:00:00.000Z"), ("message", Obj(("role", "user"), ("content", "Revisa el archivo leeme")))),
            Obj(("type", "user"), ("uuid", "meta"), ("isMeta", true), ("message", Obj(("role", "user"), ("content", "Mensaje interno")))),
            Obj(("type", "assistant"), ("uuid", "s1"), ("isSidechain", true),
                ("message", Obj(("role", "assistant"), ("content", Arr(Obj(("type", "text"), ("text", "Subagente"))))))),
            Obj(("type", "assistant"), ("uuid", "a1"),
                ("message", Obj(("role", "assistant"), ("model", "claude-opus-5-5"), ("content", Arr(
                    Obj(("type", "thinking"), ("thinking", "Miro el archivo")),
                    Obj(("type", "text"), ("text", "Voy a leerlo.")),
                    Obj(("type", "tool_use"), ("id", "t1"), ("name", "Read"), ("input", Obj(("file_path", "leeme.md"))))))))),
            Obj(("type", "user"), ("uuid", "u2"),
                ("message", Obj(("role", "user"), ("content", Arr(
                    Obj(("type", "tool_result"), ("tool_use_id", "t1"), ("content", "contenido"), ("is_error", false))))))),
            Obj(("type", "assistant"), ("uuid", "a2"),
                ("message", Obj(("role", "assistant"), ("model", "claude-opus-5-5"), ("content", Arr(Obj(("type", "text"), ("text", "Listo."))))))),
            Obj(("type", "user"), ("uuid", "u3"),
                ("message", Obj(("role", "user"), ("content", "<command-name>usage</command-name><command-args></command-args>")))),
            Obj(("type", "ai-title"), ("aiTitle", "Revisar leeme"), ("sessionId", sessionA)),
            Obj(("type", "last-prompt"), ("lastPrompt", "Revisa el archivo leeme"), ("sessionId", sessionA)));

        WriteLines(fileB,
            Obj(("type", "user"), ("uuid", "b1"), ("entrypoint", "sdk-cli"), ("cwd", project),
                ("message", Obj(("role", "user"), ("content", "Otra tarea")))));

        WriteLines(fileC,
            Obj(("type", "user"), ("uuid", "c1"), ("entrypoint", "cli"), ("cwd", project),
                ("message", Obj(("role", "user"), ("content", "Tercera")))),
            Obj(("type", "ai-title"), ("aiTitle", "Título IA")),
            Obj(("type", "custom-title"), ("customTitle", "Título manual")));

        WriteLines(fileD,
            Obj(("type", "user"), ("uuid", "d1"), ("entrypoint", "cli"), ("cwd", missing),
                ("message", Obj(("role", "user"), ("content", "Carpeta borrada")))));

        // Orden por fecha de modificación: C (1 h), B (2 h), A (3 h); D es más reciente pero su carpeta no existe.
        File.SetLastWriteTimeUtc(fileA, now.AddHours(-3));
        File.SetLastWriteTimeUtc(fileB, now.AddHours(-2));
        File.SetLastWriteTimeUtc(fileC, now.AddHours(-1));
        File.SetLastWriteTimeUtc(fileD, now.AddMinutes(-30));

        // Listado por proyecto.
        var listed = ClaudeSessions.ListRecent(project, root: sessionsRoot);
        Check(listed.Select(session => session.Id).SequenceEqual(new[] { sessionC, sessionB, sessionA }),
            "La lista va de la sesión más nueva a la más antigua.");
        Check(listed[0].Title == "Título manual", "custom-title tiene prioridad sobre ai-title.");
        Check(listed[1].Title == "Otra tarea", "Sin títulos, se usa el primer prompt del usuario.");
        Check(listed[2].Title == "Revisar leeme", "ai-title se usa si no hay custom-title.");
        Check(listed[1].Entrypoint == "sdk-cli", "El punto de entrada se lee de la cabecera de la sesión.");
        Check(listed[0].ProjectPath == project, "La carpeta de trabajo viene del campo cwd.");
        Check(ClaudeSessions.ListRecent(project, limit: 1, root: sessionsRoot).Count == 1, "limit limita el número de sesiones.");

        // Carga de la conversación: se omiten las líneas de subagentes y meta, y el resultado de una herramienta se une a su llamada.
        var summaryA = listed.Single(session => session.Id == sessionA);
        var loaded = ClaudeSessions.Load(summaryA, sessionsRoot);
        Check(loaded.Messages.Select(message => message.Role).SequenceEqual(new[] { "user", "reasoning", "assistant", "tool", "assistant", "user" }),
            "La conversación conserva prompts, razonamiento, respuestas y herramientas en orden.");
        Check(loaded.Messages[0].Text == "Revisa el archivo leeme", "El prompt del usuario se carga tal cual.");
        Check(loaded.Messages[1].Text == "Miro el archivo", "El razonamiento se carga como reasoning.");
        Check(loaded.Messages[3].Text == "Read" && loaded.Messages[3].Status == "completed", "La herramienta conserva su nombre y estado.");
        Check(loaded.Messages[3].Detail.Contains("leeme.md", StringComparison.Ordinal)
            && loaded.Messages[3].Detail.EndsWith("\ncontenido", StringComparison.Ordinal),
            "El detalle de la herramienta une la entrada y el resultado.");
        Check(loaded.Messages[5].Text == "/usage", "Un comando de barra se muestra como se escribió.");
        Check(loaded.Model == "opus", "El modelo se toma del último mensaje del asistente.");

        var missingSession = new ClaudeSessionSummary { Id = "no-existe", Title = "x", ProjectPath = project, UpdatedAt = now };
        var notFound = ClaudeSessions.Load(missingSession, sessionsRoot);
        Check(notFound.Messages.Count == 0 && notFound.Model is null, "Una sesión sin archivo devuelve una conversación vacía.");

        // Importación: sin D (carpeta borrada), sin B (SDK) y sin A (archivada en la app de Claude). C toma el título y el modelo de la app.
        var desktopSessions = Path.Combine(desktopRoot, "sesiones");
        Directory.CreateDirectory(desktopSessions);
        File.WriteAllText(Path.Combine(desktopSessions, "c.json"),
            Obj(("cliSessionId", sessionC), ("title", "Título de la app"), ("model", "claude-sonnet-4-6"), ("cwd", project)).ToJsonString());
        File.WriteAllText(Path.Combine(desktopSessions, "a.json"),
            Obj(("cliSessionId", sessionA), ("title", "Archivada"), ("isArchived", true), ("cwd", project)).ToJsonString());

        var since = now.AddHours(-4);
        var candidates = ClaudeSessions.ImportCandidates(since, 10, root: sessionsRoot, desktopRoot: desktopRoot);
        Check(candidates.Count == 1 && candidates[0].Id == sessionC, "Solo se importan las sesiones de terminal o de la app que siguen activas.");
        Check(candidates[0].Title == "Título de la app", "El título de la app de Claude tiene prioridad.");
        Check(candidates[0].Model == "sonnet", "El modelo de la app se reduce a su alias.");

        var excluded = ClaudeSessions.ImportCandidates(since, 10, excluding: new HashSet<string> { sessionC }, root: sessionsRoot, desktopRoot: desktopRoot);
        Check(excluded.Count == 0, "Las sesiones excluidas no se importan.");

        // Cuotas de Claude a partir del caché de ~/.claude.json.
        var fetchedMs = (long)(now.AddSeconds(-30) - DateTime.UnixEpoch).TotalMilliseconds;
        var cacheJson = $$"""
            {
              "oauthAccount": { "accountUuid": "cuenta-1" },
              "cachedUsageUtilization": {
                "fetchedAtMs": {{fetchedMs}},
                "accountUuid": "cuenta-1",
                "utilization": {
                  "five_hour": { "utilization": 42.5, "resets_at": "2026-11-23T18:00:00.000Z" },
                  "seven_day": { "utilization": 10, "resets_at": "2026-11-27T00:00:00Z" },
                  "limits": [
                    { "kind": "weekly_scoped", "scope": { "model": { "display_name": "Fable" } }, "percent": 77, "resets_at": "2026-11-27T00:00:00Z" }
                  ]
                }
              }
            }
            """;
        var config = JsonNode.Parse(cacheJson)!.AsObject();

        var fresh = UsageDecoder.ClaudeCache(config, now);
        Check(!fresh.IsCached, "Una lectura de hace 30 s es fresca.");
        Check(fresh.Windows.Count == 3, "El caché devuelve las ventanas de 5 h, 7 d y del modelo Fable.");
        Check(fresh.Windows[0].Id == "five_hour" && fresh.Windows[0].Title == "5 h" && fresh.Windows[0].UsedPercent == 42.5,
            "La ventana de 5 h conserva su porcentaje.");
        Check(fresh.Windows[0].ResetsAt == new DateTime(2026, 11, 23, 18, 0, 0, DateTimeKind.Utc), "El reinicio se lee como fecha ISO 8601.");
        Check(fresh.Windows[2].Id == "seven_day_fable" && fresh.Windows[2].Title == "Fable · 7 d" && fresh.Windows[2].UsedPercent == 77,
            "Los límites semanales de un modelo aparecen aparte.");

        var stale = UsageDecoder.ClaudeCache(config, now.AddMinutes(10));
        Check(stale.IsCached && stale.Note.StartsWith("Última lectura guardada", StringComparison.Ordinal),
            "Una lectura de hace más de 2 minutos se marca como guardada.");

        var otherAccount = JsonNode.Parse(cacheJson)!.AsObject();
        otherAccount["cachedUsageUtilization"]!.AsObject()["accountUuid"] = JsonValue.Create("cuenta-2");
        var mismatch = UsageDecoder.ClaudeCache(otherAccount, now);
        Check(mismatch.Windows.Count == 0 && mismatch.IsCached, "Una lectura de otra cuenta no se muestra.");

        var empty = UsageDecoder.ClaudeCache(new JsonObject(), now);
        Check(empty.IsCached && empty.Windows.Count == 0, "Sin caché, Claude informa de que aún no hay lectura.");

        // Evento rate_limit_event del flujo de Claude Code.
        var rateEvent = JsonNode.Parse("""{"type":"rate_limit_event","rate_limit_info":{"rateLimitType":"five_hour","status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.9,"resetsAt":1795456800},"seven_day":{"utilization":0.25}}}}""")!.AsObject();
        var decoded = UsageDecoder.ClaudeEvent(rateEvent);
        Check(decoded is not null && decoded.Windows.Count == 2, "El evento trae dos ventanas unificadas.");
        Check(decoded!.Windows[0].Id == "five_hour" && Math.Abs(decoded.Windows[0].UsedPercent!.Value - 90) < 1e-6,
            "La fracción de utilización se convierte en porcentaje.");
        Check(decoded.Windows[0].ResetsAt == DateTime.UnixEpoch.AddSeconds(1795456800), "El reinicio numérico se lee como segundos desde 1970.");
        Check(decoded.Windows[1].Id == "seven_day" && Math.Abs(decoded.Windows[1].UsedPercent!.Value - 25) < 1e-6 && decoded.Windows[1].ResetsAt is null,
            "Una ventana sin reinicio conserva su porcentaje.");

        var rejected = UsageDecoder.ClaudeEvent(JsonNode.Parse("""{"rate_limit_info":{"rateLimitType":"overage","status":"rejected"}}""")!.AsObject());
        Check(rejected is not null && rejected.Windows.Count == 1 && rejected.Windows[0].UsedPercent == 100 && rejected.Windows[0].Title == "Uso adicional",
            "Una ventana agotada sin porcentaje se muestra al 100 %.");
        Check(UsageDecoder.ClaudeEvent(JsonNode.Parse("""{"tipo":"otro"}""")!.AsObject()) is null, "Un evento sin ventanas no produce cuota.");

        // Lectura del archivo de configuración: con caché, y sin archivo.
        var configPath = Path.Combine(root, "claude.json");
        File.WriteAllText(configPath, cacheJson);
        var read = ChatUsageService.ReadClaudeAsync(configPath: configPath).GetAwaiter().GetResult();
        Check(read.Provider == ChatProvider.Claude && read.Windows.Count == 3, "ReadClaudeAsync lee el caché del archivo de configuración.");
        var withoutFile = ChatUsageService.ReadClaudeAsync(configPath: Path.Combine(root, "no-existe.json")).GetAwaiter().GetResult();
        Check(withoutFile.IsCached && withoutFile.Windows.Count == 0, "Sin archivo de configuración, no hay cuota y se informa de ello.");

        // Artefactos: solo cuenta el contenido completo; un update parcial después de create lo invalida.
        var artifactJson = """{"chat_messages":[{"uuid":"m1","content":[{"type":"tool_use","name":"artifacts","input":{"id":"art-1","command":"create","content":"<h1>Vista previa</h1>"}}]},{"uuid":"m2","parent_message_uuid":"m1","content":[{"type":"tool_use","name":"artifacts","input":{"id":"art-1","command":"update"}}]}],"current_leaf_message_uuid":"m2"}""";
        Check(ClaudeArtifactContent.Extract(Encoding.UTF8.GetBytes(artifactJson), "art-1") is null,
            "Un update parcial después de create no produce un documento completo.");
        var beforeUpdate = artifactJson.Replace("\"current_leaf_message_uuid\":\"m2\"", "\"current_leaf_message_uuid\":\"m1\"", StringComparison.Ordinal);
        Check(ClaudeArtifactContent.Extract(Encoding.UTF8.GetBytes(beforeUpdate), "art-1") == "<h1>Vista previa</h1>",
            "El contenido completo de create se extrae de la rama activa.");
        Check(ClaudeArtifactContent.KindName("text/markdown") == "markdown", "El tipo de artefacto se deduce del MIME.");

        var artifact = new ClaudeArtifact
        {
            Uuid = "uuid-1",
            ArtifactIdentifier = "art-1",
            ArtifactType = "text/html",
            Title = "Ejemplo",
            ChatConversationUuid = "chat-1",
        };
        Check(artifact.SourceUrl == new Uri("https://claude.ai/chat/chat-1?artifact=art-1"),
            "Sin publicación, el enlace abre la conversación con el artefacto seleccionado.");
    }

    /// <summary>Escribe un objeto JSON por línea, como hace Claude Code en sus .jsonl.</summary>
    private static void WriteLines(string path, params JsonObject[] lines) =>
        File.WriteAllLines(path, lines.Select(line => line.ToJsonString()));

    /// <summary>Construye un objeto JSON a partir de pares clave-valor (cadenas, booleanos, números y nodos).</summary>
    private static JsonObject Obj(params (string Key, object? Value)[] fields)
    {
        var result = new JsonObject();
        foreach (var (key, value) in fields) result[key] = ToNode(value);
        return result;
    }

    private static JsonArray Arr(params JsonObject[] items) => new(items);

    private static JsonNode? ToNode(object? value) => value switch
    {
        null => null,
        JsonNode node => node,
        string text => JsonValue.Create(text),
        bool flag => JsonValue.Create(flag),
        double number => JsonValue.Create(number),
        _ => throw new ArgumentException("Tipo no admitido en la comprobación: " + value.GetType().Name),
    };

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Comprobación fallida: " + message);
    }
}
