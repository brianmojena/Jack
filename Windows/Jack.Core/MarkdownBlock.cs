using System.Globalization;
using System.Text;

namespace Jack.Core;

/// Bloques de Markdown que dibuja el chat. Lectura tolerante: el texto puede llegar a medias mientras responde el agente.
public abstract record MarkdownBlock
{
    /// Elemento de lista. La sangría se mide en niveles de dos espacios (un tabulador cuenta como cuatro).
    public sealed record Item(string Text, int Indent);

    public enum ColumnAlignment { Left, Center, Right }

    public sealed record Table(IReadOnlyList<string> Header, IReadOnlyList<ColumnAlignment> Alignments, IReadOnlyList<IReadOnlyList<string>> Rows);

    public sealed record TableBlock(Table Value) : MarkdownBlock;
    public sealed record ParagraphBlock(string Text) : MarkdownBlock;
    public sealed record HeadingBlock(int Level, string Text) : MarkdownBlock;
    public sealed record ListBlock(IReadOnlyList<Item> Items, bool Ordered) : MarkdownBlock;
    public sealed record QuoteBlock(string Text) : MarkdownBlock;
    public sealed record CodeBlock(string Language, string Code) : MarkdownBlock;
    public sealed record RuleBlock : MarkdownBlock;

    private sealed class OpenFence(string language)
    {
        public string Language { get; } = language;
        public List<string> Lines { get; } = [];
    }

    public static IReadOnlyList<MarkdownBlock> Parse(string source)
    {
        var blocks = new List<MarkdownBlock>();
        var paragraph = new List<string>();
        var quote = new List<string>();
        var items = new List<Item>();
        var ordered = false;
        OpenFence? fence = null;

        void FlushParagraph()
        {
            if (paragraph.Count == 0) return;
            blocks.Add(new ParagraphBlock(string.Join("\n", paragraph)));
            paragraph.Clear();
        }
        void FlushQuote()
        {
            if (quote.Count == 0) return;
            blocks.Add(new QuoteBlock(string.Join("\n", quote)));
            quote.Clear();
        }
        void FlushList()
        {
            if (items.Count == 0) return;
            blocks.Add(new ListBlock(items.ToArray(), ordered));
            items.Clear();
        }
        void FlushAll()
        {
            FlushParagraph();
            FlushQuote();
            FlushList();
        }

        var lines = source.Split('\n');
        var index = 0;
        while (index < lines.Length)
        {
            var rawLine = lines[index];
            index++;
            var line = TrimHorizontal(rawLine);
            if (fence is { } open)
            {
                if (line.StartsWith("```", StringComparison.Ordinal))
                {
                    blocks.Add(new CodeBlock(open.Language, string.Join("\n", open.Lines)));
                    fence = null;
                }
                else
                {
                    open.Lines.Add(rawLine);
                }
                continue;
            }
            if (line.StartsWith("```", StringComparison.Ordinal))
            {
                FlushAll();
                fence = new OpenFence(TrimHorizontal(line[3..]));
                continue;
            }
            // Un encabezado solo se convierte en tabla cuando llega su fila de delimitadores completa.
            // Así las tablas parciales siguen legibles mientras la respuesta se escribe.
            if (index < lines.Length && TableCells(line) is { } header && TableAlignments(lines[index]) is { } alignments && header.Count == alignments.Count)
            {
                FlushAll();
                index++;
                var rows = new List<IReadOnlyList<string>>();
                while (index < lines.Length && TableCells(lines[index]) is { } cells)
                {
                    rows.Add(cells.Concat(Enumerable.Repeat("", header.Count)).Take(header.Count).ToArray());
                    index++;
                }
                blocks.Add(new TableBlock(new Table(header, alignments, rows)));
                continue;
            }
            if (line.Length == 0)
            {
                FlushAll();
                continue;
            }
            if (line is "---" or "***" or "___")
            {
                FlushAll();
                blocks.Add(new RuleBlock());
                continue;
            }
            if (HeadingLevel(line) is { } level)
            {
                FlushAll();
                blocks.Add(new HeadingBlock(level, TrimHorizontal(line.TrimStart('#'))));
                continue;
            }
            if (line.StartsWith(">", StringComparison.Ordinal))
            {
                FlushParagraph();
                FlushList();
                quote.Add(TrimHorizontal(line[1..]));
                continue;
            }
            var indent = 0;
            foreach (var character in rawLine)
            {
                if (character is not (' ' or '\t')) break;
                indent += character == '\t' ? 4 : 1;
            }
            indent /= 2;
            if (BulletText(line) is { } bullet)
            {
                FlushParagraph();
                FlushQuote();
                if (items.Count > 0 && ordered) FlushList();
                ordered = false;
                items.Add(new Item(bullet, Math.Min(indent, 3)));
                continue;
            }
            if (OrderedText(line) is { } number)
            {
                FlushParagraph();
                FlushQuote();
                if (items.Count > 0 && !ordered) FlushList();
                ordered = true;
                items.Add(new Item(number, Math.Min(indent, 3)));
                continue;
            }
            if (items.Count > 0 && indent > 0)
            {
                var last = items[^1];
                items[^1] = last with { Text = last.Text + " " + line };
                continue;
            }
            FlushQuote();
            FlushList();
            paragraph.Add(line);
        }
        if (fence is { } unclosed) blocks.Add(new CodeBlock(unclosed.Language, string.Join("\n", unclosed.Lines)));
        FlushAll();
        return blocks;
    }

