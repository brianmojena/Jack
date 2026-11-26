using System.Text.Json.Nodes;
using Jack.Core;

namespace Jack.Core.Checks;

// Comprobaciones de ClaudeProtocol.cs con líneas de ejemplo del stream-json de Claude Code.
// Lanza InvalidOperationException si algo falla.
// Nota: las aprobaciones y las herramientas con entrada dependen de BoundedJson (TODO(port) en ClaudeProtocol.cs).
public static class ClaudeProtocolChecks
{
    public static void Run()
    {
        CheckParseLine();
        CheckPermissionTitles();
        CheckResultText();
        CheckAlwaysChoice();
        CheckTurnStream();
        CheckCommands();
        CheckSuggestion();
        CheckPermissionRequests();
        CheckQuestionRequest();
        CheckPlanRequest();
        CheckSubagentAndBackground();
        CheckStartsTurn();
        CheckUserMessage();
        CheckUserMessageAttachments();
        CheckControlMessages();
        CheckModeNames();
    }

    private static void CheckParseLine()
    {
        Check(ClaudeProtocol.ParseLine("[1, 2]") is null, "ParseLine rechaza una lista JSON.");
        Check(ClaudeProtocol.ParseLine("{roto") is null, "ParseLine rechaza JSON mal formado.");
        Check(ClaudeProtocol.ParseLine("") is null, "ParseLine rechaza una línea vacía.");
        Check(ClaudeProtocol.ParseLine("""{"type":"result"}""") is { } parsed && ClaudeJson.Str(parsed["type"]) == "result", "ParseLine acepta un objeto JSON.");
    }

    private static void CheckModeNames()
    {
        Expect(ClaudeProtocol.JackMode("default"), "manual", "Claude Code 'default' es el modo 'manual' de Jack.");
        Expect(ClaudeProtocol.CliMode("manual"), "default", "El modo 'manual' de Jack es 'default' en Claude Code.");
        Expect(ClaudeProtocol.JackMode("plan"), "plan", "Los demás modos no cambian.");
    }

    private static void CheckPermissionTitles()
    {
        Expect(ClaudeProtocol.PermissionTitle("Bash", Obj("{}")), "Ejecutar un comando", "Bash pide ejecutar un comando.");
        Expect(ClaudeProtocol.PermissionTitle("Edit", Obj("""{"file_path":"/proj/src/Program.cs"}""")), "Editar Program.cs", "Edit muestra el nombre del archivo.");
        Expect(ClaudeProtocol.PermissionTitle("Write", Obj("{}")), "Escribir un archivo", "Write sin ruta usa el título genérico.");
        Expect(ClaudeProtocol.PermissionTitle("WebFetch", Obj("""{"url":"https://example.com/a"}""")), "Abrir example.com", "WebFetch muestra el host.");
        Expect(ClaudeProtocol.PermissionTitle("mcp__jack__ask", Obj("{}")), "Usar jack · ask", "Las herramientas MCP separan servidor y herramienta.");
        Expect(ClaudeProtocol.PermissionTitle("Otra", Obj("{}")), "Usar Otra", "Una herramienta desconocida se nombra tal cual.");
    }

    private static void CheckResultText()
    {
        Expect(ClaudeProtocol.ResultText(JsonValue.Create("plano")), "plano", "Un resultado de texto plano se devuelve tal cual.");
        var blocks = JsonNode.Parse("""[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}]""");
        Expect(ClaudeProtocol.ResultText(blocks), "a\nb", "Un resultado en bloques une solo los bloques de texto.");
    }

    private static void CheckAlwaysChoice()
    {
        var session = Objects("""[{"type":"setMode","mode":"acceptEdits","destination":"session"}]""");
        Expect(ClaudeProtocol.AlwaysChoice(session)?.Title ?? "", "Aceptar todas las ediciones en esta sesión", "setMode acceptEdits ofrece aceptar ediciones en la sesión.");
        var directories = Objects("""[{"type":"addDirectories","directories":["/a/docs","/b/lib"],"destination":"projectSettings"}]""");
        Expect(ClaudeProtocol.AlwaysChoice(directories)?.Title ?? "", "Permitir siempre docs, lib en este proyecto, para todo el equipo", "addDirectories nombra las carpetas.");
        Check(ClaudeProtocol.AlwaysChoice(Objects("[]")) is null, "Sin sugerencias no hay opción 'siempre'.");
    }

