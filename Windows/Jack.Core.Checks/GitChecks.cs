using System.Text;
using System.Text.Json;
using Jack.Core;

namespace Jack.Core.Checks;

/// Comprobaciones del parseo de Git con texto de ejemplo (sin repositorio real).
public static class GitChecks
{
    public static void Run()
    {
        ParseStatusChecks();
        ParseLogChecks();
        ParseBranchChecks();
        GitResultChecks();
        CommitMessageChecks();
        EvidenceChecks();
    }

    private static void ParseStatusChecks()
    {
        // Salida de `git status --porcelain=v2 --branch -z`: cada entrada termina en NUL.
        const string sample =
            "# branch.oid 0123456789abcdef0123456789abcdef01234567\0" +
            "# branch.head main\0" +
            "# branch.upstream origin/main\0" +
            "# branch.ab +2 -1\0" +
            "1 .M N... 100644 100644 100644 1111111 1111111 src/a.cs\0" +
            "1 M. N... 100644 100644 100644 1111111 2222222 src/con espacio.cs\0" +
            "2 R. N... 100644 100644 100644 1111111 2222222 R100 new name.cs\0" +
            "old name.cs\0" +
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflicto.cs\0" +
            "? untracked.txt\0";

        var status = Git.ParseStatus(sample);
        Check(status.IsRepository, "La salida de status describe un repositorio.");
        Check(status.Branch == "main", "La rama se lee de branch.head.");
        Check(status.Head == "0123456", "El HEAD se acorta a 7 caracteres.");
        Check(status.Upstream == "origin/main", "El upstream se lee de branch.upstream.");
        Check(status.Ahead == 2 && status.Behind == 1, "Ahead y behind se leen de branch.ab.");
        Check(status.Files.Count == 5, "Se leen los cinco archivos de la salida.");

        Check(status.Files[0].Path == "src/a.cs" && status.Files[0].Staged is null && status.Files[0].Unstaged == 'M',
            "Un cambio solo en el árbol de trabajo tiene estado sin preparar.");
        Check(status.Files[1].Path == "src/con espacio.cs" && status.Files[1].Staged == 'M' && status.Files[1].Unstaged is null,
            "Una ruta con espacios se conserva entera y un cambio preparado no tiene estado sin preparar.");
        Check(status.Files[2].Path == "new name.cs" && status.Files[2].OriginalPath == "old name.cs" && status.Files[2].Staged == 'R',
            "Un renombre toma la ruta original de la siguiente entrada NUL.");
        Check(status.Files[3].Path == "conflicto.cs" && status.Files[3].Conflicted,
            "Una entrada 'u' es un conflicto.");
        Check(status.Files[4].Path == "untracked.txt" && status.Files[4].Untracked,
            "Una entrada '?' es un archivo sin seguimiento.");

        Check(status.Staged.Select(f => f.Path).SequenceEqual(new[] { "src/con espacio.cs", "new name.cs" }),
            "Staged incluye los cambios preparados y no los conflictos.");
        Check(status.Unstaged.Select(f => f.Path).SequenceEqual(new[] { "src/a.cs", "untracked.txt" }),
            "Unstaged incluye los cambios sin preparar y los archivos sin seguimiento.");
        Check(status.Conflicted.Select(f => f.Path).SequenceEqual(new[] { "conflicto.cs" }), "Conflicted solo incluye los conflictos.");

        var detached = Git.ParseStatus("# branch.oid (initial)\0# branch.head (detached)\0");
        Check(detached.Head is null && detached.Branch is null, "Sin commits ni rama se muestran como nulos.");
        Check(detached.Ahead == 0 && detached.Behind == 0 && detached.Files.Count == 0, "Sin branch.ab no hay adelantos ni retrasos.");

        Check(Git.ParseStatus("").IsRepository && Git.ParseStatus("").Files.Count == 0, "Una salida vacía es un repositorio sin cambios.");
        Check(!GitStatus.NotRepository.IsRepository, "NotRepository no es un repositorio.");

        // La igualdad por valor se usa para detectar cambios entre dos lecturas.
        Check(Git.ParseStatus(sample).Equals(Git.ParseStatus(sample)), "Dos lecturas iguales del mismo estado son iguales.");
        Check(!Git.ParseStatus(sample).Equals(Git.ParseStatus(sample.Replace("+2 -1", "+3 -1"))),
            "Un cambio en ahead/behind hace distintos dos estados.");
    }

