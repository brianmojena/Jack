using System.Text.Json.Nodes;

namespace Jack.Core;

// Port de Sources/JackCore/ChatDrivers.swift, líneas 1-107: ChatDriverFactory, ProcessChatDriver, PendingApproval y ChatDriverError.
//
// Hilos: en Swift todo ocurría en el MainActor. Aquí el estado del controlador se protege con `Gate` (un monitor reentrante).
// Las llamadas a onEvent se hacen SIEMPRE bajo ese candado y en orden, desde el hilo que produjo el evento: el hilo lector
// de stdout del proceso, o el hilo que llama a RunAsync/FollowAsync (eventos bufferizados, primer mensaje).
// Consecuencia: onEvent no debe bloquear; la capa de UI debe reenviar el evento a su hilo (DispatcherQueue) dentro del callback.

/// <summary>Crea el controlador nativo de un proveedor. En esta fase solo Claude Code está portado.</summary>
public static class ChatDriverFactory
{
    /// <summary>Minutos que un proceso de Claude Code inactivo sigue abierto tras un turno; 0 lo cierra de inmediato.</summary>
    public const string ClaudeKeepAliveKey = "claudeKeepAliveMinutes";

    public static IChatDriver Make(ChatProvider provider) => provider switch
    {
        ChatProvider.Claude => new ClaudeChatDriver(),
        // TODO(port): CodexChatDriver viene de ChatDrivers.swift (línea ~240).
        ChatProvider.Codex => throw NotPorted(provider),
        // TODO(port): OpenCodeChatDriver viene de ChatDrivers.swift (línea ~1438).
        ChatProvider.OpenCode => throw NotPorted(provider),
        // TODO(port): StellarChatDriver viene de StellarCode.swift (línea ~454).
        ChatProvider.Stellar => throw NotPorted(provider),
        // TODO(port): AntigravityChatDriver viene de ChatDrivers.swift (línea ~1292).
        ChatProvider.Antigravity => throw NotPorted(provider),
        // TODO(port): QoderChatDriver viene de ChatDrivers.swift (línea ~1361).
        ChatProvider.Qoder => throw NotPorted(provider),
        _ => throw new ArgumentOutOfRangeException(nameof(provider))
    };

    private static NotSupportedException NotPorted(ChatProvider provider) =>
        new($"El proveedor {provider.Title()} todavía no está portado a Windows.");
}

/// <summary>
/// Base de los controladores que hablan con un proceso (<c>ProcessChatDriver</c> en Swift). Los métodos virtuales
/// son las implementaciones por defecto de <see cref="IChatDriver"/>, igual que la clase base de Swift.
/// </summary>
public abstract class ProcessChatDriver : IChatDriver
{
    /// <summary>Candado del controlador (sustituye al MainActor de Swift). Reentrante; ver la nota de hilos del archivo.</summary>
    protected readonly object Gate = new();
    protected StructuredChild? Child;
    protected Guid RunGeneration = Guid.NewGuid();
    protected Dictionary<string, PendingApproval> PendingApprovals { get; } = new();

    public abstract Task RunAsync(ChatConversation conversation, string prompt, Action<ChatEvent> onEvent);

    public virtual Task RunAsync(ChatConversation conversation, string prompt, ChatDelegation? delegation, Action<ChatEvent> onEvent) =>
        RunAsync(conversation, prompt, onEvent);

    public virtual async Task RespondAsync(string approvalId, bool allow)
    {
        var pending = TakePendingApproval(approvalId);
        await ResolveAsync(pending, allow);
    }

    public virtual Task AnswerAsync(string approvalId, IReadOnlyDictionary<string, string> answers) =>
        Task.FromException(ChatDriverError.UnsupportedApproval());

    /// <summary>Responde con una de las opciones de la aprobación, "allow" o "deny".</summary>
    public virtual Task RespondAsync(string approvalId, string choice, string? message) =>
        RespondAsync(approvalId, choice != "deny");

    public virtual void Stop()
    {
        lock (Gate)
        {
            RunGeneration = Guid.NewGuid();
            Child?.Terminate();
            Child = null;
            PendingApprovals.Clear();
        }
    }

    public virtual void Stop(bool keepingQueued) => Stop();

