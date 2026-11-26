namespace Jack.Core;

// Port de Sources/JackCore/ChatStore.swift (modo Normal, proveedor Claude Code): envío y cola de mensajes (líneas 1080-1282),
// parada y respuestas (1416-1474 y 1566-1583), cola global y arranque/fin de turnos (1748-1933) y eventos (1977-2104).
//
// Hilos: todo el estado se toca en el hilo de interfaz (ver ChatStore.cs). Los turnos corren en el pool con Task.Run, y el
// arranque de cada turno se decide en el hilo de interfaz (equivale al guardia Task.checkCancellation + stoppingRuns de Swift).
// Los eventos de los drivers llegan desde otros hilos y se reenvían con RunOnUi. El agrupado `pending` + `flushTask` de Swift
// se traduce a un temporizador de 50 ms que dispara RunOnUi(FlushAll).
//
// Los campos y propiedades los declara ChatStore.State.cs con la convención `_nombre` para los campos privados de Swift.
public sealed partial class ChatStore
{
    // ----------------------------------------------------------------------------------------- Envío

    /// <summary>Envía al chat seleccionado.</summary>
    public void Send(string prompt, IReadOnlyList<string>? attachments = null)
    {
        if (SelectedId is not { } id) return;
        Send(prompt, id, attachments);
    }

    /// <summary>Los mensajes siempre se pueden escribir: mientras el agente trabaja, esperan a que los lea.</summary>
    public bool CanSend(Guid id) => !_stopped; // TODO(port): antigravitySessionIsInTerminal viene de ChatStore.swift:1085 (Antigravity/Terminal fuera de alcance).

    /// <summary>Si el agente está ocupado, un mensaje nuevo espera.</summary>
    public bool IsBusy(Guid id) => _runs.ContainsKey(id) || _queue.Any(entry => entry.Id == id);

    /// <summary>El agente lee los mensajes en espera mientras trabaja, en lugar de al terminar su turno.</summary>
    public bool ReadsWhileWorking(Guid id) =>
        (_drivers.TryGetValue(id, out var driver) && driver.KeepsAlive) || _liveDrivers.ContainsKey(id);

    /// <summary>
    /// Envía un mensaje a un agente. <paramref name="interrupting"/> detiene el turno para que el agente lea el mensaje
    /// ya, como Ctrl+Enter. El puerto de la puerta de CodeOS (<see cref="SendGate"/>) decide antes de entregarlo.
    /// </summary>
    public void Send(string prompt, Guid to, IReadOnlyList<string>? attachments = null, bool interrupting = false, bool preservingApproval = false)
    {
        if (SendGate is { } gate && FindConversation(to) is { } conversation && conversation.Provider == ChatProvider.Claude
            && gate(conversation) is { } refusal)
        {
            ErrorMessage = refusal;
            return;
        }
        SendIfAccepted(prompt, attachments, to, interrupting, preservingApproval);
    }

    /// <summary>Acepta el mensaje si el agente existe y no se está cerrando; devuelve false si lo rechaza.</summary>
    internal bool SendIfAccepted(string prompt, IReadOnlyList<string>? attachments, Guid id, bool interrupting = false, bool preservingApproval = false)
    {
        attachments ??= [];
        // TODO(port): guardas de sesión abierta en la interfaz Terminal (ChatStore.swift:1102-1110): Claude en Terminal y Antigravity fuera de alcance.
        var text = prompt.Trim();
        if ((text.Length == 0 && attachments.Count == 0) || FindConversation(id) == null || _stopped) return false;
        ClearSuggestion(id);
        // TODO(port): isUnplaced/place viene de ChatStore.swift:1119-1127 (localización de carpeta con ProjectLocator, no portada).
        var ordinaryText = text.StartsWith("!!", StringComparison.Ordinal) ? text[1..] : text;
        if (IsBusy(id) && JackCommandCatalog.Parse(text) == null)
        {
            Wait(ordinaryText, attachments, id, preservingApproval);
            if (interrupting) SendWaitingNow(id);
            return true;
        }
        if (JackCommandCatalog.Parse(text) is { } command)
        {
            if (attachments.Count > 0)
            {
                ErrorMessage = "Los comandos ! no admiten archivos adjuntos.";
                return false;
            }
            ExecuteJack(command.Name, command.Arguments, id);
            return true;
        }
        // TODO(port): /compact de Stellar viene de ChatStore.swift:1138-1143 (Stellar fuera de alcance).

        if (!_runs.ContainsKey(id) && !_compactions.ContainsKey(id) && !_handoffs.ContainsKey(id)
            && FindConversation(id) is { } candidate
            && candidate.JackContext is { AutoThreshold: int threshold, AutoTarget: int target }
            && candidate.ContextUsage is { } usage && usage.Used >= threshold)
        {
            // Compactación automática: el mensaje se guarda y se envía cuando termina el resumen.
            _afterCompaction[id] = (text, attachments.ToList());
            LoadTranscript(id);
            var compactIndex = ConversationIndex(id);
            if (compactIndex >= 0)
            {
                Conversations[compactIndex].Messages.Add(new ChatMessage
                {
                    Role = "jack",
                    Text = "Mensaje conservado mientras se compacta el contexto:\n" + ordinaryText,
                    Attachments = AttachmentsOrNull(attachments)
                });
                Notify(nameof(Conversations));
                Save(id);
            }
            BeginCompaction(id, target);
            return true;
        }

        LoadTranscript(id);
        var index = ConversationIndex(id);
        if (index < 0) return false;
        var conversation = Conversations[index];
        conversation.Messages.Add(new ChatMessage { Role = "user", Text = ordinaryText, Attachments = AttachmentsOrNull(attachments) });
        // TODO(port): improveChatName(withAI:) para agentes Stellar con Ollama viene de ChatStore.swift:1160-1169 (Stellar fuera de alcance).
        if (conversation.Title == "Nuevo agente")
        {
            var title = text.Length == 0 ? string.Join(", ", attachments.Select(file => Path.GetFileName(file))) : text;
            conversation.Title = FirstChars(title, 55).Replace("\n", " ");
        }
        conversation.UpdatedAt = DateTime.UtcNow;
        Notify(nameof(Conversations));
        Save(id);
        SetStatus(id, ChatStatus.Queued);
        _queue.Add((id, ordinaryText));
        DrainQueue();
        return true;
    }

