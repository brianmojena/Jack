namespace Jack.Core;

// Miembros de ChatStore que usan varios archivos parciales y que ninguno declaró al repartir el trabajo.
public sealed partial class ChatStore
{
    /// <summary>
    /// Comprobación previa al envío (por ejemplo, un aviso de que falta algo): devuelve un mensaje de error para
    /// rechazar el envío, o null para aceptarlo. Swift: `sendGate`.
    /// </summary>
    public Func<ChatConversation, string?>? SendGate { get; set; }

    /// <summary>
    /// Pregunta al margen (`/btw`) sin interrumpir al agente ni entrar en su historial. Swift: `askAside(_:in:)`.
    /// </summary>
    public void AskAside(string question, Guid id)
    {
        // TODO(port): askAside viene de ChatStore.swift:1363 y usa ChatAside.swift, todavía sin portar.
        ErrorMessage = "Las preguntas al margen (/btw) todavía no están disponibles en Windows.";
    }
}
