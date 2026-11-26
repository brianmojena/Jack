using System.Text.Json;

namespace Jack.Core.Checks;

/// Comprobaciones de los analizadores de texto de Jack.Core: Markdown, progreso, planes y diagramas de flujo.
/// Lanza InvalidOperationException en el primer caso que no cumple lo esperado.
public static class ParsingChecks
{
    public static void Run()
    {
        CheckMarkdown();
        CheckProgress();
        CheckPlans();
        CheckFlowDiagrams();
    }

    private static void CheckMarkdown()
    {
        var heading = MarkdownBlock.Parse("## Plan");
        Check(heading.Count == 1 && heading[0] is MarkdownBlock.HeadingBlock { Level: 2, Text: "Plan" },
            "Un encabezado de nivel 2 se lee como título.");

        var code = MarkdownBlock.Parse("```swift\nlet x = 1\n```");
        Check(code.Count == 1 && code[0] is MarkdownBlock.CodeBlock { Language: "swift", Code: "let x = 1" },
            "Un bloque de código conserva su lenguaje y su contenido.");

        var unclosed = MarkdownBlock.Parse("```\na\nb");
        Check(unclosed.Count == 1 && unclosed[0] is MarkdownBlock.CodeBlock { Code: "a\nb" },
            "Un bloque sin cerrar llega entero mientras se escribe.");

        var table = MarkdownBlock.Parse("| A | B |\n|:--|--:|\n| 1 | 2 |");
        Check(table.Count == 1 && table[0] is MarkdownBlock.TableBlock { Value: var parsed }
            && parsed.Header.SequenceEqual(new[] { "A", "B" })
            && parsed.Alignments.SequenceEqual(new[] { MarkdownBlock.ColumnAlignment.Left, MarkdownBlock.ColumnAlignment.Right })
            && parsed.Rows.Count == 1 && parsed.Rows[0].SequenceEqual(new[] { "1", "2" }),
            "Una tabla con alineación izquierda y derecha.");

        // Una sublista tras una lista numerada abre otra lista: el analizador la parte en dos.
        var nested = MarkdownBlock.Parse("1. Paso\n   - detalle");
        Check(nested.Count == 2
            && nested[0] is MarkdownBlock.ListBlock { Ordered: true } first && first.Items.Count == 1 && first.Items[0].Text == "Paso"
            && nested[1] is MarkdownBlock.ListBlock { Ordered: false } second && second.Items.Count == 1
            && second.Items[0].Text == "detalle" && second.Items[0].Indent == 1,
            "Una sublista tras una lista numerada abre otra lista con sangría 1.");

        var quoteAndRule = MarkdownBlock.Parse("> a\n> b\n---");
        Check(quoteAndRule.Count == 2
            && quoteAndRule[0] is MarkdownBlock.QuoteBlock { Text: "a\nb" }
            && quoteAndRule[1] is MarkdownBlock.RuleBlock,
            "Las citas consecutivas forman un bloque y --- es una regla.");

        var checkboxes = MarkdownBlock.Parse("- [x] hecho\n- [ ] pendiente");
        Check(checkboxes.Count == 1 && checkboxes[0] is MarkdownBlock.ListBlock { Items.Count: 2 } tasks
            && tasks.Items[0].Text == "\u2611\uFE0E hecho" && tasks.Items[1].Text == "\u2610 pendiente",
            "Las casillas de tarea se convierten en símbolos.");

        var paragraphs = MarkdownBlock.Parse("uno\ndos\n\ntres");
        Check(paragraphs.Count == 2
            && paragraphs[0] is MarkdownBlock.ParagraphBlock { Text: "uno\ndos" }
            && paragraphs[1] is MarkdownBlock.ParagraphBlock { Text: "tres" },
            "Las líneas seguidas forman un párrafo y una línea vacía lo separa.");
    }

