using Jack.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Jack.WinUI;

// Barra lateral al estilo del Mac: "Nuevo agente", búsqueda y los agentes agrupados por proyecto
// (los fijados arriba). Los elementos se construyen en código y solo se reconstruyen si cambia algo visible.
public sealed partial class SidebarView : UserControl
{
    private ChatStore? store;
    private string signature = "";
    private readonly HashSet<string> collapsed = new();
    private string query = "";

    /// <summary>El usuario pide un agente nuevo (botón o atajo).</summary>
    public event Action? NewAgentRequested;

    /// <summary>El usuario pulsó una conversación (aunque ya estuviera seleccionada).</summary>
    public event Action? ConversationChosen;

    public SidebarView()
    {
        InitializeComponent();
    }

    public void Attach(ChatStore chatStore) => store = chatStore;

    private void NewAgentButton_Click(object sender, RoutedEventArgs e) => NewAgentRequested?.Invoke();

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        query = SearchBox.Text.Trim();
        signature = "";
        Refresh();
    }

    private static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    private static Brush Clear() => new SolidColorBrush(Microsoft.UI.Colors.Transparent);

    /// <summary>Repinta la lista si cambió lo que se ve.</summary>
    public void Refresh()
    {
        if (store is null) return;
        var rows = ChatPresentation.OrderedConversations(store)
            .Where(c => query.Length == 0
                || c.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || c.ProjectPath.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .ToList();
        var minute = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMinute;
        var key = store.SelectedId + "#" + minute + "#" + string.Join(",", collapsed) + "\n" + string.Join("\n", rows.Select(c =>
            $"{c.Id}|{c.Title}|{c.ProjectPath}|{ChatPresentation.StatusOf(store, c.Id).Label}|{c.HasUnread == true}|{c.PinnedAt is not null}"));
        if (key == signature) return;
        signature = key;

        ListHost.Children.Clear();
        if (rows.Count == 0)
        {
            ListHost.Children.Add(new TextBlock
            {
                Text = query.Length > 0 ? $"Sin resultados para «{query}»" : "Aún no hay agentes",
                Style = (Style)Application.Current.Resources["JackCaption"],
                Margin = new Thickness(8, 12, 8, 0)
            });
            return;
        }

        var pinned = rows.Where(c => c.PinnedAt is not null).ToList();
        if (pinned.Count > 0) AddGroup("Fijados", "\u0001pin", pinned, "\uE840");
        foreach (var group in rows.Where(c => c.PinnedAt is null).GroupBy(c => c.ProjectPath, StringComparer.OrdinalIgnoreCase))
        {
            AddGroup(ChatPresentation.ProjectName(group.Key), group.Key, group.ToList(), "\uE8B7");
        }
    }

    private void AddGroup(string title, string key, List<ChatConversation> items, string glyph)
    {
        var open = !collapsed.Contains(key) || query.Length > 0;
        var header = new Grid { ColumnSpacing = 10, Padding = new Thickness(10, 10, 10, 6), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon { Glyph = glyph, FontSize = 13, Foreground = Res("JackMutedBrush") };
        header.Children.Add(icon);
        var name = new TextBlock
        {
            Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Res("JackMutedBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap
        };
        Grid.SetColumn(name, 1);
        header.Children.Add(name);
        header.Tapped += (_, _) =>
        {
            if (!collapsed.Remove(key)) collapsed.Add(key);
            signature = "";
            Refresh();
        };
        ListHost.Children.Add(header);
        if (!open) return;
        foreach (var conversation in items) ListHost.Children.Add(BuildRow(conversation));
    }

    private static string Age(DateTime updatedUtc)
    {
        var span = DateTime.UtcNow - updatedUtc;
        if (span.TotalMinutes < 1) return "ahora";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} min";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} h";
        if (span.TotalDays < 30) return $"{(int)span.TotalDays} d";
        return $"{(int)(span.TotalDays / 30)} m";
    }

    private FrameworkElement BuildRow(ChatConversation conversation)
    {
        var (statusLabel, statusColor) = ChatPresentation.StatusOf(store!, conversation.Id);
        var unread = conversation.HasUnread == true;
        var selected = store!.SelectedId == conversation.Id;
        var working = statusLabel == "Ocupado";

        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(10, 8, 10, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        FrameworkElement indicator;
        if (working)
        {
            indicator = new ProgressRing { Width = 16, Height = 16, IsActive = true, Foreground = Res("JackAccentBrush") };
        }
        else
        {
            var color = statusLabel == "Inactivo" ? Windows.UI.Color.FromArgb(255, 0x6B, 0x72, 0x80) : statusColor;
            indicator = new Ellipse { Width = 8, Height = 8, Fill = new SolidColorBrush(color) };
            ToolTipService.SetToolTip(indicator, statusLabel);
        }
        indicator.HorizontalAlignment = HorizontalAlignment.Center;
        indicator.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(indicator);

        var model = string.IsNullOrWhiteSpace(conversation.Model) ? conversation.Provider.Title() : ChatPresentation.ModelTitle(conversation.Model);
        var text = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(conversation.Title) ? "Nuevo agente" : conversation.Title,
            FontSize = 14, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
            FontWeight = unread ? FontWeights.SemiBold : FontWeights.Normal
        });
        var subtitle = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        subtitle.Children.Add(new TextBlock { Text = model + " · " + Age(conversation.UpdatedAt), FontSize = 12, Foreground = Res("JackMutedBrush"), TextTrimming = TextTrimming.CharacterEllipsis });
        if (unread) subtitle.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = Res("JackAccentBrush"), VerticalAlignment = VerticalAlignment.Center });
        text.Children.Add(subtitle);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var layers = new Grid { Children = { grid } };
        if (selected)
        {
            layers.Children.Add(new Border
            {
                Width = 3, Height = 24, CornerRadius = new CornerRadius(2), Background = Res("JackAccentBrush"),
                HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center
            });
        }

        var row = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = selected ? Res("JackSelectionBrush") : Clear(),
            Child = layers,
            ContextFlyout = BuildMenu(conversation)
        };
        ToolTipService.SetToolTip(row, $"{conversation.Provider.Title()} · {conversation.ProjectPath}");
        if (!selected)
        {
            row.PointerEntered += (_, _) => row.Background = Res("JackHoverBrush");
            row.PointerExited += (_, _) => row.Background = Clear();
        }
        var id = conversation.Id;
        row.Tapped += (_, _) =>
        {
            if (store!.SelectedId != id) store.Select(id);
            ConversationChosen?.Invoke();
        };
        return row;
    }

    // Menú contextual: los textos dependen del estado actual; la fila se reconstruye cuando ese estado cambia.
    private MenuFlyout BuildMenu(ChatConversation conversation)
    {
        var id = conversation.Id;
        var flyout = new MenuFlyout();
        flyout.Items.Add(Command("Renombrar", () => _ = RenameAsync(id)));
        flyout.Items.Add(Command(conversation.PinnedAt is null ? "Fijar" : "Desfijar", () => store?.SetPinned(id, !IsPinned(id))));
        flyout.Items.Add(Command(conversation.HasUnread == true ? "Marcar como leído" : "Marcar como no leído",
            () => store?.SetUnread(id, !IsUnread(id))));
        flyout.Items.Add(new MenuFlyoutSeparator());
        flyout.Items.Add(Command("Eliminar", () => _ = DeleteAsync(id)));
        return flyout;
    }

    private static MenuFlyoutItem Command(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    private bool IsPinned(Guid id) => store?.Conversations.Any(conversation => conversation.Id == id && conversation.PinnedAt is not null) == true;

    private bool IsUnread(Guid id) => store?.Conversations.Any(conversation => conversation.Id == id && conversation.HasUnread == true) == true;

    private ChatConversation? Find(Guid id) => store?.Conversations.FirstOrDefault(conversation => conversation.Id == id);

    private async Task RenameAsync(Guid id)
    {
        var conversation = Find(id);
        if (store is null || conversation is null) return;
        var box = new TextBox
        {
            Text = conversation.Title,
            MaxLength = 120,
            PlaceholderText = "Nombre del agente"
        };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Renombrar agente",
            Content = box,
            PrimaryButtonText = "Guardar",
            CloseButtonText = "Cancelar",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await ChatPresentation.ShowDialogAsync(dialog) == ContentDialogResult.Primary) store.Rename(id, box.Text);
    }

    private async Task DeleteAsync(Guid id)
    {
        var conversation = Find(id);
        if (store is null || conversation is null) return;

        // El store no elimina una conversación mientras trabaja o tiene mensajes en cola.
        if (store.IsBusy(id))
        {
            await ChatPresentation.ShowDialogAsync(new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "No se puede eliminar",
                Content = "Espera a que el agente termine o deténlo antes de eliminarlo.",
                CloseButtonText = "Cerrar"
            });
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Eliminar agente",
            Content = $"Se eliminará «{conversation.Title}» y su historial. No se puede deshacer.",
            PrimaryButtonText = "Eliminar",
            CloseButtonText = "Cancelar",
            DefaultButton = ContentDialogButton.Close
        };
        if (await ChatPresentation.ShowDialogAsync(dialog) == ContentDialogResult.Primary) store.Remove(id);
    }
}
