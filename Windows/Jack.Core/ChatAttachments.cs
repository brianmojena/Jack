namespace Jack.Core;

/// Archivos que el usuario suelta en una conversación. Todos los agentes reciben sus rutas; las imágenes van también en línea.
public static class ChatAttachments
{
    /// Las imágenes en línea deben caber en el límite de 5 MB de la API una vez codificadas en base64.
    internal const long InlineLimit = 3_750_000;

    /// Dónde guarda Jack los adjuntos que no tienen archivo propio, como imágenes arrastradas como datos.
    public static string Directory => JackDataPaths.ApplicationData("Attachments");

    /// Guarda datos soltados como un archivo que el agente puede abrir. `folder` es opcional (por defecto `Directory`; útil en pruebas).
    public static async Task<string> StoreAsync(byte[] data, string fileExtension, string? folder = null, CancellationToken cancellationToken = default)
    {
        var target = folder ?? Directory;
        System.IO.Directory.CreateDirectory(target);
        var path = Path.Combine(target, Guid.NewGuid().ToString("N")[..8] + "." + fileExtension);
        await AtomicFile.WriteBytesAsync(path, data, cancellationToken);
        return path;
    }

    /// Los archivos en carpetas temporales (p. ej. una captura arrastrada desde su miniatura) pueden desaparecer antes
    /// de que el agente los lea, así que Jack conserva su propia copia. Fuera de temporales devuelve la ruta tal cual.
    public static Task<string> PersistAsync(string path, string? folder = null) =>
        Task.Run(() => Persist(path, folder ?? Directory));

    private static string Persist(string path, string target)
    {
        var full = Path.GetFullPath(path);
        var temporaryRoot = Path.GetFullPath(Path.GetTempPath());
        if (!full.StartsWith(temporaryRoot, StringComparison.OrdinalIgnoreCase)) return full;
        var copyFolder = Path.Combine(target, Guid.NewGuid().ToString("N")[..8]);
        var copy = Path.Combine(copyFolder, Path.GetFileName(full));
        try
        {
            System.IO.Directory.CreateDirectory(copyFolder);
            File.Copy(full, copy);
            return copy;
        }
        catch (IOException)
        {
            return full;
        }
        catch (UnauthorizedAccessException)
        {
            return full;
        }
    }

    /// El tipo real de la imagen, leído de sus primeros bytes, si los proveedores la aceptan en línea.
    public static string? ImageType(string path)
    {
        if (!File.Exists(path)) return null;
        Span<byte> head = stackalloc byte[12];
        int count;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            count = stream.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
        }
        var bytes = head[..count];
        if (StartsWith(bytes, [0x89, 0x50, 0x4E, 0x47])) return "image/png";
        if (StartsWith(bytes, [0xFF, 0xD8, 0xFF])) return "image/jpeg";
        if (StartsWith(bytes, "GIF8"u8)) return "image/gif";
        if (bytes.Length >= 12 && StartsWith(bytes, "RIFF"u8) && bytes.Slice(8, 4).SequenceEqual("WEBP"u8)) return "image/webp";
        return null;
    }

    /// Una imagen lo bastante pequeña para enviarla en línea, con su tipo de medio.
    internal static async Task<(string MediaType, byte[] Data)?> InlineImageAsync(string path)
    {
        if (ImageType(path) is not { } type) return null;
        if (new FileInfo(path).Length > InlineLimit) return null;
        return (type, await File.ReadAllBytesAsync(path));
    }

    /// El mensaje más la ubicación de cada adjunto, para que el agente pueda abrir cualquiera.
    /// `inlineImages` es false para proveedores como Antigravity que solo reciben rutas.
    internal static string PromptText(string prompt, IReadOnlyList<string> attachments, bool inlineImages = true)
    {
        if (attachments.Count == 0) return prompt;
        var list = string.Join("\n", attachments.Select(path => "- " + path));
        var note = inlineImages
            ? "Archivos adjuntos por el usuario (ábrelos desde estas rutas antes de responder sobre ellos; las imágenes también van incluidas en el mensaje):"
            : "Archivos adjuntos por el usuario (ábrelos desde estas rutas antes de responder sobre ellos; las imágenes no se incluyen en el mensaje):";
        return (prompt.Length == 0 ? "" : prompt + "\n\n") + note + "\n" + list;
    }

    private static bool StartsWith(ReadOnlySpan<byte> bytes, ReadOnlySpan<byte> prefix) =>
        bytes.Length >= prefix.Length && bytes[..prefix.Length].SequenceEqual(prefix);
}

/// Extensiones de ChatConversation para adjuntos (equivalente a `extension ChatConversation` en Swift).
public static class ChatConversationAttachments
{
    extension(ChatConversation conversation)
    {
        /// Archivos adjuntos al mensaje que inicia el turno actual.
        public IReadOnlyList<string> TurnAttachments
        {
            get
            {
                var messages = conversation.Messages;
                if (messages.Count == 0) return new List<string>();
                var last = messages[messages.Count - 1];
                if (last.Role != "user") return new List<string>();
                return last.Attachments is { } files ? files.ToList() : new List<string>();
            }
        }

        /// Carpetas con adjuntos del turno que el agente no podría leer de otro modo.
        public IReadOnlyList<string> AttachmentDirectories
        {
            get
            {
                var projectPrefix = conversation.ProjectPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
                // TODO(port): AdditionalDirectories es una extensión de ChatConversation en ChatModels.swift; debe existir en ChatModels.cs.
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { conversation.ProjectPath };
                foreach (var directory in conversation.AdditionalDirectories) seen.Add(directory);

                var folders = new List<string>();
                foreach (var path in conversation.TurnAttachments)
                {
                    string folder;
                    if (System.IO.Directory.Exists(path)) folder = path;
                    else if (File.Exists(path)) folder = Path.GetDirectoryName(path) ?? path;
                    else continue;
                    if (folder.StartsWith(projectPrefix, StringComparison.OrdinalIgnoreCase)) continue;
                    if (seen.Add(folder)) folders.Add(folder);
                }
                return folders;
            }
        }
    }
}