    private static void CheckProgress()
    {
        var plain = ProgressParser.Parse("45% listo");
        Check(plain is not null && Near(plain.Fraction, 0.45), "Un porcentaje suelto da la fracción.");
        Check(ProgressParser.Parse("pulling 8eeb52dfb3bb  45%") is { Phase: "pulling 8eeb52dfb3bb" } phased && Near(phased.Fraction, 0.45),
            "El texto antes del porcentaje nombra la fase.");
        Check(ProgressParser.Parse("texto sin progreso") is null, "Una línea sin progreso no produce lectura.");
        Check(ProgressParser.Parse("") is null, "Una línea vacía no produce lectura.");

        var curl = ProgressParser.Parse("  45  100M   45 45.2M    0     0  10.1M      0  0:00:09  0:00:04  0:00:05 10.3M");
        Check(curl is not null && Near(curl.Fraction, 0.45) && curl.Unit == "bytes" && Near(curl.Total, 104_857_600)
            && curl.Eta == TimeSpan.FromSeconds(5) && Near(curl.Completed, 45.2 * 1_048_576) && Near(curl.Speed, 10.3 * 1_048_576),
            "curl: tamaño total, progreso, velocidad y tiempo restante.");

        var aria2 = ProgressParser.Parse("[#2089b0 1.2MiB/10MiB(12%) CN:1 DL:3.1MiB ETA:3s]");
        Check(aria2 is not null && Near(aria2.Completed, 1.2 * 1_048_576) && Near(aria2.Fraction, 0.12) && aria2.Eta == TimeSpan.FromSeconds(3),
            "aria2: bytes hechos, porcentaje y ETA.");

        var git = ProgressParser.Parse("Receiving objects:  45% (450/1000), 1.20 MiB | 2.30 MiB/s");
        Check(git is not null && git.Phase == "Receiving objects 450/1000" && Near(git.Fraction, 0.45) && Near(git.Speed, 2.30 * 1_048_576),
            "git: fase con recuento, fracción y velocidad.");

        // pip: los dos tamaños comparten unidad.
        var pip = ProgressParser.Parse("Downloading model 2.1/4.7 GB");
        Check(pip is not null && Near(pip.Completed, 2.1e9) && Near(pip.Total, 4.7e9) && pip.Unit == "bytes",
            "pip: tamaños con unidad compartida en decimal.");

        Check(Near(ProgressParser.Bytes("2,1 GB"), 2.1e9), "Bytes: la coma decimal cuenta como punto y GB es decimal.");
        Check(Near(ProgressParser.Bytes("100M"), 104_857_600), "Bytes: M sin i ni B es binario.");
        Check(Near(ProgressParser.Bytes("1.2MiB"), 1.2 * 1_048_576), "Bytes: MiB es binario.");
        Check(ProgressParser.Bytes("12 parsecs") is null, "Bytes: una unidad desconocida no produce valor.");
        Check(ProgressParser.Duration("1m2s") == TimeSpan.FromSeconds(62), "Duración: 1m2s son 62 segundos.");
        Check(ProgressParser.Duration("1h 2m") == TimeSpan.FromSeconds(3720), "Duración: 1h 2m son 3720 segundos.");
        Check(ProgressParser.Duration("0:00:05") == TimeSpan.FromSeconds(5), "Duración: formato de reloj.");
        Check(ProgressParser.Duration("--:--:--") is null, "Duración: un valor desconocido es nulo.");
        Check(ProgressParser.Number("1,234,567") == 1_234_567, "Número: la coma con grupos de tres es separador de miles.");
        Check(ProgressParser.Number("1,5") == 1.5, "Número: una coma sola es decimal.");

        // Un archivo de tarea escrito a mano: tipos mal escritos se ignoran sin fallar.
        var conversation = Guid.Parse("11111111-2222-3333-4444-555555555555");
        using (var document = JsonDocument.Parse("""{"title":"Descargando modelo","status":"paused","percent":40,"completed":2,"total":5,"unit":"bytes","fields":{"Velocidad":"12"}}"""))
        {
            var task = new ProgressTask(document.RootElement, "descarga-1", conversation, DateTimeOffset.UnixEpoch.AddHours(1));
            Check(task.Title == "Descargando modelo" && task.Status == ProgressStatus.Paused, "Tarea: título y estado desde JSON.");
            Check(task.Progress is { } progress && Near(progress, 0.4), "Tarea: el porcentaje se convierte en fracción.");
            Check(task.Fields.Count == 1 && task.Fields[0] == new ProgressField("Velocidad", "12"), "Tarea: los campos se leen como pares.");
            Check(task.IsBytes && task.IsActive && task.Id == "11111111-2222-3333-4444-555555555555/descarga-1",
                "Tarea: unidad bytes, pausada sigue activa, y el id es conversación y tarea en mayúsculas.");
        }
        using (var document = JsonDocument.Parse("""{"status":"nope","total":"abc","pid":true,"controllable":"sí"}"""))
        {
            var lenient = new ProgressTask(document.RootElement, "tolerante", conversation, DateTimeOffset.UnixEpoch);
            Check(lenient.Status == ProgressStatus.Running && lenient.Total is null && lenient.Pid is null && !lenient.Controllable,
                "Tarea: valores de tipo incorrecto se ignoran.");
        }

        Check(ProgressFiles.SanitizedID("Mi Modelo: v1.2/ñ") == "mi-modelo-v1.2", "Identificadores: caracteres no admitidos se convierten en guiones.");
        Check(ProgressFiles.SanitizedID("") == "task", "Identificadores: vacío da `task`.");

        Check(ProgressFormat.Duration(TimeSpan.FromSeconds(3725)) == "1 h 2 min", "Formato: 3725 s son 1 h 2 min.");
        Check(ProgressFormat.Duration(TimeSpan.FromSeconds(192)) == "3 min 12 s", "Formato: 192 s son 3 min 12 s.");
        Check(ProgressFormat.Duration(TimeSpan.FromSeconds(45)) == "45 s", "Formato: 45 s.");
        Check(ProgressFormat.Duration(TimeSpan.FromHours(1)) == "1 h", "Formato: una hora exacta.");
    }

