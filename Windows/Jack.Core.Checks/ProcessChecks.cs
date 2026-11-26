using System.Text.Json.Nodes;
using Jack.Core;

namespace Jack.Core.Checks;

/// Comprobaciones de ExecutableResolver (shims de npm y resolución de PATH), de StructuredChild (cmd.exe real, stdin,
/// cancelación y parada del árbol de procesos) y de la parte pura de ClaudeModelDetector. No ejecuta `claude`.
public static class ProcessChecks
{
    // Shim `claude.cmd` tal como lo escribe npm (formato cmd-shim): el .exe real está en la línea que reenvía %*.
    private const string ExeShimText = """
        @ECHO off
        GOTO start
        :find_dp0
        SET dp0=%~dp0
        EXIT /b
        :start
        SETLOCAL
        CALL :find_dp0

        IF EXIST "%dp0%\node.exe" (
          SET "_prog=%dp0%\node.exe"
        ) ELSE (
          SET "_prog=node"
          SET PATHEXT=%PATHEXT:;.JS;=;%
        )

        endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%dp0%\node_modules\@anthropic-ai\claude-code\bin\claude.exe"   %*
        """;

    // Shim de un script de Node: la invocación ejecuta "%_prog%" (node) sobre el .js.
    private const string NodeShimText = """
        @ECHO off
        IF EXIST "%dp0%\node.exe" (
          SET "_prog=%dp0%\node.exe"
        ) ELSE (
          SET "_prog=node"
        )
        endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\pkg\cli.js" %*
        """;

    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "jack-process-checks-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            ShimChecks(root);
            ResolveChecks(root);
            ModelDetectorChecks(root);
            ChatProcessChecksAsync().GetAwaiter().GetResult();
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void ShimChecks(string root)
    {
        // Instalación simulada de npm: el .exe real existe; el shim solo lo referencia.
        var npm = Path.Combine(root, "npm");
        var claudeBin = Path.Combine(npm, "node_modules", "@anthropic-ai", "claude-code", "bin");
        Directory.CreateDirectory(claudeBin);
        var exe = Path.Combine(claudeBin, "claude.exe");
        File.WriteAllBytes(exe, []);
        var shim = Path.Combine(npm, "claude.cmd");
        File.WriteAllText(shim, ExeShimText);

        var parsed = ExecutableResolver.ParseNpmShim(ExeShimText, npm);
        Check(parsed is not null && SamePath(parsed.FileName, exe) && parsed.PrefixArguments.Count == 0,
            "El shim .cmd de npm debe resolverse al .exe real que invoca, sin argumentos previos.");
        Check(SamePath(ExecutableResolver.Unwrap(shim).FileName, exe), "Unwrap debe devolver el .exe del shim.");

        // Shim de un script .js: node.exe junto al shim y el script como primer argumento.
        var nodeDirectory = Path.Combine(root, "nodeshim");
        var cliDirectory = Path.Combine(nodeDirectory, "node_modules", "pkg");
        Directory.CreateDirectory(cliDirectory);
        var node = Path.Combine(nodeDirectory, "node.exe");
        File.WriteAllBytes(node, []);
        var cli = Path.Combine(cliDirectory, "cli.js");
        File.WriteAllText(cli, "");
        var nodeParsed = ExecutableResolver.ParseNpmShim(NodeShimText, nodeDirectory);
        Check(nodeParsed is not null && SamePath(nodeParsed.FileName, node)
            && nodeParsed.PrefixArguments.Count == 1 && SamePath(nodeParsed.PrefixArguments[0], cli),
            "Un shim de script .js debe resolverse a node.exe + ruta del script.");

        // Destino inexistente, invocación ausente o .cmd que no es un shim: no se lanza nada.
        Check(ExecutableResolver.ParseNpmShim("@echo off\n\"%dp0%\\no\\existe.exe\" %*", npm) is null,
            "Un shim cuyo destino no existe no debe resolverse.");
        Check(ExecutableResolver.ParseNpmShim("@echo off\n\"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe\"", npm) is null,
            "Sin la invocación con %* no hay destino que resolver.");
        var notShim = Path.Combine(root, "otro.cmd");
        File.WriteAllText(notShim, "@echo hola\r\n");
        Reject<InvalidOperationException>(() => ExecutableResolver.Unwrap(notShim));
    }

