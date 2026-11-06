using Jack.Core;

var workspace = new ChatWorkspace();
var project = Path.GetTempPath();
var first = workspace.CreateConversation("  Revisar Jack  ", project, ChatProvider.Codex);
var second = workspace.CreateConversation("Otra conversación", project, ChatProvider.Claude);
Check(first.Title == "Revisar Jack", "El nombre se normaliza.");
Check(first.ProjectPath == Path.GetFullPath(project), "La ruta se normaliza.");
Check(first.Id != second.Id, "Cada conversación tiene una identidad independiente.");
Check(workspace.Conversations.SequenceEqual([first, second]), "Se conserva el orden de creación.");
Check(second.ProviderTitle == "Claude Code", "El proveedor conserva su nombre visible.");
Check(workspace.CreateConversation("Tercera", project, ChatProvider.OpenCode).ProviderTitle == "OpenCode",
    "OpenCode conserva su nombre visible.");
Check(first.ProviderTitle == "Codex", "Codex conserva su nombre visible.");

Reject<ArgumentException>(() => workspace.CreateConversation(" ", project, ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation(null!, project, ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", " ", ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", null!, ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", ".", ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", Path.Combine(project, Guid.NewGuid().ToString()), ChatProvider.Codex));
Reject<ArgumentOutOfRangeException>(() => workspace.CreateConversation("Agente", project, (ChatProvider)999));
Check(workspace.Conversations.Count == 3, "Las entradas inválidas no modifican el espacio de trabajo.");

Console.WriteLine("Jack.Core: todas las comprobaciones pasaron.");

static void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static void Reject<T>(Action action) where T : Exception
{
    try { action(); }
    catch (T) { return; }
    throw new InvalidOperationException($"Se esperaba {typeof(T).Name}.");
}
