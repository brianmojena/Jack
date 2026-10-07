import Foundation

/// Asks the agent's own model which project folder a request is about, so a new agent can start
/// with "arregla el login de la app de finanzas" and land in the right space by itself.
public enum ProjectLocator {
    /// Where an agent waits while its project is unknown; its space reads "Sin proyecto".
    public static var unplacedFolder: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jack/Sin proyecto", isDirectory: true).path
    }

    /// The folder `request` is about, or nil when the model cannot tell.
    @MainActor
    public static func locate(_ request: String, provider: ChatProvider, model: String, projects: [String]) async throws -> String? {
        if let path = ProjectFinder.explicitPath(in: request) { return path }
        let likely = ProjectFinder.score(request, projects: projects).prefix(5).map(\.match.path)
        // Choosing a folder is a small job: Claude Code does it with its fastest model.
        var asker = ChatConversation(projectPath: FileManager.default.homeDirectoryForCurrentUser.path, provider: provider,
                                     model: provider == .claude ? "haiku" : model)
        asker.effort = provider == .claude ? "" : "low"
        let answer = try await ChatAsideService.ask(request, about: asker, instructions: prompt(request, projects: projects, likely: likely)) { _ in }
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
