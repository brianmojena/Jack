using System.Collections.Specialized;
using Jack.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage.Pickers;

namespace Jack.WinUI;

public sealed partial class MainWindow : Window
{
    private const string DefaultModel = "Predeterminado";

    // Modelo, esfuerzo y permisos que se muestran en el compositor. Todavía no llegan a ninguna CLI: viven en la ventana.
    private sealed class AgentOptions
    {
        public string Model = DefaultModel;
        public string Effort = "Alto";
        public string Mode = "Auto";
    }

    private sealed record SidebarRow(Button Row, Microsoft.UI.Xaml.Shapes.Rectangle Indicator);

    private readonly ChatWorkspace workspace = new();
    private readonly Dictionary<Guid, IReadOnlyList<Turn>> demoTurns = [];
    private readonly Dictionary<Guid, DateTime> created = [];
    private readonly Dictionary<Guid, AgentOptions> options = [];
    private readonly Dictionary<Guid, SidebarRow> rows = [];
    private readonly Dictionary<Guid, TextBlock> subtitles = [];
    private Guid? selectedId;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
        Root.ActualThemeChanged += (_, _) =>
        {
            ApplyCaptionColors();
            RebuildSidebar();
        };
        ((INotifyCollectionChanged)workspace.Conversations).CollectionChanged += OnConversationsChanged;
        var clock = DispatcherQueue.CreateTimer();
        clock.Interval = TimeSpan.FromSeconds(30);
        clock.Tick += (_, _) => UpdateSubtitles();
        clock.Start();
        FitToScreen();
        ApplyCaptionColors();
        ShowConversation(null);
        ApplyCaptureMode();
    }

    // Botones de ventana transparentes con hover blanco 8 % (negro en claro).
    private void ApplyCaptionColors()
    {
        var light = Root.ActualTheme == ElementTheme.Light;
        var text = light ? Look.Hex(0x1B1E25) : Look.Hex(0xE9EBF0);
        var hover = light ? Look.Hex(0x000000, 0x14) : Look.Hex(0xFFFFFF, 0x14);
        var title = AppWindow.TitleBar;
        title.ButtonBackgroundColor = title.ButtonInactiveBackgroundColor = Colors.Transparent;
        title.ButtonForegroundColor = text;
        title.ButtonHoverBackgroundColor = hover;
        title.ButtonHoverForegroundColor = text;
        title.ButtonPressedBackgroundColor = light ? Look.Hex(0x000000, 0x1F) : Look.Hex(0xFFFFFF, 0x1F);
        title.ButtonPressedForegroundColor = text;
        title.ButtonInactiveForegroundColor = light ? Look.Hex(0x5A6170) : Look.Hex(0xA3A9B5);
    }

    // El tamaño por defecto no debe superar el área útil (p. ej. una pantalla de 800x600).
    private void FitToScreen()
    {
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(1100, work.Width);
        var height = Math.Min(740, work.Height);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height));
    }

    // Solo para CI: JACK_CAPTURE=empty|demo|reference y JACK_THEME=light|dark preparan la ventana para la captura de pantalla.
    // "demo" y "reference" rellenan conversaciones y mensajes de ejemplo; la app real no los crea.
    // "reference" reproduce la maqueta del plan (plan jack windows/referencia) a 1280×860.
    private void ApplyCaptureMode()
    {
        var mode = Environment.GetEnvironmentVariable("JACK_CAPTURE");
        if (mode is not ("empty" or "demo" or "reference")) return;
        // MoveAndResize usa píxeles físicos: se escala por el DPI para que el tamaño lógico sea el de la maqueta.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var (width, height) = mode == "reference" ? (1280, 860) : (1000, 700);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(0, 0, (int)(width * scale), (int)(height * scale)));
        Root.RequestedTheme = Environment.GetEnvironmentVariable("JACK_THEME") == "light" ? ElementTheme.Light : ElementTheme.Dark;
        if (mode == "empty") return;
        var demo = Path.Combine(Path.GetTempPath(), "jack-demo");
        ChatConversation Add(string title, string folder, ChatProvider provider, TimeSpan age)
        {
            var conversation = workspace.CreateConversation(title, Directory.CreateDirectory(Path.Combine(demo, folder)).FullName, provider);
            created[conversation.Id] = DateTime.Now - age;
            return conversation;
        }
        if (mode == "reference")
        {
            var ok = Add("Responde solo con la palabra OK", "Jack", ChatProvider.Claude, TimeSpan.Zero);
            Add("Nuevo agente", "Jack", ChatProvider.Claude, TimeSpan.FromMinutes(6));
            Add("Nuevo agente", "Jack", ChatProvider.Claude, TimeSpan.FromMinutes(17));
            options[ok.Id] = new AgentOptions { Model = "Sonnet 5.5" };
            demoTurns[ok.Id] =
            [
                new(TurnKind.Agent, @"**Para probarlo:** la compilación normal falla porque tu Jack está abierto y bloquea el `.exe` (PID 3068). Ciérralo y recompila. El `dotnet` del PATH es el SDK 8, así que usé `C:\Program Files (x86)\dotnet\dotnet.exe`, que es el 10."),
                new(TurnKind.Agent, "¿Quieres que añada también los selectores de modelo y modo en esta pantalla?"),
                new(TurnKind.User, "sí, y también el esfuerzo y demás"),
                new(TurnKind.Tools, "", new ToolGroup("Explorar", "1 búsqueda · 2 lecturas",
                    "Mientras no exista el agente, guardo el modelo, el esfuerzo y el modo pendientes en la ventana para aplicarlos al crearlo; también hago público `DefaultMode` para no duplicar la regla del modo inicial.",
                    "Editar · 5 archivos",
                    [
                        new("NuevoAgenteView.xaml", "Edit"),
                        new("NuevoAgenteView.xaml.cs", "Edit"),
                        new("MainWindow.xaml.cs", "Edit"),
                        new("AgentOptions.cs", "Edit"),
                        new("Composer.xaml", "Edit", Running: true)
                    ]))
            ];
            RebuildSidebar();
            Select(ok);
            return;
        }
        var pagos = Add("Revisar el módulo de pagos", "tienda-web", ChatProvider.Codex, TimeSpan.FromMinutes(2));
        var migrar = Add("Migrar a .NET 10", "api-pedidos", ChatProvider.Claude, TimeSpan.FromMinutes(9));
        var docs = Add("Documentar la CLI", "docs", ChatProvider.OpenCode, TimeSpan.FromMinutes(31));
        demoTurns[pagos.Id] =
        [
            new(TurnKind.User, "Revisa el módulo de pagos: los totales con descuento salen con un céntimo de diferencia."),
            new(TurnKind.Agent, "Voy a empezar por ver cómo se calcula el total y en qué punto se redondea."),
            new(TurnKind.Tools, "", new ToolGroup("Explorar", "1 búsqueda · 1 lectura",
                "El descuento se redondea antes de sumar los impuestos y el error se acumula. Redondeo una sola vez, al final.",
                "Editar · 2 archivos",
                [
                    new("src/Pagos/Totales.cs", "Edit"),
                    new("tests/Pagos/TotalesTests.cs", "Edit", Running: true)
                ]))
        ];
        demoTurns[migrar.Id] =
        [
            new(TurnKind.User, "Migra api-pedidos a .NET 10 sin romper los contratos públicos."),
            new(TurnKind.Agent, "Empiezo por el archivo de proyecto y los paquetes que ya tienen versión compatible.")
        ];
        demoTurns[docs.Id] =
        [
            new(TurnKind.User, "Documenta los comandos de la CLI en `docs/uso.md`."),
            new(TurnKind.Agent, "Listo el índice. Reviso cada comando con su ayuda integrada antes de describirlo.")
        ];
        RebuildSidebar();
        Select(pagos);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    // ===== Estado de cada agente =====

    private void OnConversationsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems is not null)
        {
            foreach (ChatConversation conversation in e.NewItems)
                created.TryAdd(conversation.Id, DateTime.Now);
        }
        RebuildSidebar();
    }

    private AgentOptions OptionsOf(ChatConversation conversation)
    {
        if (!options.TryGetValue(conversation.Id, out var current))
        {
            options[conversation.Id] = current = new AgentOptions
            {
                Model = conversation.Provider == ChatProvider.Claude ? "Sonnet 5.5" : DefaultModel
            };
        }
        return current;
    }

    private static string[] ModelsOf(ChatProvider provider) =>
        provider == ChatProvider.Claude ? ["Sonnet 5.5", "Opus 5.5", "Haiku 5.5"] : [DefaultModel];

    private bool IsRunning(Guid id) =>
        demoTurns.TryGetValue(id, out var turns) && turns.Any(turn => turn.Group?.Running == true);

    private static string Ago(DateTime moment)
    {
        var elapsed = DateTime.Now - moment;
        if (elapsed < TimeSpan.FromMinutes(1)) return "ahora";
        if (elapsed < TimeSpan.FromHours(1)) return $"hace {(int)elapsed.TotalMinutes} min";
        if (elapsed < TimeSpan.FromDays(1)) return $"hace {(int)elapsed.TotalHours} h";
        return $"hace {(int)elapsed.TotalDays} d";
    }

    // Una vez que el agente ha trabajado, el subtítulo muestra su modelo; antes, solo el tiempo.
    private string SubtitleOf(ChatConversation conversation)
    {
        var ago = created.TryGetValue(conversation.Id, out var moment) ? Ago(moment) : "ahora";
        if (!demoTurns.ContainsKey(conversation.Id)) return ago;
        var model = OptionsOf(conversation).Model;
        return $"{(model == DefaultModel ? conversation.ProviderTitle : model)} · {ago}";
    }

    private void UpdateSubtitles()
    {
        foreach (var conversation in workspace.Conversations)
        {
            if (subtitles.TryGetValue(conversation.Id, out var text)) text.Text = SubtitleOf(conversation);
        }
    }

    // ===== Barra lateral =====

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => RebuildSidebar();

    private void RebuildSidebar()
    {
        AgentList.Children.Clear();
        rows.Clear();
        subtitles.Clear();
        var query = SearchBox.Text.Trim();
        var visible = workspace.Conversations
            .Where(c => query.Length == 0
                || c.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || c.ProjectName.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .OrderByDescending(c => created.GetValueOrDefault(c.Id))
            .ToList();
        foreach (var group in visible.GroupBy(c => c.ProjectPath, StringComparer.OrdinalIgnoreCase))
        {
            AgentList.Children.Add(GroupLabel(group.First().ProjectName));
            foreach (var conversation in group) AgentList.Children.Add(AgentRow(conversation));
        }
        UpdateSelection();
    }

    private static UIElement GroupLabel(string name)
    {
        var label = new Grid { Padding = new Thickness(10, 12, 10, 4), ColumnSpacing = 8 };
        label.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        label.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon { Glyph = "", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        var text = new TextBlock { Text = name, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(text, 1);
        label.Children.Add(icon);
        label.Children.Add(text);
        Muted(label, text, icon);
        return label;
    }

    // Texto atenuado: los pinceles temáticos no se resuelven desde código, así que se elige el color al cargar según el tema.
    private static void Muted(FrameworkElement host, params FrameworkElement[] targets) =>
        host.Loaded += (_, _) =>
        {
            var color = host.ActualTheme == ElementTheme.Light ? Look.Hex(0x5A6170) : Look.Hex(0xA3A9B5);
            var brush = new Microsoft.UI.Xaml.Media.SolidColorBrush(color);
            foreach (var target in targets)
            {
                if (target is TextBlock text) text.Foreground = brush;
                else if (target is FontIcon icon) icon.Foreground = brush;
            }
        };

    private UIElement AgentRow(ChatConversation conversation)
    {
        var running = IsRunning(conversation.Id);
        var content = new Grid { ColumnSpacing = 10 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var indicator = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Width = 3,
            RadiusX = 2,
            RadiusY = 2,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Stretch,
            Margin = new Thickness(-10, 2, 0, 2),
            Fill = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["JackAccentBrush"],
            Visibility = Visibility.Collapsed
        };
        Grid.SetColumnSpan(indicator, 2);
        content.Children.Add(indicator);

        UIElement state = running
            ? new Spinner()
            : new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = 6, Height = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Fill = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["JackIdleDotBrush"]
            };
        var stateHost = new Grid { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 0, 0) };
        stateHost.Children.Add(state);
        content.Children.Add(stateHost);

        var title = new TextBlock { Text = conversation.Title, TextTrimming = TextTrimming.CharacterEllipsis };
        var subtitle = new TextBlock { Text = SubtitleOf(conversation), FontSize = 12 };
        Muted(subtitle, subtitle);
        var texts = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch };
        texts.Children.Add(title);
        texts.Children.Add(subtitle);
        Grid.SetColumn(texts, 1);
        content.Children.Add(texts);
        subtitles[conversation.Id] = subtitle;

        var row = new Button
        {
            Style = (Style)Application.Current.Resources["JackButton"],
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
            Padding = new Thickness(10, 8, 10, 8),
            MinHeight = 0
        };
        AutomationProperties.SetName(row, conversation.Title);
        ToolTipService.SetToolTip(row, conversation.ProjectPath);
        row.Click += (_, _) => Select(conversation);
        rows[conversation.Id] = new SidebarRow(row, indicator);
        return row;
    }

    // Fila seleccionada: fondo blanco 8 % y barra de acento de 3 px a la izquierda.
    private void UpdateSelection()
    {
        foreach (var (id, row) in rows)
        {
            var isSelected = id == selectedId;
            row.Indicator.Visibility = isSelected ? Visibility.Visible : Visibility.Collapsed;
            if (isSelected) row.Row.Background = Look.Selected(Root.ActualTheme);
            else row.Row.ClearValue(Control.BackgroundProperty);
            AutomationProperties.SetItemStatus(row.Row, isSelected ? "Seleccionado" : "");
        }
    }

    private void Select(ChatConversation conversation)
    {
        selectedId = conversation.Id;
        UpdateSelection();
        ShowConversation(conversation);
    }

    // ===== Conversación =====

    private void ShowConversation(ChatConversation? conversation)
    {
        EmptyState.Visibility = conversation is null ? Visibility.Visible : Visibility.Collapsed;
        ConversationView.Visibility = conversation is null ? Visibility.Collapsed : Visibility.Visible;
        if (conversation is null) return;

        var running = IsRunning(conversation.Id);
        var hasTurns = demoTurns.TryGetValue(conversation.Id, out var turns);
        ConversationTitle.Text = conversation.Title;
        HeaderFolder.Text = conversation.ProjectName;
        HeaderProvider.Text = conversation.ProviderTitle;
        HeaderBusy.Text = running ? "Trabajando…" : "";
        HeaderIdle.Text = running ? "" : "CLI sin conectar";
        StopButton.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        SendButton.IsEnabled = running;
        SendIcon.Glyph = running ? "\uE71A" : "\uE724";
        AutomationProperties.SetName(SendButton, running ? "Detener" : "Enviar");
        ComposerHint.Text = hasTurns
            ? "Intro envía · Mayús+Intro nueva línea"
            : "La CLI de este agente aún no está conectada: todavía no se pueden enviar mensajes.";
        BuildOptionMenus(conversation);
        Transcript.ItemsSource = turns;
        // Como en un chat, lo más reciente queda a la vista.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            TranscriptScroll.UpdateLayout();
            TranscriptScroll.ChangeView(null, TranscriptScroll.ScrollableHeight, null, true);
        });
    }

    // Píldoras del compositor: el menú de cada una cambia el valor mostrado y lo recuerda por agente.
    private void BuildOptionMenus(ChatConversation conversation)
    {
        var current = OptionsOf(conversation);
        ModelText.Text = current.Model;
        EffortText.Text = $"Esfuerzo · {current.Effort}";
        ModeText.Text = $"Permisos · {current.Mode}";
        FillMenu(ModelMenu, ModelsOf(conversation.Provider), current.Model, value =>
        {
            current.Model = value;
            ModelText.Text = value;
            UpdateSubtitles();
        });
        FillMenu(EffortMenu, ["Bajo", "Medio", "Alto"], current.Effort, value =>
        {
            current.Effort = value;
            EffortText.Text = $"Esfuerzo · {value}";
        });
        FillMenu(ModeMenu, ["Manual", "Auto"], current.Mode, value =>
        {
            current.Mode = value;
            ModeText.Text = $"Permisos · {value}";
        });
    }

    private static void FillMenu(MenuFlyout menu, string[] choices, string selected, Action<string> apply)
    {
        menu.Items.Clear();
        foreach (var choice in choices)
        {
            var item = new RadioMenuFlyoutItem { Text = choice, GroupName = menu.GetHashCode().ToString(), IsChecked = choice == selected };
            item.Click += (_, _) => apply(choice);
            menu.Items.Add(item);
        }
    }

    // Pliega y despliega el cuerpo de la tarjeta de herramientas.
    private void ToolHeader_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Parent: StackPanel card, Content: Grid header } || card.Children.Count < 2) return;
        var body = card.Children[1];
        var open = body.Visibility == Visibility.Collapsed;
        body.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (header.Children[^1] is FontIcon chevron) chevron.Glyph = open ? "\uE70D" : "\uE70E";
    }

    // ===== Nuevo agente =====

    private bool isCreating;

    private void NewConversation_Accelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        NewConversation_Click(sender, new RoutedEventArgs());
    }

    private async void NewConversation_Click(object sender, RoutedEventArgs e)
    {
        // Hay dos botones "Nuevo agente" y un atajo; WinUI solo permite un ContentDialog abierto a la vez.
        if (isCreating) return;
        isCreating = true;
        NewConversationButton.IsEnabled = false;
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;

            var title = new TextBox { Header = "Nombre", Text = "Nuevo agente", MaxLength = 200 };
            var provider = new ComboBox
            {
                Header = "Proveedor",
                ItemsSource = new[] { "Codex", "Claude Code", "OpenCode" },
                SelectedIndex = 0,
                HorizontalAlignment = HorizontalAlignment.Stretch
            };
            var validation = new TextBlock { TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetLiveSetting(validation, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
            var fields = new StackPanel { Spacing = 16 };
            fields.Children.Add(title);
            fields.Children.Add(provider);
            fields.Children.Add(new TextBlock { Text = folder.Path, TextWrapping = TextWrapping.Wrap });
            fields.Children.Add(validation);
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Nuevo agente",
                Content = fields,
                PrimaryButtonText = "Crear conversación",
                CloseButtonText = "Cancelar",
                DefaultButton = ContentDialogButton.Primary
            };
            dialog.PrimaryButtonClick += (_, args) =>
            {
                try
                {
                    var selectedProvider = provider.SelectedIndex switch
                    {
                        1 => ChatProvider.Claude,
                        2 => ChatProvider.OpenCode,
                        _ => ChatProvider.Codex
                    };
                    Select(workspace.CreateConversation(title.Text, folder.Path, selectedProvider));
                }
                catch (ArgumentException)
                {
                    validation.Text = "Indica un nombre y comprueba que la carpeta del proyecto siga disponible.";
                    args.Cancel = true;
                }
            };
            await dialog.ShowAsync();
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine(error);
            await new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "No se pudo preparar la conversación",
                Content = "Vuelve a intentarlo y elige una carpeta local a la que tengas acceso.",
                CloseButtonText = "Cerrar"
            }.ShowAsync();
        }
        finally
        {
            NewConversationButton.IsEnabled = true;
            isCreating = false;
        }
    }
}