    // TODO(port): routeMention viene de ChatStore.swift:1178-1226 (menciones @agente): depende de AgentMentions, AgentBridge.maxChildren
    // y ChatDelegation.subAgentGuidance, todavía no portados.

    /// <summary>Un mensaje para un agente que trabaja. Un permiso pendiente se rechaza con él como motivo, como al escribir en Claude Code; si no, espera.</summary>
    private void Wait(string text, IReadOnlyList<string> attachments, Guid id, bool preservingApproval)
    {
        ClearSuggestion(id);
        var index = ConversationIndex(id);
        if (index < 0) return;
        var conversation = Conversations[index];
        if (!preservingApproval && _drivers.TryGetValue(id, out var active) && active.KeepsAlive && attachments.Count == 0
            && Approvals.TryGetValue(id, out var requests) && requests.FirstOrDefault(a => a.Questions.Count == 0) is { } request)
        {
            conversation.Messages.Add(new ChatMessage { Role = "user", Text = text });
            conversation.UpdatedAt = DateTime.UtcNow;
            Notify(nameof(Conversations));
            Save(id);
            Respond(id, request.Id, "deny", text);
            return;
        }
        var message = new ChatQueuedMessage { Text = text, Attachments = attachments.ToList() };
        if (!preservingApproval && _runs.ContainsKey(id) && _drivers.TryGetValue(id, out var driver) && driver.KeepsAlive)
            message.Sent = driver.Inject(message, conversation);
        WaitingOf(id).Add(message);
        Notify(nameof(Waiting));
    }

    /// <summary>Interrumpe el turno para que el agente lea ya los mensajes en espera.</summary>
    public void SendWaitingNow(Guid id)
    {
        if (!Waiting.TryGetValue(id, out var messages) || messages.Count == 0) return;
        if (!_runs.ContainsKey(id) || !_drivers.TryGetValue(id, out var driver))
        {
            if (!_runs.ContainsKey(id) && !_queue.Any(entry => entry.Id == id)) DeliverWaiting(id);
            return;
        }
        var generation = CurrentGeneration(id);
        // Un agente que sigue vivo lee sus mensajes en cola justo tras la interrupción; el resto, al terminar el turno.
        driver.Stop(keepingQueued: true);
        if (driver.AwaitsStopAcknowledgement)
        {
            _stoppingRuns.Add(id);
            Flush(id);
            SettleActivities(id);
            SetStatus(id, ChatStatus.Idle);
        }
        else if (!driver.KeepsAlive && _runs.TryGetValue(id, out var run))
        {
            run.Cancel();
        }
        ResolveApprovals(id, ApprovalIds(id), generation);
        Approvals[id] = new List<ChatApproval>();
        Notify(nameof(Approvals));
    }

    /// <summary>Retira un mensaje en espera para editarlo o descartarlo. Devuelve null si el agente ya lo leyó.</summary>
    public async Task<ChatQueuedMessage?> WithdrawAsync(string messageId, Guid from)
    {
        if (!Waiting.TryGetValue(from, out var list) || list.FirstOrDefault(m => m.Id == messageId) is not { } message) return null;
        if (message.Sent && (_drivers.GetValueOrDefault(from) ?? _liveDrivers.GetValueOrDefault(from)) is { } driver
            && driver.IsQueued(messageId))
        {
            if (!await driver.WithdrawAsync(messageId)) return null;
        }
        if (!Waiting.TryGetValue(from, out list) || !list.Any(m => m.Id == messageId)) return null;
        list.RemoveAll(m => m.Id == messageId);
        Notify(nameof(Waiting));
        return message;
    }

    public void ClearRecalled(Guid id)
    {
        if (Recalled.Remove(id)) Notify(nameof(Recalled));
    }

    public void ClearSuggestion(Guid id)
    {
        if (Suggestions.Remove(id)) Notify(nameof(Suggestions));
    }