    private static void CheckPlans()
    {
        const string plan = "# Plan: Migrar datos\n\n1. Leer `src/Datos.cs`\n2. ¿Usar caché?\n3. Escribir `out.json`";
        var flow = PlanFlow.Parse(plan);
        Check(flow is not null && flow.Title == "Migrar datos" && flow.Steps.Count == 3, "Plan: título sin prefijo y tres pasos.");
        Check(flow is not null && flow.Steps[0].Title == "Leer src/Datos.cs" && flow.Steps[0].Files.SequenceEqual(new[] { "src/Datos.cs" }),
            "Plan: el código entre comillas invertidas es archivo del paso.");
        Check(flow is not null && flow.Steps[1].IsDecision && !flow.Steps[0].IsDecision, "Plan: una pregunta es decisión.");
        Check(flow is not null && flow.Steps[2].Files.SequenceEqual(new[] { "out.json" }), "Plan: out.json es archivo.");

        var mermaid = flow!.Mermaid.Split('\n');
        Check(mermaid[0] == "flowchart TD", "Mermaid: cabecera.");
        Check(mermaid.Contains("    start([\"Migrar datos\"])"), "Mermaid: nodo de inicio.");
        Check(mermaid.Contains("    s2{\"¿Usar caché?\"}"), "Mermaid: la decisión es un rombo.");
        Check(mermaid.Contains("    s2 -->|sí| s3"), "Mermaid: la salida de una decisión lleva etiqueta.");
        Check(mermaid[^1] == "    s3 --> done", "Mermaid: el último paso va a Listo.");

        var phases = PlanFlow.Parse("## Fase A\n1. a\n2. b\n## Fase B\n1. c\n2. d");
        Check(phases is not null && phases.Steps.Count == 4 && phases.Steps[2].Phase == "Fase B",
            "Plan: dos secciones conservan la fase de cada paso.");

        Check(PlanFlow.Parse("1. Solo uno") is null, "Plan: un único paso no es un diagrama.");

        Check(PlanSource.PlanFromDetail("{\"plan\": \"# Plan\\n1. a\"}") == "# Plan\n1. a",
            "Detalle de herramienta: el plan se extrae del JSON.");
        Check(PlanSource.PlanFromDetail("{\"plan\":\"a } b\"}") == "a } b", "Detalle de herramienta: las llaves dentro de cadenas no cierran el objeto.");
        Check(PlanSource.PlanFromDetail("  texto") is null, "Detalle de herramienta: texto sin JSON no tiene plan.");
        Check(PlanSource.PlanFromDetail("{\"x\":1}") is null, "Detalle de herramienta: un objeto sin plan no tiene plan.");
    }

