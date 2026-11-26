using System.Text.Json;
using System.Text.Json.Nodes;
using Jack.Core;

namespace Jack.Core.Checks;

/// Comprobaciones de persistencia: conversaciones, índice y adjuntos, en una carpeta temporal que se borra al final.
public static class ArchiveChecks
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            RunAsync(root).GetAwaiter().GetResult();
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static async Task RunAsync(string root)
    {
        var archiveDirectory = Path.Combine(root, "Chats");
        var archive = new ChatArchive(archiveDirectory);
        var project = Path.Combine(root, "Proyecto");
        var outside = Path.Combine(root, "Adjuntos");
        Directory.CreateDirectory(project);
        Directory.CreateDirectory(outside);

        // Adjuntos: una imagen PNG fuera del proyecto y un archivo dentro del proyecto.
        var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0 };
        var imageSource = Path.Combine(outside, "captura.png");
        var insideSource = Path.Combine(project, "notas.txt");
        await File.WriteAllBytesAsync(imageSource, png);
        await File.WriteAllTextAsync(insideSource, "dentro del proyecto");

        var stored = await ChatAttachments.StoreAsync(png, "png", folder: Path.Combine(root, "Guardados"));
        Check(File.Exists(stored), "StoreAsync crea el archivo.");
        Check(stored.EndsWith(".png", StringComparison.Ordinal), "StoreAsync conserva la extensión.");
        Check(File.ReadAllBytes(stored).SequenceEqual(png), "StoreAsync guarda los bytes tal cual.");
        Check(ChatAttachments.ImageType(stored) == "image/png", "ImageType reconoce el PNG por sus bytes.");
        Check(ChatAttachments.ImageType(insideSource) is null, "ImageType no reconoce un texto como imagen.");

        var persisted = await ChatAttachments.PersistAsync(imageSource, folder: Path.Combine(root, "Copias"));
        Check(persisted != imageSource && File.Exists(persisted), "PersistAsync copia archivos que están en temporales.");
        Check(File.ReadAllBytes(persisted).SequenceEqual(png), "La copia conserva el contenido.");

        // Conversación con el formato Codable de Swift (fechas en segundos desde 2001, UUID en mayúsculas).
        var id = Guid.Parse("6F9619FF-8B86-4D01-B42D-00C04FC964FF");
        var conversation = SwiftConversation(id, project, [imageSource, insideSource]);
        Check(conversation.Title == "Revisar Jack", "La conversación se decodifica con el formato de Swift.");
        Check(conversation.Messages.Count == 2, "Se decodifican los mensajes.");

        // Como en Swift, solo cuenta si el último mensaje es del usuario; aquí el último es del asistente.
        Check(conversation.TurnAttachments.Count == 0, "TurnAttachments está vacío si el último mensaje no es del usuario.");
        var userTurn = conversation with { Messages = [conversation.Messages[0]] };
        var turn = userTurn.TurnAttachments;
        Check(turn.Count == 2 && turn[0] == imageSource, "TurnAttachments devuelve los adjuntos del último mensaje de usuario.");
        var folders = userTurn.AttachmentDirectories;
        Check(folders.Count == 1 && string.Equals(folders[0], outside, StringComparison.OrdinalIgnoreCase),
            "AttachmentDirectories incluye solo las carpetas fuera del proyecto.");

        // Guardar y cargar la transcripción y el índice.
        await archive.SaveAsync(new[] { conversation }, conversation);
        var loaded = await archive.LoadAsync(id);
        Check(loaded is not null, "LoadAsync encuentra la transcripción guardada.");
        Check(loaded!.Id == id && loaded.Title == conversation.Title && loaded.Provider == ChatProvider.Claude, "La transcripción conserva identidad y proveedor.");
        Check(loaded.Messages.Count == 2 && loaded.Messages[0].Text == "Hola", "La transcripción conserva los mensajes.");
        Check(loaded.Messages[0].Attachments?.Count() == 2,"La transcripción conserva los adjuntos del mensaje.");

        var index = await archive.LoadIndexAsync();
        Check(index.Count == 1 && index[0].Id == id, "El índice contiene la conversación.");
        Check(index[0].Messages.Count == 0, "El índice no guarda mensajes, como en Swift.");

        var transcriptFile = Path.Combine(archiveDirectory, id.ToString("D").ToUpperInvariant() + ".json");
        Check(File.Exists(transcriptFile), "La transcripción se guarda como <UUID en mayúsculas>.json.");
        var indexFile = Path.Combine(archiveDirectory, "index.json");
        var indexJson = JsonNode.Parse(File.ReadAllText(indexFile))!.AsArray();
        Check(indexJson[0]!["messages"]!.AsArray().Count == 0, "El índice escrito tiene messages vacío.");
        Check(Math.Abs(indexJson[0]!["updatedAt"]!.GetValue<double>() - 800_000_000.5) < 1e-6,
            "Las fechas se escriben como segundos desde 2001-01-01 UTC.");
        Check(indexJson[0]!["provider"]!.GetValue<string>() == "claude", "Los enums se escriben por rawValue.");
        Check(!Directory.GetFiles(archiveDirectory, "*.tmp").Any(), "No quedan archivos temporales tras guardar.");

        // Borrar una conversación: se elimina su transcripción y el índice queda vacío.
        await archive.SaveAsync(Array.Empty<ChatConversation>(), removedId: id);
        Check(!File.Exists(transcriptFile), "SaveAsync con removedId borra la transcripción.");
        Check(await archive.LoadAsync(id) is null, "Una conversación borrada ya no se carga.");
        Check((await archive.LoadIndexAsync()).Count == 0, "El índice vacío se carga sin entradas.");

        // Carpeta sin índice: lista vacía y sin errores.
        var empty = new ChatArchive(Path.Combine(root, "Vacio"));
        Check((await empty.LoadIndexAsync()).Count == 0, "Sin índice, LoadIndexAsync devuelve una lista vacía.");
    }

    /// Construye una conversación con el mismo JSON que escribe Swift, decodificado con las opciones de SwiftJson.
    private static ChatConversation SwiftConversation(Guid id, string projectPath, string[] attachments)
    {
        var json = new JsonObject
        {
            ["id"] = id.ToString("D").ToUpperInvariant(),
            ["title"] = "Revisar Jack",
            ["projectPath"] = projectPath,
            ["provider"] = "claude",
            ["model"] = "sonnet",
            ["effort"] = "high",
            ["messages"] = new JsonArray
            {
                new JsonObject
                {
                    ["id"] = "m1",
                    ["role"] = "user",
                    ["text"] = "Hola",
                    ["detail"] = "",
                    ["status"] = "",
                    ["attachments"] = new JsonArray(attachments.Select(path => (JsonNode)JsonValue.Create(path)!).ToArray()),
                },
                new JsonObject
                {
                    ["id"] = "m2",
                    ["role"] = "assistant",
                    ["text"] = "Listo",
                    ["detail"] = "",
                    ["status"] = "",
                },
            },
            ["updatedAt"] = JsonValue.Create(800_000_000.5),
        };
        return JsonSerializer.Deserialize<ChatConversation>(json.ToJsonString(), SwiftJson.Options)
            ?? throw new InvalidOperationException("No se pudo decodificar la conversación.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
