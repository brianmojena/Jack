using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jack.Core;

// Port de `private final class ClaudeChatDriver` (Sources/JackCore/ChatDrivers.swift, ~820-1171).
//
// Claude Code se mantiene vivo entre turnos, como en una terminal: el siguiente mensaje omite el arranque, los subagentes
// en segundo plano siguen tras una respuesta y detener interrumpe el turno en lugar de terminar el proceso. Un proceso
// inactivo se cierra tras unos minutos; el siguiente mensaje reanuda la sesión (--resume).
//
// Hilos: el estado se protege con Gate (ver ChatDriverBase.cs). onEvent se invoca bajo Gate, desde el hilo lector de stdout
// o desde el hilo que llama a RunAsync/FollowAsync. Los temporizadores (interrumpir a 5 s, esperar respuestas a 5 s, cierre
// por inactividad) corren en el pool de hilos y comprueban su cancelación bajo Gate.
// Cancelación: IChatDriver no recibe CancellationToken; la cancelación se expresa con Stop() y Close(). En Swift, cancelar
// la Task del turno enviaba interrupt y terminaba el turno con CancellationError; aquí eso equivale a Stop().
//
// TODO(port): la ejecución remota por SSH (conversation.Remote) viene de SSHTransport.swift y SSHKeySetup.swift; no portada.
// TODO(port): la delegación de Jack (ChatDelegation) viene de AgentBridge.swift; no portada (el turno lanza NotSupportedException).
// TODO(port): ClaudeProtocol.Decoder/ClaudeProtocol y StructuredChild/ExecutableResolver se portan en sus archivos propios.

/// <summary>Controlador de Claude Code: un proceso `claude` en modo stream-json que sobrevive entre turnos.</summary>
internal sealed class ClaudeChatDriver : ProcessChatDriver
{
    private ClaudeProtocol.Decoder _decoder = new();
    /// <summary>Firma con la que se lanzó el proceso; el modo y el modelo cambian en vivo sin reiniciarlo.</summary>
    private List<string> _launch = [];
    private string? _liveMode;
    private string? _liveModel;
    private Task? _reader;
    /// <summary>Receptor del turno en curso; null cuando no hay turno.</summary>
    private Action<ChatEvent>? _sink;
    private TaskCompletionSource? _turnEnded;
    private Action<ChatEvent>? _idleSink;
    private Action? _unprompted;
    /// <summary>Eventos de un turno que el agente inicia por sí mismo, hasta que alguien lo sigue (FollowAsync).</summary>
    private List<ChatEvent>? _unpromptedEvents;
    /// <summary>Temporizador de interrupción: mientras existe, el turno se está deteniendo.</summary>
    private CancellationTokenSource? _interruptTimer;
    private CancellationTokenSource? _idleTimer;
    private int _requests;
    private readonly Dictionary<string, TaskCompletionSource<JsonObject?>> _replies = new();
    /// <summary>Mensajes entregados a mitad de turno que el agente aún no ha leído, por id.</summary>
    private readonly Dictionary<string, string> _queued = new();
    /// <summary>Los agentes delegados se cierran al terminar su turno: un orquestador puede lanzar varios y la memoria escasea.</summary>
    private bool _closesWhenIdle;
    private bool _energySaving;

    public override bool KeepsAlive => true;

    public override void SetEnergySaving(bool enabled)
    {
        lock (Gate)
        {
            if (_energySaving == enabled) return;
            _energySaving = enabled;
            ScheduleIdleClose();
        }
    }

    public override void Observe(Action<ChatEvent> idle, Action unprompted)
    {
        lock (Gate)
        {
            _idleSink = idle;
            _unprompted = unprompted;
        }
    }

    public override Task RunAsync(ChatConversation conversation, string prompt, Action<ChatEvent> onEvent) =>
        RunAsync(conversation, prompt, null, onEvent);

