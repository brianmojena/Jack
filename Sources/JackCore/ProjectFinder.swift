import Foundation

/// Finds the user's project folders and works out which one a request is about, so a new agent
/// can start with "ve a Jack y arregla el login" instead of a folder picker.
public enum ProjectFinder {
    public struct Match: Equatable, Sendable {
        public let path: String
        /// The words of the request that named the project.
        public let mention: String
    }

    /// Files and folders that mark the root of a project.
    static let markers: Set<String> = [
        ".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "requirements.txt", "go.mod",
        "pubspec.yaml", "Gemfile", "composer.json", "build.gradle", "build.gradle.kts", "pom.xml", "deno.json",
        "CMakeLists.txt", "Makefile", "project.yml", "CLAUDE.md", "AGENTS.md",
    ]
    static let skipped: Set<String> = [
        "node_modules", "Library", "Applications", "Pictures", "Music", "Movies", "Public", "build", "dist",
        "DerivedData", "Pods", "vendor", "venv", "target", "__pycache__",
    ]
    /// Folder names too common to identify a project by themselves.
    static let generic: Set<String> = [
        "app", "apps", "web", "api", "src", "lib", "test", "tests", "docs", "code", "proyecto", "proyectos",
        "project", "projects", "server", "client", "backend", "frontend", "mobile", "ios", "android", "main",
        "demo", "temp", "tmp", "nuevo", "new", "old", "data", "scripts", "tools", "trabajo", "work", "personal",
    ]

    /// Folders where people usually keep code.
    public static var defaultRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Documents", "Developer", "Projects", "Proyectos", "projects", "code", "Code", "src", "dev", "repos", "GitHub", "Desktop", "Sites", "Work"]
            .map { "\(home)/\($0)" }
    }

    /// Project folders below `roots`, without going into a project once its root is found.
    public static func scan(roots: [String], maxDepth: Int = 5, limit: Int = 2_000) -> [String] {
        let manager = FileManager.default
        var found: [String] = []
        var seen = Set<String>()
        func visit(_ path: String, depth: Int) {
            guard found.count < limit, let names = try? manager.contentsOfDirectory(atPath: path) else { return }
            let isProject = names.contains { markers.contains($0) || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
            if isProject, depth > 0 {
                found.append(path)
                return
            }
            guard depth < maxDepth else { return }
            for name in names.sorted() where !name.hasPrefix(".") && !skipped.contains(name) && !name.hasSuffix(".app") {
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

    public enum Resolution: Equatable, Sendable {
        case none
        case one(Match)
        /// Folders that fit about equally well, e.g. two named "Orion": the user picks one.
        case several([Match])

        public var match: Match? { if case .one(let match) = self { match } else { nil } }
        public var choices: [Match] { if case .several(let matches) = self { matches } else { [] } }
    }

    /// The project a request names. `projects` should come most recently used first,
    /// so equally good candidates are offered in that order.
    public static func resolve(_ text: String, projects: [String]) -> Resolution {
        if let path = explicitPath(in: text) { return .one(Match(path: path, mention: (path as NSString).abbreviatingWithTildeInPath)) }
        let scored = score(text, projects: projects)
        guard let best = scored.first else { return .none }
        // Equal scores mean the request does not tell the folders apart; one more matching letter does.
        let close = scored.prefix { $0.score >= best.score - 3 }.prefix(4).map(\.match)
        return close.count > 1 ? .several(close) : .one(best.match)
    }

    /// Every project the request could mean, best first.
    static func score(_ text: String, projects: [String]) -> [(match: Match, score: Int)] {
        let words = tokens(text)
        guard !words.isEmpty else { return [] }
        let compactText = words.joined()
        // Each word, and each word glued to the next, so "llego oficina" also reads as one name.
        let joined = words.indices.map { index in index + 1 < words.count ? [words[index], words[index] + words[index + 1]] : [words[index]] }
        let candidates = words.indices.flatMap { index in joined[index].map { (index, $0) } }
        var scored: [(match: Match, score: Int, rank: Int)] = []
        for (rank, path) in projects.enumerated() {
            let url = URL(fileURLWithPath: path)
            var name = url.lastPathComponent
            var nameWords = tokens(name)
            if nameWords.allSatisfy(generic.contains) {
                // "Atlas/frontend" is known as "Atlas frontend".
                name = "\(url.deletingLastPathComponent().lastPathComponent) \(name)"
                nameWords = tokens(name)
            }
            let compact = nameWords.joined()
            guard compact.count >= 3, !nameWords.allSatisfy(generic.contains) else { continue }
            var score = 0
            if let start = find(nameWords, in: words) {
                score = 100 + compact.count * 4
                // "proyecto Jack", "en Jack", "carpeta jack": a cue word makes the mention clearer.
                if start > 0, cues.contains(words[start - 1]) { score += 40 }
            } else if nameWords.count > 1, compactText.contains(compact) {
                score = 80 + compact.count * 3
            } else if let start = candidates.first(where: { $0.1.count >= 4 && close($0.1, compact) })?.0 {
                // A small typo: "finanica", "llegoofisina".
                score = 50 + compact.count * 2
                if start > 0, cues.contains(words[start - 1]) { score += 40 }
            }
            guard score > 0 else { continue }
            scored.append((Match(path: path, mention: name), score, rank))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.rank < $1.rank }.map { ($0.match, $0.score) }
    }

    static let cues: Set<String> = ["proyecto", "carpeta", "repo", "repositorio", "en", "a", "de", "del", "project", "folder", "in", "to", "on", "app"]

    /// "/Users/me/x" or "~/x" written in the request, when it is a folder.
    static func explicitPath(in text: String) -> String? {
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "`" || $0 == "\"" }) {
            var candidate = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()'"))
            guard candidate.hasPrefix("/") || candidate.hasPrefix("~/") else { continue }
            candidate = (candidate as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue { return candidate }
        }
        return nil
    }

    /// Lowercased words without accents; camelCase, kebab-case and snake_case split apart.
    static func tokens(_ text: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for character in text {
            if let previous, character.isUppercase, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func find(_ needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle { return start }
        return nil
    }

    /// One edit apart, for names of five letters or more.
    private static func close(_ lhs: String, _ rhs: String) -> Bool {
        guard rhs.count >= 5, abs(lhs.count - rhs.count) <= 1, lhs != rhs else { return false }
        let a = Array(lhs), b = Array(rhs)
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