    /// <summary>Entrega al agente los mensajes que Jack aún conserva, como siguiente turno, cuando está libre.</summary>
    private void DeliverWaiting(Guid id)
    {
        if (_stopped || _runs.ContainsKey(id) || _queue.Any(entry => entry.Id == id)) return;
        ReconcileWaiting(id);
        if (!Waiting.TryGetValue(id, out var messages) || messages.Count == 0 || messages.Any(m => m.Sent)) return;
        Waiting.Remove(id);
        Notify(nameof(Waiting));
        var text = string.Join("\n\n", messages.Select(m => m.Text).Where(t => t.Length > 0));
        var files = messages.SelectMany(m => m.Attachments).Distinct().ToList();
        Send(text, id, files);
    }

    /// <summary>Los mensajes que el agente ya no conserva (p. ej. porque su proceso terminó) vuelven a la cola de Jack.</summary>
    private void ReconcileWaiting(Guid id)
    {
        if (!Waiting.TryGetValue(id, out var messages) || messages.Count == 0) return;
        var driver = _liveDrivers.GetValueOrDefault(id);
        foreach (var message in messages)
        {
            if (message.Sent && driver?.IsQueued(message.Id) != true) message.Sent = false;
        }
    }

    /// <summary>El agente leyó un mensaje en espera: entra en la transcripción en el punto donde lo leyó.</summary>
    private void ReceiveDelivered(string messageId, string text, int index)
    {
        var conversation = Conversations[index];
        var id = conversation.Id;
        ChatQueuedMessage? message = null;
        if (Waiting.TryGetValue(id, out var list))
        {
            message = list.FirstOrDefault(m => m.Id == messageId);
            list.RemoveAll(m => m.Id == messageId);
            if (list.Count == 0) Waiting.Remove(id);
            Notify(nameof(Waiting));
        }
        if (conversation.Messages.Any(m => m.Id == messageId)) return;
        conversation.Messages.Add(new ChatMessage
        {
            Id = messageId,
            Role = "user",
            Text = message?.Text ?? text,
            Attachments = AttachmentsOrNull(message?.Attachments)
        });
        Notify(nameof(Conversations));
        Save(id);
    }

    // ----------------------------------------------------------------------------------------- Parada y respuestas

    /// <summary>Detiene el turno. Los mensajes en espera vuelven al compositor (como Esc en Claude Code).</summary>
    public void Stop(Guid id)
    {
        var generation = CurrentGeneration(id);
        if (_compactions.ContainsKey(id) || _handoffs.ContainsKey(id)) _cancelledJackTurns.Add(id);
        if (!_runs.ContainsKey(id))
        {
            _compactions.Remove(id);
            _handoffs.Remove(id);
            if (_afterCompaction.Remove(id, out var next))
            {
                var (nextText, nextFiles) = next;
                JackNotice("Compactación cancelada. Mensaje pendiente (vuelve a enviarlo):\n" + nextText, id);
                var index = ConversationIndex(id);
                if (index >= 0 && nextFiles.Count > 0)
                {
                    Conversations[index].Messages.Add(new ChatMessage { Role = "jack", Text = "Archivos del mensaje pendiente", Attachments = AttachmentsOrNull(nextFiles) });
                    Notify(nameof(Conversations));
                    Save(id);
                }
            }
        }
        _queue.RemoveAll(entry => entry.Id == id);
        // TODO(port): cancelLocating(id) viene de ChatStore.swift:1429 (búsqueda de carpeta no portada).
        if (Waiting.Remove(id, out var messages))
        {
            Notify(nameof(Waiting));
            if (messages.Count > 0)
            {
                var files = messages.SelectMany(m => m.Attachments).Distinct().ToList();
                var previous = Recalled.GetValueOrDefault(id);
                var texts = new List<string>();
                if (previous != null) texts.Add(previous.Text);
                texts.AddRange(messages.Select(m => m.Text));
                var recalledFiles = new List<string>();
                if (previous != null) recalledFiles.AddRange(previous.Attachments);
                recalledFiles.AddRange(files);
                Recalled[id] = new ChatQueuedMessage
                {
                    Text = string.Join("\n\n", texts.Where(t => t.Length > 0)),
                    Attachments = recalledFiles
                };
                Notify(nameof(Recalled));
            }
        }
        if (_drivers.TryGetValue(id, out var driver))
        {
            _stoppingRuns.Add(id);
            Flush(id);
            SettleActivities(id);
            driver.Stop();
            // Las interrupciones del protocolo conservan su reserva hasta la confirmación.
            if (!driver.KeepsAlive && !driver.AwaitsStopAcknowledgement)
            {
                if (_runs.TryGetValue(id, out var run)) run.Cancel();
                if (generation is { } current) FinishRun(id, current, cancelled: true);
            }
        }
        SetStatus(id, ChatStatus.Idle);
        ResolveApprovals(id, ApprovalIds(id), generation);
        Approvals[id] = new List<ChatApproval>();
        Notify(nameof(Approvals));
        Save(id);
    }

    /// <summary>Responde a un permiso con permitir o rechazar.</summary>
    public void Respond(Guid conversationId, string approvalId, bool allow) =>
        Respond(conversationId, approvalId, allow ? "allow" : "deny", null);

