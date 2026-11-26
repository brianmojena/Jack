using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace Jack.Core;

/// Errores de un proceso estructurado (`ChatProcessError` en Swift).
public enum ChatProcessError
{
    /// El proceso ya no acepta entrada (se cerró stdin, se paró o terminó).
    Closed,
    /// Una línea de salida supera 16 MB.
    LineTooLarge,
}

public sealed class ChatProcessException : Exception
{
    public ChatProcessException(ChatProcessError error)
        : base(error switch
        {
            ChatProcessError.Closed => "El proceso ya no acepta entrada.",
            _ => "Una línea de salida del proceso supera 16 MB.",
        })
    {
        Error = error;
    }

    public ChatProcessError Error { get; }
}

/// Un proceso hijo de una sola vez que intercambia líneas JSON por stdin/stdout. stdout y stderr se drenan en segundo plano,
/// así que un stderr lleno nunca bloquea la salida estructurada.
/// Se lanza sin shell (ProcessStartInfo.ArgumentList): ningún argumento se reinterpreta como comando de cmd.exe.
/// Al cancelar `cancellationToken` o al llamar a Terminate se mata el árbol de procesos completo.
public sealed class StructuredChild : IDisposable
{
    private const int MaxLineBytes = 16 * 1024 * 1024;
    private const int MaxStderrBytes = 64 * 1024;
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    private static readonly JsonSerializerOptions JsonOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly Process _process;
    private readonly Channel<string> _lines = Channel.CreateUnbounded<string>();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly object _stateLock = new();
    private readonly List<byte> _stderr = new();
    private readonly Task _exited;
    private readonly Task _stdoutPump;
    private readonly Task _stderrPump;
    private readonly CancellationTokenRegistration _registration;
    private bool _stopped;
    private bool _inputClosed;

    /// Lanza `executable` con `arguments` en `directory`. `environment` se mezcla sobre `ExecutableResolver.ChildEnvironment()`.
    public StructuredChild(ResolvedExecutable executable, IEnumerable<string> arguments, string directory,
        IReadOnlyDictionary<string, string>? environment = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(executable);

        var startInfo = new ProcessStartInfo
        {
            FileName = executable.FileName,
            WorkingDirectory = directory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = Utf8,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8,
        };
        foreach (var argument in executable.PrefixArguments) startInfo.ArgumentList.Add(argument);
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

        var childEnvironment = ExecutableResolver.ChildEnvironment();
        if (environment is not null)
        {
            foreach (var pair in environment) childEnvironment[pair.Key] = pair.Value;
        }
        startInfo.Environment.Clear();
        foreach (var pair in childEnvironment) startInfo.Environment[pair.Key] = pair.Value;

        _process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        _process.Start();
        _exited = _process.WaitForExitAsync();
        _stdoutPump = PumpLinesAsync(_process.StandardOutput.BaseStream);
        _stderrPump = DrainErrorsAsync(_process.StandardError.BaseStream);
        _registration = cancellationToken.Register(() =>
        {
            // Primero se completa el canal con la cancelación, para que quien lee vea OperationCanceledException y no un fin normal.
            _lines.Writer.TryComplete(new OperationCanceledException(cancellationToken));
            Terminate();
        });
    }

    /// Igual que el constructor anterior, pero el ejecutable llega como ruta. Un .cmd/.bat de npm se sustituye por su destino real
    /// (ExecutableResolver.Unwrap); cualquier otro script que no se pueda lanzar sin shell lanza InvalidOperationException.
    public StructuredChild(string executable, IEnumerable<string> arguments, string directory,
        IReadOnlyDictionary<string, string>? environment = null, CancellationToken cancellationToken = default)
        : this(ExecutableResolver.Unwrap(executable), arguments, directory, environment, cancellationToken)
    {
    }

    /// Líneas de stdout sin el salto de línea (los `\r` finales se conservan, como en Swift). Se puede enumerar una sola vez:
    /// la misma enumeración sirve para el handshake y luego para los turnos (equivale a StructuredLineReader).
    /// Termina cuando el proceso cierra stdout. Si se cancela, lanza OperationCanceledException.
    public IAsyncEnumerable<string> Lines => ReadLinesAsync();

