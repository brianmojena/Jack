using System.Text.RegularExpressions;
using Jack.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Jack.WinUI;

// Piezas visuales que XAML no da hechas: texto con fragmentos en monoespaciado y los colores que la barra lateral
// (construida en código) necesita según el tema.
public static class Look
{
    public static Color Hex(uint rgb, byte alpha = 255) => Color.FromArgb(alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    /// <summary>Fondo de la fila seleccionada: blanco 8 % en oscuro, negro 8 % en claro.</summary>
    public static Brush Selected(ElementTheme theme) =>
        new SolidColorBrush(theme == ElementTheme.Light ? Hex(0x000000, 0x14) : Hex(0xFFFFFF, 0x14));

    private static readonly FontFamily Mono = new("Cascadia Code, Consolas");
    private static readonly Regex Markup = new(@"(\*\*.+?\*\*|`.+?`)", RegexOptions.Compiled | RegexOptions.Singleline);

    public static readonly DependencyProperty RichProperty =
        DependencyProperty.RegisterAttached("Rich", typeof(string), typeof(Look), new PropertyMetadata(null, OnRichChanged));

    public static string? GetRich(DependencyObject element) => (string?)element.GetValue(RichProperty);
    public static void SetRich(DependencyObject element, string? value) => element.SetValue(RichProperty, value);

    // `código` se muestra en Cascadia Code 12 atenuado y **negrita** en seminegrita.
    private static void OnRichChanged(DependencyObject element, DependencyPropertyChangedEventArgs e)
    {
        if (element is not TextBlock block) return;
        block.Inlines.Clear();
        var text = e.NewValue as string ?? "";
        var muted = new SolidColorBrush(block.ActualTheme == ElementTheme.Light ? Hex(0x5A6170) : Hex(0xA3A9B5));
        foreach (var part in Markup.Split(text))
        {
            if (part.Length == 0) continue;
            if (part.Length > 4 && part.StartsWith("**") && part.EndsWith("**"))
                block.Inlines.Add(new Run { Text = part[2..^2], FontWeight = FontWeights.SemiBold });
            else if (part.Length > 2 && part[0] == '`' && part[^1] == '`')
                block.Inlines.Add(new Run { Text = part[1..^1], FontFamily = Mono, FontSize = 12, Foreground = muted });
            else
                block.Inlines.Add(new Run { Text = part });
        }
    }
}

// Spinner de la maqueta: anillo tenue y arco de acento de 16 px que gira a 1 s lineal. Solo anima mientras es visible.
public sealed partial class Spinner : Grid
{
    private readonly Microsoft.UI.Xaml.Media.RotateTransform rotation = new() { CenterX = 8, CenterY = 8 };
    private readonly Microsoft.UI.Xaml.Media.Animation.Storyboard spin = new();

    public Spinner()
    {
        Width = Height = 16;
        VerticalAlignment = VerticalAlignment.Center;
        HorizontalAlignment = HorizontalAlignment.Center;
        var accent = (Brush)Application.Current.Resources["JackAccentBrush"];
        Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 11, Height = 11, Stroke = accent, StrokeThickness = 1.6, Opacity = 0.25
        });
        Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Stroke = accent,
            StrokeThickness = 1.6,
            StrokeStartLineCap = Microsoft.UI.Xaml.Media.PenLineCap.Round,
            StrokeEndLineCap = Microsoft.UI.Xaml.Media.PenLineCap.Round,
            Data = (Microsoft.UI.Xaml.Media.Geometry)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(
                typeof(Microsoft.UI.Xaml.Media.Geometry), "M8,2.5 A5.5,5.5 0 0 1 13.5,8"),
            RenderTransform = rotation
        });
        var turn = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation
        {
            From = 0, To = 360, Duration = TimeSpan.FromSeconds(1), RepeatBehavior = Microsoft.UI.Xaml.Media.Animation.RepeatBehavior.Forever
        };
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(turn, rotation);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(turn, "Angle");
        spin.Children.Add(turn);
        Loaded += (_, _) => Sync();
        Unloaded += (_, _) => spin.Stop();
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => Sync());
    }

    private void Sync()
    {
        if (Visibility == Visibility.Visible) spin.Begin();
        else spin.Stop();
    }
}

public enum TurnKind { User, Agent, Tools }

// Una fila de la tarjeta de herramientas: archivo y acción; en curso muestra el spinner y «Trabajando…».
public sealed record FileRow(string Name, string Action, bool Running = false)
{
    public Visibility ShowRunning => Running ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ShowDone => Running ? Visibility.Collapsed : Visibility.Visible;
    public string ActionText => Running ? "Trabajando…" : Action;
    public double TintOpacity => Running ? 1 : 0;
}

// Tarjeta plegable: «Explorar», su resumen, una nota y los archivos editados.
public sealed record ToolGroup(string Title, string Summary, string Note, string FilesLabel, IReadOnlyList<FileRow> Files)
{
    public Visibility ShowNote => Note.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ShowFiles => Files.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public bool Running => Files.Any(file => file.Running);
}

// Mensaje de la conversación. Solo la vista de demostración de CI los crea: todavía no hay conexión con las CLI.
public sealed record Turn(TurnKind Kind, string Text, ToolGroup? Group = null);

public sealed partial class TurnSelector : DataTemplateSelector
{
    public DataTemplate? User { get; set; }
    public DataTemplate? Agent { get; set; }
    public DataTemplate? Tools { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => (item as Turn)?.Kind switch
    {
        TurnKind.User => User,
        TurnKind.Agent => Agent,
        TurnKind.Tools => Tools,
        _ => null
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
