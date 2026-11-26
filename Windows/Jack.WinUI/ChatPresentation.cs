using Jack.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Jack.WinUI;

// Textos y reglas de presentación compartidos por las vistas: estados, nombres, orden de la barra lateral y
// utilidades de diseño. Nada de aquí toca el estado del store.
public static class ChatPresentation
{
    // Colores fijos y sobrios para los puntos de estado (legibles en claro y oscuro).
    public static readonly Windows.UI.Color BusyColor = Windows.UI.Color.FromArgb(255, 0x0F, 0x6C, 0xBD);
    public static readonly Windows.UI.Color WaitingColor = Windows.UI.Color.FromArgb(255, 0xB3, 0x6B, 0x00);
    public static readonly Windows.UI.Color FailedColor = Windows.UI.Color.FromArgb(255, 0xC4, 0x2B, 0x1C);
    public static readonly Windows.UI.Color IdleColor = Windows.UI.Color.FromArgb(255, 0x8A, 0x8A, 0x8A);

    private static bool dialogOpen;

    /// <summary>Carpeta personal: el espacio "Sin carpeta", como en macOS.</summary>
    public static readonly string HomeFolder = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public static bool IsHome(string projectPath) =>
        string.Equals(projectPath.TrimEnd('\\', '/'), HomeFolder.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);

    public static string ProjectName(string projectPath) =>
        IsHome(projectPath) ? "Sin carpeta" : Path.GetFileName(projectPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)) is { Length: > 0 } name
            ? name
            : projectPath;

    /// <summary>Modelo legible. Sin modelo, el predeterminado del proveedor.</summary>
    public static string ModelTitle(string model) =>
        string.IsNullOrWhiteSpace(model) ? "Predeterminado" : ChatModelChoice.ClaudeTitle(model);

    /// <summary>Modo de permisos legible para una conversación.</summary>
    public static string ModeTitle(ChatConversation conversation)
    {
        var id = conversation.Mode ?? "manual";
        if (id == ChatRunMode.Bypass.Id) return ChatRunMode.Bypass.Title;
        foreach (var choice in ChatRunMode.Choices(conversation.Provider))
        {
            if (choice.Id == id) return choice.Title;
        }
        return id;
    }

    /// <summary>
    /// Estado de una conversación para la barra lateral: ocupado, inactivo, esperando (necesita al usuario) o fallido.
    /// Una aprobación pendiente cuenta como "esperando" aunque el proceso siga en marcha.
    /// </summary>
    public static (string Label, Windows.UI.Color Color) StatusOf(ChatStore store, Guid id)
    {
        var needsUser = store.Approvals.TryGetValue(id, out var approvals) && approvals.Count > 0;
        var status = store.Statuses.TryGetValue(id, out var value) ? value : ChatStatus.Idle;
        if (needsUser || status == ChatStatus.Waiting) return ("Esperando", WaitingColor);
        return status switch
        {
            ChatStatus.Running or ChatStatus.Queued => ("Ocupado", BusyColor),
            ChatStatus.Failed => ("Fallido", FailedColor),
            _ => ("Inactivo", IdleColor)
        };
    }

    /// <summary>Fijadas primero; dentro de cada grupo, la más reciente primero.</summary>
    public static List<ChatConversation> OrderedConversations(ChatStore store) =>
        store.Conversations
            .OrderByDescending(conversation => conversation.PinnedAt is not null)
            .ThenByDescending(conversation => conversation.UpdatedAt)
            .ToList();

    /// <summary>Recorta un texto para una vista previa en una línea.</summary>
    public static string Preview(string text, int maxLength)
    {
        var singleLine = text.ReplaceLineEndings(" ").Trim();
        return singleLine.Length <= maxLength ? singleLine : singleLine[..maxLength] + "…";
    }

    /// <summary>
    /// Muestra un ContentDialog como mucho uno a la vez (WinUI lanza excepción si ya hay uno abierto).
    /// Devuelve None si ya había otro abierto.
    /// </summary>
    public static async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        if (dialogOpen) return ContentDialogResult.None;
        dialogOpen = true;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            dialogOpen = false;
        }
    }

    /// <summary>
    /// Limita el ancho de <paramref name="column"/> a <paramref name="maxWidth"/> (o al de la ventana menos un margen)
    /// y lo centra, para que la transcripción y el compositor no ocupen toda la pantalla en ventanas anchas.
    /// Quien llama debe centrar <paramref name="column"/> con HorizontalAlignment="Center".
    /// </summary>
    public static void FitColumn(FrameworkElement viewport, FrameworkElement column, double maxWidth = 760, double margin = 48)
    {
        void Apply(double available) => column.Width = Math.Max(0, Math.Min(maxWidth, available - margin));
        Apply(viewport.ActualWidth);
        viewport.SizeChanged += (_, e) => Apply(e.NewSize.Width);
    }
}
