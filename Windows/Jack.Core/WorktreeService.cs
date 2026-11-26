using System.Text;

namespace Jack.Core;

public sealed record GitWorktree(string Path, string? Branch, string? Head);

public sealed record WorktreeReview(string Branch, string BasePath, string BaseBranch, string BaseCommit, string Head, string Diff)
{
    public bool HasReviewedCommits => Head != BaseCommit;
}

/// Casos de `WorktreeError` de Swift (los datos extra van en el mensaje ya formateado).
public enum WorktreeErrorKind
{
    NotRepository,
    NoCommit,
    NormalOnly,
    InvalidBranch,
    BranchExists,
    DestinationExists,
    InvalidPath,
    UnsafeDestination,
    NotManagedWorktree,
    DirtyBase,
    DirtyWorktree,
    GitStatusFailed,
    DivergedHistory,
    BaseChanged,
    ReviewedHeadChanged,
    ModeChangedDuringIntegration,
    Operation,
    Rollback,
}

/// Error de worktrees. `Message` es el texto en español que mostraría Swift en errorDescription.
public sealed class WorktreeException(WorktreeErrorKind kind, string message) : Exception(message)
{
    public WorktreeErrorKind Kind { get; } = kind;
}

/// Crea worktrees aislados para agentes y guarda su base de integración en la configuración local de Git.
/// Cada invocación de git pasa un vector de argumentos directamente al proceso; no interviene ningún shell.
public static class WorktreeService
{
    private const string NormalOnlyMessage = "Los worktrees de agentes solo están disponibles en el modo Normal.";
    private const string NoCommitMessage = "El repositorio todavía no tiene un commit confirmado (HEAD).";

