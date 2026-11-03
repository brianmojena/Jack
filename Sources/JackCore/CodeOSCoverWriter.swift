import Foundation

/// CodeOS (modo Normal): Claude Haiku revisa el proyecto con herramientas de solo lectura (README, manifiestos, carpetas, código y
/// recursos) y, con los colores de su tema, escribe el prompt con el que el modelo de imagen pinta la portada. Si no responde, quien
/// llama usa una plantilla.
@MainActor public final class CodeOSCoverWriter {
    /// El último Haiku disponible.
    public static let modelName = "claude-haiku-5-5"

    /// model, system, prompt, folder and the extra environment of the account used.
    var ask: @MainActor (String, String, String, String, [String: String]) async throws -> String = { model, system, prompt, directory, environment in
        #if os(macOS)
        try await ChatAsideService.exploreOneShot(model: model, system: system, prompt: prompt, directory: directory, environment: environment)
        #else
        throw OfficeBrain.Failure.needsMac
        #endif
    }

    /// A second Claude Code account to fall back on when the main one reaches its usage limit. A JSON next to the covers:
    /// `{ "configDir": "~/.claude-backup" }` (a folder made with `CLAUDE_CONFIG_DIR=~/.claude-backup claude auth login`)
    /// and/or `{ "apiKey": "sk-ant-…" }` to bill an API key instead.
    public static let backupAccountFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS/claude-backup.json")
    private static let limitedUntilKey = "codeOSClaudeLimitedUntil"
    /// How long the main account is skipped after it reports its limit, so the next covers do not wait for it to fail again.
    private static let limitPause: TimeInterval = 30 * 60

    struct BackupAccount: Decodable {
        var configDir: String?
        var apiKey: String?

        var environment: [String: String] {
            var values: [String: String] = [:]
            if let configDir, !configDir.isEmpty { values["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath }
            if let apiKey, !apiKey.isEmpty { values["ANTHROPIC_API_KEY"] = apiKey }
            return values
        }
    }

    static func loadBackup() -> BackupAccount? {
        guard let data = try? Data(contentsOf: backupAccountFile), let account = try? JSONDecoder().decode(BackupAccount.self, from: data),
              !account.environment.isEmpty else { return nil }
        return account
    }

    /// Writes a `claude-backup.json` to fill in, unless there is one already.
    public static func writeBackupTemplate() {
        guard !FileManager.default.fileExists(atPath: backupAccountFile.path) else { return }
        try? FileManager.default.createDirectory(at: backupAccountFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{\n  \"configDir\": \"~/.claude-backup\"\n}\n".write(to: backupAccountFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupAccountFile.path)
    }

    /// What Claude Code prints, with a normal exit, when the account has no quota left. A real prompt is long and never says this.
    static func isLimitMessage(_ output: String) -> Bool {
        let text = output.lowercased()
        guard text.count < 500 else { return false }
        return ["usage limit", "hit your limit", "limit reached", "reached your limit", "rate limit", "out of extra usage", "out of usage", "credit balance", "resets at", "resets ", "too many requests", "quota", "overloaded", "límite"].contains { text.contains($0) }
    }

    public init() {}

    /// El prompt de la portada del proyecto en `path`. `palette` son colores del tema («#3A7BD5»); `brief` es un primer resumen que ya se leyó.
    public func prompt(projectName: String, path: String, brief: String, palette: [String], lastSession: String) async throws -> String {
        let system = """
        You write prompts for a state-of-the-art text-to-image model (FLUX.2). You are working inside a software project's folder with \
        read-only tools (Read, Glob, Grep). Your job is to understand the project properly and then write ONE prompt for a wide 16:9 \
        cover illustration (key art, like the poster of a game on a console home screen) that expresses what the project is and does \
        through a single striking visual metaphor, not through a literal screenshot.

        FIRST investigate, and do not rush. Read the README and any docs, the manifests (package.json, Package.swift, pubspec.yaml, \
        pyproject.toml, build files), the folder structure, the main entry points, a few of the core source files, the main screens or \
        views, and the assets (icons, images, color definitions). Read at least 8 different files, and more if the project is large or \
        you are still unsure what it really does, who it is for, and what its personality is (serious tool, playful app, game, data \
        platform...). Only when you are confident, write the prompt.

        Rules for the prompt:
        - Output ONLY the prompt, in English, as one paragraph of 80 to 130 words. No title, no quotes, no Markdown, no explanations.
        - Start with the subject and scene (concrete objects, setting, scale), then composition and camera (wide shot, depth, a clear focal \
        point on the right, empty dark space on the left for a title), then lighting and atmosphere, then the colour palette, then the \
        rendering style.
        - Turn the palette hex codes into plain colour words (for example "deep teal", "warm amber") and make them dominate the image; \
        keep the rest dark and cinematic so white text stays readable on it.
        - No text, letters, numbers, logos, watermarks or UI screenshots. No people's faces. No real brands or famous characters.
        - Finish with quality terms: ultra detailed, volumetric light, sharp focus, high dynamic range, 8k.
        """
        var user = "Project: \(projectName) (the current folder).\n"
        if !lastSession.isEmpty { user += "Latest work session: \(lastSession)\n" }
        user += "Theme colours of its logo: \(palette.joined(separator: ", "))\n\nA first quick look, to start from (not enough on its own):\n\(brief)\n\nNow investigate the project in depth and write the cover prompt."
        let output = try await answer(system, user, path)
        guard let cleaned = Self.clean(output) else { throw StellarError.message("Haiku no escribió ningún prompt.") }
        return cleaned
    }

    /// Asks with the main account and, if it has hit its limit (or is known to be paused), with the backup one.
    private func answer(_ system: String, _ user: String, _ path: String) async throws -> String {
        let defaults = UserDefaults.standard
        let paused = defaults.double(forKey: Self.limitedUntilKey) > Date().timeIntervalSince1970
        if !paused || Self.loadBackup() == nil {
            do {
                let output = try await ask(Self.modelName, system, user, path, [:])
                if !Self.isLimitMessage(output) { return output }
            } catch {
                // A failed run (no answer at all) is treated like a limit: the backup may still work.
                if Self.loadBackup() == nil { throw error }
            }
            defaults.set(Date().addingTimeInterval(Self.limitPause).timeIntervalSince1970, forKey: Self.limitedUntilKey)
        }
        guard let backup = Self.loadBackup() else {
            Self.writeBackupTemplate()
            throw StellarError.message("Tu cuenta de Claude llegó al límite y no hay cuenta de respaldo: rellena claude-backup.json.")
        }
        let output = try await ask(Self.modelName, system, user, path, backup.environment)
        if Self.isLimitMessage(output) { throw StellarError.message("Las dos cuentas de Claude llegaron al límite.") }
        return output
    }

    static func clean(_ output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "```", with: "").replacingOccurrences(of: "**", with: "")
        // The answer may carry a lead-in line ("Here is the prompt:"): keep the longest paragraph.
        if let longest = text.components(separatedBy: "\n\n").max(by: { $0.count < $1.count }) { text = longest }
        if text.lowercased().hasPrefix("prompt:") { text = String(text.dropFirst(7)) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' \n"))
        return text.count >= 40 ? String(text.prefix(1_400)) : nil
    }
}
