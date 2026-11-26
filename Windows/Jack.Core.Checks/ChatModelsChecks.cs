using System.Text.Json;
using Jack.Core;

namespace Jack.Core.Checks;

// Comprobaciones de ChatModels.cs. Lanza InvalidOperationException si algo falla.
public static class ChatModelsChecks
{
    public static void Run()
    {
        CheckChatCommandParse();
        CheckJackCommandCatalogParse();
        CheckRunModeChoices();
        CheckExecutableName();
        CheckAdditionalDirectories();
        CheckConversationJsonRoundTrip();
    }

    private static void CheckChatCommandParse()
    {
        var parsed = ChatCommand.Parse("/compact  8000 tokens ");
        Check(parsed is { Name: "compact", Arguments: "8000 tokens" }, "ChatCommand.Parse separa nombre y argumentos.");
        var bare = ChatCommand.Parse("/contexto");
        Check(bare is { Name: "contexto", Arguments: "" }, "ChatCommand.Parse acepta un comando sin argumentos.");
        Check(ChatCommand.Parse("hola /compact") is null, "ChatCommand.Parse ignora un prompt normal.");
        Check(ChatCommand.Parse("/") is null, "ChatCommand.Parse rechaza un nombre vacío.");
        Check(ChatCommand.Parse("/ruta/absoluta") is null, "ChatCommand.Parse rechaza nombres con barra.");
    }

    private static void CheckJackCommandCatalogParse()
    {
        var parsed = JackCommandCatalog.Parse("!Build  x y ");
        Check(parsed is { Name: "build", Arguments: "x y" }, "JackCommandCatalog.Parse pasa el nombre a minúsculas.");
        Check(JackCommandCatalog.Parse("!!literal") is null, "JackCommandCatalog.Parse ignora !!.");
        Check(JackCommandCatalog.Parse("hola") is null, "JackCommandCatalog.Parse ignora texto sin !.");
        Check(JackCommandCatalog.EstimatedTokens("") == 1, "EstimatedTokens devuelve al menos 1.");
        Check(JackCommandCatalog.EstimatedTokens("abcdefgh") == 2, "EstimatedTokens aproxima cuatro bytes por token.");
    }

    private static void CheckRunModeChoices()
    {
        var codex = ChatRunMode.Choices(ChatProvider.Codex).Select(mode => mode.Id).ToArray();
        Check(codex.SequenceEqual(["default", "plan", "auto"]), "Codex ofrece Normal, Plan y Auto.");
        var claude = ChatRunMode.Choices(ChatProvider.Claude).Select(mode => mode.Id).ToArray();
        Check(claude.SequenceEqual(["manual", "plan", "auto", "acceptEdits", "dontAsk"]), "Claude Code ofrece sus cinco modos.");
        Check(ChatRunMode.Choices(ChatProvider.OpenCode).Count == 0, "OpenCode no ofrece modos.");
        Check(ChatRunMode.Bypass.Id == "bypassPermissions", "Bypass usa bypassPermissions.");
        Check(!ChatRunMode.Choices(ChatProvider.Claude).Contains(ChatRunMode.Bypass), "Bypass no forma parte del ciclo de modos.");
    }

    private static void CheckExecutableName()
    {
        Check(ChatProvider.Antigravity.ExecutableName() == "agy", "Antigravity instala agy.");
        Check(ChatProvider.Qoder.ExecutableName() == "qodercli", "Qoder instala qodercli.");
        Check(ChatProvider.Codex.ExecutableName() == "codex", "Codex usa su rawValue como ejecutable.");
        Check(ChatProvider.OpenCode.ExecutableName() == "opencode", "OpenCode usa su rawValue como ejecutable.");
        Check(ChatProvider.Antigravity.IsNormalOnly() && ChatProvider.Qoder.IsNormalOnly(), "Antigravity y Qoder son solo Normal.");
        Check(!ChatProvider.Codex.IsNormalOnly(), "Codex no es solo Normal.");
    }