    /// Crea un worktree en `destination` con la rama nueva `branch`, a partir del HEAD de `sourcePath`.
    /// `normalMode` indica si Jack sigue en modo Normal; se comprueba antes y después de cada paso.
    public static async Task<GitWorktree> CreateAsync(string sourcePath, string branch, string destination, Func<bool> normalMode,
        CancellationToken ct = default)
    {
        EnsureNormal(normalMode);
        if (!IsAbsolute(sourcePath)) throw InvalidPathError(sourcePath);
        if (!IsAbsolute(destination)) throw InvalidPathError(destination);
        var source = CanonicalPath(sourcePath);
        var requestedTarget = Path.GetFullPath(destination);
        var parent = CanonicalPath(Path.GetDirectoryName(requestedTarget) ?? throw InvalidPathError(destination));
        var target = CanonicalPath(Path.Combine(parent, Path.GetFileName(requestedTarget)));
        var sourceRoot = await RepositoryRootAsync(source, normalMode, ct);
        if (IsWithin(target, sourceRoot))
            throw new WorktreeException(WorktreeErrorKind.UnsafeDestination, $"La ruta debe estar fuera de la carpeta del proyecto: {target}");
        if (PathEntryExists(target))
            throw new WorktreeException(WorktreeErrorKind.DestinationExists, $"La ruta de destino ya existe: {target}");

        var check = await RunChecked(["check-ref-format", "--branch", branch], sourceRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!check.Succeeded || check.Output.Trim() != branch)
            throw new WorktreeException(WorktreeErrorKind.InvalidBranch, $"El nombre de rama no es válido: {branch}");

        var exists = await RunChecked(["show-ref", "--verify", "--quiet", $"refs/heads/{branch}"], sourceRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (exists.Status != 1)
        {
            if (exists.Succeeded) throw new WorktreeException(WorktreeErrorKind.BranchExists, $"La rama ya existe: {branch}");
            throw Operation(exists.Message);
        }

        var head = await RunChecked(["rev-parse", "--verify", "HEAD^{commit}"], sourceRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!head.Succeeded) throw new WorktreeException(WorktreeErrorKind.NoCommit, NoCommitMessage);
        var commit = head.Output.Trim();
        var currentBranch = await RunChecked(["symbolic-ref", "--quiet", "--short", "HEAD"], sourceRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        var baseBranch = currentBranch.Succeeded ? currentBranch.Output.Trim() : "(HEAD separado)";

        var keys = MetadataKeys(Encoded(branch));
        foreach (var key in keys)
        {
            var existingMetadata = await RunChecked(["config", "--local", "--get", key], sourceRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
            if (existingMetadata.Status != 1)
                throw Operation("Ya hay metadatos locales para esta rama. Elige otro nombre de rama.");
        }

        EnsureNormal(normalMode);
        var added = await Git.RunAsync(["worktree", "add", "-b", branch, target, commit], sourceRoot, TimeSpan.FromSeconds(120), ct: ct);
        if (!normalMode())
        {
            if (added.Succeeded)
            {
                var cleanup = await RollbackAsync(sourceRoot, target, branch, ct);
                throw new WorktreeException(WorktreeErrorKind.Rollback, JoinLines(NormalOnlyMessage, cleanup));
            }
            throw new WorktreeException(WorktreeErrorKind.NormalOnly, NormalOnlyMessage);
        }
        // Git se encarga de deshacer un `worktree add` fallido. No se tocan rutas ni referencias aquí:
        // otro proceso pudo reclamarlas después de nuestra validación.
        if (!added.Succeeded) throw Operation(added.Message);

        var values = new[] { target, sourceRoot, baseBranch, commit };
        for (var i = 0; i < keys.Count; i++)
        {
            try { EnsureNormal(normalMode); }
            catch (WorktreeException error)
            {
                var extra = await CleanupAfterFailureAsync(sourceRoot, target, branch, keys, ct);
                throw new WorktreeException(WorktreeErrorKind.Rollback, JoinLines(error.Message, extra));
            }
            var result = await Git.RunAsync(["config", "--local", keys[i], values[i]], sourceRoot, TimeSpan.FromSeconds(20), ct: ct);
            if (!normalMode())
            {
                var extra = await CleanupAfterFailureAsync(sourceRoot, target, branch, keys, ct);
                throw new WorktreeException(WorktreeErrorKind.Rollback, JoinLines(NormalOnlyMessage, extra));
            }
            if (!result.Succeeded)
            {
                var extra = await CleanupAfterFailureAsync(sourceRoot, target, branch, keys, ct);
                var details = JoinLines(result.Message, extra);
                throw new WorktreeException(WorktreeErrorKind.Rollback, $"No se pudieron guardar los metadatos del worktree. {details}");
            }
        }
        return new GitWorktree(target, branch, commit);
    }

    /// Revisa los commits del worktree frente a su base registrada. Solo funciona con worktrees creados por Jack.
    public static async Task<WorktreeReview> ReviewAsync(string worktreePath, Func<bool> normalMode, CancellationToken ct = default)
    {
        EnsureNormal(normalMode);
        if (!IsAbsolute(worktreePath)) throw InvalidPathError(worktreePath);
        var path = CanonicalPath(worktreePath);
        var root = await RepositoryRootAsync(path, normalMode, ct);
        var metadata = await ReadMetadataAsync(root, normalMode, ct)
            ?? throw new WorktreeException(WorktreeErrorKind.NotManagedWorktree, "No se encontraron metadatos de worktree creados por Jack.");
        var headResult = await RunChecked(["rev-parse", "--verify", "HEAD^{commit}"], root, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!headResult.Succeeded) throw new WorktreeException(WorktreeErrorKind.NoCommit, NoCommitMessage);
        var head = headResult.Output.Trim();
        if (head != metadata.BaseCommit)
        {
            var ancestor = await RunChecked(["merge-base", "--is-ancestor", metadata.BaseCommit, head], root, TimeSpan.FromSeconds(20), normalMode, ct: ct);
            if (!ancestor.Succeeded) throw DivergedHistoryError();
        }
        var diff = await RunChecked(["diff", "--no-ext-diff", "--no-color", "--no-renames", $"{metadata.BaseCommit}..{head}", "--"],
            root, TimeSpan.FromSeconds(60), normalMode, outputLimit: 500_000, ct: ct);
        if (!diff.Succeeded) throw Operation(diff.Message);
        return new WorktreeReview(metadata.Branch, metadata.BasePath, metadata.BaseBranch, metadata.BaseCommit, head, diff.Output);
    }

    /// Integra solo trabajo confirmado, y solo si la base registrada sigue limpia y sin cambios.
    public static async Task IntegrateAsync(string worktreePath, string reviewedHead, Func<bool> normalMode, CancellationToken ct = default)
    {
        EnsureNormal(normalMode);
        if (!IsAbsolute(worktreePath)) throw InvalidPathError(worktreePath);
        var worktree = CanonicalPath(worktreePath);
        var root = await RepositoryRootAsync(worktree, normalMode, ct);
        var metadata = await ReadMetadataAsync(root, normalMode, ct)
            ?? throw new WorktreeException(WorktreeErrorKind.NotManagedWorktree, "No se encontraron metadatos de worktree creados por Jack.");

        var worktreeStatusResult = await RunChecked(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], root,
            TimeSpan.FromSeconds(30), normalMode, ct: ct);
        if (!worktreeStatusResult.Succeeded) throw GitStatusFailedError(worktreeStatusResult.Message);
        var worktreeStatus = Git.ParseStatus(worktreeStatusResult.Output);
        if (worktreeStatus.Files.Count > 0)
            throw new WorktreeException(WorktreeErrorKind.DirtyWorktree,
                "La rama del agente tiene cambios sin confirmar. Confírmalos o guárdalos y vuelve a revisar antes de integrar. " +
                $"Archivos: {string.Join(", ", worktreeStatus.Files.Select(f => f.Path))}");

        var worktreeHeadResult = await RunChecked(["rev-parse", "--verify", "HEAD^{commit}"], root, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!worktreeHeadResult.Succeeded) throw new WorktreeException(WorktreeErrorKind.NoCommit, NoCommitMessage);
        var worktreeHead = worktreeHeadResult.Output.Trim();
        if (worktreeHead != reviewedHead)
            throw new WorktreeException(WorktreeErrorKind.ReviewedHeadChanged,
                $"La rama del agente cambió después de la revisión (revisado {Prefix10(reviewedHead)}, actual {Prefix10(worktreeHead)}). Vuelve a revisar el diff antes de integrar.");
        var reviewedCommit = await RunChecked(["rev-parse", "--verify", $"{reviewedHead}^{{commit}}"], root, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!reviewedCommit.Succeeded || reviewedCommit.Output.Trim() != reviewedHead)
            throw Operation("El HEAD revisado ya no es un commit válido. Vuelve a revisar el diff.");

        var baseRoot = metadata.BasePath;
        var baseBranchResult = await RunChecked(["symbolic-ref", "--quiet", "--short", "HEAD"], baseRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        var currentBranch = baseBranchResult.Succeeded ? baseBranchResult.Output.Trim() : "(HEAD separado)";
        if (currentBranch != metadata.BaseBranch)
            throw Operation($"La carpeta base ya no está en la rama {metadata.BaseBranch}. Está en {currentBranch}. Revisa el diff e integra manualmente con fast-forward.");

        var statusResult = await RunChecked(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], baseRoot,
            TimeSpan.FromSeconds(30), normalMode, ct: ct);
        if (!statusResult.Succeeded) throw GitStatusFailedError(statusResult.Message);
        var status = Git.ParseStatus(statusResult.Output);
        if (!status.IsRepository) throw new WorktreeException(WorktreeErrorKind.NotRepository, $"La carpeta no es un repositorio Git: {baseRoot}");
        if (status.Files.Count > 0)
            throw new WorktreeException(WorktreeErrorKind.DirtyBase,
                "La carpeta base tiene cambios locales. Confírmalos o guárdalos antes de integrar. " +
                $"Archivos: {string.Join(", ", status.Files.Select(f => f.Path))}");
        var baseHead = await RunChecked(["rev-parse", "--verify", "HEAD^{commit}"], baseRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!baseHead.Succeeded) throw new WorktreeException(WorktreeErrorKind.NoCommit, NoCommitMessage);
        var actual = baseHead.Output.Trim();
        if (actual != metadata.BaseCommit)
            throw new WorktreeException(WorktreeErrorKind.BaseChanged,
                $"La rama base cambió desde que se creó este worktree (base guardada {Prefix10(metadata.BaseCommit)}, actual {Prefix10(actual)}). Revisa los cambios antes de integrar.");
        if (reviewedHead != metadata.BaseCommit)
        {
            var ancestor = await RunChecked(["merge-base", "--is-ancestor", metadata.BaseCommit, reviewedHead], root, TimeSpan.FromSeconds(20), normalMode, ct: ct);
            if (!ancestor.Succeeded) throw DivergedHistoryError();
        }

        EnsureNormal(normalMode);
        var merged = await Git.RunAsync(["merge", "--ff-only", reviewedHead], baseRoot, TimeSpan.FromSeconds(120), ct: ct);
        if (!normalMode()) throw new WorktreeException(WorktreeErrorKind.ModeChangedDuringIntegration, ModeChangedMessage);
        if (!merged.Succeeded)
            throw Operation($"No se pudo integrar con fast-forward. No se aplicaron cambios a la base. {merged.Message}");

        GitResult updatedBase;
        try
        {
            updatedBase = await RunChecked(["rev-parse", "--verify", "HEAD^{commit}"], baseRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        }
        catch (WorktreeException error) when (error.Kind == WorktreeErrorKind.NormalOnly)
        {
            throw new WorktreeException(WorktreeErrorKind.ModeChangedDuringIntegration, ModeChangedMessage);
        }
        if (!updatedBase.Succeeded)
            throw Operation("Los commits se integraron, pero no se pudo leer el nuevo HEAD de la base.");

        var metadataKey = MetadataKeys(Encoded(metadata.Branch))[3];
        GitResult savedBase;
        try
        {
            savedBase = await RunChecked(["config", "--local", metadataKey, updatedBase.Output.Trim()], baseRoot, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        }
        catch (WorktreeException error) when (error.Kind == WorktreeErrorKind.NormalOnly)
        {
            throw new WorktreeException(WorktreeErrorKind.ModeChangedDuringIntegration, ModeChangedMessage);
        }
        if (!savedBase.Succeeded)
            throw Operation($"Los commits se integraron, pero no se pudo actualizar el metadato de base: {savedBase.Message}");
    }

    /// Elimina el worktree y la rama creados tras un fallo al crear el agente. Nunca fuerza nada.
    public static async Task RollbackCreatedAsync(GitWorktree worktree, string sourcePath, CancellationToken ct = default)
    {
        var rootResult = await Git.RunAsync(["rev-parse", "--show-toplevel"], CanonicalPath(sourcePath), TimeSpan.FromSeconds(20), ct: ct);
        if (!rootResult.Succeeded) throw new WorktreeException(WorktreeErrorKind.NotRepository, $"La carpeta no es un repositorio Git: {sourcePath}");
        var source = CanonicalPath(rootResult.Output.Trim());
        if (worktree.Branch is not { } branch)
            throw new WorktreeException(WorktreeErrorKind.Rollback, "No se puede verificar la rama creada.");

        var keys = MetadataKeys(Encoded(branch));
        var values = new List<string>();
        foreach (var key in keys)
        {
            var result = await Git.RunAsync(["config", "--local", "--get", key], source, TimeSpan.FromSeconds(15), ct: ct);
            if (!result.Succeeded)
                throw new WorktreeException(WorktreeErrorKind.Rollback, "No se encontraron metadatos verificables para retirar este worktree.");
            values.Add(result.Output.Trim());
        }
        if (values.Count != 4) throw new WorktreeException(WorktreeErrorKind.Rollback, "Los metadatos del worktree están incompletos.");

        var path = CanonicalPath(worktree.Path);
        var recordedPath = CanonicalPath(values[0]);
        if (!PathEquals(path, recordedPath) || !PathEquals(source, CanonicalPath(values[1])))
            throw new WorktreeException(WorktreeErrorKind.Rollback, "La ruta o el repositorio no coinciden con el worktree creado por Jack.");

        var worktreeRoot = await Git.RunAsync(["rev-parse", "--show-toplevel"], recordedPath, TimeSpan.FromSeconds(20), ct: ct);
        var worktreeBranch = await Git.RunAsync(["symbolic-ref", "--quiet", "--short", "HEAD"], recordedPath, TimeSpan.FromSeconds(20), ct: ct);
        if (!worktreeRoot.Succeeded || !worktreeBranch.Succeeded
            || !PathEquals(CanonicalPath(worktreeRoot.Output.Trim()), recordedPath)
            || worktreeBranch.Output.Trim() != branch)
        {
            throw new WorktreeException(WorktreeErrorKind.Rollback, "La ruta ya no apunta a la rama worktree creada por Jack.");
        }

        var cleanupError = await RollbackAsync(source, recordedPath, branch, ct);
        if (cleanupError.Length > 0) throw new WorktreeException(WorktreeErrorKind.Rollback, cleanupError);
        var metadataError = await RemoveMetadataAsync(keys, source, ct);
        if (metadataError.Length > 0) throw new WorktreeException(WorktreeErrorKind.Rollback, metadataError);
    }

    private sealed record Metadata(string WorktreePath, string BasePath, string BaseBranch, string BaseCommit, string Branch);

    private static async Task<Metadata?> ReadMetadataAsync(string worktreePath, Func<bool> normalMode, CancellationToken ct)
    {
        var branchResult = await RunChecked(["symbolic-ref", "--quiet", "--short", "HEAD"], worktreePath, TimeSpan.FromSeconds(15), normalMode, ct: ct);
        if (!branchResult.Succeeded) return null;
        var branch = branchResult.Output.Trim();
        var keys = MetadataKeys(Encoded(branch));
        var values = new List<string>();
        foreach (var key in keys)
        {
            var result = await RunChecked(["config", "--local", "--get", key], worktreePath, TimeSpan.FromSeconds(15), normalMode, ct: ct);
            if (!result.Succeeded) return null;
            values.Add(result.Output.Trim());
        }
        if (values.Count != 4 || !PathEquals(CanonicalPath(values[0]), CanonicalPath(worktreePath))) return null;
        var worktreeCommon = await CommonDirectoryAsync(worktreePath, normalMode, ct);
        var baseCommon = await CommonDirectoryAsync(values[1], normalMode, ct);
        if (worktreeCommon is null || baseCommon is null || !PathEquals(worktreeCommon, baseCommon)) return null;
        return new Metadata(values[0], values[1], values[2], values[3], branch);
    }

    private static async Task<string?> CommonDirectoryAsync(string root, Func<bool> normalMode, CancellationToken ct)
    {
        var result = await RunChecked(["rev-parse", "--git-common-dir"], root, TimeSpan.FromSeconds(15), normalMode, ct: ct);
        if (!result.Succeeded) return null;
        // Git puede devolver una ruta relativa a `root`; Path.GetFullPath la resuelve contra esa carpeta.
        return CanonicalPath(Path.GetFullPath(result.Output.Trim(), root));
    }

    private static async Task<string> RepositoryRootAsync(string path, Func<bool> normalMode, CancellationToken ct)
    {
        var result = await RunChecked(["rev-parse", "--show-toplevel"], path, TimeSpan.FromSeconds(20), normalMode, ct: ct);
        if (!result.Succeeded) throw new WorktreeException(WorktreeErrorKind.NotRepository, $"La carpeta no es un repositorio Git: {path}");
        // git devuelve barras normales en Windows (C:/...); CanonicalPath las pasa a barras invertidas.
        return CanonicalPath(result.Output.Trim());
    }

    private static IReadOnlyList<string> MetadataKeys(string id) =>
    [
        $"jack.worktree.{id}.path",
        $"jack.worktree.{id}.basepath",
        $"jack.worktree.{id}.basebranch",
        $"jack.worktree.{id}.basecommit",
    ];

    /// Codifica el nombre de la rama en hexadecimal (UTF-8, minúsculas), como `%02x` de Swift.
    private static string Encoded(string value) => Convert.ToHexString(Encoding.UTF8.GetBytes(value)).ToLowerInvariant();

    /// Borra las claves de metadatos. Devuelve los fallos unidos con "; " (vacío si todo fue bien).
    private static async Task<string> RemoveMetadataAsync(IReadOnlyList<string> keys, string directory, CancellationToken ct)
    {
        var failures = new List<string>();
        foreach (var key in keys)
        {
            var result = await Git.RunAsync(["config", "--local", "--unset-all", key], directory, TimeSpan.FromSeconds(15), ct: ct);
            // Código 5: la clave no existía.
            if (!result.Succeeded && result.Status != 5) failures.Add(result.Message);
        }
        return string.Join("; ", failures);
    }

    /// Retira el worktree y la rama. Devuelve los fallos unidos con "; " (vacío si todo fue bien).
    private static async Task<string> RollbackAsync(string source, string path, string branch, CancellationToken ct)
    {
        var failures = new List<string>();
        if (PathEntryExists(path))
        {
            var removed = await Git.RunAsync(["worktree", "remove", path], source, TimeSpan.FromSeconds(60), ct: ct);
            if (!removed.Succeeded) failures.Add(removed.Message);
        }
        var exists = await Git.RunAsync(["show-ref", "--verify", "--quiet", $"refs/heads/{branch}"], source, TimeSpan.FromSeconds(15), ct: ct);
        if (exists.Succeeded)
        {
            var deleted = await Git.RunAsync(["branch", "-d", branch], source, TimeSpan.FromSeconds(20), ct: ct);
            if (!deleted.Succeeded) failures.Add(deleted.Message);
        }
        return string.Join("; ", failures);
    }

    /// Tras un fallo a mitad de la creación: deshace el worktree y, si eso salió bien, también los metadatos.
    private static async Task<string> CleanupAfterFailureAsync(string sourceRoot, string target, string branch, IReadOnlyList<string> keys, CancellationToken ct)
    {
        var cleanup = await RollbackAsync(sourceRoot, target, branch, ct);
        var metadataCleanup = cleanup.Length == 0 ? await RemoveMetadataAsync(keys, sourceRoot, ct) : "";
        return JoinLines(metadataCleanup, cleanup);
    }

    private static void EnsureNormal(Func<bool> normalMode)
    {
        if (!normalMode()) throw new WorktreeException(WorktreeErrorKind.NormalOnly, NormalOnlyMessage);
    }

    /// Ejecuta git comprobando el modo antes y después. Solo lanza si el modo cambió o si la ejecución se canceló.
    private static async Task<GitResult> RunChecked(IReadOnlyList<string> arguments, string directory, TimeSpan timeout,
        Func<bool> normalMode, int? outputLimit = null, CancellationToken ct = default)
    {
        EnsureNormal(normalMode);
        var result = await Git.RunAsync(arguments, directory, timeout, outputLimit: outputLimit, ct: ct);
        EnsureNormal(normalMode);
        return result;
    }

    private static bool IsAbsolute(string path) => Path.IsPathFullyQualified(path);

    /// Ruta canónica para comparar: absoluta, con barras de Windows y sin separador final.
    /// TODO(port): Swift también resuelve enlaces simbólicos (resolvingSymlinksInPath); aquí no se hace todavía.
    internal static string CanonicalPath(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full) ?? "";
        return full.Length > root.Length ? full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) : full;
    }

    private static bool PathEquals(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    private static bool IsWithin(string child, string parent)
    {
        if (PathEquals(child, parent)) return true;
        var prefix = parent.EndsWith(Path.DirectorySeparatorChar) ? parent : parent + Path.DirectorySeparatorChar;
        return child.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static bool PathEntryExists(string path) => File.Exists(path) || Directory.Exists(path);

    private static string JoinLines(params string[] parts) => string.Join("\n", parts.Where(part => part.Length > 0));

    private static string Prefix10(string value) => value.Length > 10 ? value[..10] : value;

    private const string ModeChangedMessage = "Jack cambió a Light mientras Git integraba. Comprueba la rama base antes de repetir la acción.";

    private static WorktreeException InvalidPathError(string path) =>
        new(WorktreeErrorKind.InvalidPath, $"La ruta debe ser absoluta: {path}");

    private static WorktreeException Operation(string message) => new(WorktreeErrorKind.Operation, message);

    private static WorktreeException DivergedHistoryError() =>
        new(WorktreeErrorKind.DivergedHistory,
            "La rama del agente ya no desciende de la base revisada. Revisa ambas historias e intégralas manualmente; Jack no puede hacer fast-forward seguro.");

    private static WorktreeException GitStatusFailedError(string message) =>
        new(WorktreeErrorKind.GitStatusFailed,
            $"No se pudo comprobar el estado de Git; no se puede confirmar que la carpeta esté limpia. {message}");
}
