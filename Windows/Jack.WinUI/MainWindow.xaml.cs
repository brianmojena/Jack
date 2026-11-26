using Jack.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;

namespace Jack.WinUI;

public sealed partial class MainWindow : Window
{
    // Borrador del compositor de una conversación: el texto y los archivos adjuntos aún no enviados.
    private sealed class Draft
    {
        public string Text = "";
        public List<string> Files = new();
    }

    private readonly ChatStore store;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer refreshTimer;
    private readonly Dictionary<Guid, Draft> drafts = new();

    private Guid? shownId;
    private Draft? draft;
    private bool newMode;
    private readonly Draft newDraft = new();
    private Guid? comboOwner;
    private string effortKey = "";
    private string approvalKey = "";
    private bool sendShowsStop;
    private bool suppressCombos;
    private bool suppressErrorBar;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        try { AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "jack.ico")); } catch { }
        SetTitleBar(AppTitleBar);
        FitToScreen();
        AppWindow.Changed += EnforceMinimumSize;
        ApplyCaptureTheme();

        // Un único store, creado en el hilo de interfaz: sus eventos llegan a este hilo.
        store = new ChatStore(new ChatArchive(), new JsonPreferences());
        refreshTimer = DispatcherQueue.CreateTimer();
        refreshTimer.Interval = TimeSpan.FromMilliseconds(50);
        refreshTimer.IsRepeating = false;
        refreshTimer.Tick += (_, _) => Refresh();
        store.Changed += ScheduleRefresh;

        Sidebar.Attach(store);
        Sidebar.NewAgentRequested += EnterNewMode;
        ChatPresentation.FitColumn(ApprovalsHost, ApprovalsBox);
        ChatPresentation.FitColumn(ComposerHost, ComposerBox, 780);
        Closed += (_, _) => store.Shutdown();
        NewFolder.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter) { e.Handled = true; Composer.Focus(FocusState.Programmatic); }
        };
        ChatPresentation.FitColumn(NewChatPanel, NewChatBox, 560);
        Sidebar.ConversationChosen += LeaveNewMode;

        Refresh();
    }

    // ----------------------------------------------------------------------------------- Ventana

    // Tamaño inicial 1280x800, sin superar el área útil de la pantalla.
    private void FitToScreen()
    {
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(1280, work.Width);
        var height = Math.Min(800, work.Height);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height));
    }

    // WinUI no tiene MinWidth en Window: si la ventana se hace más pequeña que 900x600, se vuelve a estirar.
    private void EnforceMinimumSize(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidSizeChange) return;
        var size = sender.Size;
        var width = Math.Max(size.Width, 900);
        var height = Math.Max(size.Height, 600);
        if (width != size.Width || height != size.Height) sender.Resize(new Windows.Graphics.SizeInt32(width, height));
    }

    // Solo para capturas de CI: JACK_THEME=light|dark fuerza el tema de la ventana.
    private void ApplyCaptureTheme()
    {
        var theme = Environment.GetEnvironmentVariable("JACK_THEME");
        if (theme is "light" or "dark") Root.RequestedTheme = theme == "dark" ? ElementTheme.Dark : ElementTheme.Light;
    }

    private void NewAgentShortcut_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        EnterNewMode();
        args.Handled = true;
    }

    // ----------------------------------------------------------------------------------- Refresco

    // El store avisa en cada cambio pequeño (p. ej. cada fragmento de respuesta); agrupamos los repintados.
    private void ScheduleRefresh()
    {
        if (!refreshTimer.IsRunning) refreshTimer.Start();
    }

    private void Refresh()
    {
        Sidebar.Refresh();
        ShowError();
        if (newMode)
        {
            ShowNewMode();
            return;
        }

        var conversation = store.SelectedConversation;
        if (conversation is null)
        {
            shownId = null;
            draft = null;
            ShowEmpty();
            return;
        }

        EmptyState.Visibility = Visibility.Collapsed;
        ConversationView.Visibility = Visibility.Visible;
        HeaderBar.Visibility = Visibility.Visible;
        NewChatPanel.Visibility = Visibility.Collapsed;
        Transcript.Visibility = Visibility.Visible;
        SettingsRow.Visibility = Visibility.Visible;
        if (conversation.Id != shownId) SwitchTo(conversation);

        var id = conversation.Id;
        ConversationTitle.Text = string.IsNullOrWhiteSpace(conversation.Title) ? "Nuevo agente" : conversation.Title;
        ConversationDescription.Text = $"{ChatPresentation.ProjectName(conversation.ProjectPath)} · {conversation.Provider.Title()}";

        var busy = store.IsBusy(id);
        var working = store.Statuses.TryGetValue(id, out var status) && (status == ChatStatus.Running || status == ChatStatus.Queued);
        Transcript.Show(id, conversation.Messages, working);
        ConversationState.Text = working ? "· Trabajando…" : "";
        StopButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;

        ShowApprovals(id);
        ShowQueue(id);
        RestoreRecalled(id);
        SyncSettings(conversation, busy);
        UpdateSendButton();
    }

    private void ShowEmpty()
    {
        var any = store.Conversations.Count > 0;
        EmptyTitle.Text = any ? "Selecciona un agente" : "Crea tu primer agente";
        EmptyBody.Text = any
            ? "Elige una conversación en la barra lateral o crea una nueva."
            : "Elige la carpeta de un proyecto y un proveedor para preparar una conversación.";
        HeaderBar.Visibility = Visibility.Collapsed;
        EmptyState.Visibility = Visibility.Visible;
        ConversationView.Visibility = Visibility.Collapsed;
    }

    private void ShowError()
    {
        var message = store.ErrorMessage;
        suppressErrorBar = true;
        ErrorBar.Message = message ?? "";
        ErrorBar.IsOpen = message is not null;
        suppressErrorBar = false;
    }

    private void ErrorBar_Closed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (!suppressErrorBar) store.DismissError();
    }

    // Cambia la conversación mostrada: guarda el borrador de la anterior y carga el de la nueva.
    private void SwitchTo(ChatConversation conversation)
    {
        if (shownId is { } previous && draft is not null) drafts[previous] = draft;
        shownId = conversation.Id;
        if (!drafts.TryGetValue(conversation.Id, out draft))
        {
            draft = new Draft();
            drafts[conversation.Id] = draft;
        }
        Composer.Text = draft.Text;
        RenderAttachments();
        comboOwner = null;
        effortKey = "";
        approvalKey = "";
        // El cursor queda listo en el compositor al abrir o crear un agente.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Composer.Focus(FocusState.Programmatic));
    }

    // ----------------------------------------------------------------------------------- Aprobaciones

    private void ShowApprovals(Guid id)
    {
        var approvals = store.Approvals.TryGetValue(id, out var list) ? list : null;
        // Solo se reconstruye si cambian las aprobaciones: así no se pierden las respuestas que el usuario escribe.
        var key = id + "|" + (approvals is null ? "" : string.Join("|", approvals.Select(approval => approval.Id + ":" + approval.Questions.Count)));
        if (key != approvalKey)
        {
            approvalKey = key;
            ApprovalsBox.Children.Clear();
            if (approvals is not null)
            {
                foreach (var approval in approvals) ApprovalsBox.Children.Add(ApprovalView.Build(store, id, approval));
            }
        }
        ApprovalsHost.Visibility = ApprovalsBox.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    // ----------------------------------------------------------------------------------- Cola de mensajes y adjuntos

    private void ShowQueue(Guid id)
    {
        QueueHost.Children.Clear();
        if (store.Waiting.TryGetValue(id, out var waiting))
        {
            foreach (var message in waiting)
            {
                var text = new TextBlock
                {
                    Text = "En espera: " + ChatPresentation.Preview(message.Text, 48),
                    Style = (Style)Application.Current.Resources["JackCaption"],
                    TextWrapping = TextWrapping.NoWrap,
                    TextTrimming = TextTrimming.CharacterEllipsis
                };
                QueueHost.Children.Add(new Border
                {
                    Style = (Style)Application.Current.Resources["JackChip"],
                    Child = text
                });
            }
        }
        QueueHost.Visibility = QueueHost.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    // Si el agente se detuvo con mensajes en espera, el texto vuelve al compositor para editarlo.
    private void RestoreRecalled(Guid id)
    {
        if (draft is null || !store.Recalled.TryGetValue(id, out var recalled)) return;
        if (Composer.Text.Trim().Length == 0 && draft.Files.Count == 0)
        {
            Composer.Text = recalled.Text;
            draft.Files = recalled.Attachments.ToList();
            RenderAttachments();
        }
        store.ClearRecalled(id);
    }

    private void RenderAttachments()
    {
        AttachmentsHost.Children.Clear();
        var owner = draft;
        var files = owner?.Files ?? new List<string>();
        foreach (var path in files)
        {
            var chip = new Button
            {
                Content = Path.GetFileName(path) + "  ×",
                Padding = new Thickness(8, 2, 8, 2),
                MinHeight = 0
            };
            ToolTipService.SetToolTip(chip, path);
            chip.Click += (_, _) =>
            {
                owner?.Files.Remove(path);
                RenderAttachments();
                UpdateSendButton();
            };
            AttachmentsHost.Children.Add(chip);
        }
        AttachmentsHost.Visibility = files.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    // ----------------------------------------------------------------------------------- Ajustes (modelo, esfuerzo, modo)

    private void SyncSettings(ChatConversation conversation, bool busy)
    {
        suppressCombos = true;
        try
        {
            var provider = conversation.Provider;
            if (comboOwner != conversation.Id)
            {
                comboOwner = conversation.Id;
                ModeBox.Items.Clear();
                foreach (var mode in ChatRunMode.Choices(provider))
                {
                    ModeBox.Items.Add(new ComboBoxItem { Content = mode.Title, Tag = mode.Id });
                }
                ModelBox.Items.Clear();
                foreach (var choice in store.ModelChoices(provider))
                {
                    ModelBox.Items.Add(new ComboBoxItem { Content = choice.Title, Tag = choice.Id });
                }
            }

            // Modelo: si no está en la lista (p. ej. una versión antigua), se añade para que se vea.
            SelectByTag(ModelBox, conversation.Model, () => new ComboBoxItem
            {
                Content = ChatPresentation.ModelTitle(conversation.Model),
                Tag = conversation.Model
            });

            // Esfuerzo: depende del modelo, así que se reconstruye solo cuando cambia el modelo.
            var key = conversation.Id + "|" + conversation.Model;
            if (key != effortKey)
            {
                effortKey = key;
                EffortBox.Items.Clear();
                foreach (var effort in store.SupportedEfforts(provider, conversation.Model))
                {
                    EffortBox.Items.Add(new ComboBoxItem { Content = ChatModelChoice.EffortTitle(effort), Tag = effort });
                }
            }
            SelectByTag(EffortBox, conversation.Effort, () => new ComboBoxItem
            {
                Content = ChatModelChoice.EffortTitle(conversation.Effort),
                Tag = conversation.Effort
            });

            SelectByTag(ModeBox, conversation.Mode ?? "manual", () => new ComboBoxItem
            {
                Content = ChatPresentation.ModeTitle(conversation),
                Tag = conversation.Mode ?? "manual"
            });

            // Como en Swift, el modelo y el esfuerzo no cambian con un turno en marcha o con mensajes en cola.
            ModelBox.IsEnabled = !busy;
            EffortBox.IsEnabled = !busy;
            ModeBox.IsEnabled = !busy || store.ChangesModeLive(conversation.Id);
        }
        finally
        {
            suppressCombos = false;
        }
    }

    // Selecciona el elemento cuyo Tag coincide; si no existe, lo añade con <paramref name="create"/>.
    private static void SelectByTag(ComboBox box, string? tag, Func<ComboBoxItem> create)
    {
        if (tag is null) return;
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if ((item.Tag as string) == tag)
            {
                box.SelectedItem = item;
                return;
            }
        }
        var added = create();
        box.Items.Add(added);
        box.SelectedItem = added;
    }

    private void ModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressCombos || shownId is not { } id) return;
        if (ModelBox.SelectedItem is not ComboBoxItem { Tag: string model }) return;
        var conversation = store.SelectedConversation;
        if (conversation is null || model == conversation.Model) return;
        store.UpdateSettings(id, model, conversation.Effort);
    }

    private void EffortBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressCombos || shownId is not { } id) return;
        if (EffortBox.SelectedItem is not ComboBoxItem { Tag: string effort }) return;
        var conversation = store.SelectedConversation;
        if (conversation is null || effort == conversation.Effort) return;
        store.UpdateSettings(id, conversation.Model, effort);
    }

    private void ModeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressCombos || shownId is not { } id) return;
        if (ModeBox.SelectedItem is not ComboBoxItem { Tag: string mode }) return;
        var conversation = store.SelectedConversation;
        if (conversation is null || mode == conversation.Mode) return;
        store.UpdateMode(id, mode, ChatRunMode.Choices(conversation.Provider));
    }

    // ----------------------------------------------------------------------------------- Compositor

    // Mientras la conversación está ocupada y el compositor está vacío, el botón detiene al agente.
    private void UpdateSendButton()
    {
        var empty = Composer.Text.Trim().Length == 0 && (draft?.Files.Count ?? 0) == 0;
        var showStop = shownId is { } id && store.IsBusy(id) && empty;
        if (showStop == sendShowsStop) return;
        sendShowsStop = showStop;
        SendGlyph.Glyph = showStop ? "\uE71A" : "\uE74A";
        ToolTipService.SetToolTip(SendButton, showStop ? "Detener" : "Enviar");
        AutomationProperties.SetName(SendButton, showStop ? "Detener" : "Enviar");
    }

    private void Composer_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (draft is not null) draft.Text = Composer.Text;
        UpdateSendButton();
    }

    private void Composer_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        // Mayús+Intro inserta una nueva línea; Intro envía.
        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down)) return;
        e.Handled = true;
        SendCurrent();
    }

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        if (shownId is { } id) store.Stop(id);
    }

    private void Send_Click(object sender, RoutedEventArgs e)
    {
        if (newMode)
        {
            SendNew();
            return;
        }
        if (shownId is not { } id || draft is null) return;
        var empty = Composer.Text.Trim().Length == 0 && draft.Files.Count == 0;
        // Ocupada y sin texto: el botón es "Detener". Con texto, se envía y el store lo pone en cola.
        if (empty && store.IsBusy(id))
        {
            store.Stop(id);
            return;
        }
        SendCurrent();
    }

    private void SendCurrent()
    {
        if (newMode)
        {
            SendNew();
            return;
        }
        if (shownId is not { } id || draft is null) return;
        var text = Composer.Text;
        if (text.Trim().Length == 0 && draft.Files.Count == 0) return;
        var files = draft.Files.ToList();
        // Si el agente está ocupado, store.Send deja el mensaje en cola (store.Waiting) y lo entrega al terminar.
        store.Send(text, id, files.Count == 0 ? null : files);
        Composer.Text = "";
        draft.Files.Clear();
        RenderAttachments();
        UpdateSendButton();
    }

    private void Attach_Click(object sender, RoutedEventArgs e)
    {
        if (draft is null) return;
        try
        {
            foreach (var path in NativePicker.PickFiles(WinRT.Interop.WindowNative.GetWindowHandle(this), "Adjuntar archivos"))
            {
                if (!draft.Files.Contains(path)) draft.Files.Add(path);
            }
            RenderAttachments();
            UpdateSendButton();
        }
        catch (Exception error)
        {
            store.ReportError("No se pudo abrir el selector de archivos: " + error.Message);
        }
    }

    // ----------------------------------------------------------------------------------- Nuevo agente

    private void NewAgent_Click(object sender, RoutedEventArgs e) => EnterNewMode();

    // Pantalla de agente nuevo, dentro del propio chat: carpeta arriba y compositor abajo.
    private void EnterNewMode()
    {
        if (!newMode)
        {
            if (shownId is { } previous && draft is not null) drafts[previous] = draft;
            newMode = true;
            shownId = null;
            draft = newDraft;
            Composer.Text = newDraft.Text;
            RenderAttachments();
            comboOwner = null;
            effortKey = "";
            approvalKey = "";
            FillNewRecents();
        }
        Refresh();
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (NewFolder.Text.Trim().Length == 0) NewFolder.Focus(FocusState.Programmatic);
            else Composer.Focus(FocusState.Programmatic);
        });
    }

    private void LeaveNewMode()
    {
        if (!newMode) return;
        newMode = false;
        shownId = null;
        draft = null;
        Refresh();
    }

    private void ShowNewMode()
    {
        EmptyState.Visibility = Visibility.Collapsed;
        ConversationView.Visibility = Visibility.Visible;
        HeaderBar.Visibility = Visibility.Visible;
        NewChatPanel.Visibility = Visibility.Visible;
        Transcript.Visibility = Visibility.Collapsed;
        ApprovalsHost.Visibility = Visibility.Collapsed;
        QueueHost.Visibility = Visibility.Collapsed;
        SettingsRow.Visibility = Visibility.Collapsed;
        StopButton.Visibility = Visibility.Collapsed;
        ConversationTitle.Text = "Nuevo agente";
        ConversationDescription.Text = "Claude Code";
        ConversationState.Text = "";
        UpdateSendButton();
    }

    private void FillNewRecents()
    {
        NewRecent.Children.Clear();
        NewRecent.Children.Add(RecentRow("\uE80F", "Sin carpeta", "Usa tu carpeta personal", ChatPresentation.HomeFolder));
        var recent = store.Conversations
            .OrderByDescending(c => c.UpdatedAt)
            .Select(c => c.ProjectPath)
            .Where(path => Directory.Exists(path) && !ChatPresentation.IsHome(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(6)
            .ToList();
        foreach (var path in recent) NewRecent.Children.Add(RecentRow("\uE8B7", ChatPresentation.ProjectName(path), path, path));
        NewRecentBox.Visibility = Visibility.Visible;
    }

    private Button RecentRow(string glyph, string title, string subtitle, string path)
    {
        var row = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 7, 10, 7),
            CornerRadius = new CornerRadius(8),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                Children =
                {
                    new FontIcon { Glyph = glyph, FontSize = 13, Foreground = (Brush)Application.Current.Resources["JackMutedBrush"] },
                    new TextBlock { Text = title, FontSize = 13.5 },
                    new TextBlock { Text = subtitle, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
                                    Style = (Style)Application.Current.Resources["JackCaption"], MaxWidth = 300 }
                }
            }
        };
        row.Click += (_, _) =>
        {
            NewFolder.Text = path;
            Composer.Focus(FocusState.Programmatic);
        };
        return row;
    }

    private void NewFolder_TextChanged(object sender, TextChangedEventArgs e)
    {
        var path = NewFolder.Text.Trim().Trim('"');
        var missing = path.Length > 0 && !Directory.Exists(path);
        NewHint.Text = "La carpeta no existe.";
        NewHint.Visibility = missing ? Visibility.Visible : Visibility.Collapsed;
    }

    private void NewBrowse_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var folder = NativePicker.PickFolder(WinRT.Interop.WindowNative.GetWindowHandle(this), "Carpeta del proyecto");
            if (folder is not null)
            {
                NewFolder.Text = folder;
                Composer.Focus(FocusState.Programmatic);
            }
        }
        catch (Exception error)
        {
            NewHint.Text = "No se pudo abrir el selector: " + error.Message + ". Escribe la ruta a mano.";
            NewHint.Visibility = Visibility.Visible;
        }
    }

    // Crea el agente en la carpeta elegida y le envía el primer mensaje.
    private void SendNew()
    {
        var path = NewFolder.Text.Trim().Trim('"');
        if (!Directory.Exists(path))
        {
            NewHint.Text = path.Length == 0 ? "Elige primero la carpeta del proyecto." : "La carpeta no existe.";
            NewHint.Visibility = Visibility.Visible;
            NewFolder.Focus(FocusState.Programmatic);
            return;
        }
        var text = Composer.Text;
        var files = newDraft.Files.ToList();
        if (text.Trim().Length == 0 && files.Count == 0) return;

        if (store.Create(path, ChatProvider.Claude) is not { } id) return; // el store deja el aviso en ErrorMessage
        newMode = false;
        shownId = null;
        draft = null;
        newDraft.Text = "";
        newDraft.Files.Clear();
        Composer.Text = "";
        NewFolder.Text = "";
        store.Send(text, id, files.Count == 0 ? null : files);
        Refresh();
    }
}
