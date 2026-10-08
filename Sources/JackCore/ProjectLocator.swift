import Foundation

/// Asks the agent's own model which project folder a request is about, so a new agent can start
/// with "arregla el login de la app de finanzas" and land in the right space by itself.
public enum ProjectLocator {
    /// Where an agent waits while its project is unknown; its space reads "Sin proyecto".
    public static var unplacedFolder: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jack/Sin proyecto", isDirectory: true).path
    }

    /// Reuses the exact path of an existing Jack project, including when the user
    /// writes an alias or a symlink. An open project wins over an indexed namesake.
    static func knownPath(in request: String, projects: [String], openProjects: [String]) -> String? {
        if let path = ProjectFinder.explicitPath(in: request) {
            return existingPath(path, projects: openProjects + projects)
        }
        if let match = ProjectFinder.resolve(request, projects: openProjects).match {
            return match.path
        }
        return ProjectFinder.resolve(request, projects: projects).match?.path
    }

    static func existingPath(_ path: String, projects: [String]) -> String {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return projects.first {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == canonical
        } ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static let folderWords: Set<String> = ["carpeta", "carpetas", "folder", "directorio", "directory"]
    static let creationWords: Set<String> = ["crea", "crear", "creala", "cree", "nueva", "nuevo", "create", "new", "mkdir", "haz", "genera"]

    /// A folder the request asks for that is not a project yet: an empty folder, one that does not exist
    /// and is to be created, or one without any project marker. Project folders are found by `knownPath`.
    /// Does disk work, so call it off the main actor.
    public static func folderToStart(in request: String, roots: [String] = ProjectFinder.defaultRoots) -> String? {
        let words = Set(ProjectFinder.tokens(request))
        if !words.isDisjoint(with: creationWords), let path = newFolder(in: request) { return path }
        guard !words.isDisjoint(with: folderWords) else { return nil }
        return ProjectFinder.resolve(request, projects: plainFolders(roots: roots)).match?.path
    }

    /// A path written in the request that does not exist yet, inside a folder that does, under the user's home.
    /// It is created, so the agent can start in it.
    static func newFolder(in request: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for raw in request.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "`" || $0 == "\"" }) {
            let candidate = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()'"))
            guard candidate.hasPrefix("/") || candidate.hasPrefix("~/") else { continue }
            let path = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath).standardizedFileURL.path
            let parent = (path as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            guard path.hasPrefix(home + "/"), !FileManager.default.fileExists(atPath: path),
                  FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue,
                  (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)) != nil else { continue }
            return path
        }
        return nil
    }

    /// Folders below `roots` that are not projects, empty ones included: where a new project can start.
    static func plainFolders(roots: [String], maxDepth: Int = 4, limit: Int = 4_000) -> [String] {
        let manager = FileManager.default
        var found: [String] = []
        var seen = Set<String>()
        func visit(_ path: String, depth: Int) {
            guard found.count < limit, let names = try? manager.contentsOfDirectory(atPath: path) else { return }
            if depth > 0 { found.append(path) }
            // A project's insides are not places to start a new one.
            if names.contains(where: { ProjectFinder.markers.contains($0) || $0.hasSuffix(".xcodeproj") }) { return }
            guard depth < maxDepth else { return }
            for name in names.sorted() where !name.hasPrefix(".") && !ProjectFinder.skipped.contains(name) && !name.hasSuffix(".app") {
                let child = (path as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: child, isDirectory: &isDirectory), isDirectory.boolValue,
                      (try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      seen.insert(child).inserted else { continue }
                visit(child, depth: depth + 1)
            }
        }
        for root in roots where seen.insert(root).inserted { visit(root, depth: 0) }
        return found
    }

    /// The folder `request` is about, or nil when the model cannot tell.
    @MainActor
    public static func locate(_ request: String, provider: ChatProvider, model: String, projects: [String], allowCloud: Bool = false) async throws -> String? {
        if let path = ProjectFinder.explicitPath(in: request) { return path }
        let likely = ProjectFinder.score(request, projects: projects).prefix(5).map(\.match.path)
        // Choosing a folder is a small job: Claude Code does it with its fastest model.
        var asker = ChatConversation(projectPath: FileManager.default.homeDirectoryForCurrentUser.path, provider: provider,
                                     model: provider == .claude ? "haiku" : model)
        asker.effort = provider == .claude ? "" : "low"
        let answer = try await ChatAsideService.ask(request, about: asker, instructions: prompt(request, projects: projects, likely: likely), allowCloud: allowCloud) { _ in }
        return path(in: answer, projects: projects)
    }

    static func prompt(_ request: String, projects: [String], likely: [String]) -> String {
        var seen = Set<String>()
        let listed = (likely + projects).filter { seen.insert($0).inserted }.prefix(400)
            .map { ($0 as NSString).abbreviatingWithTildeInPath }
        return """
        [Jack: elegir carpeta] Jack va a abrir un agente para la petición de abajo y necesita saber en qué carpeta \
        de proyecto debe trabajar. No hagas la tarea, no uses herramientas y no modifiques nada: solo elige la carpeta.

        Carpetas de proyecto de este Mac (las más probables y recientes primero):
        \(listed.joined(separator: "\n"))

        Petición del usuario:
        «\(request)»

        Responde únicamente con la ruta de la carpeta, tal como aparece en la lista, en una sola línea. \
        Deduce el proyecto aunque no se nombre: por su nombre, por lo que hace la app o por el tema. \
        Si de verdad no hay forma de saberlo, responde NINGUNA.
        """
    }

    /// The folder named in the model's answer: one of `projects` if it can, else any existing folder.
    static func path(in answer: String, projects: [String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = Set(projects)
        var fallback: String?
        for line in answer.split(whereSeparator: \.isNewline) {
            var candidate = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'«»*.,;: "))
            if let start = candidate.range(of: "~/") ?? candidate.range(of: "/") { candidate = String(candidate[start.lowerBound...]) } else { continue }
            candidate = (candidate as NSString).expandingTildeInPath
            if candidate.count > 1, candidate.hasSuffix("/") { candidate.removeLast() }
            if known.contains(candidate) { return candidate }
            var isDirectory: ObjCBool = false
            if fallback == nil, candidate != home, candidate != "/",
               FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                fallback = candidate
            }
        }
        return fallback
    }
}
