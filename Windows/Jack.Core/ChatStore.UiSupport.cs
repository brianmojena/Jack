namespace Jack.Core;

// Soporte para la interfaz de Windows: operaciones que la vista necesita y que no encajan en los demás archivos del store.
public sealed partial class ChatStore
{
    /// <summary>Descarta el último aviso de error (la interfaz lo muestra en una barra descartable).</summary>
    public void DismissError() => ErrorMessage = null;

    /// <summary>Muestra un aviso de error generado por la interfaz.</summary>
    public void ReportError(string message) => ErrorMessage = message;
}