    public override async Task RunAsync(ChatConversation conversation, string prompt, ChatDelegation? delegation, Action<ChatEvent> onEvent)
    {
        // TODO(port): SSHTransport.swift y SSHKeySetup.swift (ejecución remota). Sin soporte por ahora.
        if (conversation.Remote != null)
            throw ChatDriverError.ProcessFailure("Ejecutar Claude Code por SSH todavía no está disponible en Windows.");
        // TODO(port): ChatDelegation viene de AgentBridge.swift; sus herramientas de delegación aún no están portadas.
        if (delegation != null)
            throw new NotSupportedException("Las herramientas de delegación de Jack todavía no están portadas a Windows.");

        Task turn;
        lock (Gate)
        {
            if (_sink != null) throw ChatDriverError.ProcessFailure("Claude Code ya está trabajando en esta conversación.");
            _idleTimer?.Cancel();
            _idleTimer = null;
            _closesWhenIdle = conversation.ParentId != null;
            var process = Session(conversation);
            // Igual que en Swift: el modo y el modelo se aplican al proceso ya existente.
            SetMode(conversation.Mode ?? "manual");
            if (!string.IsNullOrEmpty(conversation.Model) && conversation.Model != _liveModel)
            {
                Control(new JsonObject { ["subtype"] = "set_model", ["model"] = conversation.Model });
                _liveModel = conversation.Model;
            }
            var buffered = _unpromptedEvents ?? new List<ChatEvent>();
            _unpromptedEvents = null;
            turn = AwaitTurn(onEvent, () =>
            {
                foreach (var pending in buffered) Deliver(pending);
                try
                {
                    process.WriteJson(UserMessage(conversation, prompt));
                }
                catch (Exception error)
                {
                    EndTurn(ChatDriverError.ProcessFailure("No se pudo escribir a Claude Code: " + error.Message));
                }
            });
        }
        await turn;
    }

    public override Task FollowAsync(Action<ChatEvent> onEvent)
    {
        lock (Gate)
        {
            if (_sink != null || _unpromptedEvents == null) return Task.CompletedTask;
            var buffered = _unpromptedEvents ?? new List<ChatEvent>();
            _unpromptedEvents = null;
            return AwaitTurn(onEvent, () =>
            {
                foreach (var value in buffered) Deliver(value);
            });
        }
    }

    /// <summary>Claude Code guarda el mensaje en su cola y lo lee entre pasos, como al escribir en su terminal mientras trabaja.</summary>
    public override bool Inject(ChatQueuedMessage message, ChatConversation conversation)
    {
        lock (Gate)
        {
            if (_sink == null && _unpromptedEvents == null) return false;
            if (Child is not { } child) return false;
            var line = UserMessage(conversation, message.Text, message.Attachments);
            line["uuid"] = message.Id;
            try
            {
                child.WriteJson(line);
            }
            catch (Exception)
            {
                return false;
            }
            _idleTimer?.Cancel();
            _idleTimer = null;
            _queued[message.Id] = message.Text;
            return true;
        }
    }

    public override async Task<bool> WithdrawAsync(string messageId)
    {
        lock (Gate)
        {
            if (!_queued.ContainsKey(messageId)) return true;
        }
        var response = await RequestAsync(new JsonObject { ["subtype"] = "cancel_async_message", ["message_uuid"] = messageId });
        if (response == null || BoolField(response, "cancelled") != true) return false;
        lock (Gate)
        {
            _queued.Remove(messageId);
        }
        return true;
    }

    public override bool IsQueued(string messageId)
    {
        lock (Gate)
        {
            return _queued.ContainsKey(messageId);
        }
    }

    public override bool SetMode(string mode)
    {
        lock (Gate)
        {
            if (Child == null) return true;
            if (_liveMode == mode) return true;
            if (!Control(new JsonObject { ["subtype"] = "set_permission_mode", ["mode"] = ClaudeProtocol.CliMode(mode) })) return false;
            _liveMode = mode;
            return true;
        }
    }

    /// <summary>Interrumpe el turno como Esc en la terminal, descartando los mensajes en cola; el proceso y sus tareas siguen.</summary>
    public override void Stop() => Stop(keepingQueued: false);

    public override void Stop(bool keepingQueued)
    {
        lock (Gate)
        {
            // También invalida el arranque, antes de que el turno haya instalado su receptor.
            RunGeneration = Guid.NewGuid();
            if (_sink == null || _interruptTimer != null) return;
            PendingApprovals.Clear();
            var interrupt = new JsonObject { ["subtype"] = "interrupt" };
            if (!keepingQueued)
            {
                interrupt["cancel_queued"] = true;
                _queued.Clear();
            }
            if (!Control(interrupt))
            {
                CloseSession();
                EndTurn(null);
                return;
            }
            _interruptTimer = Schedule(TimeSpan.FromSeconds(5), () =>
            {
                // No se detuvo a tiempo: termina el proceso; el siguiente mensaje reanuda la sesión.
                if (_sink == null) return;
                CloseSession();
                EndTurn(null);
            });
        }
    }