    private static void ParseLogChecks()
    {
        // Registros separados por US (0x1f) entre campos y RS (0x1e) entre commits.
        const string log =
            "0123456789abcdef0123456789abcdef01234567\u001f0123456\u001fAñade Git\u001fAna Pérez\u001f1700000000\u001e\n" +
            "fedcba9876543210fedcba9876543210fedcba98\u001ffedcba9\u001fCorrige | tabs\tdel mensaje\u001fBob\u001f1600000000\u001e" +
            "registro roto\u001fsin todos los campos\u001e";

        var commits = Git.ParseLog(log);
        Check(commits.Count == 2, "Un registro con campos de menos se descarta.");
        Check(commits[0].Hash == "0123456789abcdef0123456789abcdef01234567" && commits[0].ShortHash == "0123456",
            "El hash y el hash corto se leen de los campos 1 y 2.");
        Check(commits[0].Subject == "Añade Git" && commits[0].Author == "Ana Pérez", "Asunto y autor conservan acentos.");
        Check(commits[0].Date == DateTimeOffset.FromUnixTimeSeconds(1700000000), "La fecha es el %at en segundos Unix.");
        Check(commits[1].Subject == "Corrige | tabs\tdel mensaje", "El asunto conserva tabuladores y barras.");
        Check(commits[1].Id == commits[1].Hash, "El id de un commit es su hash.");
        Check(Git.ParseLog("").Count == 0, "Una salida vacía no tiene commits.");
    }

    private static void ParseBranchChecks()
    {
        var branches = Git.ParseBranches("main\nfeature/git-checks\r\n\n");
        Check(branches.SequenceEqual(new[] { "main", "feature/git-checks" }), "Las ramas vacías se descartan y se quita el CR final.");
        Check(Git.ParseBranches("").Count == 0, "Sin ramas, la lista está vacía.");
    }

    private static void GitResultChecks()
    {
        Check(new GitResult(0, "", "").Succeeded, "El estado 0 es un éxito.");
        Check(new GitResult(1, "", "  error fatal\n").Message == "error fatal", "El mensaje de error tiene prioridad y se recorta.");
        Check(new GitResult(2, "salida\n", "").Message == "salida", "Sin error se usa la salida.");
        Check(new GitResult(3, " \n", " ").Message == "git terminó con el código 3.", "Sin texto se indica el código de salida.");
    }

    private static void CommitMessageChecks()
    {
        Check(GitCommitAutomation.ValidatedMessage("  Añade parseo de Git\n\nCuerpo breve.\n") == "Añade parseo de Git\n\nCuerpo breve.",
            "Un mensaje válido se devuelve recortado.");
        var longSubject = new string('a', 120);
        Check(GitCommitAutomation.ValidatedMessage(longSubject) == longSubject, "Un asunto de 120 caracteres es válido.");

        Reject<GitCommitAutomation.Failure>(() => GitCommitAutomation.ValidatedMessage("   "));
        Reject<GitCommitAutomation.Failure>(() => GitCommitAutomation.ValidatedMessage("```bash\nrm -rf x\n```"));
        Reject<GitCommitAutomation.Failure>(() => GitCommitAutomation.ValidatedMessage(new string('a', 121)));
        Reject<GitCommitAutomation.Failure>(() => GitCommitAutomation.ValidatedMessage("asunto\u0007oculto"));
        Reject<GitCommitAutomation.Failure>(() => GitCommitAutomation.ValidatedMessage(new string('é', 1001)));
    }

    private static void EvidenceChecks()
    {
        // Dentro de presupuesto: el resumen y el diff caben enteros.
        var whole = GitCommitAutomation.Evidence("a", "b", 100_000);
        using (var document = JsonDocument.Parse(whole))
        {
            Check(document.RootElement.GetProperty("diff").GetString() == "b", "La evidencia completa conserva el diff.");
            Check(document.RootElement.GetProperty("summary").GetString() == "a", "La evidencia completa conserva el resumen.");
            Check(document.RootElement.GetProperty("possibly_truncated").GetBoolean(), "La evidencia siempre marca possibly_truncated.");
        }

        // Presupuesto justo: el diff se recorta y el JSON resultante respeta el límite.
        var small = GitCommitAutomation.Evidence("resumen", new string('d', 5000), 1000);
        Check(Encoding.UTF8.GetByteCount(small) <= 1000, "La evidencia recortada no supera el presupuesto en bytes.");
        using (var document = JsonDocument.Parse(small))
        {
            Check(document.RootElement.GetProperty("diff").GetString()!.Length < 5000, "El diff se recorta cuando no cabe.");
            Check(document.RootElement.GetProperty("summary").GetString() == "resumen", "El resumen corto se conserva.");
        }

        // Un presupuesto imposible no devuelve evidencia parcial inválida.
        Reject<GitCommitAutomation.Failure>(() => GitCommitAutomation.Evidence("resumen", "diff", 10));
    }


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
}