    /// <summary>Resuelve una aprobación pendiente. Los controladores que no admiten aprobaciones lanzan error.</summary>
    protected virtual Task ResolveAsync(PendingApproval pending, bool allow) =>
        throw ChatDriverError.UnsupportedApproval();

    public virtual bool KeepsAlive => false;

    public virtual bool AwaitsStopAcknowledgement => false;

    public virtual void Observe(Action<ChatEvent> idle, Action unprompted) { }

    public virtual Task FollowAsync(Action<ChatEvent> onEvent) => Task.CompletedTask;

    public virtual bool Inject(ChatQueuedMessage message, ChatConversation conversation) => false;

    public virtual Task<bool> WithdrawAsync(string messageId) => Task.FromResult(false);

    public virtual bool IsQueued(string messageId) => false;

    public virtual bool SetMode(string mode) => false;

    public virtual void Close() => Stop();

    public virtual void SetEnergySaving(bool enabled) { }

    /// <summary>Quita la aprobación del diccionario; lanza InvalidApproval si no existe (como en Swift).</summary>
    protected PendingApproval TakePendingApproval(string approvalId)
    {
        lock (Gate)
        {
            if (PendingApprovals.Remove(approvalId, out var pending)) return pending;
        }
        throw ChatDriverError.InvalidApproval(approvalId);
    }

    /// <summary>Lanza el proceso y lo registra como hijo actual. Puede lanzar si el ejecutable no existe o no arranca.</summary>
    protected StructuredChild Begin(ResolvedExecutable executable, IReadOnlyList<string> arguments, string directory, IReadOnlyDictionary<string, string>? environment = null)
    {
        var process = new StructuredChild(executable, arguments, directory, environment);
        lock (Gate)
        {
            Child = process;
        }
        return process;
    }

    /// <summary>Termina el proceso y, si nadie lo ha reemplazado durante la espera, limpia el estado de la carrera.</summary>
    protected async Task FinishAsync(StructuredChild process, Guid generation)
    {
        process.Terminate();
        await process.WaitForExitAsync();
        lock (Gate)
        {
            if (RunGeneration == generation)
            {
                Child = null;
                PendingApprovals.Clear();
            }
        }
    }

    /// <summary>Entrega un evento solo si la generación sigue vigente. Se invoca bajo <see cref="Gate"/>.</summary>
    protected void Emit(ChatEvent value, Guid generation, Action<ChatEvent> onEvent)
    {
        lock (Gate)
        {
            if (RunGeneration != generation) return;
            onEvent(value);
        }
    }
}

/// <summary>Aprobación pendiente de un proveedor: el mensaje original (<c>Payload</c>) y su proveedor.</summary>
public sealed record PendingApproval(JsonObject Payload, string Provider);

/// <summary>Errores del controlador, con el mismo texto que Swift.</summary>
public sealed class ChatDriverError : Exception
{
    private ChatDriverError(string message) : base(message) { }

    public static ChatDriverError ExecutableMissing(string name) =>
        new($"No se encontró {name}. Instálalo o indica su ruta en Ajustes.");

    public static ChatDriverError InvalidApproval(string id) =>
        new($"No pending approval has id {id}.");

    public static ChatDriverError UnsupportedApproval() =>
        new("This provider cannot resolve that approval request.");

    public static ChatDriverError ProcessFailure(string detail) => new(detail);

    public static ChatDriverError ProtocolFailure(string detail) => new(detail);
}

/// <summary>
/// Ajustes que Swift lee de UserDefaults. El almacén de ajustes todavía no está portado: el host (Jack.WinUI)
/// asigna estas funciones cuando exista.
/// </summary>
// TODO(port): UserDefaults.standard (Ajustes) viene de la capa de ajustes de Swift; aún no portada.
public static class ChatDriverSettings
{
    /// <summary>Ruta de ejecutable elegida en Ajustes para un proveedor (clave Swift "providerExecutablePath.&lt;nombre&gt;"). Null usa la búsqueda normal.</summary>
    public static Func<string, string?> ExecutableOverride { get; set; } = _ => null;

    /// <summary>Ajuste entero (como <c>UserDefaults.object(forKey:) as? Int</c>). Null si no existe.</summary>
    public static Func<string, int?> IntSetting { get; set; } = _ => null;
}
