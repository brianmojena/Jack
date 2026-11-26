using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jack.Core;

// Port de `enum ClaudeProtocol` de Sources/JackCore/ChatDrivers.swift (líneas ~490-815), más los mensajes de
// entrada que Swift construye en ClaudeChatDriver (userMessage, control_request, control_response) y
// ChatRunConfiguration.claudeContent (ChatDrivers.swift ~2148), que aquí viven junto al protocolo.
//
// Los diccionarios [String: Any] de Swift son JsonObject (System.Text.Json.Nodes). JsonObject conserva el orden de
// inserción, así que las claves salen en el mismo orden que el literal Swift. Swift no garantiza orden (JSONSerialization),
// por eso las comprobaciones leen el JSON por campos cuando el orden no importa.

/// <summary>Protocolo stream-json de Claude Code: construcción de mensajes de entrada y lectura de la salida.</summary>
public static class ClaudeProtocol
{
    // boundedJSON de StellarOllama.swift: claves ordenadas, límite de 64 KB (ver BoundedJson.cs).
    private static string BoundedJson(JsonNode? value) => Jack.Core.BoundedJson.Format(value);

    /// <summary>Serialización compacta de una línea para stdin. Sin escapar caracteres no ASCII, como el JSON que lee Claude Code.</summary>
    private static readonly JsonSerializerOptions WireOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>Todo lo que la petición envió más lo que generó: lo que se queda en el contexto.</summary>
    public static int ContextTokens(JsonObject? usage)
    {
        var total = 0;
        foreach (var key in new[] { "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens" })
        {
            total += ClaudeJson.Int(usage?[key]) ?? 0;
        }
        return total;
    }

    /// <summary>Los comandos integrados, como /compact, van primero; las skills y plugins siguen en el orden de la CLI.</summary>
    public static IReadOnlyList<ChatCommand> Commands(IEnumerable<JsonObject> values)
    {
        var list = values.ToList();
        var ordered = list.Where(value => ClaudeJson.Bool(value["builtin"]) == true)
            .Concat(list.Where(value => ClaudeJson.Bool(value["builtin"]) != true));
        var commands = new List<ChatCommand>();
        foreach (var value in ordered)
        {
            var name = ClaudeJson.Str(value["name"]);
            if (string.IsNullOrEmpty(name) || name.StartsWith("__", StringComparison.Ordinal)) continue;
            commands.Add(new ChatCommand
            {
                Name = name,
                Description = ClaudeJson.Str(value["description"]) ?? "",
                ArgumentHint = ClaudeJson.Str(value["argumentHint"]) ?? "",
            });
        }
        return commands;
    }

    /// <summary>Llamadas que son contabilidad y no trabajo, como cargar el esquema de otra herramienta.</summary>
    public static readonly IReadOnlySet<string> HiddenTools = new HashSet<string>(StringComparer.Ordinal) { "ToolSearch" };

    /// <summary>Claude Code llama "default" al modo "manual" de Jack.</summary>
    public static string JackMode(string mode) => mode == "default" ? "manual" : mode;

    public static string CliMode(string mode) => mode == "manual" ? "default" : mode;

    /// <summary>Un resultado de herramienta como texto: texto plano, o los bloques de texto de una lista.</summary>
    public static string ResultText(JsonNode? content)
    {
        if (content is JsonValue value && value.GetValueKind() == JsonValueKind.String) return value.GetValue<string>();
        if (content is JsonArray array && array.All(item => item is JsonObject))
        {
            var texts = array.Cast<JsonObject>()
                .Where(block => ClaudeJson.Str(block["type"]) == "text")
                .Select(block => ClaudeJson.Str(block["text"]))
                .OfType<string>()
                .ToList();
            if (texts.Count > 0) return string.Join("\n", texts);
        }
        return BoundedJson(content ?? new JsonArray());
    }

    /// <summary>Qué pide una solicitud de permiso, como lo muestran la barra lateral y la cabecera de la solicitud.</summary>
    public static string PermissionTitle(string tool, JsonObject input)
    {
        var file = ClaudeJson.Str(FirstPresent(input, "file_path", "notebook_path", "path")) is { } path
            ? Path.GetFileName(path.TrimEnd('/', '\\'))
            : null;
        switch (tool)
        {
            case "Bash":
                return "Ejecutar un comando";
            case "Edit":
            case "MultiEdit":
            case "NotebookEdit":
                return file is null ? "Editar un archivo" : $"Editar {file}";
            case "Write":
                return file is null ? "Escribir un archivo" : $"Escribir {file}";
            case "Read":
                return file is null ? "Leer un archivo" : $"Leer {file}";
            case "WebFetch":
                return ClaudeJson.Str(input["url"]) is { } url && Uri.TryCreate(url, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.Host)
                    ? $"Abrir {uri.Host}"
                    : "Abrir una página web";
            case "WebSearch":
                return "Buscar en la web";
            case "Agent":
            case "Task":
                return "Lanzar un subagente";
            default:
                if (tool.StartsWith("mcp__", StringComparison.Ordinal))
                {
                    return "Usar " + tool[5..].Replace("__", " · ", StringComparison.Ordinal);
                }
                return $"Usar {tool}";
        }
    }