    /// <summary>Una sola conversación de principio a fin: init, texto en stream, herramienta, foto, resultado y error.</summary>
    private static void CheckTurnStream()
    {
        var decoder = new ClaudeProtocol.Decoder();

        var init = decoder.DecodeLine("""{"type":"system","subtype":"init","session_id":"sess-1","permissionMode":"default","model":"sonnet"}""");
        Check(init.Count == 2 && init[0] is SessionEvent { SessionId: "sess-1" } && init[1] is ModeEvent { Mode: "manual" },
            "init emite la sesión y el modo de Jack.");
        Expect(decoder.SessionId ?? "", "sess-1", "init guarda el session_id.");

        Check(decoder.DecodeLine("""{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1"}}}""").Count == 0,
            "message_start no emite eventos.");
        Check(decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}""").Count == 0,
            "El inicio de un bloque de texto no emite eventos.");

        var text = decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hola"}}}""");
        Check(text is [TextEvent { Id: "msg_1:0", Text: "Hola", Replace: false }], "Un delta de texto emite TextEvent sin reemplazo.");

        var tool = decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}""");
        Check(tool is [ToolEvent { Id: "msg_1:1", Title: "Bash", Status: "running" }], "Un tool_use en el stream emite ToolEvent en ejecución.");

        var partial = decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}}""");
        Check(partial is [ToolOutputEvent { Id: "msg_1:1" }], "Un input_json_delta emite ToolOutputEvent.");

        var hiddenStart = decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_search","name":"ToolSearch","input":{}}}}""");
        Check(hiddenStart.Count == 0, "ToolSearch no se muestra.");
        Check(decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}}""").Count == 0,
            "Los deltas de una herramienta oculta tampoco se muestran.");

        // Foto del mensaje: el texto ya se emitió por el stream (se omite); la herramienta se reconoce por su id nativo.
        var snapshot = decoder.DecodeLine("""{"type":"assistant","message":{"id":"msg_1","model":"sonnet","content":[{"type":"text","text":"Hola"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":0}},"parent_tool_use_id":null}""");
        Check(snapshot.Count == 2 && snapshot[0] is ContextEvent { Used: 35, Window: null }, "La foto suma el contexto usado (10+20+5+0).");
        Check(snapshot[1] is ToolEvent { Id: "msg_1:1", Title: "Bash", Status: "running" }, "La herramienta de la foto conserva el id del stream.");

        var result = decoder.DecodeLine("""{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file1\nfile2","is_error":false}]},"parent_tool_use_id":null}""");
        Check(result is [ToolEvent { Id: "msg_1:1", Status: "completed" } done] && done.Detail.EndsWith("file1\nfile2", StringComparison.Ordinal),
            "El resultado de la herramienta cierra la llamada con su salida.");

        var final = decoder.DecodeLine("""{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0123,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"iterations":[{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}]},"modelUsage":{"sonnet":{"contextWindow":200000}}}""");
        Check(final.Count == 3, "El resultado emite contexto, tokens y completado.");
        Check(final[0] is ContextEvent { Used: 10, Window: 200000 }, "El contexto usa la última iteración y la ventana del modelo.");
        Check(final[1] is TokensEvent { Usage: { Input: 10, Output: 20, Cached: 5, CostUsd: 0.0123 } }, "El resultado informa de los tokens y el coste.");
        Check(final[2] is CompletedEvent, "El resultado termina el turno.");
    }

    private static void CheckCommands()
    {
        var commands = ClaudeProtocol.Commands(Objects("""[{"name":"review","description":"Revisa cambios","argumentHint":"[instrucciones]","builtin":false},{"name":"compact","description":"Compacta","builtin":true},{"name":"__oculto","description":"x"}]"""));
        Check(commands.Select(command => command.Name).SequenceEqual(["compact", "review"]), "Los comandos integrados van primero y se ocultan los que empiezan por __.");
        Expect(commands[1].ArgumentHint, "[instrucciones]", "El argumentHint se conserva.");
        var decoder = new ClaudeProtocol.Decoder();
        var events = decoder.DecodeLine("""{"type":"system","subtype":"commands_changed","commands":[{"name":"review","description":"Revisa cambios","builtin":false}]}""");
        Check(events is [CommandsEvent { Commands.Count: 1 }], "commands_changed emite CommandsEvent.");
    }

    private static void CheckSuggestion()
    {
        var decoder = new ClaudeProtocol.Decoder();
        Check(decoder.DecodeLine("""{"type":"prompt_suggestion","suggestion":"Ejecuta los tests"}""") is [SuggestionEvent { Text: "Ejecuta los tests" }],
            "prompt_suggestion emite SuggestionEvent.");
        Check(decoder.DecodeLine("""{"type":"prompt_suggestion","suggestion":"   "}""").Count == 0, "Una sugerencia vacía se ignora.");
    }

    private static void CheckPermissionRequests()
    {
        var decoder = new ClaudeProtocol.Decoder();
        var events = decoder.DecodeLine("""{"type":"control_request","request_id":"req_1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}]}}""");
        Check(events is [ApprovalEvent { Approval: { Id: "req_1", Title: "Ejecutar un comando", Tool: "Bash" } approval }]
            && approval.Choices is [{ Id: "always", Title: "Permitir siempre Bash(rm -rf build) en este proyecto" }],
            "Un permiso de Bash ofrece la opción 'siempre' de su sugerencia.");
        Check(decoder.Approvals.TryGetValue("req_1", out var payload) && ClaudeJson.Str(payload["requestID"]) == "req_1",
            "La aprobación guarda su requestID en el payload.");

        Expect(Serialize(ClaudeProtocol.ApprovalReply(payload!, ClaudeProtocol.PermissionResponse(payload!, "allow", null))),
            """{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"behavior":"allow","updatedInput":{"command":"rm -rf build"}}}}""",
            "Permitir una vez responde con allow y la entrada original.");
        Expect(Serialize(ClaudeProtocol.PermissionResponse(payload!, "deny", "  no  ")),
            """{"behavior":"deny","message":"The user rejected this action and said: no"}""",
            "Rechazar con motivo lo indica al agente.");
        Expect(Serialize(ClaudeProtocol.PermissionResponse(payload!, "deny", null)),
            """{"behavior":"deny","message":"User denied this action."}""",
            "Rechazar sin motivo usa el mensaje genérico.");
        Expect(Serialize(ClaudeProtocol.PermissionResponse(payload!, "always", null)),
            """{"behavior":"allow","updatedInput":{"command":"rm -rf build"},"updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}]}""",
            "Siempre permite y envía las sugerencias como permisos.");
        Check(ClaudeProtocol.ApprovalReply(new JsonObject(), new JsonObject()) is null, "Sin requestID no hay respuesta.");
    }

    private static void CheckQuestionRequest()
    {
        var decoder = new ClaudeProtocol.Decoder();
        var events = decoder.DecodeLine("""{"type":"control_request","request_id":"req_2","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"¿Qué base de datos?","header":"Base","multiSelect":false,"options":[{"label":"SQLite","description":"Local"},{"label":"Postgres","description":"Servidor"}]}]}}}""");
        Check(events is [ApprovalEvent { Approval: { Title: "Claude tiene preguntas", Questions: [{ Question: "¿Qué base de datos?", MultiSelect: false, Options: [{ Label: "SQLite" }, { Label: "Postgres" }] }] } }],
            "AskUserQuestion emite preguntas con sus opciones.");
        var payload = decoder.Approvals["req_2"];
        var answered = Serialize(ClaudeProtocol.ApprovalReply(payload, ClaudeProtocol.QuestionResponse(payload, new Dictionary<string, string> { ["¿Qué base de datos?"] = "SQLite" })) ?? new JsonObject());
        Check(answered.Contains("\"answers\":{\"¿Qué base de datos?\":\"SQLite\"}", StringComparison.Ordinal), "Las respuestas se añaden a la entrada, indexadas por pregunta.");
    }

    private static void CheckPlanRequest()
    {
        var decoder = new ClaudeProtocol.Decoder();
        var events = decoder.DecodeLine("""{"type":"control_request","request_id":"req_3","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Plan\n1. Paso"}}}""");
        Check(events is [ApprovalEvent { Approval: { IsPlan: true, Detail: "# Plan\n1. Paso" } plan }]
            && plan.Choices.Select(choice => choice.Id).SequenceEqual(["plan.acceptEdits", "plan.manual", "deny"]),
            "ExitPlanMode emite un plan con sus tres opciones.");
        var payload = decoder.Approvals["req_3"];
        Expect(Serialize(ClaudeProtocol.PermissionResponse(payload, "plan.acceptEdits", null)),
            """{"behavior":"allow","updatedInput":{"plan":"# Plan\n1. Paso"},"updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}""",
            "Aprobar un plan cambia el modo a aceptar ediciones.");
        Expect(Serialize(ClaudeProtocol.PermissionResponse(payload, "deny", "revisa el paso 2")),
            """{"behavior":"deny","message":"The user wants to keep planning and said: revisa el paso 2"}""",
            "Rechazar un plan pide seguir planificando.");
    }

    private static void CheckSubagentAndBackground()
    {
        var decoder = new ClaudeProtocol.Decoder();
        decoder.DecodeLine("""{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_2"}}}""");
        var agent = decoder.DecodeLine("""{"type":"stream_event","event":{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_agent","name":"Agent"}}}""");
        Check(agent is [ToolEvent { Id: "msg_2:3", Title: "Agent", Status: "running" }], "Un subagente aparece como herramienta.");

        var nested = decoder.DecodeLine("""{"type":"assistant","parent_tool_use_id":"toolu_agent","message":{"id":"msg_sub","content":[{"type":"tool_use","id":"toolu_r","name":"Read","input":{"file_path":"/proj/a.cs"}}]}}""");
        Check(nested is [ToolEvent { Id: "msg_2:3", Detail: "› Read /proj/a.cs" }], "Las herramientas del subagente se listan bajo su llamada.");
        Check(decoder.DecodeLine("""{"type":"user","parent_tool_use_id":"toolu_agent","message":{"role":"user","content":[]}}""").Count == 0,
            "Los mensajes de usuario del subagente no emiten eventos.");

        var background = decoder.DecodeLine("""{"type":"system","subtype":"task_started","tool_use_id":"toolu_agent","is_backgrounded":true}""");
        Check(background is [ToolEvent { Status: "background" }], "Una tarea en segundo plano queda como 'background'.");
        Check(decoder.DecodeLine("""{"type":"system","subtype":"background_tasks_changed","tasks":[{"id":"t1"}]}""").Count == 0
            && decoder.BackgroundTaskCount == 1, "background_tasks_changed cuenta las tareas vivas.");

        var finished = decoder.DecodeLine("""{"type":"system","subtype":"task_notification","tool_use_id":"toolu_agent","status":"completed","summary":"Listo"}""");
        Check(finished is [ToolEvent { Status: "completed", Detail: "› Read /proj/a.cs\n\nListo" }],
            "Al terminar la tarea, el detalle conserva la actividad y el resumen.");
    }

    private static void CheckStartsTurn()
    {
        Check(ClaudeProtocol.StartsTurn(Obj("""{"type":"assistant","parent_tool_use_id":null}""")), "Un asistente de nivel superior inicia un turno.");
        Check(!ClaudeProtocol.StartsTurn(Obj("""{"type":"assistant","parent_tool_use_id":"toolu_x"}""")), "Un asistente de un subagente no inicia un turno.");
        Check(ClaudeProtocol.StartsTurn(Obj("""{"type":"system","subtype":"status","status":"requesting"}""")), "Un estado 'requesting' inicia un turno.");
        Check(!ClaudeProtocol.StartsTurn(Obj("""{"type":"system","subtype":"status","status":"idle"}""")), "Un estado 'idle' no inicia un turno.");
        Check(!ClaudeProtocol.StartsTurn(Obj("""{"type":"result"}""")), "Un resultado no inicia un turno.");
    }

    private static void CheckUserMessage()
    {
        var conversation = new ChatConversation("C:\\proj", ChatProvider.Claude);
        Expect(Serialize(ClaudeProtocol.UserMessage(conversation, "hola")),
            """{"type":"user","message":{"role":"user","content":"hola"},"parent_tool_use_id":null}""",
            "Un mensaje sin adjuntos envía el texto plano.");
        Check(Serialize(ClaudeProtocol.UserMessage(conversation, "hola", uuid: "u1")).EndsWith(""",\"uuid\":\"u1\"}""".Replace("\\", ""), StringComparison.Ordinal)
            || Serialize(ClaudeProtocol.UserMessage(conversation, "hola", uuid: "u1")).EndsWith("\"uuid\":\"u1\"}", StringComparison.Ordinal),
            "Un mensaje en cola lleva su uuid al final.");
    }

    private static void CheckUserMessageAttachments()
    {
        var folder = Path.Combine(Path.GetTempPath(), "jack-claude-checks-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        try
        {
            var notePath = Path.Combine(folder, "nota.txt");
            File.WriteAllText(notePath, "texto");
            var imagePath = Path.Combine(folder, "captura.png");
            var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0 };
            File.WriteAllBytes(imagePath, png);

            var conversation = new ChatConversation(folder, ChatProvider.Claude);
            var message = ClaudeProtocol.UserMessage(conversation, "mira", [notePath, imagePath]);
            var content = message["message"]?["content"] as JsonArray;
            Check(content is { Count: 2 }, "Un mensaje con texto e imagen tiene dos bloques: texto y la imagen; el .txt solo viaja como ruta.");
            Expect(ClaudeJson.Str(content![0]?["type"]), "text", "El primer bloque es de texto.");
            Check(ClaudeJson.Str(content[0]?["text"]).Contains(notePath, StringComparison.Ordinal), "El texto incluye la ruta del adjunto.");
            Expect(ClaudeJson.Str(content[1]?["type"]), "image", "El segundo bloque es una imagen.");
            Expect(ClaudeJson.Str(content[1]?["source"]?["media_type"]), "image/png", "La imagen declara su tipo de medio.");
            Expect(ClaudeJson.Str(content[1]?["source"]?["data"]), Convert.ToBase64String(png), "La imagen va en base64.");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private static void CheckControlMessages()
    {
        Expect(Serialize(ClaudeProtocol.ControlRequest(ClaudeProtocol.ControlRequestId(1), ClaudeProtocol.InterruptRequest(false))),
            """{"type":"control_request","request_id":"jack-1","request":{"subtype":"interrupt","cancel_queued":true}}""",
            "Interrumpir descartando la cola incluye cancel_queued.");
        Expect(Serialize(ClaudeProtocol.InterruptRequest(true)), """{"subtype":"interrupt"}""", "Interrumpir conservando la cola no envía cancel_queued.");
        Expect(Serialize(ClaudeProtocol.SetPermissionModeRequest("manual")), """{"subtype":"set_permission_mode","mode":"default"}""",
            "El cambio de modo traduce 'manual' a 'default'.");
        Expect(Serialize(ClaudeProtocol.SetModelRequest("sonnet")), """{"subtype":"set_model","model":"sonnet"}""", "El cambio de modelo se envía tal cual.");
        Expect(Serialize(ClaudeProtocol.CancelAsyncMessageRequest("u1")), """{"subtype":"cancel_async_message","message_uuid":"u1"}""",
            "Cancelar un mensaje en cola usa su uuid.");
        Expect(Serialize(ClaudeProtocol.ControlResponse("req_1", new JsonObject { ["behavior"] = "allow" })),
            """{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"behavior":"allow"}}}""",
            "Una respuesta de control envuelve el cuerpo con subtype success.");
    }

    // MARK: Ayudas

    private static JsonObject Obj(string json) => (JsonNode.Parse(json) as JsonObject)!;

    private static List<JsonObject> Objects(string json) => (JsonNode.Parse(json) as JsonArray)!.Select(node => (JsonObject)node!).ToList();

    private static List<JsonObject> Array(string json) => Objects(json);

    private static string Serialize(JsonNode? node) => node is null ? "null" : ClaudeProtocol.Serialize(node);

    private static void Expect(string actual, string expected, string message)
    {
        if (actual != expected) throw new InvalidOperationException($"{message} Esperado: {expected}. Obtenido: {actual}");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