    /// Las barras escapadas son contenido de celda, también dentro de código en línea (sintaxis GFM).
    private static IReadOnlyList<string>? TableCells(string source)
    {
        var line = source.Trim();
        if (line.Length == 0) return null;
        var cells = new List<string>();
        var cell = new StringBuilder();
        var escaped = false;
        var separators = 0;
        var endsWithSeparator = false;
        foreach (var character in line)
        {
            if (escaped)
            {
                if (character == '|') cell.Append(character);
                else
                {
                    cell.Append('\\');
                    cell.Append(character);
                }
                escaped = false;
                endsWithSeparator = false;
            }
            else if (character == '\\')
            {
                escaped = true;
                endsWithSeparator = false;
            }
            else if (character == '|')
            {
                cells.Add(TrimHorizontal(cell.ToString()));
                cell.Clear();
                separators++;
                endsWithSeparator = true;
            }
            else
            {
                cell.Append(character);
                endsWithSeparator = false;
            }
        }
        if (escaped) cell.Append('\\');
        if (separators == 0) return null;
        cells.Add(TrimHorizontal(cell.ToString()));
        if (line[0] == '|') cells.RemoveAt(0);
        if (endsWithSeparator) cells.RemoveAt(cells.Count - 1);
        return cells.Count == 0 ? null : cells;
    }

    private static IReadOnlyList<ColumnAlignment>? TableAlignments(string line)
    {
        if (TableCells(line) is not { } cells) return null;
        var result = new List<ColumnAlignment>();
        foreach (var cell in cells)
        {
            var marker = cell;
            var left = marker.Length > 0 && marker[0] == ':';
            var right = marker.Length > 0 && marker[^1] == ':';
            if (left) marker = marker[1..];
            if (right && marker.Length > 0) marker = marker[..^1];
            if (marker.Length == 0 || marker.Any(c => c != '-')) return null;
            result.Add(left && right ? ColumnAlignment.Center : right ? ColumnAlignment.Right : ColumnAlignment.Left);
        }
        return result;
    }

    private static int? HeadingLevel(string line)
    {
        var hashes = 0;
        while (hashes < line.Length && line[hashes] == '#') hashes++;
        if (hashes is < 1 or > 6 || line.Length <= hashes || line[hashes] != ' ') return null;
        return hashes;
    }

    private static string? BulletText(string line)
    {
        foreach (var marker in new[] { "- ", "* ", "+ " })
        {
            if (!line.StartsWith(marker, StringComparison.Ordinal)) continue;
            var text = line[2..];
            if (text.StartsWith("[ ] ", StringComparison.Ordinal)) text = "\u2610 " + text[4..];
            else if (text.StartsWith("[x] ", StringComparison.Ordinal) || text.StartsWith("[X] ", StringComparison.Ordinal)) text = "\u2611\uFE0E " + text[4..];
            return text;
        }
        return null;
    }

    private static string? OrderedText(string line)
    {
        var digits = 0;
        while (digits < line.Length && char.IsNumber(line[digits])) digits++;
        if (digits == 0 || digits >= 4) return null;
        var rest = line[digits..];
        if (!rest.StartsWith(". ", StringComparison.Ordinal) && !rest.StartsWith(") ", StringComparison.Ordinal)) return null;
        return rest[2..];
    }

    /// Recorta espacios y tabuladores (no saltos de línea), como `.whitespaces` de Foundation.
    internal static string TrimHorizontal(string value)
    {
        var start = 0;
        var end = value.Length;
        while (start < end && IsHorizontalSpace(value[start])) start++;
        while (end > start && IsHorizontalSpace(value[end - 1])) end--;
        return value[start..end];
    }

    private static bool IsHorizontalSpace(char character) =>
        character == '\t' || char.GetUnicodeCategory(character) == UnicodeCategory.SpaceSeparator;
}
