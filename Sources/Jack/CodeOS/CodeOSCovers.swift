import AppKit
import JackCore
import SwiftUI

/// Cover art for a project: Claude Haiku reads the project and writes the prompt from the project's own files and theme colours, and Cloudflare Workers AI
/// paints it with FLUX.2 dev at 1920×1080. The image is kept on disk, with its prompt beside it, so it is made once.
enum CodeOSCoverStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS/Covers")
    static let credentials = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS/cloudflare.json")
    /// A second Cloudflare account, used when the main one runs out of its free daily allowance.
    static let backupCredentials = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS/cloudflare-backup.json")

    private static func base(for project: CodeOSProject) -> String {
        // djb2 of the whole path, so two folders with the same name do not share a cover.
        let seed = project.id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return "\(project.name.filter { $0.isLetter || $0.isNumber })-\(String(seed, radix: 16))"
    }

    /// The cover is saved exactly as the model returned it (a JPEG), so it is not compressed twice.
    static func url(for project: CodeOSProject) -> URL { directory.appendingPathComponent(base(for: project) + ".jpg") }
    static func promptURL(for project: CodeOSProject) -> URL { directory.appendingPathComponent(base(for: project) + ".prompt.txt") }

    static func existing(for project: CodeOSProject) -> NSImage? {
        NSImage(contentsOf: url(for: project)) ?? NSImage(contentsOf: directory.appendingPathComponent(base(for: project) + ".png"))
    }

    /// What is used when Haiku cannot write one: the project's name and latest session, and its colours.
    static func fallbackPrompt(for project: CodeOSProject, palette: [String]) -> String {
        var text = "Cinematic wide key art for a software project called \(project.name)"
        if !project.title.isEmpty { text += ", about: \(project.title.prefix(80))" }
        text += ". Dark moody atmosphere, abstract futuristic technology scene, glowing light, depth, widescreen composition with empty space on the left, no text, no people"
        if !palette.isEmpty { text += ", dominant colours \(palette.joined(separator: " and "))" }
        return text + ", ultra detailed, volumetric light, sharp focus, 8k."
    }
}