    private static void CheckFlowDiagrams()
    {
        const string valid = """
{"title":"Flujo","nodes":[{"id":"start","label":"Inicio","kind":"start"},{"id":"check","label":"¿Válido?","kind":"decision"},{"id":"fix","label":"Corregir","kind":"process"},{"id":"done","label":"Fin","kind":"end"}],"edges":[{"from":"start","to":"check"},{"from":"check","to":"fix","label":"no"},{"from":"check","to":"done","label":"sí"},{"from":"fix","to":"check"}]}
""";

        var diagram = FlowDiagram.Parse(valid);
        Check(diagram.Title == "Flujo" && diagram.Nodes.Count == 4 && diagram.Edges.Count == 4, "Diagrama: título, nodos y aristas.");

        var fenced = FlowDiagram.Parse("```json\n" + valid + "\n```");
        Check(fenced.Title == "Flujo" && fenced.Nodes.Count == 4, "Diagrama: acepta el JSON dentro de una valla de código.");

        var layers = diagram.Layers;
        Check(layers.Count == 3 && layers[2].Select(node => node.Id).SequenceEqual(new[] { "fix", "done" }),
            "Diagrama: las capas siguen la distancia desde el inicio.");

        var mermaid = diagram.Mermaid.Split('\n');
        Check(mermaid.Contains("%% Flujo") && mermaid.Contains("    n0([\"Inicio\"])") && mermaid.Contains("    n1{\"¿Válido?\"}"),
            "Mermaid del diagrama: nodos con su forma.");
        Check(mermaid.Contains("    n1 -->|\"no\"| n2") && mermaid.Contains("    n1 -->|\"sí\"| n3") && mermaid.Contains("    n2 --> n1"),
            "Mermaid del diagrama: aristas con etiqueta y bucles.");

        var layout = new FlowDiagramLayout(diagram);
        Check(layout.ReturnRoutes.ContainsKey("fix>check:") && layout.Frames.Count == 4 && layout.Size.Width > 0,
            "Disposición: la arista que vuelve tiene carril de retorno.");

        Rejects(() => FlowDiagram.Parse("no es JSON"), FlowDiagramError.InvalidJSON, "Diagrama: texto que no es JSON.");
        Rejects(() => FlowDiagram.Parse(valid.Replace("\"sí\"", "\"no\"")), FlowDiagramError.InvalidGraph,
            "Diagrama: dos ramas de decisión con la misma etiqueta.");
        Rejects(() => FlowDiagram.Parse(valid.Replace(
                "{\"id\":\"done\",\"label\":\"Fin\",\"kind\":\"end\"}",
                "{\"id\":\"done\",\"label\":\"Fin\",\"kind\":\"end\"},{\"id\":\"suelto\",\"label\":\"Suelto\",\"kind\":\"process\"}")),
            FlowDiagramError.InvalidGraph, "Diagrama: un nodo sin camino desde el inicio.");
        Rejects(() => FlowDiagram.Parse(new string('a', 24_001)), FlowDiagramError.OutputTooLarge, "Diagrama: respuesta por encima del límite.");

        var context = FlowDiagramContext.RecentVisible(new[]
        {
            new FlowDiagramContextMessage("user", "uno"),
            new FlowDiagramContextMessage("assistant", ""),
            new FlowDiagramContextMessage("system", "x"),
            new FlowDiagramContextMessage("user", "dos"),
        });
        Check(context.Select(message => message.Content).SequenceEqual(new[] { "uno", "dos" }),
            "Contexto: solo mensajes de usuario y asistente con texto, en orden.");

        var many = Enumerable.Range(1, 10).Select(index => new FlowDiagramContextMessage("user", "m" + index)).ToList();
        var recent = FlowDiagramContext.RecentVisible(many);
        Check(recent.Count == 8 && recent[0].Content == "m3" && recent[^1].Content == "m10", "Contexto: como máximo ocho mensajes, los más recientes.");
        Check(FlowDiagramContext.PrefixUtf8("ñandú", 3) == "ña", "Contexto: el corte no parte caracteres UTF-8.");
    }

    private static bool Near(double? actual, double expected)
    {
        if (actual is not { } value) return false;
        return Math.Abs(value - expected) <= Math.Max(1e-9, Math.Abs(expected) * 1e-9);
    }

    private static void Rejects(Action action, FlowDiagramError expected, string message)
    {
        try
        {
            action();
        }
        catch (Exception error) when (error is FlowDiagramException { Error: var actual } && actual == expected)
        {
            return;
        }
        throw new InvalidOperationException(message + " Se esperaba " + expected + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
