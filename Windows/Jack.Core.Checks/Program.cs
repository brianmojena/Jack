using Jack.Core;

var workspace = new ChatWorkspace();
var project = Path.GetTempPath();
var first = workspace.CreateConversation("  Revisar Jack  ", project, ChatProvider.Codex);
var second = workspace.CreateConversation("Otra conversación", project, ChatProvider.Claude);
Check(first.Title == "Revisar Jack", "El nombre se normaliza.");
Check(first.ProjectPath == Path.GetFullPath(project), "La ruta se normaliza.");
Check(first.Id != second.Id, "Cada conversación tiene una identidad independiente.");
Check(workspace.Conversations.SequenceEqual([first, second]), "Se conserva el orden de creación.");

Reject<ArgumentException>(() => workspace.CreateConversation(" ", project, ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation(null!, project, ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", " ", ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", null!, ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", ".", ChatProvider.Codex));
Reject<ArgumentException>(() => workspace.CreateConversation("Agente", Path.Combine(project, Guid.NewGuid().ToString()), ChatProvider.Codex));
Reject<ArgumentOutOfRangeException>(() => workspace.CreateConversation("Agente", project, (ChatProvider)999));
Check(workspace.Conversations.Count == 2, "Las entradas inválidas no modifican el espacio de trabajo.");

Jack.Core.Checks.ChatModelsChecks.Run();
Jack.Core.Checks.ArchiveChecks.Run();
Jack.Core.Checks.GitChecks.Run();
Jack.Core.Checks.ParsingChecks.Run();
Jack.Core.Checks.ProcessChecks.Run();
Jack.Core.Checks.ClaudeProtocolChecks.Run();
Jack.Core.Checks.ClaudeDriverChecks.Run();
Jack.Core.Checks.ClaudeSessionsChecks.Run();
Jack.Core.Checks.ChatStoreStateChecks.Run();
Jack.Core.Checks.ChatStoreSendingChecks.Run();
Jack.Core.Checks.ChatStoreSettingsChecks.Run();

Console.WriteLine("Jack.Core: todas las comprobaciones pasaron.");

if (args.Contains("--live-claude")) await Jack.Core.Checks.LiveClaude.RunAsync();
if (args.Contains("--live-store")) await Jack.Core.Checks.LiveClaude.RunStoreAsync();

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
