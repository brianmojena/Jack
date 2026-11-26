namespace Jack.Core;

// Port de `enum ChatCommandService` en Sources/JackCore/ChatDrivers.swift:1915-1962: carga de los comandos de barra
// de un proveedor. Solo Claude Code está portado; el resto queda como TODO(port).
public static class ChatCommandService
{
    /// <summary>Tiempo máximo que espera Claude Code a anunciar sus comandos (como en Swift).</summary>
    private static readonly TimeSpan ClaudeCommandTimeout = TimeSpan.FromSeconds(45);

    /// <summary>Lee los comandos del proveedor para el directorio dado.</summary>
    public static async Task<IReadOnlyList<ChatCommand>> LoadAsync(ChatProvider provider, string directory)
    {
        switch (provider)
        {
            case ChatProvider.Claude:
                return await ClaudeAsync(directory);
            case ChatProvider.Stellar:
                return Array.Empty<ChatCommand>();
            case ChatProvider.Antigravity:
            case ChatProvider.Qoder:
                throw ChatDriverError.ProtocolFailure($"{provider.Title()} no expone su lista de comandos por el protocolo headless.");
            // TODO(port): Codex (skills/list por app-server) viene de ChatDrivers.swift:1944-1961; no portado.
            // TODO(port): OpenCode (GET /command con OpenCodeModelService.withServer) viene de ChatDrivers.swift:1923-1930; no portado.
            default:
                throw ChatDriverError.ProtocolFailure($"{provider.Title()} todavía no informa de sus comandos en Windows.");
        }
    }

    /// <summary>Claude Code anuncia sus comandos al arrancar, antes de leer ningún mensaje.</summary>
    private static async Task<IReadOnlyList<ChatCommand>> ClaudeAsync(string directory)
    {
        var executable = ExecutableResolver.Resolve("claude", ChatDriverSettings.ExecutableOverride("claude"))
            ?? throw ChatDriverError.ExecutableMissing("claude");
        string[] arguments =
        [
            "--print", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--no-session-persistence",
        ];

        // El plazo cancela el proceso y, con él, la lectura de sus líneas.
        using var deadline = new CancellationTokenSource(ClaudeCommandTimeout);
        using var child = new StructuredChild(executable, arguments, directory, cancellationToken: deadline.Token);
        try
        {
            await foreach (var line in child.Lines)
            {
                if (ClaudeProtocol.ParseLine(line) is not { } obj) continue;
                if (ClaudeJson.Str(obj["subtype"]) != "commands_changed") continue;
                if (ClaudeJson.Objects(obj["commands"]) is not { } commands) continue;
                return ClaudeProtocol.Commands(commands);
            }
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested)
        {
            throw ChatDriverError.ProcessFailure($"Claude Code tardó más de {(int)ClaudeCommandTimeout.TotalSeconds} s en informar de sus comandos.");
        }

        throw ChatDriverError.ProcessFailure(
            await child.FailureDescriptionAsync("Claude Code se cerró sin informar de sus comandos (¿tardó más de 45 s?)"));
    }
}
