import Foundation

/// Finds project folders on a machine Jack reaches over SSH, so a remote agent
/// can start with "arregla el login de la app de finanzas" instead of a path.
/// Name matching reuses ProjectFinder's scoring; only existence checks go over SSH.
public enum RemoteProjects {
    /// Folders the other Mac is likely to keep code in, mirroring ProjectFinder's roots.
    static let remoteRoots = ["Documents", "Developer", "Projects", "Proyectos", "projects", "code", "Code",
                              "src", "dev", "repos", "GitHub", "Desktop", "Sites", "Work"].map { "$HOME/\($0)" }

    /// Marker files and folders that identify a project root, mirroring ProjectFinder.
    static let markers = [".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "requirements.txt",
                          "go.mod", "pubspec.yaml", "Gemfile", "composer.json", "build.gradle", "build.gradle.kts",
                          "pom.xml", "deno.json", "CMakeLists.txt", "Makefile", "project.yml", "CLAUDE.md", "AGENTS.md"]

    /// One remote command listing the machine's projects: its Jack index when that Mac
    /// runs Jack, plus a bounded scan for marker files. Runs under `sh` explicitly.
    static func listCommand() -> String {
        let roots = remoteRoots.joined(separator: " ")
        let names = markers.map { "-name \($0)" }.joined(separator: " -o ")
        let prunes = ["node_modules", "Library", "Applications", "Pictures", "Music", "Movies", "Public", "build",
                      "dist", "DerivedData", "Pods", "vendor", "venv", "target", "__pycache__"]
            .map { "-path '*/\($0)'" }.joined(separator: " -o ")
        let script = """
        defaults read dev.jack.desktop knownProjects 2>/dev/null | grep -o '"/[^"]*"' | tr -d '"'
        { for r in \(roots); do [ -d "$r" ] || continue
        find "$r" -maxdepth 4 \\( \(prunes) \\) -prune -o \\( \(names) -o -name '*.xcodeproj' -o -name '*.xcworkspace' \\) -print 2>/dev/null
        done } | while IFS= read -r p; do case "$p" in */.git) printf '%s\\n' "${p%/.git}";; *) printf '%s\\n' "${p%/*}";; esac; done | sort -u | head -n 2000
        """
        return SSHTransport.shellScript(script)
    }

    /// Parses `listCommand` output into absolute folders, order kept, duplicates dropped.
    /// Tolerates leftover quoting from the index dump (`"/x",`) as well as bare scan paths.
    public static func parseList(_ output: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        for line in output.components(separatedBy: .newlines) {
            var path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"',"))
            guard path.hasPrefix("/"), path.count > 1 else { continue }
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard seen.insert(path).inserted else { continue }
            found.append(path)
        }
        return found
    }

    /// Lists the machine's projects: throws a user-facing message when SSH fails.
    public static func fetch(destination: String, sshPort: Int?) async throws -> [String] {
        let output = try await SSHTransport.run(destination: destination, sshPort: sshPort,
                                                remoteCommand: listCommand(), timeout: 90)
        return parseList(output)
    }

    /// A remote `test -d` for each path, in one call. Returns those that exist, in input order.
    public static func filterExisting(destination: String, sshPort: Int?, paths: [String]) async throws -> [String] {
        let candidates = Array(paths.prefix(20))
        guard !candidates.isEmpty else { return [] }
        let checks = candidates.map { "if [ -d \(SSHTransport.shellQuote($0)) ]; then printf 'FOUND:%s\\n' \(SSHTransport.shellQuote($0)); fi" }.joined(separator: "; ")
        let output = try await SSHTransport.run(destination: destination, sshPort: sshPort,
                                                remoteCommand: SSHTransport.shellScript(checks), timeout: 30)
        let found = Set(output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("FOUND:") else { return nil }
            return String(line.dropFirst(6))
        })
        return candidates.filter { found.contains($0) }
    }

    /// Absolute path tokens written in the request (`/x/y`); `~/x` matches by name instead,
    /// because the remote home is not expanded inside quotes.
    public static func pathTokens(in text: String) -> [String] {
        var tokens: [String] = []
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "`" || $0 == "\"" }) {
            var candidate = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()'"))
            guard candidate.hasPrefix("/") else { continue }
            if candidate.count > 1, candidate.hasSuffix("/") { candidate.removeLast() }
            tokens.append(candidate)
        }
        return tokens
    }

    /// The project the request names, purely by string matching: an explicit remote path
    /// first (canonicalized against known lists), then open projects, then all discovered.
    /// `existing` are request paths already verified on the remote machine.
    public static func knownPath(in request: String, projects: [String], openProjects: [String], existing: [String] = []) -> String? {
        if let path = existing.first {
            return ProjectLocator.existingPath(path, projects: openProjects + projects)
        }
        if let match = ProjectFinder.resolve(request, projects: openProjects).match { return match.path }
        return ProjectFinder.resolve(request, projects: projects).match?.path
    }
}
