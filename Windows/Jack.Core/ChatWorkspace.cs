using System.Collections.ObjectModel;

using System.Collections.ObjectModel;

using System.Collections.ObjectModel;

using System.Collections.ObjectModel;

namespace Jack.Core;

public sealed class ChatWorkspace
{
    // shortcut: conversaciones en memoria; añadir persistencia al conectar el primer proveedor.
    private readonly ObservableCollection<ChatConversation> conversations = [];
    public ReadOnlyObservableCollection<ChatConversation> Conversations { get; }

    public ChatWorkspace() => Conversations = new(conversations);

    public ChatConversation CreateConversation(string title, string projectPath, ChatProvider provider)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(title);
        ArgumentException.ThrowIfNullOrWhiteSpace(projectPath);
        if (!Enum.IsDefined(provider))
            throw new ArgumentOutOfRangeException(nameof(provider));
        if (!Path.IsPathFullyQualified(projectPath) || !Directory.Exists(projectPath))
            throw new ArgumentException("El proyecto debe ser una carpeta existente con ruta absoluta.", nameof(projectPath));

        var conversation = new ChatConversation(Path.GetFullPath(projectPath), provider) { Title = title.Trim() };
        conversations.Add(conversation);
        return conversation;
    }
}
