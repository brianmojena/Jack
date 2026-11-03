import AppKit
import SwiftUI

/// For a project folder with no icon of its own: the logo of the framework or language it is built with (FastAPI, Next.js, Swift…),
/// downloaded once from Simple Icons and kept on disk.
enum CodeOSFramework {
    struct Logo {
        let slug: String
        let name: String
        let image: NSImage
        let tint: Color
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS/FrameworkLogos")

    // MARK: Detection

    /// The framework that best describes the folder: what its manifests name, looking in the folder and one level down (a monorepo's
    /// `backend/` or `app/`). Frameworks win over languages.
    nonisolated static func detect(in root: String) -> (slug: String, name: String)? {
        let fm = FileManager.default
        var folders = [root]
        if let entries = try? fm.contentsOfDirectory(atPath: root) {
            let skipped: Set<String> = ["node_modules", "Pods", "build", "dist", "venv", "vendor", "target", "DerivedData"]
            for entry in entries.sorted() where !entry.hasPrefix(".") && !skipped.contains(entry) {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: root + "/" + entry, isDirectory: &isDirectory), isDirectory.boolValue { folders.append(root + "/" + entry) }
            }
        }
        var python = "", node = "", gradle = "", java = "", other: [String: String] = [:]
        var hasSwift = false, hasDocker = false, hasManage = false
        for folder in folders {
            func text(_ name: String) -> String? { try? String(contentsOfFile: folder + "/" + name, encoding: .utf8).lowercased() }
            for name in ["requirements.txt", "requirements-dev.txt", "requirements/base.txt", "pyproject.toml", "Pipfile", "setup.py", "poetry.lock"] { python += text(name) ?? "" }
            node += text("package.json") ?? ""
            gradle += (text("build.gradle") ?? "") + (text("build.gradle.kts") ?? "") + (text("app/build.gradle") ?? "") + (text("app/build.gradle.kts") ?? "")
            java += text("pom.xml") ?? ""
            for name in ["pubspec.yaml", "Cargo.toml", "go.mod", "composer.json", "Gemfile"] { if let content = text(name) { other[name, default: ""] += content } }
            if fm.fileExists(atPath: folder + "/Package.swift") { hasSwift = true }
            if let entries = try? fm.contentsOfDirectory(atPath: folder), entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { hasSwift = true }
            if fm.fileExists(atPath: folder + "/Dockerfile") { hasDocker = true }
            if fm.fileExists(atPath: folder + "/manage.py") { hasManage = true }
        }
        if python.contains("fastapi") { return ("fastapi", "FastAPI") }
        if python.contains("django") || hasManage { return ("django", "Django") }
        if python.contains("flask") { return ("flask", "Flask") }
        let nodeRules: [(String, String, String)] = [
            ("\"next\"", "nextdotjs", "Next.js"), ("\"nuxt\"", "nuxt", "Nuxt"), ("@nestjs/", "nestjs", "NestJS"), ("\"astro\"", "astro", "Astro"),
            ("@sveltejs/kit", "svelte", "Svelte"), ("\"svelte\"", "svelte", "Svelte"), ("\"expo\"", "expo", "Expo"), ("react-native", "react", "React Native"),
            ("\"vue\"", "vuedotjs", "Vue"), ("@angular/core", "angular", "Angular"), ("\"react\"", "react", "React"), ("\"express\"", "express", "Express"), ("\"vite\"", "vite", "Vite")
        ]
        for (needle, slug, name) in nodeRules where node.contains(needle) { return (slug, name) }
        if other["pubspec.yaml"]?.contains("flutter") == true { return ("flutter", "Flutter") }
        if gradle.contains("com.android") || gradle.contains("android {") { return ("android", "Android") }
        if gradle.contains("spring") || java.contains("spring") { return ("springboot", "Spring Boot") }
        if gradle.contains("kotlin") { return ("kotlin", "Kotlin") }
        if hasSwift { return ("swift", "Swift") }
        if other["Cargo.toml"] != nil { return ("rust", "Rust") }
        if other["go.mod"] != nil { return ("go", "Go") }
        if let composer = other["composer.json"] { return composer.contains("laravel") ? ("laravel", "Laravel") : ("php", "PHP") }
        if let gemfile = other["Gemfile"] { return gemfile.contains("rails") ? ("rubyonrails", "Ruby on Rails") : nil }
        if !node.isEmpty { return ("nodedotjs", "Node.js") }
        if !python.isEmpty { return ("python", "Python") }
        if hasDocker { return ("docker", "Docker") }
        return nil
    }

    // MARK: Logo

    /// The framework's logo as a white glyph, with its brand colour as the tint. Cached on disk; nil without network on first use.
    static func logo(for root: String) async -> Logo? {
        guard let (slug, name) = await Task.detached(priority: .utility, operation: { detect(in: root) }).value else { return nil }
        let file = directory.appendingPathComponent(slug + ".svg")
        var svg = try? String(contentsOf: file, encoding: .utf8)
        if svg == nil, let url = URL(string: "https://cdn.simpleicons.org/\(slug)"),
           let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
           let text = String(data: data, encoding: .utf8), text.contains("<svg") {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
            svg = text
        }
        guard let svg else { return nil }
        // The CDN's default file carries the brand colour in `fill`: keep it as the tint and draw the glyph in white.
        let brand = svg.range(of: ##"fill="#[0-9A-Fa-f]{6}""##, options: .regularExpression).map { String(svg[$0]).dropFirst(7).prefix(6) }.map(String.init) ?? "5B6B8C"
        let white = svg.replacingOccurrences(of: "fill=\"#\(brand)\"", with: "fill=\"#FFFFFF\"")
        guard let image = NSImage(data: Data(white.utf8)) else { return nil }
        return Logo(slug: slug, name: name, image: image, tint: Self.tint(fromHex: brand))
    }

    /// A brand colour pushed into a range that works as a tile background on a dark screen: black logos (Next.js) get a steel grey.
    private static func tint(fromHex hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x5B6B8C
        let color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: saturation, brightness: max(brightness, 0.45))
    }
}