    public override void Close()
    {
        lock (Gate)
        {
            _idleTimer?.Cancel();
            _idleTimer = null;
            CloseSession();
            _unpromptedEvents = null;
            if (_sink != null) EndTurn(new OperationCanceledException("Turno cancelado."));
        }
    }

    public override async Task RespondAsync(string approvalId, string choice, string? message)
    {
        var pending = TakePendingApproval(approvalId);
        Reply(pending, ClaudeProtocol.PermissionResponse(pending.Payload, choice, message));
    }

    protected override Task ResolveAsync(PendingApproval pending, bool allow)
    {
        Reply(pending, ClaudeProtocol.PermissionResponse(pending.Payload, allow ? "allow" : "deny", null));
        return Task.CompletedTask;
    }

    public override async Task AnswerAsync(string approvalId, IReadOnlyDictionary<string, string> answers)
    {
        var pending = TakePendingApproval(approvalId);
        Reply(pending, ClaudeProtocol.QuestionResponse(pending.Payload, answers));
    }

    private void Reply(PendingApproval pending, JsonObject response)
    {
        lock (Gate)
        {
            var requestId = StringField(pending.Payload, "requestID");
            if (Child is not { } child || requestId == null) throw ChatDriverError.InvalidApproval("expired");
            child.WriteJson(new JsonObject
            {
                ["type"] = "control_response",
                ["response"] = new JsonObject
                {
                    ["subtype"] = "success",
                    ["request_id"] = requestId,
                    ["response"] = response,
                },
            });
        }
    }

    /// <summary>Mensaje de usuario en stream-json. Con adjuntos, el contenido son bloques de texto e imagen.</summary>
    internal static JsonObject UserMessage(ChatConversation conversation, string prompt, IReadOnlyList<string>? attachments = null) =>
        new()
        {
            ["type"] = "user",
            ["message"] = new JsonObject
            {
                ["role"] = "user",
                ["content"] = ClaudeContent(prompt, attachments ?? conversation.TurnAttachments),
            },
            ["parent_tool_use_id"] = null,
        };

