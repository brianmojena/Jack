using System.Globalization;

namespace Jack.Core;

// Port de la parte de Claude Code de `enum ChatRunConfiguration` (Sources/JackCore/ChatDrivers.swift, ~1962-2268):
// argv, entorno y directorio de ejecución del proceso `claude`. No lanza procesos.
// Pendiente: Codex (codexTurn, codexDelegation), OpenCode (openCodeConfig, openCodeDelegation, openCodePrompt),
// Antigravity (antigravityArguments), Qoder (qoderArguments, qoderPermissionMode, qoderJackMode, qoderDelegation)
// y Stellar. Se portan con sus controladores.
public static class ChatRunConfiguration
{
    /// <summary>
    /// argv de `claude` para un proceso local (claudeRemoteArgs de Swift sin SSH ni delegación). Siempre en stream-json:
    /// Jack envía los mensajes por stdin y recibe eventos por stdout, y los permisos viajan por stdio.
    /// </summary>
    public static IReadOnlyList<string> ClaudeArguments(ChatConversation conversation, bool lightMode = false)
    {
        var arguments = new List<string>
        {
            "--print", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json",
            "--include-partial-messages", "--permission-prompt-tool", "stdio",
            // Repite cada mensaje cuando el agente lo lee: así un mensaje en cola pasa al chat en ese momento.
            "--replay-user-messages",
        };
        arguments.AddRange(lightMode ? new[] { "--prompt-suggestions" } : new[] { "--prompt-suggestions", "false" });
        arguments.AddRange(ClaudeSettings(conversation));
        if (!string.IsNullOrEmpty(conversation.SessionId)) arguments.AddRange(new[] { "--resume", conversation.SessionId });
        if (AgentInstructions() is { } instructions) arguments.AddRange(new[] { "--append-system-prompt", instructions });
        // TODO(port): con delegación de Jack faltan --mcp-config y --allowedTools (claudeDelegation), y las instrucciones
        // de delegación, imágenes, notebooks y artefactos. Vienen de AgentBridge.swift, NotebookSession.swift y Artifacts.swift.
        return arguments;
    }

    /// <summary>
    /// Ajustes que Claude Code recibe al arrancar: carpetas extra, modo, permisos y modelo; el esfuerzo solo si el modelo lo admite.
    /// Modo y modelo también se cambian en vivo, por eso esta lista no hace falta para ellos en cada turno.
    /// </summary>
    public static IReadOnlyList<string> ClaudeSettings(ChatConversation conversation)
    {
        var effort = ChatModelChoice.ClaudeEfforts(conversation.Model).Contains(conversation.Effort)
            ? new[] { "--effort", conversation.Effort }
            : Array.Empty<string>();
        // Los agentes remotos no pueden usar carpetas locales. `--add-dir` es variádico: cada carpeta va seguida de otro flag.
        var directories = conversation.Remote == null
            ? conversation.AdditionalDirectories.Concat(conversation.AttachmentDirectories).SelectMany(directory => new[] { "--add-dir", directory })
            : Enumerable.Empty<string>();
        var settings = new List<string>(directories)
        {
            // Hace seleccionable bypassPermissions mientras corre la sesión; no lo activa por sí mismo.
            "--permission-mode", conversation.Mode ?? "manual", "--allow-dangerously-skip-permissions", "--model", conversation.Model,
        };
        settings.AddRange(effort);
        return settings;
    }

    /// <summary>
    /// Lo que un proceso de Claude Code en marcha no puede cambiar. El modo y el modelo cambian en vivo; los adjuntos de un
    /// mensaje no entran, para que adjuntar un archivo no reinicie la sesión.
    /// </summary>
    public static IReadOnlyList<string> ClaudeLaunchSignature(ChatConversation conversation)
    {
        var effort = ChatModelChoice.ClaudeEfforts(conversation.Model).Contains(conversation.Effort) ? conversation.Effort : "";
        var signature = new List<string> { conversation.ProjectPath, effort };
        signature.AddRange(conversation.AdditionalDirectories);
        // Cambiar de equipo reinicia la sesión (campos remotos de la firma; el lanzamiento SSH no está portado).
        if (conversation.Remote is { } remote)
        {
            signature.Add("ssh:" + remote.Destination);
            signature.Add(remote.SshPort?.ToString(CultureInfo.InvariantCulture) ?? "");
            signature.Add(remote.RemotePath ?? "");
        }
        return signature;
    }

    /// <summary>Entorno de Claude Code: sugerencias de prompt y, sobre todo, el canal de progreso de Jack (que gana en empates).</summary>
    public static Dictionary<string, string> ClaudeEnvironment(ChatConversation conversation, bool lightMode)
    {
        var environment = ClaudeSuggestionEnvironment(conversation, lightMode);
        foreach (var (key, value) in ProgressFiles.EnvironmentFor(conversation.Id)) environment[key] = value;
        return environment;
    }

    /// <summary>Sugerencias de prompt: en modo ligero solo las tiene el agente principal, no los delegados.</summary>
    public static Dictionary<string, string> ClaudeSuggestionEnvironment(ChatConversation conversation, bool lightMode)
    {
        if (lightMode)
        {
            return conversation.ParentId == null
                ? new Dictionary<string, string> { ["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "true" }
                : new Dictionary<string, string>();
        }
        return new Dictionary<string, string> { ["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "false" };
    }

    /// <summary>Directorio de ejecución de `claude`: la carpeta del proyecto.</summary>
    public static string ClaudeDirectory(ChatConversation conversation) => conversation.ProjectPath;

    /// <summary>
    /// Instrucciones que Jack añade a cada agente local: cómo mostrar el progreso (ProgressFiles).
    /// Null si no hay nada que añadir.
    /// </summary>
    // TODO(port): con delegación se añaden ChatDelegation.instructions e imageInstructions (AgentBridge.swift),
    // NotebookWorkspace.agentInstructions (NotebookSession.swift) y ArtifactLibrary.agentInstructions (Artifacts.swift).
    public static string? AgentInstructions() => ProgressFiles.IsAvailable ? ProgressFiles.HelperInstructions : null;
}