/// A short first look at a project folder, handed to Haiku as a starting point: README, manifests, top-level names and the languages in use.
enum CodeOSProjectBrief {
    nonisolated static func read(_ path: String, limit: Int = 3_800) -> String {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        var parts: [String] = []

        for name in ["README.md", "readme.md", "Readme.md", "README", "README.txt", "README.rst"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) {
                parts.append("README:\n" + String(text.prefix(1_800)))
                break
            }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var line = "package.json: \(json["name"] as? String ?? "")"
            if let description = json["description"] as? String { line += " — \(description)" }
            let dependencies = ((json["dependencies"] as? [String: Any]) ?? [:]).keys.sorted().prefix(14)
            if !dependencies.isEmpty { line += "\nDependencies: " + dependencies.joined(separator: ", ") }
            parts.append(line)
        }
        for name in ["Package.swift", "pubspec.yaml", "pyproject.toml", "Cargo.toml", "go.mod", "build.gradle.kts", "build.gradle"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) {
                parts.append("\(name):\n" + String(text.prefix(500)))
                break
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: path).filter({ !$0.hasPrefix(".") }).sorted().prefix(30) {
            parts.append("Top-level: " + names.joined(separator: ", "))
        }
        if let languages = languages(in: root), !languages.isEmpty { parts.append("Main languages: " + languages.joined(separator: ", ")) }
        return String(parts.joined(separator: "\n\n").prefix(limit))
    }

    private nonisolated static func languages(in root: URL) -> [String]? {
        let names = ["swift": "Swift", "kt": "Kotlin", "java": "Java", "ts": "TypeScript", "tsx": "TypeScript/React", "js": "JavaScript", "jsx": "JavaScript/React", "py": "Python",
                     "rs": "Rust", "go": "Go", "dart": "Dart/Flutter", "rb": "Ruby", "php": "PHP", "cs": "C#", "cpp": "C++", "c": "C", "svelte": "Svelte", "vue": "Vue", "html": "HTML", "css": "CSS", "metal": "Metal"]
        let skipped: Set<String> = ["node_modules", "Pods", "build", "DerivedData", "venv", ".venv", "vendor", "target", ".next", "dist"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        var counts: [String: Int] = [:]
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 4_000 { break }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipped.contains(url.lastPathComponent) || walker.level > 5 { walker.skipDescendants() }
                continue
            }
            if let language = names[url.pathExtension.lowercased()] { counts[language, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
    }
}

extension NSImage {
    /// Up to `count` distinct theme colours of the image (most present first), as hex strings.
    func codeOSPalette(count: Int = 3) -> [String] {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var buckets: [Int: (r: Double, g: Double, b: Double, weight: Double)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.4 else { continue }
            let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha, b = Double(pixels[index + 2]) / 255 / alpha
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.2, brightness > 0.2 else { continue }
            let key = Int(hue * 12) % 12
            let weight = alpha * Double(saturation) * Double(brightness)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.r += r * weight; bucket.g += g * weight; bucket.b += b * weight; bucket.weight += weight
            buckets[key] = bucket
        }
        return buckets.values.sorted { $0.weight > $1.weight }.prefix(count).map {
            String(format: "#%02X%02X%02X", Int($0.r / $0.weight * 255), Int($0.g / $0.weight * 255), Int($0.b / $0.weight * 255))
        }
    }
}

/// Where Cloudflare's account and token come from: the environment, or `cloudflare.json` next to the covers.
struct CodeOSCloudflare: Decodable {
    var accountID: String
    var apiToken: String
    /// FLUX.2 [dev]: Black Forest Labs' highest-quality model on Workers AI (the free-tier FLUX.1 schnell is a faster, lower-quality distillation).
    var model: String? = nil
    var width: Int? = nil
    var height: Int? = nil

    static func load() -> CodeOSCloudflare? {
        let environment = ProcessInfo.processInfo.environment
        if let account = environment["CLOUDFLARE_ACCOUNT_ID"], let token = environment["CLOUDFLARE_API_TOKEN"], !account.isEmpty, !token.isEmpty {
            return CodeOSCloudflare(accountID: account, apiToken: token)
        }
        return read(CodeOSCoverStore.credentials)
    }

    static func loadBackup() -> CodeOSCloudflare? { read(CodeOSCoverStore.backupCredentials) }

    private static func read(_ file: URL) -> CodeOSCloudflare? {
        guard let data = try? Data(contentsOf: file),
              let found = try? JSONDecoder().decode(CodeOSCloudflare.self, from: data),
              !found.accountID.isEmpty, !found.apiToken.isEmpty, !found.accountID.hasPrefix("PEGA") else { return nil }
        return found
    }

    /// Writes an empty `cloudflare.json` to fill in, unless there is one already.
    static func writeTemplate() {
        guard !FileManager.default.fileExists(atPath: CodeOSCoverStore.credentials.path) else { return }
        try? FileManager.default.createDirectory(at: CodeOSCoverStore.credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = "{\n  \"accountID\": \"PEGA_AQUI_TU_ACCOUNT_ID\",\n  \"apiToken\": \"PEGA_AQUI_TU_API_TOKEN\"\n}\n"
        try? template.write(to: CodeOSCoverStore.credentials, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CodeOSCoverStore.credentials.path)
    }
}

/// A Workers AI request that did not return an image.
struct CodeOSCloudflareFailure: LocalizedError {
    var status: Int
    var detail: String

    var errorDescription: String? { detail.isEmpty ? "respuesta \(status)" : detail }

    /// The account has no free allowance left, judged by the status and the text Cloudflare sends back
    /// (for example "you have used up your daily free allocation of 10,000 neurons").
    var isQuota: Bool {
        if status == 429 { return true }
        let text = detail.lowercased()
        return ["neurons", "allocation", "quota", "rate limit", "limit exceeded", "daily", "exceeded", "capacity", "too many requests", "billing", "paid plan"].contains { text.contains($0) }
    }
}

private struct CloudflareImageReply: Decodable {
    struct Result: Decodable { var image: String? }
    var result: Result?
    var errors: [Failure]?
    struct Failure: Decodable { var message: String? }
}

extension CodeOSModel {
    /// Makes a cover for `project`: Haiku writes the prompt, Workers AI paints it. Does nothing while one is already being made for it.
    func generateCover(for project: CodeOSProject) {
        guard !generating.contains(project.id) else { return }
        guard let cloudflare = CodeOSCloudflare.load() else {
            CodeOSCloudflare.writeTemplate()
            notify("Falta la clave de Cloudflare: rellena cloudflare.json en Application Support/Jack/CodeOS.")
            NSWorkspace.shared.activateFileViewerSelecting([CodeOSCoverStore.credentials])
            return
        }
        generating.insert(project.id)
        let palette = art[project.id]?.image.codeOSPalette() ?? []
        let themeHex = palette.isEmpty ? [colorHex(tint(project))] : palette
        Task {
            defer { generating.remove(project.id) }
            do {
                notify("Haiku está revisando \(project.name) para escribir el prompt…")
                let (prompt, failure) = await Self.writePrompt(for: project, palette: themeHex)
                notify("Pintando la portada con FLUX.2 (1920×1080)…")
                let data = try await requestWithBackup(prompt, primary: cloudflare)
                guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: CodeOSCoverStore.directory, withIntermediateDirectories: true)
                try data.write(to: CodeOSCoverStore.url(for: project))
                try? prompt.write(to: CodeOSCoverStore.promptURL(for: project), atomically: true, encoding: .utf8)
                covers[project.id] = image
                notify(failure.map { "Portada lista con un prompt de plantilla: \($0)" } ?? "Portada lista.")
                CodeOSSound.shared.play(.notify)
            } catch {
                notify("No se pudo generar la portada: \(error.localizedDescription)")
            }
        }
    }

    /// Paints with the main account and, if it has no allowance left, with the backup one. After a quota failure the main account is
    /// skipped for half an hour so the next covers do not wait for it to fail again.
    private func requestWithBackup(_ prompt: String, primary: CodeOSCloudflare) async throws -> Data {
        let defaults = UserDefaults.standard
        let key = "codeOSCloudflareLimitedUntil"
        let backup = CodeOSCloudflare.loadBackup()
        if let backup, defaults.double(forKey: key) > Date().timeIntervalSince1970 {
            return try await Self.requestImage(prompt, backup)
        }
        do {
            return try await Self.requestImage(prompt, primary)
        } catch let failure as CodeOSCloudflareFailure where failure.isQuota {
            guard let backup else { throw failure }
            defaults.set(Date().addingTimeInterval(30 * 60).timeIntervalSince1970, forKey: key)
            notify("La cuenta de Cloudflare llegó al límite: pintando con la de respaldo…")
            return try await Self.requestImage(prompt, backup)
        }
    }

    private func colorHex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }

    /// Haiku's prompt, or the template when it cannot be reached.
    private static func writePrompt(for project: CodeOSProject, palette: [String]) async -> (prompt: String, failure: String?) {
        let brief = await Task.detached(priority: .userInitiated) { CodeOSProjectBrief.read(project.id) }.value
        do {
            return (try await CodeOSCoverWriter().prompt(projectName: project.name, path: project.id, brief: brief, palette: palette, lastSession: project.title), nil)
        } catch {
            return (CodeOSCoverStore.fallbackPrompt(for: project, palette: palette), error.localizedDescription)
        }
    }

    private static func requestImage(_ prompt: String, _ cloudflare: CodeOSCloudflare) async throws -> Data {
        let model = cloudflare.model ?? "@cf/black-forest-labs/flux-2-dev"
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(cloudflare.accountID)/ai/run/\(model)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cloudflare.apiToken)", forHTTPHeaderField: "Authorization")
        let width = cloudflare.width ?? 1920, height = cloudflare.height ?? 1080
        if model.contains("flux-2") {
            // FLUX.2 takes multipart form data.
            let boundary = "jack-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let fields: [(String, String)] = [("prompt", prompt), ("width", String(width)), ("height", String(height)), ("steps", "28")]
            var body = Data()
            for (name, value) in fields {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            request.httpBody = body
        } else {
            // The other models (FLUX.1 schnell, Leonardo, SDXL) take JSON. Schnell has no size and at most 8 steps.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var json: [String: Any] = ["prompt": prompt]
            if model.contains("schnell") { json["steps"] = 8 } else { json["steps"] = 28; json["width"] = width; json["height"] = height }
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true { return data }
        let reply = try? JSONDecoder().decode(CloudflareImageReply.self, from: data)
        guard status == 200, let base64 = reply?.result?.image, let image = Data(base64Encoded: base64) else {
            let detail = reply?.errors?.compactMap(\.message).joined(separator: " ") ?? ""
            throw CodeOSCloudflareFailure(status: status, detail: detail)
        }
        return image
    }
}