    /// <summary>Texto plano, o texto más imágenes en línea cuando el mensaje lleva adjuntos (ChatRunConfiguration.claudeContent).</summary>
    internal static JsonNode ClaudeContent(string prompt, IReadOnlyList<string> attachments)
    {
        if (attachments.Count == 0) return JsonValue.Create(prompt)!;
        var blocks = new JsonArray
        {
            new JsonObject { ["type"] = "text", ["text"] = ChatAttachments.PromptText(prompt, attachments) },
        };
        foreach (var path in attachments)
        {
            // Misma regla que ChatAttachments.InlineImageAsync, en síncrono: imagen reconocible y dentro del límite.
            if (ChatAttachments.ImageType(path) is not { } mediaType) continue;
            if (new FileInfo(path).Length > ChatAttachments.InlineLimit) continue;
            blocks.Add(new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject
                {
                    ["type"] = "base64",
                    ["media_type"] = mediaType,
                    ["data"] = Convert.ToBase64String(File.ReadAllBytes(path)),
                },
            });
        }
        return blocks;
    }

    // MARK: Proceso

    /// <summary>El proceso en marcha si se lanzó con estos ajustes; si no, uno nuevo que reanuda la sesión. Se llama bajo Gate.</summary>
    private StructuredChild Session(ChatConversation conversation)
    {
        var executable = ExecutableResolver.Resolve("claude", ChatDriverSettings.ExecutableOverride("claude"));
        if (executable == null) throw ChatDriverError.ExecutableMissing("claude");
        var signature = new List<string> { executable.FileName };
        signature.AddRange(executable.PrefixArguments);
        signature.AddRange(ChatRunConfiguration.ClaudeLaunchSignature(conversation));
        signature.Add(_energySaving ? "light" : "normal");
        // Reiniciar acabaría con los subagentes en segundo plano; los ajustes nuevos esperan a que terminen.
        if (Child is { } running && (_launch.SequenceEqual(signature) || _decoder.BackgroundTaskCount > 0)) return running;
        CloseSession();
        var process = Begin(
            executable,
            ChatRunConfiguration.ClaudeArguments(conversation, _energySaving),
            ChatRunConfiguration.ClaudeDirectory(conversation),
            ChatRunConfiguration.ClaudeEnvironment(conversation, _energySaving));
        _launch = signature;
        _liveMode = conversation.Mode ?? "manual";
        _liveModel = conversation.Model;
        _decoder = new ClaudeProtocol.Decoder();
        _reader = Task.Run(async () =>
        {
            try
            {
                await foreach (var line in process.Lines) HandleLine(process, line);
            }
            catch (Exception)
            {
                // La salida se interrumpió: EndedAsync informa del cierre con el mensaje del proceso.
            }
            await EndedAsync(process);
        });
        return process;
    }

    private void CloseSession()
    {
        _reader = null;
        _launch = [];
        DropPending();
        if (Child is not { } process) return;
        Child = null;
        process.Terminate();
        _ = process.WaitForExitAsync();
    }

    private async Task EndedAsync(StructuredChild process)
    {
        lock (Gate)
        {
            if (!ReferenceEquals(Child, process)) return;
            Child = null;
            _launch = [];
            _reader = null;
            _unpromptedEvents = null;
            DropPending();
            if (_sink == null) return;
        }
        var message = await process.FailureDescriptionAsync("Claude Code se cerró antes de terminar.");
        lock (Gate)
        {
            if (_sink != null && Child == null) EndTurn(ChatDriverError.ProcessFailure(message));
        }
    }

    private bool Control(JsonObject request) => Send(request) != null;

    /// <summary>Envía una control_request con id nuevo; devuelve el id o null si no hay proceso o la escritura falla.</summary>
    private string? Send(JsonObject request)
    {
        lock (Gate)
        {
            if (Child is not { } child) return null;
            _requests++;
            var id = $"jack-{_requests}";
            try
            {
                child.WriteJson(new JsonObject
                {
                    ["type"] = "control_request",
                    ["request_id"] = id,
                    ["request"] = request,
                });
                return id;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    /// <summary>Una control_request cuya respuesta importa; null si el proceso termina o no responde en 5 s.</summary>
    private Task<JsonObject?> RequestAsync(JsonObject request)
    {
        lock (Gate)
        {
            var id = Send(request);
            if (id == null) return Task.FromResult<JsonObject?>(null);
            var reply = new TaskCompletionSource<JsonObject?>(TaskCreationOptions.RunContinuationsAsynchronously);
            _replies[id] = reply;
            Schedule(TimeSpan.FromSeconds(5), () =>
            {
                if (_replies.Remove(id, out var waiting)) waiting.TrySetResult(null);
            });
            return reply.Task;
        }
    }

    /// <summary>El proceso desapareció: no se leerá lo que tenía y no se contestará ninguna petición.</summary>
    private void DropPending()
    {
        _queued.Clear();
        var waiting = _replies.Values.ToList();
        _replies.Clear();
        foreach (var reply in waiting) reply.TrySetResult(null);
    }

    // MARK: Turnos

    /// <summary>Procesa una línea de stdout. Las líneas de un proceso ya reemplazado o cerrado se descartan.</summary>
    private void HandleLine(StructuredChild process, string line)
    {
        var obj = ParseObject(line);
        if (obj == null) return;
        lock (Gate)
        {
            if (!ReferenceEquals(Child, process)) return;
            var type = StringField(obj, "type");
            if (type == "control_response")
            {
                var response = obj["response"] as JsonObject ?? new JsonObject();
                if (StringField(response, "request_id") is { } id && _replies.Remove(id, out var waiting))
                {
                    waiting.TrySetResult(response["response"] as JsonObject ?? new JsonObject());
                }
                return;
            }
            if (type == "command_lifecycle")
            {
                if (StringField(obj, "command_uuid") is { } commandId && StringField(obj, "state") is "cancelled" or "dropped")
                {
                    _queued.Remove(commandId);
                }
                return;
            }
            if (type == "user" && BoolField(obj, "isReplay") == true)
            {
                // Un mensaje en cola que el agente lee ahora. Las repeticiones de mensajes enviados como turno ya se muestran.
                if (StringField(obj, "uuid") is { } uuid && _queued.Remove(uuid, out var text)) Deliver(new DeliveredEvent(uuid, text));
                return;
            }

            if (_sink == null && _unpromptedEvents == null && ClaudeProtocol.StartsTurn(obj))
            {
                // El agente inicia un turno por sí mismo: sus eventos se guardan hasta que alguien los siga.
                _idleTimer?.Cancel();
                _idleTimer = null;
                _unpromptedEvents = new List<ChatEvent>();
                _unprompted?.Invoke();
            }
            foreach (var parsed in _decoder.Events(obj))
            {
                var value = parsed;
                if (value is ApprovalEvent approvalEvent)
                {
                    var approvalId = approvalEvent.Approval.Id;
                    if (_decoder.Approvals.TryGetValue(approvalId, out var payload)) PendingApprovals[approvalId] = new PendingApproval(payload, "claude");
                    else PendingApprovals.Remove(approvalId);
                }
                if (value is ModeEvent modeEvent) _liveMode = modeEvent.Mode;
                // Un turno interrumpido termina con un error en el resultado; es la detención que pidió el usuario.
                if (_interruptTimer != null && value is FailureEvent) value = new CompletedEvent();
                Deliver(value);
            }
            if (_sink == null && _unpromptedEvents == null && StringField(obj, "subtype") == "background_tasks_changed") ScheduleIdleClose();
        }
    }

    /// <summary>Entrega un evento: al turno activo, o a la cola de eventos no pedidos, o al receptor de inactividad. Se llama bajo Gate.</summary>
    private void Deliver(ChatEvent value)
    {
        var sink = _sink;
        if (sink != null)
        {
            sink(value);
            if (value is CompletedEvent) EndTurn(null);
            else if (value is FailureEvent failure) EndTurn(ChatDriverError.ProtocolFailure(failure.Message));
        }
        else if (_unpromptedEvents != null)
        {
            _unpromptedEvents.Add(value);
        }
        else
        {
            _idleSink?.Invoke(value);
        }
    }

    /// <summary>Abre el receptor del turno y luego arranca el turno (escribe el mensaje). Se llama bajo Gate.</summary>
    private Task AwaitTurn(Action<ChatEvent> onEvent, Action start)
    {
        var turn = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _sink = onEvent;
        _turnEnded = turn;
        start();
        return turn.Task;
    }

    /// <summary>Cierra el turno activo. Se llama bajo Gate.</summary>
    private void EndTurn(Exception? error)
    {
        _sink = null;
        _interruptTimer?.Cancel();
        _interruptTimer = null;
        PendingApprovals.Clear();
        var turn = _turnEnded;
        _turnEnded = null;
        if (error != null) turn?.TrySetException(error);
        else turn?.TrySetResult();
        ScheduleIdleClose();
    }

    /// <summary>Cierra el proceso inactivo tras los minutos configurados, pero nunca mientras hay una tarea en segundo plano. Se llama bajo Gate.</summary>
    private void ScheduleIdleClose()
    {
        _idleTimer?.Cancel();
        _idleTimer = null;
        // Los mensajes en cola inician un turno propio en cuanto el agente los lee.
        if (Child == null || _sink != null || _queued.Count > 0) return;
        var minutes = _closesWhenIdle ? 0 : (ChatDriverSettings.IntSetting(ChatDriverFactory.ClaudeKeepAliveKey) ?? 5);
        var idleSeconds = _energySaving ? Math.Min(30, minutes * 60) : minutes * 60;
        var seconds = _decoder.BackgroundTaskCount > 0 ? Math.Max(60, minutes * 60) : idleSeconds;
        _idleTimer = Schedule(TimeSpan.FromSeconds(seconds), () =>
        {
            if (_sink != null || _unpromptedEvents != null || _queued.Count > 0) return;
            if (_decoder.BackgroundTaskCount > 0) ScheduleIdleClose();
            else CloseSession();
        });
    }

    /// <summary>
    /// Ejecuta <paramref name="onElapsed"/> bajo Gate tras <paramref name="delay"/>, salvo que el temporizador devuelto
    /// se cancele antes. Equivale a las Task con Task.sleep de Swift.
    /// </summary>
    private CancellationTokenSource Schedule(TimeSpan delay, Action onElapsed)
    {
        var timer = new CancellationTokenSource();
        Task.Delay(delay, timer.Token).ContinueWith(_ =>
        {
            lock (Gate)
            {
                if (!timer.IsCancellationRequested) onElapsed();
            }
        }, CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.Default);
        return timer;
    }

    // MARK: Auxiliares

    private static JsonObject? ParseObject(string line)
    {
        try
        {
            return JsonNode.Parse(line) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? StringField(JsonObject obj, string key) =>
        obj[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static bool? BoolField(JsonObject obj, string key) =>
        obj[key] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;
}
