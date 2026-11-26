namespace Jack.Core.Checks;

// Comprobaciones de ChatStore.Sending.cs con un driver falso guionizado (FakeDriver), inyectado por el parámetro driverFactory
// del constructor del store. Sin SynchronizationContext: los eventos se procesan en línea. Como el arranque de cada turno usa
// el pool, cada comprobación espera a que el turno termine (WaitUntil) antes de mirar el estado.
//
// Cada guion controla su propio avance con TaskCompletionSource para que las comprobaciones sean deterministas: el driver
// no emite nada más hasta que la comprobación le da paso.
public static class ChatStoreSendingChecks
{
    /// <summary>Ejecuta todas las comprobaciones. Lanza InvalidOperationException en la primera que falle.</summary>
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "jack-chatstore-sending-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "project"));
        try
        {
            TurnStoresTextToolsAndSessionCheck(root);
            ApprovalCheck(root);
            WaitingCheck(root);
            KeepAliveCheck(root);
            StopCheck(root);
            QueueCheck(root);
            FailureCheck(root);
            SendGateCheck(root);
        }
        finally
        {
            try
            {
                CheckIo.DeleteDirectory(root);
            }
            catch (IOException)
            {
                // El archivo de chats puede seguir escribiéndose en segundo plano; la carpeta temporal no afecta al resultado.
            }
        }
    }

    // ----------------------------------------------------------------------------------------- Comprobaciones

    /// <summary>Un turno completo: texto agrupado, herramienta actualizada en su sitio, sesión, título y vista previa.</summary>
    private static void TurnStoresTextToolsAndSessionCheck(string root)
    {
        var harness = new Harness(root);
        harness.Script = (driver, emit, stop) =>
        {
            emit(new SessionEvent("sesion-1"));
            emit(new TextEvent("t1", "Hola ", false));
            emit(new TextEvent("t1", "mundo", false));
            emit(new ToolEvent("h1", "Leer", "a.cs", "running"));
            emit(new ToolEvent("h1", "Leer", "a.cs", "completed"));
            emit(new CompletedEvent());
            return Task.CompletedTask;
        };
        var store = harness.Store;
        var id = harness.NewConversation();
        store.Send("Hola", id);
        WaitIdle(store, id);
        var conversation = Conversation(store, id);
        Expect(store.Statuses.GetValueOrDefault(id) == ChatStatus.Idle, "tras el turno el estado es idle");
        Expect(conversation.SessionId == "sesion-1", "el id de sesión se guarda");
        Expect(conversation.Messages.Count == 3, "transcripción: usuario, asistente y herramienta");
        Expect(conversation.Messages[0].Role == "user" && conversation.Messages[0].Text == "Hola", "mensaje del usuario");
        Expect(conversation.Messages[1].Role == "assistant" && conversation.Messages[1].Text == "Hola mundo", "el texto del asistente se agrupa");
        Expect(conversation.Messages[2].Role == "tool" && conversation.Messages[2].Status == "completed", "la herramienta se actualiza en su sitio");
        Expect(conversation.Title == "Hola", "el título sale del primer mensaje");
        Expect(conversation.Preview == "Hola mundo", "la vista previa es la última respuesta");
        Expect(harness.Drivers.Count == 1 && harness.Drivers[0].Prompts.SequenceEqual(new[] { "Hola" }), "un driver recibió el prompt");
    }

    /// <summary>Un permiso pide estado en espera y Respond lo resuelve: se retira y el turno continúa hasta terminar.</summary>
    private static void ApprovalCheck(string root)
    {
        var harness = new Harness(root);
        harness.Script = async (driver, emit, stop) =>
        {
            emit(new ApprovalEvent(new ChatApproval { Id = "ap1", Title = "Permiso", Detail = "ls" }));
            await Until(driver.Responded.Task, stop);
            emit(new TextEvent("t2", "ok", false));
            emit(new CompletedEvent());
        };
        var store = harness.Store;
        var id = harness.NewConversation();
        store.Send("haz algo", id);
        WaitUntil(() => store.Statuses.GetValueOrDefault(id) == ChatStatus.Waiting, "aprobación pendiente");
        Expect(store.Approvals[id].Count == 1 && store.Approvals[id][0].Id == "ap1", "la aprobación llega a la conversación");
        store.Respond(id, "ap1", true);
        WaitIdle(store, id);
        Expect(store.Approvals[id].Count == 0, "la aprobación se retira al responder");
        Expect(harness.Drivers[0].Responses.SequenceEqual(new[] { "ap1:allow:" }), "el driver recibe la respuesta permitir");
        var conversation = Conversation(store, id);
        Expect(conversation.Messages.Any(m => m.Role == "assistant" && m.Text == "ok"), "el turno continúa tras el permiso");
        Expect(store.Statuses.GetValueOrDefault(id) == ChatStatus.Idle, "el estado vuelve a idle");
    }

    /// <summary>Un mensaje escrito mientras el agente trabaja espera y se envía como turno siguiente al terminar.</summary>
    private static void WaitingCheck(string root)
    {
        var harness = new Harness(root);
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Script = async (driver, emit, stop) =>
        {
            await Until(gate.Task, stop);
            emit(new CompletedEvent());
        };
        var store = harness.Store;
        var id = harness.NewConversation();
        store.Send("uno", id);
        WaitUntil(() => store.Statuses.GetValueOrDefault(id) == ChatStatus.Running, "turno en marcha");
        store.Send("dos", id);
        Expect(store.Waiting.TryGetValue(id, out var waiting) && waiting.Count == 1 && waiting[0].Text == "dos",
            "el mensaje espera mientras el agente trabaja");
        Expect(harness.Drivers[0].Prompts.Count == 1, "el mensaje en espera no se envía todavía");
        gate.TrySetResult(true);
        WaitUntil(() => harness.Drivers.Count == 2 && harness.Drivers[1].Prompts.Count == 1 && !store.IsBusy(id),
            "segundo turno con el mensaje en espera");
        Expect(harness.Drivers[1].Prompts[0] == "dos", "el mensaje en espera se envía al terminar el turno");
        Expect(!store.Waiting.ContainsKey(id), "la cola de espera queda vacía");
        Expect(Conversation(store, id).Messages.Count(m => m.Role == "user" && m.Text == "dos") == 1, "el mensaje aparece una sola vez");
    }

    /// <summary>Un agente que sigue vivo recibe el mensaje a mitad de turno y lo confirma con DeliveredEvent.</summary>
    private static void KeepAliveCheck(string root)
    {
        var harness = new Harness(root) { KeepsAlive = true };
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Script = async (driver, emit, stop) =>
        {
            await Until(gate.Task, stop);
            if (driver.Injected is { } injected) emit(new DeliveredEvent(injected.Id, injected.Text));
            emit(new CompletedEvent());
        };
        var store = harness.Store;
        var id = harness.NewConversation();
        store.Send("x", id);
        WaitUntil(() => store.Statuses.GetValueOrDefault(id) == ChatStatus.Running, "turno en marcha");
        store.Send("y", id);
        Expect(store.Waiting.TryGetValue(id, out var waiting) && waiting.Count == 1 && waiting[0].Sent,
            "el mensaje se entrega al driver que sigue vivo");
        Expect(harness.Drivers[0].Injected?.Text == "y", "el driver recibió el mensaje inyectado");
        gate.TrySetResult(true);
        WaitIdle(store, id);
        var conversation = Conversation(store, id);
        Expect(conversation.Messages.Count(m => m.Role == "user" && m.Text == "y") == 1, "el mensaje entregado entra una vez en la transcripción");
        Expect(!store.Waiting.ContainsKey(id) || store.Waiting[id].Count == 0, "la espera queda vacía tras la confirmación");
        Expect(harness.Drivers.Count == 1, "el driver que sigue vivo se reutiliza");
    }

    /// <summary>Detener un turno devuelve los mensajes en espera al compositor, conserva el texto parcial y no registra error.</summary>
    private static void StopCheck(string root)
    {
        var harness = new Harness(root);
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Script = async (driver, emit, stop) =>
        {
            emit(new TextEvent("p1", "parcial", false));
            // Un evento de sesión vacía el lote de texto antes de que la comprobación siga.
            emit(new SessionEvent("s-stop"));
            await Until(gate.Task, stop);
        };
        var store = harness.Store;
        var id = harness.NewConversation();
        store.Send("empieza", id);
        WaitUntil(() => Conversation(store, id).SessionId == "s-stop", "turno con texto parcial");
        store.Send("pendiente", id);
        store.Stop(id);
        WaitIdle(store, id);
        Expect(store.Statuses.GetValueOrDefault(id) == ChatStatus.Idle, "tras detener, el estado es idle");
        Expect(store.Recalled.TryGetValue(id, out var recalled) && recalled.Text == "pendiente", "el mensaje en espera vuelve al compositor");
        Expect(!store.Waiting.ContainsKey(id) || store.Waiting[id].Count == 0, "no quedan mensajes en espera");
        var conversation = Conversation(store, id);
        Expect(conversation.Messages.Any(m => m.Role == "assistant" && m.Text == "parcial"), "el texto parcial se conserva");
        Expect(!conversation.Messages.Any(m => m.Role == "error"), "detener no registra un error");
        Expect(harness.Drivers[0].WasStopped, "el driver recibió la parada");
    }

    /// <summary>Con un solo hueco de concurrencia, el segundo agente queda en cola hasta que el primero termina.</summary>
    private static void QueueCheck(string root)
    {
        var harness = new Harness(root, maxConcurrent: 1);
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Script = async (driver, emit, stop) =>
        {
            await Until(gate.Task, stop);
            emit(new CompletedEvent());
        };
        var store = harness.Store;
        var first = harness.NewConversation();
        var second = harness.NewConversation();
        store.Send("A", first);
        WaitUntil(() => store.Statuses.GetValueOrDefault(first) == ChatStatus.Running, "primer turno en marcha");
        store.Send("B", second);
        Expect(store.Statuses.GetValueOrDefault(second) == ChatStatus.Queued, "el segundo agente espera su hueco");
        gate.TrySetResult(true);
        WaitUntil(() => harness.Drivers.Count == 2 && harness.Drivers[1].Prompts.Count == 1 && !store.IsBusy(second),
            "el segundo agente arranca al liberarse el hueco");
        Expect(Conversation(store, second).Messages.Any(m => m.Role == "user" && m.Text == "B"), "el mensaje del segundo agente quedó registrado");
        Expect(store.Statuses.GetValueOrDefault(second) == ChatStatus.Idle, "el segundo agente termina en idle");
    }

    /// <summary>Un FailureEvent deja el agente en estado fallido y añade el error a la transcripción.</summary>
    private static void FailureCheck(string root)
    {
        var harness = new Harness(root);
        harness.Script = (driver, emit, stop) =>
        {
            emit(new FailureEvent("boom"));
            return Task.CompletedTask;
        };
        var store = harness.Store;
        var id = harness.NewConversation();
        store.Send("hola", id);
        WaitIdle(store, id);
        Expect(store.Statuses.GetValueOrDefault(id) == ChatStatus.Failed, "un fallo deja el estado en failed");
        var last = Conversation(store, id).Messages[^1];
        Expect(last.Role == "error" && last.Text == "boom", "el fallo aparece como mensaje de error");
    }

    /// <summary>La puerta de envío (CodeOS) rechaza antes de crear ningún driver ni tocar la transcripción.</summary>
    private static void SendGateCheck(string root)
    {
        var harness = new Harness(root);
        var store = harness.Store;
        var id = harness.NewConversation();
        store.SendGate = _ => "Cuota agotada";
        store.Send("hola", id);
        Expect(store.ErrorMessage == "Cuota agotada", "la puerta de envío muestra su motivo");
        Expect(harness.Drivers.Count == 0, "no se crea driver si la puerta rechaza");
        Expect(Conversation(store, id).Messages.Count == 0, "el mensaje rechazado no entra en la transcripción");
        Expect(!store.IsBusy(id), "el agente no queda ocupado");
    }

    // ----------------------------------------------------------------------------------------- Ayudas

    /// <summary>Crea un store con su propio archivo de chats y preferencias en memoria; cada driver nuevo se registra.</summary>
    private sealed class Harness
    {
        private readonly string _project;

        public Harness(string root, int? maxConcurrent = null)
        {
            var preferences = new MemoryPreferences();
            if (maxConcurrent is { } limit) preferences.SetInt("maxConcurrentAgents", limit);
            _project = Path.Combine(root, "project");
            var archive = new ChatArchive(Path.Combine(root, "archive-" + Guid.NewGuid().ToString("N")));
            Store = new ChatStore(archive, preferences, driverFactory: _ => CreateDriver());
        }

        public ChatStore Store { get; }

        public List<FakeDriver> Drivers { get; } = [];

        /// <summary>Si el driver que se crea mantiene vivo a su agente entre turnos.</summary>
        public bool KeepsAlive { get; set; }

        /// <summary>Guion del driver: recibe el driver, el receptor de eventos y el token de parada.</summary>
        public Func<FakeDriver, Action<ChatEvent>, CancellationToken, Task> Script { get; set; } = (_, _, _) => Task.CompletedTask;

        public Guid NewConversation() =>
            Store.Create(_project, ChatProvider.Claude) ?? throw Fail("No se pudo crear la conversación.");

        private IChatDriver CreateDriver()
        {
            var driver = new FakeDriver(KeepsAlive, Script);
            Drivers.Add(driver);
            return driver;
        }
    }

    /// <summary>Driver de pruebas: ejecuta el guion del turno y registra las llamadas que recibe.</summary>
    private sealed class FakeDriver : IChatDriver
    {
        private readonly Func<FakeDriver, Action<ChatEvent>, CancellationToken, Task> _script;
        private CancellationTokenSource _stop = new();

        public FakeDriver(bool keepsAlive, Func<FakeDriver, Action<ChatEvent>, CancellationToken, Task> script)
        {
            KeepsAlive = keepsAlive;
            _script = script;
        }

        public bool KeepsAlive { get; }

        public List<string> Prompts { get; } = [];

        /// <summary>Respuestas recibidas, como "id:choice:message".</summary>
        public List<string> Responses { get; } = [];

        /// <summary>Último mensaje inyectado a mitad de turno.</summary>
        public ChatQueuedMessage? Injected { get; private set; }

        /// <summary>Se completa cuando el driver recibe una respuesta a un permiso.</summary>
        public TaskCompletionSource<bool> Responded { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool WasStopped { get; private set; }

        public Task RunAsync(ChatConversation conversation, string prompt, Action<ChatEvent> onEvent)
        {
            Prompts.Add(prompt);
            _stop = new CancellationTokenSource();
            return _script(this, onEvent, _stop.Token);
        }

        public Task RespondAsync(string approvalId, bool allow)
        {
            Responses.Add($"{approvalId}:{(allow ? "allow" : "deny")}:");
            Responded.TrySetResult(true);
            return Task.CompletedTask;
        }

        public Task RespondAsync(string approvalId, string choice, string? message)
        {
            Responses.Add($"{approvalId}:{choice}:{message}");
            Responded.TrySetResult(true);
            return Task.CompletedTask;
        }

        public void Stop()
        {
            WasStopped = true;
            _stop.Cancel();
        }

        public void Stop(bool keepingQueued) => Stop();

        public void Close() => Stop();

        public bool Inject(ChatQueuedMessage message, ChatConversation conversation)
        {
            Injected = message;
            return true;
        }

        public bool IsQueued(string messageId) => Injected?.Id == messageId;
    }

    /// <summary>Espera a que la señal se complete o a que el turno se detenga; nunca lanza.</summary>
    private static async Task Until(Task signal, CancellationToken stop)
    {
        await Task.WhenAny(signal, Task.Delay(Timeout.Infinite, stop));
    }

    private static void WaitIdle(ChatStore store, Guid id) => WaitUntil(() => !store.IsBusy(id), "fin del turno");

    private static void WaitUntil(Func<bool> condition, string what)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw Fail("Tiempo agotado esperando: " + what);
            Thread.Sleep(5);
        }
    }

    private static ChatConversation Conversation(ChatStore store, Guid id) => store.Conversations.First(c => c.Id == id);

    private static InvalidOperationException Fail(string message) => new(message);

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw Fail("Comprobación fallida: " + message);
    }
}
