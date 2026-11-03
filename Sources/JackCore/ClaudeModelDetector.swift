import Foundation

/// Detects Claude model versions from session transcripts by reading the latest sessions
/// and extracting full model IDs, then building a catalog with detected versions.
enum ClaudeModelDetector {
    /// Parses JSONL data into individual line objects
    private static func parseLines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// Reads recent session files to find the highest version of each Claude model family
    /// (fable, opus, sonnet, haiku). Returns both detected models and any unknown families found.
    static func detectModels(from sessionsRoot: URL? = nil, maxSessionsToScan: Int = 20) -> (detected: [ChatModelChoice], unknownFamilies: [String]) {
        let root = sessionsRoot ?? ClaudeSessions.root
        var modelsByFamily: [String: (fullId: String, version: (major: Int, minor: Int, patch: Int))] = [:]
        var unknownFamilies = Set<String>()

        // Read the most recent session files
        let recentFiles = ClaudeSessions.list(limit: maxSessionsToScan, root: root)
        for session in recentFiles {
            let sessionPath = root.appendingPathComponent(ClaudeSessions.folderName(for: session.projectPath)).appendingPathComponent(session.id + ".jsonl")
            guard let handle = try? FileHandle(forReadingFrom: sessionPath) else { continue }
            defer { try? handle.close() }
            // Only the tail: the newest assistant messages carry the model in use, and sessions can be large.
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 192 * 1024 ? size - 192 * 1024 : 0)
            guard let data = try? handle.readToEnd() else { continue }

            // Extract model IDs from the session file
            for line in parseLines(data) {
                guard let message = line["message"] as? [String: Any],
                      let fullId = message["model"] as? String else { continue }

                // Parse the model ID and extract family and version
                if let (family, version) = parseModelId(fullId) {
                    // Keep the highest version for each family
                    if let existing = modelsByFamily[family] {
                        if compareVersions(version, existing.version) > 0 {
                            modelsByFamily[family] = (fullId, version)
                        }
                    } else {
                        modelsByFamily[family] = (fullId, version)
                    }
                } else {
                    // Extract family name for unknown IDs
                    for knownFamily in ["fable", "opus", "sonnet", "haiku"] {
                        if fullId.contains(knownFamily) {
                            unknownFamilies.insert(knownFamily)
                            break
                        }
                    }
                }
            }
        }

        // Build catalog from detected models, fallback to hardcoded for missing families
        var detected: [ChatModelChoice] = []
        for (family, info) in modelsByFamily.sorted(by: { a, b in ["fable", "opus", "sonnet", "haiku"].firstIndex(of: a.key) ?? 999 < ["fable", "opus", "sonnet", "haiku"].firstIndex(of: b.key) ?? 999 }) {
            let title = buildTitle(family: family, version: info.version)
            let subtitle = subtitleForFamily(family)
            detected.append(ChatModelChoice(id: family, title: title, subtitle: subtitle, efforts: ChatModelChoice.claudeEfforts(for: info.fullId)))
        }

        return (detected, Array(unknownFamilies))
    }

    /// Parses a Claude model ID like "claude-opus-5-5" into family and semantic version
    private static func parseModelId(_ id: String) -> (family: String, version: (major: Int, minor: Int, patch: Int))? {
        let lower = id.lowercased()

        for family in ["fable", "opus", "sonnet", "haiku"] {
            if lower.contains(family) {
                // Extract version numbers from patterns like "fable-5-1" or "opus-4-6"
                let pattern = family + "-([0-9]+)-([0-9]+)(?:-[0-9]+)?"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
                   let majorRange = Range(match.range(at: 1), in: lower),
                   let minorRange = Range(match.range(at: 2), in: lower),
                   let major = Int(lower[majorRange]),
                   let minor = Int(lower[minorRange]) {
                    return (family, (major, minor, 0))
                }
                // If we found the family but couldn't parse version, still return it
                return (family, (0, 0, 0))
            }
        }
        return nil
    }

    /// Builds a readable title from family and version, e.g. "Opus 5.5"
    private static func buildTitle(family: String, version: (major: Int, minor: Int, patch: Int)) -> String {
        let capitalized = family.prefix(1).uppercased() + family.dropFirst()
        if version.major == 0 && version.minor == 0 {
            return capitalized
        }
        return "\(capitalized) \(version.major).\(version.minor)"
    }

    /// Spanish subtitle for each model family
    private static func subtitleForFamily(_ family: String) -> String? {
        switch family.lowercased() {
        case "fable": return "El más capaz"
        case "opus": return "Muy capaz"
        case "sonnet": return "Equilibrado"
        case "haiku": return "Rápido y económico"
        default: return nil
        }
    }

    /// Compares two semantic versions: returns > 0 if v1 > v2, 0 if equal, < 0 if v1 < v2
    private static func compareVersions(_ v1: (major: Int, minor: Int, patch: Int), _ v2: (major: Int, minor: Int, patch: Int)) -> Int {
        if v1.major != v2.major {
            return v1.major - v2.major
        }
        if v1.minor != v2.minor {
            return v1.minor - v2.minor
        }
        return v1.patch - v2.patch
    }
}