    /// <summary>Responde a un permiso con una de sus opciones. <paramref name="message"/> explica al agente un rechazo.</summary>
    public void Respond(Guid conversationId, string approvalId, string choice, string? message = null)
    {
        if (!_drivers.TryGetValue(conversationId, out var driver)) return;
        var generation = CurrentGeneration(conversationId);
        _ = Task.Run(async () =>
        {
            try
            {
                await driver.RespondAsync(approvalId, choice, message);
                RunOnUi(() =>
                {
                    if (!IsCurrentGeneration(conversationId, generation) || !HasApproval(conversationId, approvalId)) return;
                    RemoveApproval(conversationId, approvalId);
                    ResolveApprovals(conversationId, new[] { approvalId }, generation);
                    RestoreStatus(conversationId);
                });
            }
            catch (Exception error)
            {
                RunOnUi(() =>
                {
                    if (!IsCurrentGeneration(conversationId, generation) || _stoppingRuns.Contains(conversationId)
                        || !HasApproval(conversationId, approvalId)) return;
                    ErrorMessage = "No se pudo responder al permiso: " + error.Message;
                });
            }
        });
    }

    /// <summary>Responde a una pregunta del agente con las respuestas del usuario.</summary>
    public void Answer(Guid conversationId, string approvalId, IReadOnlyDictionary<string, string> answers)
    {
        if (!_drivers.TryGetValue(conversationId, out var driver)) return;
        var generation = CurrentGeneration(conversationId);
        _ = Task.Run(async () =>
        {
            try
            {
                await driver.AnswerAsync(approvalId, answers);
                RunOnUi(() =>
                {
                    if (!IsCurrentGeneration(conversationId, generation) || !HasApproval(conversationId, approvalId)) return;
                    RemoveApproval(conversationId, approvalId);
                    ResolveApprovals(conversationId, new[] { approvalId }, generation);
                    RestoreStatus(conversationId);
                });
            }
            catch (Exception error)
            {
                RunOnUi(() =>
                {
                    if (!IsCurrentGeneration(conversationId, generation) || _stoppingRuns.Contains(conversationId)
                        || !HasApproval(conversationId, approvalId)) return;
                    ErrorMessage = "No se pudo enviar la respuesta: " + error.Message;
                });
            }
        });
    }

    // ----------------------------------------------------------------------------------------- Cola global y cierre

    /// <summary>Cierra el store: no acepta más mensajes, vuelca los eventos pendientes y cierra los drivers.</summary>
    public void Shutdown()
    {
        _stopped = true;
        _queue.Clear();
        CancelFlush();
        // TODO(port): cancelación de customization, locating, asides, cuadernos, remoto, progreso, servidores y StellarRuntime viene de ChatStore.swift:1748-1766 (fuera de alcance).
        foreach (var id in _pending.Keys.ToList()) Flush(id);
        foreach (var (id, driver) in _drivers.ToList())
        {
            // Cancelar antes de cerrar: el cierre no debe registrarse como un fallo del turno.
            if (_runs.TryGetValue(id, out var run)) run.Cancel();
            driver.Close();
            SettleActivities(id);
            Save(id);
        }
        foreach (var driver in _liveDrivers.Values.ToList()) driver.Close();
        _liveDrivers.Clear();
        // Swift: archive.flush(). El archivo de chats es asíncrono; no bloqueamos el hilo de interfaz.
        _ = _archive.FlushAsync();
    }

    /// <summary>Arranca los mensajes en cola mientras haya hueco y el agente esté libre.</summary>
    private void DrainQueue()
    {
        if (_stopped) return;
        while (MaxConcurrent == 0 || _runs.Count < MaxConcurrent)
        {
            // Un mensaje espera mientras su agente está ocupado con un turno que empezó por sí mismo.
            var next = _queue.FindIndex(entry => !_runs.ContainsKey(entry.Id));
            if (next < 0) break;
            var (id, queuedPrompt) = _queue[next];
            _queue.RemoveAt(next);
            var conversation = FindConversation(id);
            if (conversation == null) continue;
            // TODO(port): la guarda de Antigravity en Terminal (ChatStore.swift:1779-1783) está fuera de alcance.
            IChatDriver driver;
            try
            {
                driver = DriverFor(conversation);
            }
            catch (Exception error)
            {
                // Un proveedor que no existe en Windows falla como un turno fallido, sin tumbar la cola.
                conversation.Messages.Add(new ChatMessage { Role = "error", Text = error.Message });
                SetStatus(id, ChatStatus.Failed);
                Notify(nameof(Conversations));
                Save(id);
                continue;
            }
            var prompt = PreparedJackPrompt(queuedPrompt, conversation);
            // TODO(port): la delegación de Jack (ChatStore.swift:1794-1811, AgentBridge) no está portada: el turno va sin herramientas de Jack.
            // TODO(port): las imágenes y los cuadernos (ChatStore.swift:1796-1797) están fuera de alcance.
            StartRun(id, driver, onEvent => driver.RunAsync(conversation, prompt, onEvent));
        }
    }