    private static void ResolveChecks(string root)
    {
        var npm = Path.Combine(root, "npm");
        var exe = Path.Combine(npm, "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe");
        var shim = Path.Combine(npm, "claude.cmd");

        // Un ejecutable real del sistema: cmd.exe está en System32, que siempre está en el PATH.
        var cmd = ExecutableResolver.Resolve("cmd.exe");
        Check(cmd is not null && File.Exists(cmd.FileName) && cmd.FileName.EndsWith("cmd.exe", StringComparison.OrdinalIgnoreCase),
            "Resolve debe encontrar cmd.exe en el PATH.");

        // Override apuntando a un shim: se devuelve el .exe real, nunca el .cmd.
        var fromOverride = ExecutableResolver.Resolve("no-existe-jack-check", shim);
        Check(fromOverride is not null && SamePath(fromOverride.FileName, exe), "Un override .cmd debe resolverse a su .exe real.");

        // PATH controlado: PATHEXT decide las extensiones y se respeta el orden de las carpetas.
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["PATH"] = npm,
            ["PATHEXT"] = ".COM;.EXE;.BAT;.CMD",
        };
        var fromPath = ExecutableResolver.Resolve("claude", null, environment);
        Check(fromPath is not null && SamePath(fromPath.FileName, exe), "Resolve debe encontrar claude.cmd por PATH y PATHEXT.");
        Check(ExecutableResolver.Resolve("no-existe-jack-check", null, environment) is null, "Un comando inexistente no se resuelve.");
    }

    private static void ModelDetectorChecks(string root)
    {
        // Parseo puro de ids de modelo.
        ParseModelCheck("claude-opus-5-5", "opus", (5, 5, 0));
        ParseModelCheck("claude-sonnet-4-5-20250929", "sonnet", (4, 5, 0));
        ParseModelCheck("claude-fable-5-1", "fable", (5, 1, 0));
        ParseModelCheck("claude-haiku", "haiku", (0, 0, 0));
        ParseModelCheck("gpt-4o", null, (0, 0, 0));

        // Detección sobre un JSONL con una línea cortada al principio (como la cola de un archivo grande).
        var session = Path.Combine(root, "session.jsonl");
        File.WriteAllText(session, string.Join('\n',
            "{\"message\":{\"mo",
            "{\"type\":\"user\"}",
            "{\"message\":{\"model\":\"claude-opus-4-6\"}}",
            "{\"message\":{\"model\":\"claude-opus-5-5\"}}",
            "{\"message\":{\"model\":\"claude-sonnet-4-6\"}}",
            "{\"message\":{\"model\":\"claude-mystery-sonnet\"}}") + "\n");

        var (detected, _) = ClaudeModelDetector.DetectModelsFromFiles([session, Path.Combine(root, "no-existe.jsonl")]);
        Check(detected.Count == 2, $"Deben detectarse 2 familias y hay {detected.Count}.");
        Check(detected[0].Id == "opus" && detected[0].Title == "Opus 5.5", "La versión más alta de opus es 5.5.");
        Check(detected[0].Efforts.Contains("xhigh"), "Opus 5.5 admite el nivel xhigh.");
        Check(detected[1].Id == "sonnet" && detected[1].Title == "Sonnet 4.6" && detected[1].Subtitle == "Equilibrado",
            "Sonnet 4.6 conserva su subtítulo y no lo reemplaza un id sin versión.");
    }

    private static void ParseModelCheck(string id, string? family, (int Major, int Minor, int Patch) version)
    {
        var parsed = ClaudeModelDetector.ParseModelId(id);
        var matches = family is null
            ? parsed is null
            : parsed is not null && parsed.Value.Family == family && parsed.Value.Version == version;
        Check(matches, $"ParseModelId(\"{id}\") no devuelve la familia {family ?? "(ninguna)"} esperada.");
    }

    private static async Task ChatProcessChecksAsync()
    {
        var cmd = ExecutableResolver.Resolve("cmd.exe") ?? throw new InvalidOperationException("No se encuentra cmd.exe.");
        var findstr = ExecutableResolver.Resolve("findstr.exe") ?? throw new InvalidOperationException("No se encuentra findstr.exe.");
        var workdir = Path.GetTempPath();

        // Lectura de líneas de la salida de cmd.exe (sin shell de Jack, con argumentos separados).
        using (var echo = new StructuredChild(cmd, ["/c", "echo", "hola"], workdir))
        {
            var lines = new List<string>();
            await foreach (var line in echo.Lines) lines.Add(line.TrimEnd('\r'));
            Check(lines.Contains("hola"), $"cmd /c echo debe dar la línea 'hola'; salida: {string.Join("|", lines)}");
        }

        // stdin: JSON con claves ordenadas, cierre de stdin, y rechazo de escrituras posteriores.
        using (var sort = new StructuredChild(findstr, ["."], workdir))
        {
            await sort.WriteJsonAsync(new JsonObject { ["b"] = 1, ["a"] = "x" });
            sort.CloseInput();
            var received = new List<string>();
            await foreach (var line in sort.Lines) received.Add(line.TrimEnd('\r'));
            Check(received.Contains("{\"a\":\"x\",\"b\":1}"), $"El JSON debe escribirse con claves ordenadas; salida: {string.Join("|", received)}");
            await RejectAsync<ChatProcessException>(() => sort.WriteJsonAsync(new JsonObject()));
        }

        // Cancelación: el árbol (cmd + ping) debe morir y liberar la tubería de salida.
        using (var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(500)))
        using (var canceled = new StructuredChild(cmd, ["/c", "ping", "-n", "30", "127.0.0.1"], workdir, cancellationToken: cancellation.Token))
        {
            var wasCanceled = false;
            try
            {
                await foreach (var ignored in canceled.Lines) { }
            }
            catch (OperationCanceledException)
            {
                wasCanceled = true;
            }
            Check(wasCanceled, "Cancelar debe lanzar OperationCanceledException al leer las líneas.");
            await WithinAsync(canceled.Completion, "La cancelación debe matar el árbol de procesos (ping incluido).");
        }

        // Parada explícita con Terminate.
        using (var stopped = new StructuredChild(cmd, ["/c", "ping", "-n", "30", "127.0.0.1"], workdir))
        {
            await Task.Delay(300);
            stopped.Terminate();
            await WithinAsync(stopped.Completion, "Terminate debe matar el árbol de procesos.");
        }
    }

    private static async Task WithinAsync(Task task, string message)
    {
        try
        {
            await task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        catch (TimeoutException)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static bool SamePath(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Reject<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Se esperaba {typeof(T).Name}.");
    }

    private static async Task RejectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Se esperaba {typeof(T).Name}.");
    }
}
