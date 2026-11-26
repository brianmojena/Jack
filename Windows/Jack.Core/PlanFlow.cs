using System.Text.Json;

namespace Jack.Core;

/// Plan de un agente en modo plan, dibujado como diagrama de flujo: inicio, un nodo por paso y fin.
/// Se construye solo desde el Markdown del plan, sin llamar a ningún modelo; así funciona con cualquier proveedor.
public sealed record PlanFlow
{
    public sealed record Step
    {
        public int Id { get; set; }
        public string Title { get; set; } = "";
        /// Subpasos y notas bajo el paso.
        public List<string> Details { get; set; } = [];
        /// La sección del plan a la que pertenece, cuando el plan tiene varias.
        public string? Phase { get; set; }
        /// Una pregunta: el flujo puede ir por dos caminos, así que el nodo se dibuja como decisión.
        public bool IsDecision { get; set; }
        /// Archivos que nombra el paso, como `code` en el Markdown.
        public List<string> Files { get; set; } = [];
    }

    public string Title { get; set; }
    public List<Step> Steps { get; set; }

    /// Un flujo necesita al menos dos pasos; una sola línea no es un diagrama de flujo.
    public const int MinimumSteps = 2;

    public PlanFlow(string title, List<Step> steps)
    {
        Title = title;
        Steps = steps;
    }

    /// El flujo de un plan, o nulo cuando el texto no tiene una secuencia de pasos.
    public static PlanFlow? Parse(string markdown)
    {
        var blocks = MarkdownBlock.Parse(markdown);
        var title = "";
        string? phase = null;
        var numbered = new List<Step>();
        var bullets = new List<Step>();
        var headings = new List<Step>();
        // Los elementos anidados pertenecen al último elemento de primer nivel, aunque el analizador haya partido la lista en dos.
        bool? lastOrdered = null;

        foreach (var block in blocks)
        {
            switch (block)
            {
                case MarkdownBlock.HeadingBlock heading:
                {
                    var clean = Plain(heading.Text);
                    if (heading.Level == 1 && title.Length == 0)
                    {
                        title = StripPrefix(clean);
                        continue;
                    }
                    if (title.Length == 0 && heading.Level == 2) title = StripPrefix(clean);
                    phase = clean;
                    if (heading.Level >= 2)
                    {
                        headings.Add(new Step { Id = 0, Title = StripPrefix(clean), Details = [], Phase = null, IsDecision = false, Files = [] });
                    }
                    break;
                }
                case MarkdownBlock.ListBlock list:
                    foreach (var item in list.Items)
                    {
                        if (item.Indent == 0)
                        {
                            if (list.Ordered) numbered.Add(CreateStep(item.Text, phase));
                            else bullets.Add(CreateStep(item.Text, phase));
                            lastOrdered = list.Ordered;
                        }
                        else if (lastOrdered == true && numbered.Count > 0)
                        {
                            numbered[^1].Details.Add(Plain(item.Text));
                        }
                        else if (lastOrdered == false && bullets.Count > 0)
                        {
                            bullets[^1].Details.Add(Plain(item.Text));
                        }
                    }
                    break;
            }
        }

        // Los pasos numerados son el orden propio del plan; las viñetas, la siguiente opción; las secciones, último recurso.
        var steps = numbered.Count >= MinimumSteps ? numbered : bullets.Count >= MinimumSteps ? bullets : headings;
        if (steps.Count < MinimumSteps) return null;
        // Las fases que nombran un único grupo de pasos no aportan nada.
        if (steps.Select(step => step.Phase).OfType<string>().Distinct().Count() < 2)
        {
            foreach (var step in steps) step.Phase = null;
        }
        for (var index = 0; index < steps.Count; index++) steps[index].Id = index;
        return new PlanFlow(title.Length == 0 ? "Plan" : title, steps.Take(40).ToList());
    }

    private static Step CreateStep(string text, string? phase)
    {
        var files = CodeSpans(text).Where(LooksLikeFile).ToList();
        var title = Plain(text);
        return new Step { Id = 0, Title = title, Details = [], Phase = phase, IsDecision = IsDecision(title), Files = files };
    }

    private static bool IsDecision(string title)
    {
        var lower = title.ToLowerInvariant();
        return lower.EndsWith("?", StringComparison.Ordinal)
            || lower.StartsWith("decidir ", StringComparison.Ordinal)
            || lower.StartsWith("decide ", StringComparison.Ordinal)
            || lower.StartsWith("comprobar si ", StringComparison.Ordinal)
            || lower.StartsWith("check whether ", StringComparison.Ordinal)
            || lower.StartsWith("decide whether ", StringComparison.Ordinal);
    }

    private static bool LooksLikeFile(string span)
    {
        if (span.Contains(' ') || span.Length >= 120) return false;
        var parts = span.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var name = parts.Length > 0 ? parts[^1] : span;
        var dot = name.LastIndexOf('.');
        if (dot <= 0) return span.Contains('/');
        var extension = name[(dot + 1)..];
        return extension.Length > 0 && extension.Length <= 6 && extension.All(character => char.IsLetter(character) || char.IsNumber(character));
    }

