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

    /// Words that point at a folder when they come right before its name: "la carpeta X", "entra al proyecto X".
    static let folderCues: Set<String> = [
        "carpeta", "carpetas", "folder", "directorio", "directory", "proyecto", "project", "ruta", "path",
        "entra", "entrar", "ve", "ir", "abre", "abrir", "enter", "open", "cd",
    ]
    static let articles: Set<String> = ["a", "al", "el", "la", "los", "las", "en", "de", "del", "to", "the", "in", "into"]
    static let creationWords: Set<String> = ["crea", "crear", "creala", "cree", "nueva", "nuevo", "create", "new", "mkdir", "haz", "genera"]

    /// The folder to create when the request asks for a new one by path, such as "crea ~/Foo y un proyecto".
    public static func createdFolder(in request: String) -> String? {
        Set(ProjectFinder.tokens(request)).isDisjoint(with: creationWords) ? nil : newFolder(in: request)
    }

    /// A folder the request names that is not a project: empty or without any project marker, so the
    /// project index never lists it. Project folders are found by `knownPath`.
    /// Does disk work, so call it off the main actor.
    public static func plainFolder(in request: String, roots: [String] = ProjectFinder.defaultRoots) -> String? {
        let words = ProjectFinder.tokens(request)
        guard !Set(words).isDisjoint(with: folderCues) else { return nil }
        let folders = plainFolders(roots: roots)
        if let path = folder(endingWith: request, in: folders) { return path }
        guard let match = ProjectFinder.resolve(request, projects: folders).match else { return nil }
        // Only a name the request points at: "entra al proyecto transfer", not "mejora las fotos".
        let name = ProjectFinder.tokens(URL(fileURLWithPath: match.path).lastPathComponent)
        guard let start = words.indices.first(where: { words[$0...].starts(with: name) }) else { return nil }
        var before = start - 1
        while before >= 0, articles.contains(words[before]) { before -= 1 }
        return before >= 0 && folderCues.contains(words[before]) ? match.path : nil
    }

    /// A relative path such as "proyectos personales/transfer": the folder whose path ends with it.
    static func folder(endingWith request: String, in folders: [String]) -> String? {
        func fold(_ text: String) -> String { text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() }
        let wanted = request.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "`" || $0 == "\"" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()'/")) }
            .filter { $0.contains("/") && !$0.hasPrefix("~") }
        for fragment in wanted {
            // The fragment may start mid-name ("personales/transfer" for "Proyectos Personales/Transfer"), at a word.
            let tail = fold(fragment)
            let found = folders.filter { path in
                let folded = fold(path)
                guard folded.hasSuffix(tail) else { return false }
                let before = folded.dropLast(tail.count).last
                return before == "/" || before == " "
            }
            if found.count == 1 { return found[0] }
        }
        return nil
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