    /// <summary>Devuelve el driver del agente: el vivo si existe, o uno nuevo. Los que se mantienen vivos se guardan para el siguiente mensaje.</summary>
    private IChatDriver DriverFor(ChatConversation conversation)
    {
        var id = conversation.Id;
        if (_liveDrivers.TryGetValue(id, out var live)) return live;
        var driver = _makeDriver(conversation.Provider);
        // TODO(port): el manejador de artefactos de Stellar (ChatStore.swift:1819-1828) está fuera de alcance.
        if (driver.KeepsAlive)
        {
            _liveDrivers[id] = driver;
            driver.Observe(
                idle: ev => RunOnUi(() =>
                {
                    if (IsLiveDriver(id, driver)) ReceiveIdle(ev, id);
                }),
                unprompted: () => RunOnUi(() =>
                {
                    if (IsLiveDriver(id, driver)) BeginUnpromptedTurn(id);
                }));
        }
        return driver;
    }

    private bool IsLiveDriver(Guid id, IChatDriver driver) =>
        _liveDrivers.TryGetValue(id, out var current) && ReferenceEquals(current, driver);

    // ----------------------------------------------------------------------------------------- Turnos

    /// <summary>
    /// Lanza un turno en el pool. El cuerpo recibe el receptor de eventos, que reenvía cada evento al hilo de interfaz
    /// filtrando por generación; el turno solo arranca si, en el hilo de interfaz, no se ha detenido entretanto.
    /// </summary>
    private void StartRun(Guid id, IChatDriver driver, Func<Action<ChatEvent>, Task> body)
    {
        ClearSuggestion(id);
        var generation = Guid.NewGuid();
        var cancellation = new CancellationTokenSource();
        _runGenerations[id] = generation;
        _resolvedApprovalIDs[id] = new HashSet<string>();
        _turnMessageStartIndices[id] = FindConversation(id)?.Messages.Count ?? 0;
        _stoppingRuns.Remove(id);
        _drivers[id] = driver;
        // TODO(port): la línea base del presupuesto (ChatStore.swift:1850-1852) solo se usa con Codex, todavía no portado.
        _budgetBaseline[id] = 0;
        _runs[id] = cancellation;
        SetStatus(id, ChatStatus.Running);
        _ = Task.Run(async () =>
        {
            Exception? failure = null;
            try
            {
                var mayStart = new TaskCompletionSource<bool>();
                RunOnUi(() => mayStart.TrySetResult(!cancellation.IsCancellationRequested && !_stoppingRuns.Contains(id)));
                if (await mayStart.Task)
                {
                    await body(ev => RunOnUi(() =>
                    {
                        if (!IsCurrentGeneration(id, generation)) return;
                        if (ev is CompletedEvent) FinishRun(id, generation, cancelled: false);
                        else if (!_stoppingRuns.Contains(id)) Receive(ev, id);
                    }));
                }
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                failure = error;
            }
            RunOnUi(() => FinishStartedRun(id, generation, cancellation, failure));
        });
    }

    /// <summary>Cierre del cuerpo de un turno en el hilo de interfaz: un fallo se registra salvo que el turno se detuviera.</summary>
    private void FinishStartedRun(Guid id, Guid generation, CancellationTokenSource cancellation, Exception? failure)
    {
        if (failure != null && IsCurrentGeneration(id, generation) && !_stoppingRuns.Contains(id) && !cancellation.IsCancellationRequested)
            Receive(new FailureEvent(failure.Message), id);
        FinishRun(id, generation, cancellation.IsCancellationRequested);
    }

    /// <summary>Un evento terminal cierra el turno sin esperar a la limpieza del proceso. La tarea antigua puede volver después.</summary>
    private void FinishRun(Guid id, Guid generation, bool cancelled)
    {
        if (!IsCurrentGeneration(id, generation)) return;
        var wasStopping = _stoppingRuns.Remove(id);
        FinishRunNow(id, generation, cancelled || wasStopping);
    }

    private void FinishRunNow(Guid id, Guid generation, bool cancelled)
    {
        if (!IsCurrentGeneration(id, generation)) return;
        _runGenerations.Remove(id);
        _resolvedApprovalIDs.Remove(id);
        Flush(id);
        SettleActivities(id);
        if (Statuses.GetValueOrDefault(id) != ChatStatus.Failed) SetStatus(id, ChatStatus.Idle);
        Approvals[id] = new List<ChatApproval>();
        Notify(nameof(Approvals));
        FinishTurn(id);
        _drivers.Remove(id);
        _runs.Remove(id);
        CompleteJackTurn(id, cancelled);
        // TODO(port): refreshUsageSoon (ChatStore.swift:1889-1891) solo aplica a Codex y Antigravity; Claude Code informa su cuota mientras trabaja.
        DeliverWaiting(id);
        Save(id);
        EvictInactiveTranscripts();
        DrainQueue();
    }

    /// <summary>Recalcula el estado tras una aprobación o al volver de una pausa, según lo que siga vivo.</summary>
    private void RestoreStatus(Guid id)
    {
        if (_stoppingRuns.Contains(id))
        {
            SetStatus(id, ChatStatus.Idle);
        }
        // TODO(port): las solicitudes de imagen pendientes también ponen el estado en espera (ChatStore.swift:1898); imágenes fuera de alcance.
        else if (Approvals.TryGetValue(id, out var list) && list.Count > 0)
        {
            SetStatus(id, ChatStatus.Waiting);
        }
        else if (_runs.ContainsKey(id))
        {
            SetStatus(id, ChatStatus.Running);
        }
        else
        {
            SetStatus(id, _queue.Any(entry => entry.Id == id) ? ChatStatus.Queued : ChatStatus.Idle);
            _drivers.Remove(id);
        }
    }