    /// <summary>La respuesta "no volver a preguntar" que ofrece Claude Code, según los permisos que sugiere.</summary>
    public static ChatApprovalChoice? AlwaysChoice(IReadOnlyList<JsonObject> suggestions)
    {
        foreach (var suggestion in suggestions.Where(item => ClaudeJson.Str(item["type"]) == "addRules"))
        {
            var rules = new List<string>();
            foreach (var rule in ClaudeJson.Objects(suggestion["rules"]) ?? new List<JsonObject>())
            {
                if (ClaudeJson.Str(rule["toolName"]) is not { } tool) continue;
                rules.Add(ClaudeJson.Str(rule["ruleContent"]) is { } content ? $"{tool}({content})" : tool);
            }
            if (rules.Count > 0)
            {
                return new ChatApprovalChoice
                {
                    Id = "always",
                    Title = $"Permitir siempre {string.Join(", ", rules)} {Scope(suggestion["destination"])}",
                };
            }
        }

        var mode = suggestions.FirstOrDefault(item => ClaudeJson.Str(item["type"]) == "setMode");
        if (mode is not null && ClaudeJson.Str(mode["mode"]) == "acceptEdits")
        {
            return new ChatApprovalChoice { Id = "always", Title = $"Aceptar todas las ediciones {Scope(mode["destination"])}" };
        }

        var folders = suggestions.FirstOrDefault(item => ClaudeJson.Str(item["type"]) == "addDirectories");
        if (folders is not null && ClaudeJson.StrList(folders["directories"]) is { Count: > 0 } list)
        {
            var names = string.Join(", ", list.Select(path => Path.GetFileName(path)));
            return new ChatApprovalChoice { Id = "always", Title = $"Permitir siempre {names} {Scope(folders["destination"])}" };
        }
        return null;
    }

    private static string Scope(JsonNode? destination) => ClaudeJson.Str(destination) switch
    {
        "session" => "en esta sesión",
        "userSettings" => "en todos tus proyectos",
        "projectSettings" => "en este proyecto, para todo el equipo",
        _ => "en este proyecto",
    };

    /// <summary>Opciones de un plan propuesto por el agente; sustituyen a permitir y rechazar.</summary>
    public static IReadOnlyList<ChatApprovalChoice> PlanChoices =>
    [
        new() { Id = "plan.acceptEdits", Title = "Sí, y aceptar las ediciones" },
        new() { Id = "plan.manual", Title = "Sí, revisando cada edición" },
        new() { Id = "deny", Title = "No, seguir planificando" },
    ];

    /// <summary>
    /// Cómo Jack responde a un <c>can_use_tool</c> con una de sus opciones. <paramref name="payload"/> es el payload
    /// guardado por <see cref="Decoder"/> (Swift: <c>PendingApproval.payload</c>).
    /// </summary>
    public static JsonObject PermissionResponse(JsonObject payload, string choice, string? message)
    {
        var input = payload["input"]?.DeepClone() ?? new JsonObject();
        var reason = message?.Trim() is { Length: > 0 } trimmed ? trimmed : null;
        switch (choice)
        {
            case "deny":
                if (ClaudeJson.Bool(payload["plan"]) == true)
                {
                    return new JsonObject
                    {
                        ["behavior"] = "deny",
                        ["message"] = reason is null
                            ? "The user wants to keep planning. Ask what should change in the plan."
                            : $"The user wants to keep planning and said: {reason}",
                    };
                }
                return new JsonObject
                {
                    ["behavior"] = "deny",
                    ["message"] = reason is null
                        ? "User denied this action."
                        : $"The user rejected this action and said: {reason}",
                };
            case "always":
                return new JsonObject
                {
                    ["behavior"] = "allow",
                    ["updatedInput"] = input,
                    ["updatedPermissions"] = payload["suggestions"]?.DeepClone() ?? new JsonArray(),
                };
            case "plan.acceptEdits":
            case "plan.manual":
                var mode = choice == "plan.acceptEdits" ? "acceptEdits" : "default";
                return new JsonObject
                {
                    ["behavior"] = "allow",
                    ["updatedInput"] = input,
                    ["updatedPermissions"] = new JsonArray(new JsonObject
                    {
                        ["type"] = "setMode",
                        ["mode"] = mode,
                        ["destination"] = "session",
                    }),
                };
            default:
                return new JsonObject { ["behavior"] = "allow", ["updatedInput"] = input };
        }
    }

