using Jack.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Jack.WinUI;

public sealed partial class MainWindow : Window
{
    private readonly ChatWorkspace workspace = new();

    public MainWindow()
    {
        InitializeComponent();
        ConversationList.ItemsSource = workspace.Conversations;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 740));
    }

    private async void NewConversation_Click(object sender, RoutedEventArgs e)
    {
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
                    ConversationList.SelectedItem = workspace.CreateConversation(title.Text, folder.Path, selectedProvider);
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
        }
    }

    private void ConversationList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ConversationList.SelectedItem is not ChatConversation conversation) return;
        ConversationTitle.Text = conversation.Title;
        ConversationDescription.Text = $"{conversation.ProviderTitle} · Conversación preparada";
        ProjectPath.Text = conversation.ProjectPath;
    }
}
