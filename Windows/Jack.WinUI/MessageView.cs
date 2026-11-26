using Jack.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Jack.WinUI;

// Dibuja un mensaje de la transcripción según su papel (Role): "user" en burbuja a la derecha, "assistant" a ancho
// completo con Markdown, "tool" como fila plegable, "jack" como aviso discreto y "error" en rojo.
public static class MessageView
{
    private static readonly Windows.UI.Color ErrorColor = Windows.UI.Color.FromArgb(255, 0xC4, 0x2B, 0x1C);

    public static FrameworkElement Build(ChatMessage message) => message.Role switch
    {
        "user" => User(message),
        "assistant" => Assistant(message),
        "tool" => ToolGroup(new[] { message }),
        "error" => Failure(message.Text),
        _ => Notice(message.Text)
    };

    private static FrameworkElement User(ChatMessage message)
    {
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(new TextBlock
        {
            Text = message.Text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true
        });
        if (message.Attachments is { Count: > 0 } files)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "Adjuntos: " + string.Join(", ", files.Select(path => Path.GetFileName(path))),
                Style = (Style)Application.Current.Resources["JackCaption"]
            });
        }
        return new Border
        {
            Style = (Style)Application.Current.Resources["JackBubble"],
            HorizontalAlignment = HorizontalAlignment.Right,
            MaxWidth = 640,
            Child = stack
        };
    }

    private static FrameworkElement Assistant(ChatMessage message)
    {
        var stack = new StackPanel { Spacing = 10 };
        foreach (var block in MarkdownBlock.Parse(message.Text))
        {
            stack.Children.Add(MarkdownRenderer.Build(block));
        }
        return stack;
    }

    private static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    /// <summary>
    /// Tarjeta plegable con las herramientas consecutivas de un turno: cabecera (check, resumen, chevron) y una fila
    /// por herramienta; cada fila con detalle se despliega al pulsarla.
    /// </summary>
    public static FrameworkElement ToolGroup(IReadOnlyList<ChatMessage> tools)
    {
        var running = tools.Any(t => t.Status == "running");
        var open = running || tools.Count <= 6;

        var chevron = new FontIcon { Glyph = open ? "\uE70E" : "\uE70D", FontSize = 10, Foreground = Res("JackMutedBrush"), VerticalAlignment = VerticalAlignment.Center };
        var header = new Grid { ColumnSpacing = 10, Padding = new Thickness(10, 8, 10, 8), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(StateIcon(running));
        var title = new TextBlock { Text = "Herramientas", FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(title, 1);
        header.Children.Add(title);
        var summary = new TextBlock
        {
            Text = tools.Count == 1 ? "1 acción" : tools.Count + " acciones",
            FontSize = 13, Foreground = Res("JackMutedBrush"), VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(summary, 2);
        header.Children.Add(summary);
        Grid.SetColumn(chevron, 3);
        header.Children.Add(chevron);

        var body = new StackPanel { Spacing = 0, Visibility = open ? Visibility.Visible : Visibility.Collapsed };
        foreach (var tool in tools) body.Children.Add(ToolRow(tool));

        header.Tapped += (_, _) =>
        {
            var show = body.Visibility != Visibility.Visible;
            body.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            chevron.Glyph = show ? "\uE70E" : "\uE70D";
        };

        return new Border
        {
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(6),
            Background = Res("JackCardBrush"),
            BorderBrush = Res("JackHairlineBrush"),
            Child = new StackPanel { Children = { header, body } }
        };
    }

    private static FrameworkElement StateIcon(bool running) => running
        ? new ProgressRing { Width = 16, Height = 16, IsActive = true, Foreground = Res("JackAccentBrush"), HorizontalAlignment = HorizontalAlignment.Center }
        : new FontIcon { Glyph = "\uE73E", FontSize = 13, Foreground = Res("JackSuccessBrush"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    private static FrameworkElement ToolRow(ChatMessage tool)
    {
        var running = tool.Status == "running";
        var hasDetail = !string.IsNullOrWhiteSpace(tool.Detail);
        var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(10, 0, 10, 0), MinHeight = 36, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = StateIcon(running);
        icon.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(icon);
        var name = new TextBlock
        {
            Text = tool.Text, FontFamily = (FontFamily)Application.Current.Resources["JackMonoFont"], FontSize = 12.5,
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(name, 1);
        row.Children.Add(name);
        var tail = new TextBlock
        {
            Text = running ? "Trabajando…" : (hasDetail ? "Ver" : ""), FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
            Foreground = running ? Res("JackAccentBrush") : Res("JackMutedBrush")
        };
        Grid.SetColumn(tail, 2);
        row.Children.Add(tail);

        var holder = new Border { CornerRadius = new CornerRadius(8), Background = running ? Res("JackHoverBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent), Child = row };
        if (!hasDetail) return holder;

        var detail = new Border
        {
            Style = (Style)Application.Current.Resources["JackCodeBlock"],
            Margin = new Thickness(28, 0, 8, 6),
            Visibility = Visibility.Collapsed,
            Child = new ScrollViewer
            {
                MaxHeight = 280,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = new TextBlock
                {
                    Text = tool.Detail,
                    Style = (Style)Application.Current.Resources["JackMono"],
                    FontSize = 12,
                    IsTextSelectionEnabled = true
                }
            }
        };
        row.Tapped += (_, _) => detail.Visibility = detail.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        row.PointerEntered += (_, _) => { if (!running) holder.Background = Res("JackHoverBrush"); };
        row.PointerExited += (_, _) => { if (!running) holder.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); };
        return new StackPanel { Children = { holder, detail } };
    }

    private static FrameworkElement Failure(string text) =>
        new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = new SolidColorBrush(ErrorColor)
        };

    private static FrameworkElement Notice(string text) =>
        new TextBlock
        {
            Text = text,
            Style = (Style)Application.Current.Resources["JackCaption"],
            TextAlignment = TextAlignment.Center,
            Margin = new Thickness(0, 4, 0, 4)
        };
}