    /// <summary>AskUserQuestion se permite con las respuestas añadidas a su entrada, indexadas por pregunta.</summary>
    public static JsonObject QuestionResponse(JsonObject payload, IReadOnlyDictionary<string, string> answers)
    {
        var input = (payload["input"]?.DeepClone() as JsonObject) ?? new JsonObject();
        var answerObject = new JsonObject();
        foreach (var (question, answer) in answers)
        {
            answerObject[question] = answer;
        }
        input["answers"] = answerObject;
        return new JsonObject { ["behavior"] = "allow", ["updatedInput"] = input };
    }

    /// <summary>Una línea, o el inicio de un turno, que el agente empieza por sí mismo fuera de un turno que Jack inició.</summary>
    public static bool StartsTurn(JsonObject obj)
    {
        var topLevel = obj["parent_tool_use_id"] is null;
        return ClaudeJson.Str(obj["type"]) switch
        {
            "assistant" or "stream_event" => topLevel,
            "system" => ClaudeJson.Str(obj["subtype"]) == "status" && ClaudeJson.Str(obj["status"]) == "requesting",
            _ => false,
        };
    }

    // MARK: Entrada (Jack -> Claude Code)

    /// <summary>Una línea JSON compacta para escribir en stdin.</summary>
    public static string Serialize(JsonNode node) => node.ToJsonString(WireOptions);