    /// Completa cuando han terminado el proceso y los dos drenajes de salida. Útil para comprobar que no quedan procesos nietos
    /// con la tubería abierta tras una cancelación.
    public Task Completion => Task.WhenAll(_exited, _stdoutPump, _stderrPump);

    /// Escribe `payload` como una línea JSON (claves ordenadas, como `.sortedKeys` en Swift) seguida de `\n`.
    /// Lanza ChatProcessException(Closed) si el proceso ya no acepta entrada.
    public async Task WriteJsonAsync(JsonNode payload, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var bytes = Utf8.GetBytes(SortedKeys(payload)!.ToJsonString(JsonOptions) + "\n");

        await _writeLock.WaitAsync(cancellationToken);
        try
        {
            lock (_stateLock)
            {
                if (_stopped || _inputClosed || _process.HasExited) throw new ChatProcessException(ChatProcessError.Closed);
            }
            var input = _process.StandardInput.BaseStream;
            await input.WriteAsync(bytes, cancellationToken);
            await input.FlushAsync(cancellationToken);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    private readonly object _writeChainLock = new();
    private Task _writeTail = Task.CompletedTask;

    /// Escribe `payload` como `WriteJsonAsync`, pero sin esperar: serializa en el momento (el llamante puede seguir
    /// modificando el objeto), comprueba de inmediato que el proceso acepta entrada y encola la escritura en orden.
    /// Así se puede llamar bajo un candado sin riesgo de interbloqueo con el lector de stdout.
    /// Lanza ChatProcessException(Closed) si el proceso ya no acepta entrada; un fallo posterior de la tubería lo
    /// notifica el fin de la salida estándar.
    public void WriteJson(JsonNode payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var bytes = Utf8.GetBytes(SortedKeys(payload)!.ToJsonString(JsonOptions) + "\n");
        lock (_stateLock)
        {
            if (_stopped || _inputClosed || _process.HasExited) throw new ChatProcessException(ChatProcessError.Closed);
        }
        lock (_writeChainLock) _writeTail = WriteQueuedAsync(_writeTail, bytes);
    }

    private async Task WriteQueuedAsync(Task previous, byte[] bytes)
    {
        try { await previous.ConfigureAwait(false); } catch { }
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (_stateLock)
            {
                if (_stopped || _inputClosed || _process.HasExited) return;
            }
            var input = _process.StandardInput.BaseStream;
            await input.WriteAsync(bytes).ConfigureAwait(false);
            await input.FlushAsync().ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Tubería rota: el proceso terminó; el final de la salida estándar lo comunica al driver.
        }
        finally
        {
            _writeLock.Release();
        }
    }
    /// Cierra stdin. Para CLI de una sola pasada que leen stdin hasta el final antes de arrancar.
    public void CloseInput()
    {
        _writeLock.Wait();
        try
        {
            lock (_stateLock) _inputClosed = true;
            CloseStdin();
        }
        finally
        {
            _writeLock.Release();
        }
    }

    /// Para el proceso: cierra stdin y mata el árbol de procesos (Process.Kill(entireProcessTree: true)).
    /// Es idempotente. No espera a que el proceso muera; para eso está WaitForExitAsync.
    public void Terminate()
    {
        lock (_stateLock)
        {
            if (_stopped) return;
            _stopped = true;
        }
        // No se toma _writeLock aquí: una escritura bloqueada por un hijo que no lee no debe impedir matarlo.
        CloseStdin();
        KillTree();
    }

    /// Espera la salida hasta 2 segundos, como en Swift; si no sale, mata el árbol y espera a que termine.
    public async Task WaitForExitAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await _exited.WaitAsync(TimeSpan.FromSeconds(2), cancellationToken);
        }
        catch (TimeoutException)
        {
            KillTree();
            await _exited.WaitAsync(cancellationToken);
        }
    }

    /// Descripción del fallo: el final de stderr si hay texto; si no, el código de salida; si no, `fallback`.
    public async Task<string> FailureDescriptionAsync(string fallback)
    {
        await WaitForExitAsync();
        // stderr puede seguir drenándose un instante tras la salida; no esperamos más de un segundo.
        await Task.WhenAny(_stderrPump, Task.Delay(TimeSpan.FromSeconds(1)));

        string detail;
        lock (_stateLock) detail = Utf8.GetString(_stderr.ToArray());
        var trimmed = detail.Trim();
        if (trimmed.Length > 0) return trimmed.Length > MaxStderrBytes ? trimmed[^MaxStderrBytes..] : trimmed;
        if (_process.ExitCode != 0) return $"{fallback} (exit {_process.ExitCode}).";
        return fallback;
    }

    public void Dispose()
    {
        Terminate();
        _registration.Dispose();
        _process.Dispose();
    }

    private async IAsyncEnumerable<string> ReadLinesAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await foreach (var line in _lines.Reader.ReadAllAsync(cancellationToken))
        {
            yield return line;
        }
    }

    /// Parte stdout por `\n` sin pasar por StreamReader (que también corta por `\r`), como hace Swift con los bytes.
    private async Task PumpLinesAsync(Stream stream)
    {
        var chunk = new byte[16 * 1024];
        using var pending = new MemoryStream();
        try
        {
            int count;
            while ((count = await stream.ReadAsync(chunk.AsMemory())) > 0)
            {
                var start = 0;
                while (true)
                {
                    var newline = Array.IndexOf(chunk, (byte)'\n', start, count - start);
                    if (newline < 0)
                    {
                        pending.Write(chunk, start, count - start);
                        break;
                    }
                    pending.Write(chunk, start, newline - start);
                    EmitLine(pending);
                    start = newline + 1;
                }
                if (pending.Length > MaxLineBytes) throw new ChatProcessException(ChatProcessError.LineTooLarge);
            }
            if (pending.Length > 0) EmitLine(pending);
            _lines.Writer.TryComplete();
        }
        catch (Exception exception)
        {
            _lines.Writer.TryComplete(exception);
        }
    }

    private void EmitLine(MemoryStream pending)
    {
        if (pending.Length > MaxLineBytes) throw new ChatProcessException(ChatProcessError.LineTooLarge);
        _lines.Writer.TryWrite(Utf8.GetString(pending.GetBuffer(), 0, (int)pending.Length));
        pending.SetLength(0);
    }

    /// Guarda solo los últimos 64 KB de stderr.
    private async Task DrainErrorsAsync(Stream stream)
    {
        var chunk = new byte[4096];
        try
        {
            int count;
            while ((count = await stream.ReadAsync(chunk.AsMemory())) > 0)
            {
                lock (_stateLock)
                {
                    for (var index = 0; index < count; index++) _stderr.Add(chunk[index]);
                    if (_stderr.Count > MaxStderrBytes) _stderr.RemoveRange(0, _stderr.Count - MaxStderrBytes);
                }
            }
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            // El proceso se cerró mientras drenábamos stderr: no hay nada más que guardar.
        }
    }

    private void KillTree()
    {
        try
        {
            if (!_process.HasExited) _process.Kill(entireProcessTree: true);
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Ya terminó entre la comprobación y la llamada.
        }
    }

    private void CloseStdin()
    {
        try
        {
            _process.StandardInput.Close();
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException or InvalidOperationException)
        {
            // stdin ya estaba cerrado o el proceso ya no existe.
        }
    }

    /// Copia del nodo con las claves de cada objeto ordenadas (ordinal), recursivamente.
    private static JsonNode? SortedKeys(JsonNode? node) => node switch
    {
        JsonObject obj => SortedObject(obj),
        JsonArray array => new JsonArray(array.Select(SortedKeys).ToArray()),
        _ => node?.DeepClone(),
    };

    private static JsonObject SortedObject(JsonObject obj)
    {
        var sorted = new JsonObject();
        foreach (var pair in obj.OrderBy(entry => entry.Key, StringComparer.Ordinal))
        {
            sorted[pair.Key] = SortedKeys(pair.Value);
        }
        return sorted;
    }
}
