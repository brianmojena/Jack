using Jack.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Jack.WinUI;

// Transcripción de la conversación seleccionada. Cada mensaje se construye una vez y se reutiliza mientras no cambie
// (así un fragmento nuevo de respuesta no reconstruye todo el historial). Se desplaza al final solo si el usuario
// ya estaba abajo o si acaba de cambiar de conversación.
public sealed partial class TranscriptView : UserControl
{
    private const double BottomTolerance = 60;

    // Elemento y firma (contenido) de cada mensaje ya construido, por id.
    private Dictionary<string, (int Signature, FrameworkElement Element)> cache = new();
    private Guid? shownId;

    public TranscriptView()
    {
        InitializeComponent();
        ChatPresentation.FitColumn(Scroller, ContentColumn, 780);
    }

    /// <summary>Muestra los mensajes de una conversación. <paramref name="working"/> enciende el indicador "Trabajando…".</summary>
    public void Show(Guid? conversationId, IReadOnlyList<ChatMessage> messages, bool working)
    {
        var switched = conversationId != shownId;
        // Se decide antes de tocar los hijos: después el contenido ya habrá crecido.
        var follow = switched || IsNearBottom();
        if (switched)
        {
            shownId = conversationId;
            cache = new Dictionary<string, (int, FrameworkElement)>();
        }

        var next = new Dictionary<string, (int Signature, FrameworkElement Element)>();
        MessagesHost.Children.Clear();
        for (var i = 0; i < messages.Count; i++)
        {
            var message = messages[i];
            var group = new List<ChatMessage> { message };
            if (message.Role == "tool")
            {
                while (i + 1 < messages.Count && messages[i + 1].Role == "tool") group.Add(messages[++i]);
            }
            var signature = 0;
            foreach (var m in group)
            {
                signature = HashCode.Combine(signature, m.Role, m.Text, m.Detail, m.Status, m.Attachments?.Count ?? 0);
            }
            var key = message.Id + (group.Count > 1 ? "+" : "");
            if (!cache.TryGetValue(key, out var entry) || entry.Signature != signature)
            {
                entry = (signature, message.Role == "tool" ? MessageView.ToolGroup(group) : MessageView.Build(message));
            }
            next[key] = entry;
            MessagesHost.Children.Add(entry.Element);
        }
        cache = next;

        WorkingHost.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
        if (follow) ScrollToEnd();
    }

    private bool IsNearBottom() => Scroller.ScrollableHeight - Scroller.VerticalOffset <= BottomTolerance;

    // Tras el repintado el contenido ya tiene su altura nueva; por eso se encola con prioridad baja.
    private void ScrollToEnd() =>
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => Scroller.ChangeView(null, Scroller.ScrollableHeight, null, true));
}