    /// <summary>Texto plano, o bloques de texto e imagen cuando el mensaje lleva adjuntos (Swift: <c>claudeContent</c>).</summary>
    public static JsonNode ClaudeContent(string prompt, IReadOnlyList<string> attachments)
    {
        if (attachments.Count == 0) return JsonValue.Create(prompt)!;
        var blocks = new JsonArray(new JsonObject
        {
            ["type"] = "text",
            ["text"] = ChatAttachments.PromptText(prompt, attachments),
        });
        foreach (var path in attachments)
        {
            if (InlineImage(path) is not { } image) continue;
            blocks.Add(new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject
                {
                    ["type"] = "base64",
                    ["media_type"] = image.MediaType,
                    ["data"] = Convert.ToBase64String(image.Data),
                },
            });
        }
        return blocks;
    }

    /// <summary>
    /// Imagen en línea si cabe en el límite de la API. Equivalente síncrono de <c>ChatAttachments.InlineImageAsync</c>,
    /// porque el mensaje se construye en el mismo hilo que lo escribe en stdin, como en Swift.
    /// </summary>
    private static (string MediaType, byte[] Data)? InlineImage(string path)
    {
        if (ChatAttachments.ImageType(path) is not { } type) return null;
        if (new FileInfo(path).Length > ChatAttachments.InlineLimit) return null;
        return (type, File.ReadAllBytes(path));
    }

    /// <summary>Mensaje de usuario para stream-json. <paramref name="uuid"/> identifica un mensaje en cola (Swift: <c>line["uuid"]</c>).</summary>
    public static JsonObject UserMessage(ChatConversation conversation, string prompt, IReadOnlyList<string>? attachments = null, string? uuid = null)
    {
        var message = new JsonObject
        {
            ["type"] = "user",
            ["message"] = new JsonObject
            {
                ["role"] = "user",
                ["content"] = ClaudeContent(prompt, attachments ?? conversation.TurnAttachments),
            },
            ["parent_tool_use_id"] = null,
        };
        if (uuid is not null) message["uuid"] = uuid;
        return message;
    }

    /// <summary>Id de una solicitud de control de Jack: "jack-N", con N creciente por proceso.</summary>
    public static string ControlRequestId(int counter) => $"jack-{counter}";

    public static JsonObject ControlRequest(string requestId, JsonObject request) => new()
    {
        ["type"] = "control_request",
        ["request_id"] = requestId,
        ["request"] = request,
    };

    /// <summary>Respuesta a una solicitud de Claude Code, siempre con subtype "success".</summary>
    public static JsonObject ControlResponse(string requestId, JsonObject response) => new()
    {
        ["type"] = "control_response",
        ["response"] = new JsonObject
        {
            ["subtype"] = "success",
            ["request_id"] = requestId,
            ["response"] = response,
        },
    };

    /// <summary>Respuesta a una aprobación guardada; null si el payload no tiene requestID (Swift: "expired").</summary>
    public static JsonObject? ApprovalReply(JsonObject payload, JsonObject response) =>
        ClaudeJson.Str(payload["requestID"]) is { } requestId ? ControlResponse(requestId, response) : null;

    public static JsonObject SetPermissionModeRequest(string mode) => new()
    {
        ["subtype"] = "set_permission_mode",
        ["mode"] = CliMode(mode),
    };

    public static JsonObject SetModelRequest(string model) => new()
    {
        ["subtype"] = "set_model",
        ["model"] = model,
    };

    /// <summary>
    /// Interrumpe el turno como Esc en la terminal. Sin <paramref name="keepingQueued"/> se descartan los mensajes en cola
    /// (cancel_queued). Con true, la interrupción de cancelación de awaitTurn de Swift usa el mismo resultado sin cancel_queued.
    /// </summary>
    public static JsonObject InterruptRequest(bool keepingQueued)
    {
        var request = new JsonObject { ["subtype"] = "interrupt" };
        if (!keepingQueued) request["cancel_queued"] = true;
        return request;
    }

    public static JsonObject CancelAsyncMessageRequest(string messageUuid) => new()
    {
        ["subtype"] = "cancel_async_message",
        ["message_uuid"] = messageUuid,
    };

    /// <summary>El id de solicitud de una línea control_response entrante, si lo tiene.</summary>
    public static string? ControlResponseRequestId(JsonObject line) =>
        ClaudeJson.Str(ClaudeJson.Obj(line["response"])?["request_id"]);

    /// <summary>El cuerpo de una línea control_response entrante; vacío si falta.</summary>
    public static JsonObject ControlResponseBody(JsonObject line) =>
        ClaudeJson.Obj(ClaudeJson.Obj(line["response"])?["response"]) ?? new JsonObject();

    // MARK: Salida (Claude Code -> Jack)

    /// <summary>Una línea del stream como objeto JSON; null si no es un objeto válido (Swift: jsonObject).</summary>
    public static JsonObject? ParseLine(string line)
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

    private static JsonNode? FirstPresent(JsonObject obj, params string[] keys)
    {
        // Como `??` en Swift: una clave presente con null (NSNull) cuenta como encontrada.
        foreach (var key in keys)
        {
            if (obj.ContainsKey(key)) return obj[key];
        }
        return null;
    }

    /// <summary>
    /// Traduce cada línea de salida de Claude Code a eventos de Jack. Guarda estado entre líneas, como el struct
    /// <c>Decoder</c> de Swift: un controlador nuevo equivale a <c>ClaudeProtocol.Decoder()</c>.
    /// </summary>
    public sealed class Decoder
    {
        private readonly Dictionary<string, string> _emittedTextByBlock = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _emittedReasoningByBlock = new(StringComparer.Ordinal);
        private readonly Dictionary<string, (string Id, string Name)> _tools = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _toolNames = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _toolInputs = new(StringComparer.Ordinal);
        /// <summary>Qué contiene cada id de bloque, para que una foto nunca reutilice el id de otro tipo de bloque.</summary>
        private readonly Dictionary<string, string> _blockKinds = new(StringComparer.Ordinal);
        private readonly Dictionary<string, JsonObject> _approvals = new(StringComparer.Ordinal);
        private readonly HashSet<string> _hiddenBlocks = new(StringComparer.Ordinal);
        /// <summary>Herramientas que siguen trabajando tras devolver su llamada, como subagentes en segundo plano.</summary>
        private readonly HashSet<string> _backgroundTools = new(StringComparer.Ordinal);
        /// <summary>Qué ha hecho cada subagente, por el id de la llamada que lo inició.</summary>
        private readonly Dictionary<string, List<string>> _subagentActivity = new(StringComparer.Ordinal);
        private string _messageId = "claude-message";

        /// <summary>session_id de la línea init.</summary>
        public string? SessionId { get; private set; }

        /// <summary>Tareas en segundo plano que siguen en marcha, que mantienen vivo el proceso entre turnos.</summary>
        public int BackgroundTaskCount { get; private set; }

        /// <summary>
        /// Payload de cada aprobación pendiente, por id. Swift guarda <c>PendingApproval(payload:, provider: "claude")</c>;
        /// aquí solo el payload. El controlador lo envuelve si lo necesita.
        /// </summary>
        // TODO(port): PendingApproval viene de ChatDrivers.swift; ClaudeChatDriver lo crea a partir de este payload.
        public IReadOnlyDictionary<string, JsonObject> Approvals => _approvals;

        /// <summary>Una línea cruda del stream. Devuelve lista vacía si no es un objeto JSON.</summary>
        public List<ChatEvent> DecodeLine(string line) =>
            ParseLine(line) is { } obj ? Events(obj) : new List<ChatEvent>();

        /// <summary>Eventos de una línea ya parseada.</summary>
        public List<ChatEvent> Events(JsonObject obj)
        {
            var type = ClaudeJson.Str(obj["type"]) ?? "";
            if (ClaudeJson.Str(obj["parent_tool_use_id"]) is { } parent && (type is "assistant" or "user" or "stream_event"))
            {
                return SubagentEvents(obj, parent);
            }
            // TODO(port): UsageDecoder viene de ChatUsage.swift (UsageDecoder.claudeEvent). Debe aceptar un JsonObject.
            if (type == "rate_limit_event" && UsageDecoder.ClaudeEvent(obj) is { } usage)
            {
                return [new UsageEvent(usage)];
            }
            if (type == "prompt_suggestion" && ClaudeJson.Str(obj["suggestion"]) is { } suggestion && suggestion.Trim().Length > 0)
            {
                return [new SuggestionEvent(suggestion)];
            }
            if (type == "user" && ClaudeJson.Obj(obj["message"]) is { } message && ClaudeJson.Objects(message["content"]) is { } blocks)
            {
                return ToolResults(blocks);
            }
            if (type == "system") return SystemEvents(obj);
            if (type == "stream_event") return StreamEvents(obj);
            if (type == "assistant") return AssistantEvents(obj);
            if (type == "control_request")
            {
                var requestId = ClaudeJson.Str(obj["request_id"]) ?? Guid.NewGuid().ToString();
                var request = ClaudeJson.Obj(obj["request"]) ?? new JsonObject();
                if (ClaudeJson.Str(request["subtype"]) == "can_use_tool")
                {
                    return [new ApprovalEvent(BuildApproval(requestId, request))];
                }
            }
            if (type == "result") return ResultEvents(obj);
            return [];
        }

        /// <summary>Resultados de herramientas de un mensaje de usuario, solo de llamadas conocidas y no en segundo plano.</summary>
        private List<ChatEvent> ToolResults(List<JsonObject> blocks)
        {
            var events = new List<ChatEvent>();
            foreach (var block in blocks)
            {
                if (ClaudeJson.Str(block["type"]) != "tool_result") continue;
                if (ClaudeJson.Str(block["tool_use_id"]) is not { } nativeId) continue;
                if (!_tools.TryGetValue(nativeId, out var tool) || _backgroundTools.Contains(nativeId)) continue;
                var status = ClaudeJson.Bool(block["is_error"]) == true ? "failed" : "completed";
                events.Add(new ToolEvent(tool.Id, tool.Name, ToolDetail(nativeId, ClaudeProtocol.ResultText(block["content"])), status));
            }
            return events;
        }

        private List<ChatEvent> SystemEvents(JsonObject obj)
        {
            switch (ClaudeJson.Str(obj["subtype"]))
            {
                case "commands_changed":
                    if (ClaudeJson.Objects(obj["commands"]) is { } commands)
                    {
                        return [new CommandsEvent(ClaudeProtocol.Commands(commands))];
                    }
                    break;
                case "init":
                    if (ClaudeJson.Str(obj["session_id"]) is not { } sessionId) break;
                    SessionId = sessionId;
                    var initEvents = new List<ChatEvent> { new SessionEvent(sessionId) };
                    if (ClaudeJson.Str(obj["permissionMode"]) is { } initMode)
                    {
                        initEvents.Add(new ModeEvent(ClaudeProtocol.JackMode(initMode)));
                    }
                    return initEvents;
                case "status":
                    if (ClaudeJson.Str(obj["permissionMode"]) is { } statusMode)
                    {
                        return [new ModeEvent(ClaudeProtocol.JackMode(statusMode))];
                    }
                    break;
                case "background_tasks_changed":
                    BackgroundTaskCount = ClaudeJson.Arr(obj["tasks"])?.Count ?? 0;
                    break;
                case "task_started":
                    // "background" no es un estado de ejecución: al terminar el turno, la fila se queda como está.
                    if (ClaudeJson.Bool(obj["is_backgrounded"]) == true
                        && ClaudeJson.Str(obj["tool_use_id"]) is { } startedId
                        && _tools.TryGetValue(startedId, out var started))
                    {
                        _backgroundTools.Add(startedId);
                        return [new ToolEvent(started.Id, started.Name, ToolDetail(startedId, ""), "background")];
                    }
                    break;
                case "task_notification":
                    if (ClaudeJson.Str(obj["tool_use_id"]) is not { } doneId
                        || !_backgroundTools.Remove(doneId)
                        || !_tools.TryGetValue(doneId, out var finished))
                    {
                        break;
                    }
                    var doneStatus = ClaudeJson.Str(obj["status"]) switch
                    {
                        "completed" => "completed",
                        "failed" => "failed",
                        _ => "interrupted",
                    };
                    return [new ToolEvent(finished.Id, finished.Name, ToolDetail(doneId, ClaudeJson.Str(obj["summary"]) ?? ""), doneStatus)];
                default:
                    break;
            }
            return [];
        }

        private List<ChatEvent> StreamEvents(JsonObject obj)
        {
            var evt = ClaudeJson.Obj(obj["event"]) ?? new JsonObject();
            if (ClaudeJson.Str(evt["type"]) == "message_start"
                && ClaudeJson.Obj(evt["message"]) is { } started
                && ClaudeJson.Str(started["id"]) is { } startedMessageId)
            {
                _messageId = startedMessageId;
            }
            var delta = ClaudeJson.Obj(evt["delta"]) ?? new JsonObject();
            var index = evt["index"] is { } indexNode ? (ClaudeJson.Str(indexNode) ?? indexNode.ToJsonString()) : "0";
            var blockId = $"{_messageId}:{index}";
            if (_hiddenBlocks.Contains(blockId)) return [];

            if (ClaudeJson.Str(evt["type"]) == "content_block_start" && ClaudeJson.Obj(evt["content_block"]) is { } block)
            {
                var blockType = ClaudeJson.Str(block["type"]);
                if (blockType == "tool_use")
                {
                    var name = ClaudeJson.Str(block["name"]) ?? "Herramienta";
                    if (ClaudeProtocol.HiddenTools.Contains(name))
                    {
                        _hiddenBlocks.Add(blockId);
                        return [];
                    }
                    _toolNames[blockId] = name;
                    _blockKinds[blockId] = "tool";
                    if (ClaudeJson.Str(block["id"]) is { } toolId) _tools[toolId] = (blockId, name);
                    return [new ToolEvent(blockId, name, "", "running")];
                }
                if (blockType == "thinking")
                {
                    _blockKinds[blockId] = "thinking";
                    return [new ReasoningEvent(blockId, ClaudeJson.Str(block["thinking"]) ?? "", true)];
                }
            }

            if (ClaudeJson.Str(delta["thinking"]) is { } thinking)
            {
                _blockKinds[blockId] = "thinking";
                Append(_emittedReasoningByBlock, blockId, thinking);
                return [new ReasoningEvent(blockId, thinking, false)];
            }
            if (ClaudeJson.Str(delta["text"]) is { } text)
            {
                _blockKinds[blockId] = "text";
                Append(_emittedTextByBlock, blockId, text);
                return [new TextEvent(blockId, text, false)];
            }
            if (ClaudeJson.Str(delta["type"]) == "input_json_delta")
            {
                return [new ToolOutputEvent(blockId, ClaudeJson.Str(delta["partial_json"]) ?? "")];
            }
            return [];
        }

        private List<ChatEvent> AssistantEvents(JsonObject obj)
        {
            var message = ClaudeJson.Obj(obj["message"]) ?? new JsonObject();
            // Los comandos locales responden con un mensaje sintético cuyo uso es todo ceros.
            var used = ClaudeJson.Str(message["model"]) == "<synthetic>" ? 0 : ClaudeProtocol.ContextTokens(ClaudeJson.Obj(message["usage"]));
            var events = new List<ChatEvent>();
            if (used > 0) events.Add(new ContextEvent(used, null));

            var content = ClaudeJson.Objects(message["content"]) ?? new List<JsonObject>();
            var messageId = ClaudeJson.Str(message["id"]) ?? _messageId;
            var prefix = $"{messageId}:";
            // Claude Code envía una foto por bloque: la posición en `content` no es el índice del stream.
            for (var index = 0; index < content.Count; index++)
            {
                var block = content[index];
                var kind = ClaudeJson.Str(block["type"]) ?? "";
                var item = SnapshotEvent(block, kind, index, messageId, prefix);
                if (item is not null) events.Add(item);
            }
            return events;
        }

        /// <summary>Un bloque de una foto del mensaje, sin repetir lo que ya se emitió por el stream.</summary>
        private ChatEvent? SnapshotEvent(JsonObject block, string kind, int index, string messageId, string prefix)
        {
            if (kind == "tool_use")
            {
                var name = ClaudeJson.Str(block["name"]) ?? "Herramienta";
                if (ClaudeProtocol.HiddenTools.Contains(name)) return null;
                var input = BoundedJson(block["input"] ?? new JsonObject());
                var nativeId = ClaudeJson.Str(block["id"]);
                var id = nativeId is not null && _tools.TryGetValue(nativeId, out var known)
                    ? known.Id
                    : SnapshotId(messageId, index, "tool");
                if (nativeId is not null)
                {
                    _tools[nativeId] = (id, name);
                    _toolInputs[nativeId] = input;
                }
                return new ToolEvent(id, name, input, "running");
            }
            if (kind == "thinking" && ClaudeJson.Str(block["thinking"]) is { } thinking)
            {
                if (_emittedReasoningByBlock.Any(entry => entry.Key.StartsWith(prefix, StringComparison.Ordinal) && entry.Value == thinking)) return null;
                var id = SnapshotId(messageId, index, "thinking");
                _emittedReasoningByBlock[id] = thinking;
                return new ReasoningEvent(id, thinking, true);
            }
            if (kind == "text" && ClaudeJson.Str(block["text"]) is { } text)
            {
                if (_emittedTextByBlock.Any(entry => entry.Key.StartsWith(prefix, StringComparison.Ordinal) && entry.Value == text)) return null;
                var id = SnapshotId(messageId, index, "text");
                _emittedTextByBlock[id] = text;
                return new TextEvent(id, text, true);
            }
            return null;
        }

        /// <summary>Id de un bloque de foto; si el id ya es de otro tipo de bloque, se distingue por el tipo.</summary>
        private string SnapshotId(string messageId, int index, string kind)
        {
            var id = $"{messageId}:{index}";
            if (_blockKinds.TryGetValue(id, out var existing) && existing != kind)
            {
                return $"{messageId}:{kind}:{index}";
            }
            _blockKinds[id] = kind;
            return id;
        }

        private List<ChatEvent> ResultEvents(JsonObject obj)
        {
            if (ClaudeJson.Bool(obj["is_error"]) == true)
            {
                return [new FailureEvent(ClaudeJson.Str(obj["result"]) ?? "Claude reported an error.")];
            }
            var value = ClaudeJson.Obj(obj["usage"]) ?? new JsonObject();
            // Ventana de contexto: el mayor `contextWindow` de los modelos usados.
            var windows = new List<int>();
            if (ClaudeJson.Obj(obj["modelUsage"]) is { } modelUsage && modelUsage.All(entry => entry.Value is JsonObject))
            {
                foreach (var entry in modelUsage)
                {
                    if (ClaudeJson.Int(((JsonObject)entry.Value!)["contextWindow"]) is { } contextWindow) windows.Add(contextWindow);
                }
            }
            int? window = windows.Count > 0 ? windows.Max() : null;
            var last = ClaudeProtocol.ContextTokens(ClaudeJson.Objects(value["iterations"])?.LastOrDefault());

            var events = new List<ChatEvent>();
            if (window is not null || last > 0)
            {
                events.Add(new ContextEvent(last > 0 ? last : (int?)null, window));
            }
            events.Add(new TokensEvent(new ChatTokenUsage
            {
                Input = ClaudeJson.Int(value["input_tokens"]) ?? 0,
                Output = ClaudeJson.Int(value["output_tokens"]) ?? 0,
                Cached = ClaudeJson.Int(value["cache_read_input_tokens"]) ?? 0,
                CostUsd = ClaudeJson.Dbl(obj["total_cost_usd"]),
            }));
            events.Add(new CompletedEvent());
            return events;
        }

        /// <summary>Entrada en JSON de la herramienta, luego lo que hizo su subagente, luego su resultado.</summary>
        private string ToolDetail(string nativeId, string result)
        {
            var activity = _subagentActivity.TryGetValue(nativeId, out var lines)
                ? string.Join("\n", lines) + (result.Length == 0 ? "" : "\n\n")
                : "";
            var input = _toolInputs.TryGetValue(nativeId, out var stored) ? stored + "\n" : "";
            return input + activity + result;
        }

        /// <summary>Las llamadas de herramientas de un subagente se listan bajo la llamada que lo inició, en vez de mezclarse con la transcripción.</summary>
        private List<ChatEvent> SubagentEvents(JsonObject obj, string parent)
        {
            if (ClaudeJson.Str(obj["type"]) != "assistant") return [];
            if (!_tools.TryGetValue(parent, out var tool)) return [];
            if (ClaudeJson.Objects(ClaudeJson.Obj(obj["message"])?["content"]) is not { } blocks) return [];

            var calls = blocks
                .Where(block => ClaudeJson.Str(block["type"]) == "tool_use"
                    && !ClaudeProtocol.HiddenTools.Contains(ClaudeJson.Str(block["name"]) ?? ""))
                .ToList();
            if (calls.Count == 0) return [];

            foreach (var call in calls)
            {
                var input = ClaudeJson.Obj(call["input"]) ?? new JsonObject();
                var subject = new[] { "command", "file_path", "pattern", "url", "query", "description" }
                    .Select(key => ClaudeJson.Str(input[key]))
                    .FirstOrDefault(value => value is not null) ?? "";
                var line = $"› {ClaudeJson.Str(call["name"]) ?? "Herramienta"}"
                    + (subject.Length == 0 ? "" : " " + subject.Replace("\n", " ", StringComparison.Ordinal));
                // Hasta 160 caracteres (puntos de código), como `String(line.prefix(160))` en Swift.
                if (!_subagentActivity.TryGetValue(parent, out var list))
                {
                    list = new List<string>();
                    _subagentActivity[parent] = list;
                }
                list.Add(string.Concat(line.EnumerateRunes().Take(160)));
            }
            return [new ToolEvent(tool.Id, tool.Name, ToolDetail(parent, ""), _backgroundTools.Contains(parent) ? "background" : "running")];
        }

        private ChatApproval BuildApproval(string id, JsonObject request)
        {
            var name = ClaudeJson.Str(request["tool_name"]) ?? "tool";
            var input = ClaudeJson.Obj(request["input"]) ?? new JsonObject();
            var payload = new JsonObject
            {
                ["requestID"] = id,
                ["input"] = input.DeepClone(),
            };
            ChatApproval approval;
            if (name == "AskUserQuestion" && ClaudeJson.Objects(input["questions"]) is { Count: > 0 } questions)
            {
                approval = new ChatApproval { Id = id, Title = "Claude tiene preguntas", Detail = "" };
                approval.Questions = questions.Select(ToQuestion).OfType<ChatInputQuestion>().ToList();
            }
            else if (name == "ExitPlanMode")
            {
                approval = new ChatApproval
                {
                    Id = id,
                    Title = "Plan listo para revisar",
                    Detail = ClaudeJson.Str(input["plan"]) ?? "",
                    IsPlan = true,
                    Choices = ClaudeProtocol.PlanChoices.ToList(),
                };
                payload["plan"] = true;
            }
            else
            {
                var suggestions = ClaudeJson.Objects(request["permission_suggestions"]) ?? new List<JsonObject>();
                payload["suggestions"] = ClaudeJson.CloneArray(suggestions);
                approval = new ChatApproval
                {
                    Id = id,
                    Title = ClaudeProtocol.PermissionTitle(name, input),
                    Detail = BoundedJson(input),
                    Tool = name,
                };
                var always = ClaudeProtocol.AlwaysChoice(suggestions);
                approval.Choices = always is null ? new List<ChatApprovalChoice>() : new List<ChatApprovalChoice> { always };
            }
            _approvals[id] = payload;
            return approval;
        }

        private static ChatInputQuestion? ToQuestion(JsonObject question)
        {
            if (ClaudeJson.Str(question["question"]) is not { } text) return null;
            var options = ClaudeJson.Objects(question["options"])?
                .Select(option => ClaudeJson.Str(option["label"]) is { } label
                    ? new ChatInputOption { Label = label, Description = ClaudeJson.Str(option["description"]) ?? "" }
                    : null)
                .OfType<ChatInputOption>()
                .ToList();
            return new ChatInputQuestion
            {
                Id = text,
                Header = ClaudeJson.Str(question["header"]) ?? "",
                Question = text,
                Options = options,
                MultiSelect = ClaudeJson.Bool(question["multiSelect"]),
            };
        }

        private static void Append(Dictionary<string, string> store, string key, string text)
        {
            store[key] = store.TryGetValue(key, out var previous) ? previous + text : text;
        }
    }
}

