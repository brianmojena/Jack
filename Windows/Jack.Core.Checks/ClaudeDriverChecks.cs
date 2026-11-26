using Jack.Core;

namespace Jack.Core.Checks;

// Comprobaciones puras de ClaudeChatDriver: argumentos, firma de arranque, entorno y carpeta de ejecución de Claude Code.
// No lanza ningún proceso. Lanza InvalidOperationException si algo falla.
public static class ClaudeDriverChecks
{
    private const string Project = @"C:\Proyectos\Jack";
    private const string Extra = @"C:\Datos\Notas";

    public static void Run()
    {
        CheckStreamJsonArguments();
        CheckPermissionModeAndModel();
        CheckEffortOnlyWhenSupported();
        CheckSessionResume();
        CheckExtraDirectories();
        CheckLightModeArguments();
        CheckLaunchSignature();
        CheckSuggestionEnvironment();
        CheckWorkingDirectory();
    }

    private static void CheckStreamJsonArguments()
    {
        var arguments = Arguments(Conversation());
        Check(Pair(arguments, "--input-format", "stream-json"), "Claude Code recibe stream-json por stdin.");
        Check(Pair(arguments, "--output-format", "stream-json"), "Claude Code emite stream-json por stdout.");
        Check(arguments.Contains("--print") && arguments.Contains("--verbose") && arguments.Contains("--include-partial-messages"),
            "Claude Code corre sin interfaz con eventos parciales.");
        Check(Pair(arguments, "--permission-prompt-tool", "stdio"), "Los permisos viajan por stdio (canal del SDK).");
        Check(arguments.Contains("--replay-user-messages"), "Los mensajes en cola se repiten al leerlos.");
        Check(Pair(arguments, "--prompt-suggestions", "false"), "El modo normal desactiva las sugerencias de prompt.");
    }

    private static void CheckPermissionModeAndModel()
    {
        var manual = Arguments(Conversation(mode: null));
        Check(Pair(manual, "--permission-mode", "manual"), "Sin modo elegido, Claude Code arranca en manual.");
        Check(Pair(manual, "--model", "sonnet"), "El modelo se pasa con --model.");
        Check(manual.Contains("--allow-dangerously-skip-permissions"), "bypassPermissions queda disponible durante la sesión.");

        var plan = Arguments(Conversation(mode: "plan"));
        Check(Pair(plan, "--permission-mode", "plan"), "El modo elegido llega a --permission-mode.");
    }

    private static void CheckEffortOnlyWhenSupported()
    {
        Check(Pair(Arguments(Conversation("sonnet", "high")), "--effort", "high"), "Sonnet acepta esfuerzo alto.");
        Check(Pair(Arguments(Conversation("claude-haiku-5-5", "xhigh")), "--effort", "xhigh"), "Haiku 5 acepta xhigh.");
        Check(!Arguments(Conversation("claude-opus-4-5", "xhigh")).Contains("--effort"),
            "Opus 4.5 no admite xhigh: se omite --effort.");
        Check(!Arguments(Conversation("haiku", "high")).Contains("--effort"), "El alias haiku no admite esfuerzo.");
    }

    private static void CheckSessionResume()
    {
        var resumed = Conversation();
        resumed.SessionId = "sesion-1";
        Check(Pair(Arguments(resumed), "--resume", "sesion-1"), "Una sesión guardada se reanuda con --resume.");
        Check(!Arguments(Conversation()).Contains("--resume"), "Sin sesión guardada no hay --resume.");
    }

    private static void CheckExtraDirectories()
    {
        var conversation = Conversation();
        conversation.ExtraDirectories = new List<string> { Extra, Project, Extra };
        var arguments = Arguments(conversation);
        Check(Pair(arguments, "--add-dir", Extra), "Las carpetas extra se pasan con --add-dir.");
        Check(arguments.Count(argument => argument == "--add-dir") == 1,
            "La carpeta del proyecto y los duplicados no se repiten en --add-dir.");
    }

    private static void CheckLightModeArguments()
    {
        var light = Arguments(Conversation(), lightMode: true);
        Check(light.Contains("--prompt-suggestions") && !Pair(light, "--prompt-suggestions", "false"),
            "El modo ligero activa las sugerencias de prompt.");
    }

    private static void CheckLaunchSignature()
    {
        var conversation = Conversation("claude-opus-4-5", "xhigh");
        conversation.ExtraDirectories = new List<string> { Extra };
        var signature = ChatRunConfiguration.ClaudeLaunchSignature(conversation);
        Check(signature[0] == Project, "La firma empieza por la carpeta del proyecto.");
        Check(signature[1] == "", "Un esfuerzo que el modelo no admite no entra en la firma.");
        Check(signature.Contains(Extra), "Las carpetas extra forman parte de la firma.");

        var planned = ChatRunConfiguration.ClaudeLaunchSignature(Conversation(mode: "plan"));
        Check(planned.SequenceEqual(ChatRunConfiguration.ClaudeLaunchSignature(Conversation(mode: null))),
            "Cambiar de modo no cambia la firma: el modo se aplica en vivo sin reiniciar el proceso.");
    }

    private static void CheckSuggestionEnvironment()
    {
        const string key = "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION";
        Check(ChatRunConfiguration.ClaudeSuggestionEnvironment(Conversation(), lightMode: false)[key] == "false",
            "El modo normal desactiva las sugerencias en el entorno.");
        Check(ChatRunConfiguration.ClaudeSuggestionEnvironment(Conversation(), lightMode: true)[key] == "true",
            "El modo ligero activa las sugerencias del agente principal.");
        var delegated = Conversation();
        delegated.ParentId = Guid.NewGuid();
        Check(!ChatRunConfiguration.ClaudeSuggestionEnvironment(delegated, lightMode: true).ContainsKey(key),
            "Un agente delegado no recibe sugerencias en modo ligero.");
    }

    private static void CheckWorkingDirectory()
    {
        Check(ChatRunConfiguration.ClaudeDirectory(Conversation()) == Project, "Claude Code corre en la carpeta del proyecto.");
    }

    private static ChatConversation Conversation(string model = "sonnet", string effort = "high", string? mode = null) =>
        new(Project, ChatProvider.Claude, model) { Effort = effort, Mode = mode };

    private static IReadOnlyList<string> Arguments(ChatConversation conversation, bool lightMode = false) =>
        ChatRunConfiguration.ClaudeArguments(conversation, lightMode);

    /// <summary>True si <paramref name="flag"/> va seguido inmediatamente de <paramref name="value"/>.</summary>
    private static bool Pair(IReadOnlyList<string> arguments, string flag, string value)
    {
        for (var i = 0; i + 1 < arguments.Count; i++)
        {
            if (arguments[i] == flag && arguments[i + 1] == value) return true;
        }
        return false;
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