    private static void CheckAdditionalDirectories()
    {
        var project = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "jack-proyecto"));
        var extra = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "jack-extra"));
        var conversation = new ChatConversation(project)
        {
            ExtraDirectories = [project, "", extra, extra, Path.Combine(Path.GetTempPath(), "jack-otra")]
        };
        var directories = conversation.AdditionalDirectories;
        Check(directories.Count == 2, "AdditionalDirectories quita el proyecto, vacíos y duplicados.");
        Check(directories[0] == extra, "AdditionalDirectories conserva el orden.");
        Check(new ChatConversation(project).AdditionalDirectories.Count == 0, "Sin extras, AdditionalDirectories está vacío.");
    }

    private static void CheckConversationJsonRoundTrip()
    {
        var updatedAt = new DateTime(2026, 11, 23, 10, 0, 0, DateTimeKind.Utc);
        var id = Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e");
        var conversation = new ChatConversation(Path.GetFullPath(Path.GetTempPath()), ChatProvider.Antigravity)
        {
            Id = id,
            Title = "Prueba de formato",
            SessionId = "sesion-1",
            UpdatedAt = updatedAt,
            Messages = [new ChatMessage { Role = "user", Text = "hola", Attachments = ["a.txt"] }],
            TokenUsage = new ChatTokenUsage { Input = 10, Output = 5, CostUsd = 0.25 },
            ContextUsage = new ChatContextUsage { Used = 100, Window = 1000 },
            ParentId = Guid.Parse("11111111-2222-3333-4444-555555555555"),
            Remote = new ChatRemoteEndpoint { Destination = "usuario@equipo", SshPort = 2222 }
        };

        var json = JsonSerializer.Serialize(conversation, ChatJson.Options);
        using (var document = JsonDocument.Parse(json))
        {
            var root = document.RootElement;
            Check(root.GetProperty("sessionID").GetString() == "sesion-1", "El JSON usa sessionID como Swift.");
            Check(root.GetProperty("provider").GetString() == "antigravity", "El proveedor se guarda por su rawValue.");
            Check(root.GetProperty("id").GetString() == id.ToString("D").ToUpperInvariant(), "El UUID se guarda en mayúsculas.");
            Check(root.GetProperty("parentID").GetString() == "11111111-2222-3333-4444-555555555555", "parentID usa el nombre de Swift.");
            Check(root.GetProperty("tokenUsage").GetProperty("costUSD").GetDouble() == 0.25, "costUSD usa el nombre de Swift.");
            Check(root.GetProperty("remote").GetProperty("sshPort").GetInt32() == 2222, "El endpoint remoto conserva su puerto.");
            var secondsSince2001 = (updatedAt - new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            Check(root.GetProperty("updatedAt").GetDouble() == secondsSince2001, "Las fechas son segundos desde 2001 como en Swift.");
            Check(!root.TryGetProperty("additionalDirectories", out _), "AdditionalDirectories no se serializa.");
            Check(!root.TryGetProperty("pinnedAt", out _), "Los opcionales nulos se omiten como en Swift.");
        }

        var decoded = JsonSerializer.Deserialize<ChatConversation>(json, ChatJson.Options)
            ?? throw new InvalidOperationException("El JSON de ChatConversation no se pudo leer.");
        Check(decoded.Id == id && decoded.Provider == ChatProvider.Antigravity, "La ida y vuelta conserva identidad y proveedor.");
        Check(decoded.Model == ChatProvider.Antigravity.DefaultModel(), "La ida y vuelta conserva el modelo.");
        Check(decoded.Messages.Count == 1 && decoded.Messages[0].Attachments?[0] == "a.txt", "La ida y vuelta conserva los mensajes.");
        Check(decoded.Remote?.SshPort == 2222 && decoded.Remote.IsValid, "La ida y vuelta conserva el endpoint remoto.");
        Check(JsonSerializer.Serialize(decoded, ChatJson.Options) == json, "Serializar de nuevo produce el mismo JSON.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
