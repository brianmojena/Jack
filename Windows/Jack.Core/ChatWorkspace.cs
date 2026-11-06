using System.Collections.ObjectModel;

namespace Jack.Core;

public enum ChatProvider { Codex, Claude, OpenCode }

public sealed record ChatConversation(Guid Id, string Title, string ProjectPath, ChatProvider Provider)
{
    public string ProviderTitle => Provider switch
    {
        ChatProvider.Claude => "Claude Code",
        ChatProvider.OpenCode => "OpenCode",
        _ => "Codex"
    };
}

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

        var conversation = new ChatConversation(Guid.NewGuid(), title.Trim(), Path.GetFullPath(projectPath), provider);
        conversations.Add(conversation);
        return conversation;
    }
}
