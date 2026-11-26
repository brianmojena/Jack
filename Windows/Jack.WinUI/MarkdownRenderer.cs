using System.Text.RegularExpressions;
using Jack.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace Jack.WinUI;

// Convierte los bloques de MarkdownBlock.Parse en elementos de interfaz: títulos, párrafos, listas, citas,
// bloques de código (monoespaciado y con fondo), tablas y reglas. El texto es seleccionable.
internal static class MarkdownRenderer
{
    // Negrita y código en línea. Lo demás se muestra tal cual.
    private static readonly Regex InlineToken = new(@"(\*\*[^*\n]+\*\*|`[^`\n]+`)", RegexOptions.Compiled);

    public static FrameworkElement Build(MarkdownBlock block) => block switch
    {
        MarkdownBlock.HeadingBlock heading => Heading(heading),
        MarkdownBlock.ParagraphBlock paragraph => InlineText(paragraph.Text, 14),
        MarkdownBlock.ListBlock list => ListOf(list),
        MarkdownBlock.QuoteBlock quote => Quote(quote),
        MarkdownBlock.CodeBlock code => Code(code),
        MarkdownBlock.TableBlock table => Table(table.Value),
        _ => Rule()
    };

    private static FrameworkElement Heading(MarkdownBlock.HeadingBlock heading)
    {
        var size = heading.Level switch { 1 => 22d, 2 => 18d, 3 => 16d, _ => 15d };
        var block = InlineText(heading.Text, size);
        block.FontWeight = FontWeights.SemiBold;
        block.Margin = new Thickness(0, 6, 0, 0);
        return block;
    }

    private static FrameworkElement ListOf(MarkdownBlock.ListBlock list)
    {
        var panel = new StackPanel { Spacing = 4 };
        for (var index = 0; index < list.Items.Count; index++)
        {
            var item = list.Items[index];
            var row = new Grid
            {
                ColumnSpacing = 8,
                Margin = new Thickness(item.Indent * 16, 0, 0, 0)
            };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var marker = new TextBlock
            {
                Text = list.Ordered ? $"{index + 1}." : "•",
                FontSize = 14,
                MinWidth = 18
            };
            var body = InlineText(item.Text, 14);
            Grid.SetColumn(marker, 0);
            Grid.SetColumn(body, 1);
            row.Children.Add(marker);
            row.Children.Add(body);
            panel.Children.Add(row);
        }
        return panel;
    }

    private static FrameworkElement Quote(MarkdownBlock.QuoteBlock quote) =>
        new Border
        {
            Style = (Style)Application.Current.Resources["JackQuote"],
            Child = InlineText(quote.Text, 14)
        };

    private static FrameworkElement Code(MarkdownBlock.CodeBlock code)
    {
        var stack = new StackPanel { Spacing = 6 };
        if (!string.IsNullOrWhiteSpace(code.Language))
        {
            stack.Children.Add(new TextBlock
            {
                Text = code.Language.Trim(),
                Style = (Style)Application.Current.Resources["JackCaption"]
            });
        }
        var text = new TextBlock
        {
            Text = code.Code.TrimEnd('\r', '\n'),
            Style = (Style)Application.Current.Resources["JackMono"],
            IsTextSelectionEnabled = true
        };
        stack.Children.Add(new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = text
        });
        return new Border
        {
            Style = (Style)Application.Current.Resources["JackCodeBlock"],
            Child = stack
        };
    }

    // Tabla en cuadrícula. Es lo único (junto con el código) que puede ser más ancho que la columna: va en un ScrollViewer.
    private static FrameworkElement Table(MarkdownBlock.Table table)
    {
        var columns = table.Rows.Select(row => row.Count).Append(table.Header.Count).Max();
        var grid = new Grid();
        for (var column = 0; column < columns; column++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }

        var rows = new List<IReadOnlyList<string>> { table.Header };
        rows.AddRange(table.Rows);
        for (var row = 0; row < rows.Count; row++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var column = 0; column < columns; column++)
            {
                var value = column < rows[row].Count ? rows[row][column] : "";
                var cell = InlineText(value, 13);
                cell.TextAlignment = column < table.Alignments.Count ? Align(table.Alignments[column]) : TextAlignment.Left;
                if (row == 0) cell.FontWeight = FontWeights.SemiBold;

                var border = new Border { Style = (Style)Application.Current.Resources["JackCell"], Child = cell };
                Grid.SetRow(border, row);
                Grid.SetColumn(border, column);
                grid.Children.Add(border);
            }
        }

        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = grid
        };
    }

    private static TextAlignment Align(MarkdownBlock.ColumnAlignment alignment) => alignment switch
    {
        MarkdownBlock.ColumnAlignment.Center => TextAlignment.Center,
        MarkdownBlock.ColumnAlignment.Right => TextAlignment.Right,
        _ => TextAlignment.Left
    };

    private static FrameworkElement Rule() => new Border { Style = (Style)Application.Current.Resources["JackRule"] };

    // Texto con negrita y código en línea. Se usa también para títulos, celdas y elementos de lista.
    internal static TextBlock InlineText(string text, double fontSize)
    {
        var block = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontSize = fontSize
        };
        var last = 0;
        foreach (Match match in InlineToken.Matches(text))
        {
            if (match.Index > last) block.Inlines.Add(new Run { Text = text[last..match.Index] });
            var token = match.Value;
            if (token.StartsWith("**", StringComparison.Ordinal))
            {
                block.Inlines.Add(new Run { Text = token[2..^2], FontWeight = FontWeights.SemiBold });
            }
            else
            {
                block.Inlines.Add(new Run { Text = token[1..^1], FontFamily = new FontFamily("Cascadia Mono") });
            }
            last = match.Index + match.Length;
        }
        if (last < text.Length) block.Inlines.Add(new Run { Text = text[last..] });
        return block;
    }
}