    /// <summary>El agente empezó a trabajar por sí mismo (p. ej. un subagente en segundo plano terminó); sigue el turno que el driver inicia.</summary>
    private void BeginUnpromptedTurn(Guid id)
    {
        if (_stopped || _runs.ContainsKey(id) || !_liveDrivers.TryGetValue(id, out var driver)) return;
        LoadTranscript(id);
        StartRun(id, driver, onEvent => driver.FollowAsync(onEvent));
    }

    /// <summary>Eventos entre turnos: subagentes que terminan, cambios de modo y similares.</summary>
    private void ReceiveIdle(ChatEvent ev, Guid id)
    {
        if (FindConversation(id) == null) return;
        LoadTranscript(id);
        // Un subagente en segundo plano puede pedir permiso después del turno que lo inició.
        if (ev is ApprovalEvent && !_runs.ContainsKey(id))
        {
            if (_liveDrivers.TryGetValue(id, out var live)) _drivers[id] = live;
            else _drivers.Remove(id);
        }
        Receive(ev, id);
        Flush(id);
        Save(id);
    }

    /// <summary>Cierra el turno: vista previa, última respuesta y marca de no leído.</summary>
    private void FinishTurn(Guid id)
    {
        _turnMessageStartIndices.Remove(id, out var startIndex);
        var index = ConversationIndex(id);
        if (index < 0) return;
        var conversation = Conversations[index];
        var messages = conversation.Messages;
        var last = messages.LastOrDefault(m => (m.Role == "assistant" || m.Role == "error") && !string.IsNullOrWhiteSpace(m.Text));
        if (last != null) conversation.Preview = PreviewOf(last.Text);
        var turnMessages = messages.Skip(Math.Min(startIndex, messages.Count)).ToList();
        var reply = turnMessages.LastOrDefault(m => m.Role == "assistant" && !string.IsNullOrWhiteSpace(m.Text));
        if (reply != null) _lastReplies[id] = FirstChars(reply.Text, 24_000);
        if (SelectedId != id) conversation.HasUnread = true;
        Notify(nameof(Conversations));
    }

    // ----------------------------------------------------------------------------------------- Eventos

    /// <summary>Recibe un evento del turno. El texto y las herramientas se agrupan (50 ms); el resto se aplica en el acto.</summary>
    private void Receive(ChatEvent ev, Guid id)
    {
        switch (ev)
        {
            case TextEvent or ReasoningEvent or ToolOutputEvent or ToolEvent:
                if (!_pending.TryGetValue(id, out var events))
                {
                    events = new List<ChatEvent>();
                    _pending[id] = events;
                }
                events.Add(ev);
                if (_flushTask == null) ScheduleFlush(50);
                break;
            default:
                Flush(id);
                Apply(ev, id);
                break;
        }
    }

    /// <summary>Programa el volcado de los lotes pendientes en el hilo de interfaz.</summary>
    private void ScheduleFlush(int delayMilliseconds)
    {
        var timer = new CancellationTokenSource();
        _flushTask = timer;
        _ = Task.Delay(delayMilliseconds, timer.Token).ContinueWith(task =>
        {
            if (!task.IsCompletedSuccessfully) return;
            RunOnUi(() =>
            {
                if (!ReferenceEquals(_flushTask, timer)) return;
                _flushTask = null;
                FlushAll();
            });
        }, TaskScheduler.Default);
    }

    private void CancelFlush()
    {
        _flushTask?.Cancel();
        _flushTask = null;
    }

    private void FlushAll()
    {
        foreach (var id in _pending.Keys.ToList()) Flush(id);
    }

    /// <summary>Vuelca al transcript los eventos agrupados de un agente, en orden.</summary>
    private void Flush(Guid id)
    {
        if (!_pending.Remove(id, out var events) || events.Count == 0) return;
        var index = ConversationIndex(id);
        if (index < 0) return;
        var conversation = Conversations[index];
        foreach (var ev in events)
        {
            switch (ev)
            {
                case TextEvent text:
                    {
                        AppendText(conversation, text.Id, text.Text, text.Replace, "assistant");
                        break;
                    }
                case ReasoningEvent reasoning:
                    {
                        AppendText(conversation, reasoning.Id, reasoning.Text, reasoning.Replace, "reasoning");
                        break;
                    }
                case ToolOutputEvent output:
                    {
                        var existing = conversation.Messages.FindIndex(m => m.Id == output.Id);
                        if (existing >= 0)
                        {
                            conversation.Messages[existing].Detail = LastChars(conversation.Messages[existing].Detail + output.Text, 65_536);
                        }
                        else
                        {
                            conversation.Messages.Add(new ChatMessage
                            {
                                Id = output.Id,
                                Role = "tool",
                                Text = "Actividad",
                                Detail = LastChars(output.Text, 65_536),
                                Status = "running"
                            });
                        }
                        break;
                    }
                case ToolEvent tool:
                    {
                        var existing = conversation.Messages.FindIndex(m => m.Id == tool.Id);
                        if (existing >= 0)
                        {
                            var message = conversation.Messages[existing];
                            message.Text = tool.Title;
                            if (tool.Detail.Length > 0) message.Detail = FirstChars(tool.Detail, 65_536);
                            message.Status = tool.Status;
                        }
                        else
                        {
                            conversation.Messages.Add(new ChatMessage
                            {
                                Id = tool.Id,
                                Role = "tool",
                                Text = tool.Title,
                                Detail = FirstChars(tool.Detail, 65_536),
                                Status = tool.Status
                            });
                        }
                        break;
                    }
            }
        }
        Notify(nameof(Conversations));
    }