    private static IEnumerable<string> CodeSpans(string text)
    {
        var parts = text.Split('`');
        return parts.Where((_, index) => index % 2 == 1);
    }

    /// Quita énfasis, enlaces y marcas de código del Markdown, para las etiquetas.
    internal static string Plain(string text)
    {
        var result = text;
        // [etiqueta](url) → etiqueta
        while (true)
        {
            var open = result.IndexOf('[');
            if (open < 0) break;
            var mid = result.IndexOf("](", open + 1, StringComparison.Ordinal);
            if (mid < 0) break;
            var close = result.IndexOf(')', mid + 2);
            if (close < 0) break;
            result = result[..open] + result[(open + 1)..mid] + result[(close + 1)..];
        }
        foreach (var mark in new[] { "**", "__", "`", "*" }) result = result.Replace(mark, "", StringComparison.Ordinal);
        return result.Trim();
    }

    private static readonly string[] TitlePrefixes = ["Plan:", "Plan de implementación:", "Plan —", "Plan -"];

    /// "Plan: x" y "Paso 1: x" se leen mejor como "x".
    private static string StripPrefix(string text)
    {
        foreach (var prefix in TitlePrefixes)
        {
            if (text.StartsWith(prefix, StringComparison.Ordinal))
                return MarkdownBlock.TrimHorizontal(text[prefix.Length..]);
        }
        return text;
    }

    // MARK: Mermaid

    /// El flujo como `flowchart TD` de Mermaid, para pegar en documentación, incidencias o un archivo Markdown.
    public string Mermaid
    {
        get
        {
            static string Label(string text)
            {
                var clean = text.Replace("\"", "'");
                return clean.Length > 80 ? clean[..79] + "…" : clean;
            }

            var lines = new List<string> { "flowchart TD", $"    start([\"{Label(Title)}\"])" };
            var previous = "start";
            var arrow = "-->";
            foreach (var step in Steps)
            {
                var node = $"s{step.Id + 1}";
                lines.Add(step.IsDecision
                    ? $"    {node}{{\"{Label(step.Title)}\"}}"
                    : $"    {node}[\"{step.Id + 1}. {Label(step.Title)}\"]");
                lines.Add($"    {previous} {arrow} {node}");
                previous = node;
                arrow = step.IsDecision ? "-->|sí|" : "-->";
            }
            lines.Add("    done([\"Listo\"])");
            lines.Add($"    {previous} --> done");
            return string.Join("\n", lines);
        }
    }
}

/// Un plan que un agente ha presentado, con una identidad que se mantiene mientras el plan llega en streaming.
public sealed record PlanOffer(string Key, string Markdown);

/// Busca el plan que un agente ha presentado en una conversación.
public static class PlanSource
{
    // TODO(port): PlanSource.latest(in:mode:) necesita ChatMessage, de ChatModels.swift. Lógica a portar:
    //   recorrer los mensajes de atrás adelante hasta el último "user";
    //   si un mensaje "tool" se llama "exitplanmode" (sin mayúsculas) y su detail tiene plan, devolver
    //   PlanOffer(key: message.id, markdown: plan);
    //   si mode == "plan", unir las respuestas "assistant" no vacías posteriores al último "user" (separadas por
    //   "\n\n") y devolver PlanOffer(key: "text-" + id del turno, markdown: texto), o nulo si está vacío.

    /// `{"plan": "…"}` al inicio del detail de una herramienta. Nulo si no hay un objeto JSON con un plan no vacío.
    public static string? PlanFromDetail(string detail)
    {
        var trimmed = detail.TrimStart();
        if (trimmed.Length == 0 || trimmed[0] != '{') return null;
        var depth = 0;
        var inString = false;
        var escaped = false;
        for (var index = 0; index < trimmed.Length; index++)
        {
            var character = trimmed[index];
            if (inString)
            {
                if (escaped) escaped = false;
                else if (character == '\\') escaped = true;
                else if (character == '"') inString = false;
                continue;
            }
            if (character == '"')
            {
                inString = true;
            }
            else if (character == '{')
            {
                depth++;
            }
            else if (character == '}')
            {
                depth--;
                if (depth == 0) return PlanFromObject(trimmed[..(index + 1)]);
            }
        }
        return null;
    }

    private static string? PlanFromObject(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("plan", out var plan) || plan.ValueKind != JsonValueKind.String) return null;
            var text = plan.GetString();
            return string.IsNullOrEmpty(text) ? null : text;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

// TODO(port): la extensión ChatStore.plan(for:) viene de ChatStore.swift. Lógica a portar: primero la aprobación
//   pendiente de tipo plan (approvals[id] con isPlan y detail no vacío -> PlanOffer(approval.id, approval.detail));
//   si no, PlanSource.latest(conversation.messages, conversation.mode); y si la oferta es de texto ("text-…") y la
//   conversación está en ejecución o en cola (statuses[id]), no mostrar ningún plan.