/// <summary>Lectura y escritura de nodos JSON con la semántica de los `as? Tipo` de Swift: un tipo incorrecto da null.</summary>
public static class ClaudeJson
{
    public static string? Str(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;

    public static bool? Bool(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        var kind = value.GetValueKind();
        return (kind is JsonValueKind.True or JsonValueKind.False) ? value.GetValue<bool>() : null;
    }

    public static int? Int(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.Number && value.TryGetValue<int>(out var number) ? number : null;

    public static double? Dbl(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.Number && value.TryGetValue<double>(out var number) ? number : null;

    public static JsonObject? Obj(JsonNode? node) => node as JsonObject;

    public static JsonArray? Arr(JsonNode? node) => node as JsonArray;

    /// <summary>Una lista de objetos; null si no es lista o si algún elemento no es objeto (como `as? [[String: Any]]`).</summary>
    public static List<JsonObject>? Objects(JsonNode? node)
    {
        if (node is not JsonArray array) return null;
        var objects = new List<JsonObject>(array.Count);
        foreach (var item in array)
        {
            if (item is not JsonObject obj) return null;
            objects.Add(obj);
        }
        return objects;
    }

    /// <summary>Una lista de cadenas; null si no es lista o si algún elemento no es cadena.</summary>
    public static List<string>? StrList(JsonNode? node)
    {
        if (node is not JsonArray array) return null;
        var strings = new List<string>(array.Count);
        foreach (var item in array)
        {
            if (Str(item) is not { } text) return null;
            strings.Add(text);
        }
        return strings;
    }

    /// <summary>Copia profunda de una lista de objetos, para incrustarla en otro JSON sin reparentar nodos.</summary>
    public static JsonArray CloneArray(IEnumerable<JsonObject> items) =>
        new(items.Select(item => (JsonNode?)item.DeepClone()).ToArray());
}