    /// <summary>Añade o reemplaza el texto de un mensaje, identificado por su id de proveedor.</summary>
    private static void AppendText(ChatConversation conversation, string messageId, string text, bool replace, string role)
    {
        var index = conversation.Messages.FindIndex(m => m.Id == messageId);
        if (index >= 0)
        {
            if (replace) conversation.Messages[index].Text = text;
            else conversation.Messages[index].Text += text;
        }
        else
        {
            conversation.Messages.Add(new ChatMessage { Id = messageId, Role = role, Text = text });
        }
    }

    /// <summary>Aplica un evento que no es texto ni herramienta: uso, permisos, modo, fallos...</summary>
    private void Apply(ChatEvent ev, Guid id)
    {
        var index = ConversationIndex(id);
        if (index < 0) return;
        var conversation = Conversations[index];
        switch (ev)
        {
            case UsageEvent usage:
                {
                    MergeUsage(usage.Usage);
                    break;
                }
            case TokensEvent tokens:
                {
                    TokenUsage[id] = tokens.Usage;
                    conversation.TokenUsage = tokens.Usage;
                    Notify(nameof(TokenUsage));
                    _budgetTurnUsage[id] = Math.Max(_budgetTurnUsage.GetValueOrDefault(id),
                        Math.Max(0, tokens.Usage.Input + tokens.Usage.Output - _budgetBaseline.GetValueOrDefault(id)));
                    break;
                }
            case ContextEvent context:
                {
                    var value = conversation.ContextUsage is { } current ? current with { } : new ChatContextUsage { Used = 0 };
                    if (context.Used is { } used) value.Used = used;
                    if (context.Window is { } window) value.Window = window;
                    if (value != conversation.ContextUsage) conversation.ContextUsage = value;
                    break;
                }
            case CommandsEvent commandList:
                {
                    if (commandList.Commands.Count > 0)
                    {
                        Commands[CommandsKeyOf(conversation.Provider, conversation.ProjectPath)] = commandList.Commands.ToList();
                        Notify(nameof(Commands));
                    }
                    break;
                }
            case SuggestionEvent suggestion:
                {
                    Suggestions[id] = suggestion.Text;
                    Notify(nameof(Suggestions));
                    break;
                }
            case SessionEvent session:
                {
                    conversation.SessionId = session.SessionId;
                    Save(id);
                    break;
                }
            case ToolEvent tool:
                {
                    var message = new ChatMessage
                    {
                        Id = tool.Id,
                        Role = "tool",
                        Text = tool.Title,
                        Detail = FirstChars(tool.Detail, 65_536),
                        Status = tool.Status
                    };
                    var existing = conversation.Messages.FindIndex(m => m.Id == tool.Id);
                    if (existing >= 0) conversation.Messages[existing] = message;
                    else conversation.Messages.Add(message);
                    break;
                }
            case ApprovalEvent approval:
                {
                    // Un permiso ya resuelto no vuelve a abrirse con un evento duplicado del mismo turno.
                    if (_resolvedApprovalIDs.TryGetValue(id, out var resolved) && resolved.Contains(approval.Approval.Id)) break;
                    var list = ApprovalsOf(id);
                    if (!list.Any(a => a.Id == approval.Approval.Id)) list.Add(approval.Approval);
                    Notify(nameof(Approvals));
                    SetStatus(id, ChatStatus.Waiting);
                    break;
                }
            case ApprovalResolvedEvent resolvedEvent:
                {
                    if (Approvals.TryGetValue(id, out var pendingList))
                    {
                        pendingList.RemoveAll(a => a.Id == resolvedEvent.Id);
                        Notify(nameof(Approvals));
                    }
                    ResolveApprovals(id, new[] { resolvedEvent.Id }, CurrentGeneration(id));
                    RestoreStatus(id);
                    break;
                }
            case ModeEvent mode:
                {
                    if (conversation.Mode != mode.Mode)
                    {
                        conversation.Mode = mode.Mode;
                        Save(id);
                    }
                    break;
                }
            case DeliveredEvent delivered:
                {
                    ReceiveDelivered(delivered.Id, delivered.Text, index);
                    break;
                }
            case FailureEvent failure:
                {
                    conversation.Messages.Add(new ChatMessage { Role = "error", Text = failure.Message });
                    SetStatus(id, ChatStatus.Failed);
                    Save(id);
                    break;
                }
            default:
                // CompletedEvent, TextEvent, ReasoningEvent y ToolOutputEvent no llegan aquí: Receive los trata antes.
                break;
        }
        conversation.UpdatedAt = DateTime.UtcNow;
        Notify(nameof(Conversations));
    }

