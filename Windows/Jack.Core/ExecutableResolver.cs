using System.Collections;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Jack.Core;

/// Ejecutable listo para lanzar sin shell: el archivo y los argumentos que van antes de los del usuario.
/// Si un shim de npm apunta a un script (.js/.cjs/.mjs), FileName es node.exe y PrefixArguments contiene la ruta del script.
public sealed record ResolvedExecutable(string FileName, IReadOnlyList<string> PrefixArguments);

/// Encuentra las CLI de los agentes (claude, codex, opencode, ...) en Windows y arma el entorno de los procesos hijos.
/// En Swift el PATH venía del shell de login (`-ilc`) y de rutas de macOS (Homebrew, sockets); aquí viene del PATH del proceso,
/// del PATH de usuario y de máquina (registro) y de las carpetas habituales de npm, Node y instaladores.
/// Un `.cmd` de npm nunca se lanza con Process: se lee el shim y se devuelve el .exe (o node.exe + script) al que apunta.
public static class ExecutableResolver
{
    private static readonly string[] ExecutableExtensions = [".exe", ".com", ".cmd", ".bat"];
    private static readonly string[] ScriptExtensions = [".js", ".cjs", ".mjs"];
    private static readonly string[] ShimExtensions = [".cmd", ".bat"];

    // Línea de invocación del shim de npm: `"%dp0%\ruta\relativa.exe" %*`.
    private static readonly Regex ShimTargetPattern = new(@"""%dp0%\\([^""]+)""", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // TODO(port): DefaultSocketPath (~/.config/herdr/herdr.sock) es de herdr/terminal (TerminalInterfaceView); no se porta en Jack.Core.

    /// Busca `command` en el PATH del proceso, de usuario y de máquina, y en las carpetas de instalación habituales.
    /// `overridePath` (ruta configurada por el usuario) tiene prioridad si existe. Devuelve null si no hay un ejecutable seguro que lanzar.
    public static ResolvedExecutable? Resolve(string command, string? overridePath = null) =>
        Resolve(command, overridePath, ChildEnvironment());

    /// Igual que Resolve, pero reescanea el PATH de la sesión de usuario en cada llamada, así que encuentra
    /// una CLI instalada mientras Jack ya estaba abierto. En Swift esto evitaba la caché del shell de login; aquí no hay caché.
    public static ResolvedExecutable? Scan(string command, string? overridePath = null) =>
        Resolve(command, overridePath, ChildEnvironment());

    /// El entorno se pasa explícitamente para poder probar PATH distintos sin cambiar la instalación del usuario.
    public static ResolvedExecutable? Resolve(string command, string? overridePath, IReadOnlyDictionary<string, string> environment)
    {
        if (!string.IsNullOrEmpty(overridePath))
        {
            var path = ExpandTilde(overridePath);
            if (IsExecutableFile(path) && TryUnwrap(path, environment) is { } fromOverride) return fromOverride;
        }

        foreach (var candidate in CandidatePaths(command, environment))
        {
            if (!IsExecutableFile(candidate)) continue;
            if (TryUnwrap(candidate, environment) is { } resolved) return resolved;
        }
        return null;
    }

    /// Convierte una ruta a algo que se puede lanzar con ProcessStartInfo sin shell.
    /// Un .exe se devuelve tal cual; un shim .cmd/.bat de npm se sustituye por su destino real. Lanza si no es un shim reconocible.
    public static ResolvedExecutable Unwrap(string executable, IReadOnlyDictionary<string, string>? environment = null)
    {
        var path = Path.IsPathRooted(executable) ? executable : FindOnPath(executable, environment) ?? executable;
        return TryUnwrap(path, environment)
            ?? throw new InvalidOperationException($"No se puede lanzar \"{executable}\" sin shell: no es un shim de npm reconocible o su destino no existe.");
    }

    /// Entorno de los procesos hijos: el del proceso (sin variables HERDR_) con PATH ampliado con las rutas del usuario y de máquina.
    public static Dictionary<string, string> ChildEnvironment() =>
        SanitizedChildEnvironment(ProcessEnvironment(), LoginShellPaths());

    /// Interpreta el texto de un shim de npm (`claude.cmd`). Devuelve el .exe real o node.exe + script; null si no reconoce el formato
    /// o si el destino no existe. No ejecuta nada: solo lee texto.
    public static ResolvedExecutable? ParseNpmShim(string shimText, string shimDirectory, IReadOnlyDictionary<string, string>? environment = null)
    {
        var directory = Path.TrimEndingDirectorySeparator(shimDirectory);
        foreach (var line in shimText.Split('\n'))
        {
            // Solo la línea que reenvía los argumentos (`%*`) es la invocación real; las demás (IF EXIST, SET) no cuentan.
            if (!line.Contains("%*", StringComparison.Ordinal)) continue;

            var targets = ShimTargetPattern.Matches(line)
                .Select(match => Path.GetFullPath(Path.Combine(directory, match.Groups[1].Value)))
                .ToList();

            var nodeOnLine = targets.FirstOrDefault(IsNodeExecutable);
            var program = targets.FirstOrDefault(target => HasExtension(target, [".exe"]) && !IsNodeExecutable(target));
            if (program is not null) return File.Exists(program) ? new ResolvedExecutable(program, []) : null;

            var script = targets.FirstOrDefault(target => HasExtension(target, ScriptExtensions));
            if (script is null) continue;
            if (!File.Exists(script)) return null;

            // Como el shim de npm: node.exe junto al shim si existe; si no, el node del PATH.
            var localNode = Path.Combine(directory, "node.exe");
            var node = nodeOnLine ?? (File.Exists(localNode) ? localNode : FindOnPath("node.exe", environment));
            if (node is null || !File.Exists(node)) return null;
            return new ResolvedExecutable(node, [script]);
        }
        return null;
    }

    /// Busca un archivo en las carpetas del PATH (sin extensión adicional). Con `environment` nulo usa el PATH del proceso.
    public static string? FindOnPath(string fileName, IReadOnlyDictionary<string, string>? environment = null)
    {
        var pathValue = environment is not null ? environment.GetValueOrDefault("PATH") : Environment.GetEnvironmentVariable("PATH");
        foreach (var directory in SplitPath(pathValue))
        {
            var candidate = Path.Combine(directory, fileName);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// Carpetas de instalación de usuario que existen: npm global, instalador nativo de Claude, Node, pnpm, Bun, Volta y similares.
    /// `environment` son las variables de entorno del proceso (USERPROFILE, APPDATA, LOCALAPPDATA, NVM_HOME, ...).
    public static IReadOnlyList<string> InstalledUserPaths(string home, IReadOnlyDictionary<string, string> environment)
    {
        string Variable(string name) => environment.TryGetValue(name, out var value) ? value : "";
        string? Join(string root, string part) => string.IsNullOrWhiteSpace(root) ? null : Path.Combine(root, part);

        var appData = NonEmpty(Variable("APPDATA")) ?? Path.Combine(home, "AppData", "Roaming");
        var localAppData = NonEmpty(Variable("LOCALAPPDATA")) ?? Path.Combine(home, "AppData", "Local");
        var programFiles = NonEmpty(Variable("ProgramFiles")) ?? @"C:\Program Files";
        var programsRoot = Path.Combine(localAppData, "Programs");

        var candidates = new List<string?>
        {
            Path.Combine(home, ".local", "bin"),           // instalador nativo de Claude Code (%USERPROFILE%\.local\bin)
            Path.Combine(home, ".claude", "local"),
            Path.Combine(home, ".claude", "bin"),
            Path.Combine(home, ".opencode", "bin"),
            Path.Combine(home, ".bun", "bin"),
            Path.Combine(home, ".volta", "bin"),
            Path.Combine(home, ".cargo", "bin"),
            Path.Combine(home, ".deno", "bin"),
            Path.Combine(appData, "npm"),                  // prefijo global de npm en Windows (donde está claude.cmd)
            Path.Combine(localAppData, "pnpm"),
            Path.Combine(programFiles, "nodejs"),
            NonEmpty(Variable("PNPM_HOME")),
            NonEmpty(Variable("NPM_CONFIG_PREFIX")),
            NonEmpty(Variable("npm_config_prefix")),
            NonEmpty(Variable("NVM_SYMLINK")),
            Join(Variable("VOLTA_HOME"), "bin"),
            Join(Variable("BUN_INSTALL"), "bin"),
            programsRoot,
        };
        candidates.AddRange(SubDirectories(programsRoot));

        // Versiones de Node instaladas con nvm-windows (una carpeta por versión, node.exe directo) y con fnm (installation\).
        var nvmHome = NonEmpty(Variable("NVM_HOME")) ?? Path.Combine(appData, "nvm");
        var fnmRoot = Path.Combine(NonEmpty(Variable("FNM_DIR")) ?? Path.Combine(localAppData, "fnm"), "node-versions");
        candidates.AddRange(VersionDirectories(nvmHome, null));
        candidates.AddRange(VersionDirectories(fnmRoot, "installation"));

        return OrderedUnique(candidates.Where(path => path is not null && Directory.Exists(path)).Select(path => path!));
    }

    private static IEnumerable<string> CandidatePaths(string command, IReadOnlyDictionary<string, string> environment)
    {
        var names = NameVariants(command, environment);
        if (Path.IsPathRooted(command) || command.Contains('\\') || command.Contains('/'))
        {
            foreach (var name in names) yield return name;
            yield break;
        }

        // Como cmd.exe: cada carpeta del PATH en orden y dentro de cada una, las extensiones de PATHEXT en su orden.
        foreach (var directory in SplitPath(environment.GetValueOrDefault("PATH")))
        {
            foreach (var name in names) yield return Path.Combine(directory, name);
        }
    }

    private static List<string> NameVariants(string command, IReadOnlyDictionary<string, string> environment)
    {
        if (Path.HasExtension(command)) return [command];

        var extensions = (environment.GetValueOrDefault("PATHEXT") ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(extension => ExecutableExtensions.Contains(extension, StringComparer.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (extensions.Count == 0) extensions = [".EXE", ".COM", ".CMD", ".BAT"];
        return extensions.Select(extension => command + extension).ToList();
    }

    /// Un .exe se devuelve tal cual; un .cmd/.bat se lee como shim de npm. Null si es un script que no se puede lanzar sin shell.
    private static ResolvedExecutable? TryUnwrap(string path, IReadOnlyDictionary<string, string>? environment)
    {
        if (!HasExtension(path, ShimExtensions)) return new ResolvedExecutable(path, []);

        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        return ParseNpmShim(text, Path.GetDirectoryName(path) ?? ".", environment);
    }

    private static bool IsExecutableFile(string path) =>
        File.Exists(path) && HasExtension(path, ExecutableExtensions);

    private static bool HasExtension(string path, string[] extensions) =>
        extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    private static bool IsNodeExecutable(string path) =>
        Path.GetFileName(path).Equals("node.exe", StringComparison.OrdinalIgnoreCase);

    private static string ExpandTilde(string path)
    {
        if (!path.StartsWith('~')) return path;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, path[1..].TrimStart('/', '\\'));
    }

    private static Dictionary<string, string> ProcessEnvironment()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            if (entry.Key is string key && entry.Value is string value) result[key] = value;
        }
        return result;
    }

    /// PATH de usuario y de máquina tal como los guarda Windows (en el registro). Se lee en cada llamada: es barato
    /// y así una instalación nueva se ve sin reiniciar Jack.
    private static List<string> LoginShellPaths()
    {
        var paths = new List<string>();
        paths.AddRange(SplitPath(Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User)));
        paths.AddRange(SplitPath(Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine)));
        return paths;
    }

    private static Dictionary<string, string> SanitizedChildEnvironment(IReadOnlyDictionary<string, string> source, IEnumerable<string> loginShellPaths)
    {
        var environment = new Dictionary<string, string>(source, StringComparer.OrdinalIgnoreCase);
        foreach (var key in environment.Keys.Where(key => key.StartsWith("HERDR_", StringComparison.Ordinal)).ToList())
        {
            environment.Remove(key);
        }

        var home = NonEmpty(environment.GetValueOrDefault("USERPROFILE")) ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var existing = SplitPath(environment.GetValueOrDefault("PATH"));
        var installed = InstalledUserPaths(home, environment);
        environment["PATH"] = string.Join(';', OrderedUnique(existing.Concat(loginShellPaths).Concat(installed)));
        return environment;
    }

    private static IEnumerable<string> SplitPath(string? value) =>
        (value ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(entry => Environment.ExpandEnvironmentVariables(entry.Trim('"')))
            .Where(entry => entry.Length > 0);

    private static IEnumerable<string> SubDirectories(string root)
    {
        try
        {
            return Directory.Exists(root) ? Directory.GetDirectories(root).OrderBy(path => path, StringComparer.OrdinalIgnoreCase).ToList() : [];
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// Carpetas de versión dentro de `root`, de la más nueva a la más antigua (orden numérico, como `compare(options: .numeric)` en Swift).
    private static IEnumerable<string> VersionDirectories(string root, string? subPath)
    {
        var numeric = Comparer<string>.Create((left, right) =>
            string.Compare(left, right, CultureInfo.InvariantCulture, CompareOptions.NumericOrdering));
        return SubDirectories(root)
            .OrderByDescending(directory => Path.GetFileName(directory), numeric)
            .Select(directory => subPath is null ? directory : Path.Combine(directory, subPath))
            .ToList();
    }

    private static List<string> OrderedUnique(IEnumerable<string> values)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var value in values)
        {
            var trimmed = Path.TrimEndingDirectorySeparator(value);
            if (trimmed.Length > 0 && seen.Add(trimmed)) result.Add(trimmed);
        }
        return result;
    }

    private static string? NonEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
}