    /// <summary>Marca como resueltos los permisos de un turno, para que un duplicado no los reabra.</summary>
    private void ResolveApprovals(Guid id, IEnumerable<string> approvalIds, Guid? generation)
    {
        var ids = approvalIds.ToList();
        if (ids.Count == 0 || !IsCurrentGeneration(id, generation)) return;
        if (!_resolvedApprovalIDs.TryGetValue(id, out var set))
        {
            set = new HashSet<string>();
            _resolvedApprovalIDs[id] = set;
        }
        set.UnionWith(ids);
    }

    /// <summary>Las herramientas que seguían en curso se marcan como interrumpidas: su proceso ya no existe.</summary>
    private void SettleActivities(Guid id)
    {
        var index = ConversationIndex(id);
        if (index < 0) return;
        var changed = false;
        foreach (var message in Conversations[index].Messages)
        {
            if (message.Role == "tool" && (message.Status is "running" or "inProgress" or "pending"))
            {
                message.Status = "interrupted";
                changed = true;
            }
        }
        if (changed) Notify(nameof(Conversations));
    }

    /// <summary>Los procesos en segundo plano no pueden seguir corriendo sin su agente: se marcan como interrumpidos al cargar.</summary>
    private void SettleBackground(Guid id)
    {
        if (_liveDrivers.ContainsKey(id)) return;
        var index = ConversationIndex(id);
        if (index < 0) return;
        var changed = false;
        foreach (var message in Conversations[index].Messages)
        {
            if (message.Status == "background")
            {
                message.Status = "interrupted";
                changed = true;
            }
        }
        if (changed) Notify(nameof(Conversations));
    }

    // ----------------------------------------------------------------------------------------- Utilidades privadas

    private int ConversationIndex(Guid id) => Conversations.FindIndex(c => c.Id == id);

    private ChatConversation? FindConversation(Guid id) => Conversations.Find(c => c.Id == id);

    /// <summary>Cambia el estado de un agente y avisa a los observadores.</summary>
    private void SetStatus(Guid id, ChatStatus status)
    {
        Statuses[id] = status;
        Notify(nameof(Statuses));
    }

    /// <summary>Lista de permisos del agente, creándola si no existe.</summary>
    private List<ChatApproval> ApprovalsOf(Guid id)
    {
        if (!Approvals.TryGetValue(id, out var list))
        {
            list = new List<ChatApproval>();
            Approvals[id] = list;
        }
        return list;
    }

    /// <summary>Lista de mensajes en espera del agente, creándola si no existe.</summary>
    private List<ChatQueuedMessage> WaitingOf(Guid id)
    {
        if (!Waiting.TryGetValue(id, out var list))
        {
            list = new List<ChatQueuedMessage>();
            Waiting[id] = list;
        }
        return list;
    }

    private List<string> ApprovalIds(Guid id) =>
        Approvals.TryGetValue(id, out var list) ? list.Select(a => a.Id).ToList() : new List<string>();

    private bool HasApproval(Guid id, string approvalId) =>
        Approvals.TryGetValue(id, out var list) && list.Any(a => a.Id == approvalId);

    private void RemoveApproval(Guid id, string approvalId)
    {
        if (!Approvals.TryGetValue(id, out var list)) return;
        list.RemoveAll(a => a.Id == approvalId);
        Notify(nameof(Approvals));
    }

    /// <summary>La generación vigente del turno de un agente, o null si no hay turno.</summary>
    private Guid? CurrentGeneration(Guid id) => _runGenerations.TryGetValue(id, out var generation) ? (Guid?)generation : null;

    private bool IsCurrentGeneration(Guid id, Guid? generation) => CurrentGeneration(id) == generation;

    private static List<string>? AttachmentsOrNull(IReadOnlyList<string>? files) =>
        files is { Count: > 0 } ? files.ToList() : null;

    private static string FirstChars(string text, int count) => text.Length <= count ? text : text[..count];

    private static string LastChars(string text, int count) => text.Length <= count ? text : text[^count..];

    /// <summary>Clave de la caché de comandos de barra: proveedor y carpeta, como `rawValue|proyecto` en Swift.</summary>
    private static string CommandsKeyOf(ChatProvider provider, string projectPath) =>
        provider.ToString().ToLowerInvariant() + "|" + projectPath;

    /// <summary>Vista previa de una sola línea, sin formato, para la barra lateral.</summary>
    internal static string PreviewOf(string text)
    {
        var line = text.ReplaceLineEndings("\n").Split('\n')
            .Select(l => l.Trim(' ', '\t'))
            .FirstOrDefault(l => l.Length > 0 && !l.StartsWith("```", StringComparison.Ordinal)) ?? "";
        line = line.TrimStart('#', '>', '-', '*', '+', ' ').Replace("**", "").Replace("`", "");
        return line.Length > 160 ? line[..159] + "…" : line;
    }
}
