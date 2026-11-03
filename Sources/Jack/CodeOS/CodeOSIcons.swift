import AppKit
import SwiftUI

/// Looks for a project's own app icon on disk: Xcode `AppIcon.appiconset`, Android `ic_launcher`, or a web icon.
enum CodeOSIconFinder {
    private static let skipped: Set<String> = ["node_modules", ".git", "Pods", "build", "DerivedData", "venv", ".venv", "Carthage", "vendor", "target", ".gradle", ".next", "Library"]
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "icns", "webp", "svg", "ico"]

    /// Best candidates first. Runs off the main thread: it walks the project folder.
    nonisolated static func candidates(in root: String) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [(score: Int, size: Int, url: URL)] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 8000 { break }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) || walker.level > 7 { walker.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            let size = values?.fileSize ?? 0
            var score = 0
            let path = url.path
            // Android's adaptive layers are transparent halves of the icon, never the icon.
            let isLayer = name.contains("foreground") || name.contains("background") || name.contains("monochrome")
            if path.contains(".appiconset"), ext != "svg", size > 2_000 { score = 100 }
            // Xcode's Icon Composer bundle (`AppIcon.icon/Assets/…`): what newer projects use instead of an appiconset.
            else if path.contains(".icon/Assets/"), ext != "svg" { score = 95 }
            else if name.hasPrefix("ic_launcher"), !isLayer { score = name.contains("round") ? 70 : 80 }
            else if name.hasPrefix("appicon") || name.hasPrefix("app-icon") || name == "icon" || name.hasPrefix("icon-") || name.hasPrefix("apple-touch-icon") { score = 70 }
            else if name == "logo" || name.hasPrefix("logo-") || name.hasPrefix("favicon") || name.hasPrefix("icon") { score = 55 }
            // Names that only contain it ("llegoicon2small", "logollego") or sit in an image set named so: the app's own mark.
            else if ext != "svg", ["icon", "logo"].contains(where: { name.contains($0) || url.deletingLastPathComponent().lastPathComponent.lowercased().contains($0) }), !isLayer { score = 45 }
            // Widgets, watch apps and extensions have icons of their own: the app's wins over them.
            if score > 0, ["Widget", "Extension", "Watch", "Tests", "Clip", "tvOS", "Notification"].contains(where: path.contains) { score -= 30 }
            // Vector and .ico icons are a last resort: .ico is usually 16 px.
            if ext == "svg" { score = score > 0 ? score - 20 : 0 }
            if ext == "ico" { score = score > 0 ? score - 40 : 0 }
            if score > 0, size < 8_000_000 { found.append((score, size, url)) }
        }
        return found.sorted { ($0.score, $0.size) > ($1.score, $1.size) }.prefix(8).map(\.url)
    }
}

extension NSImage {
    var isRoughlySquare: Bool {
        guard size.height > 0 else { return false }
        let ratio = size.width / size.height
        return ratio > 0.8 && ratio < 1.25
    }

    /// The most colourful average of the image, pushed into a range that reads well as a glow on a dark screen.
    func codeOSTint() -> Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.4 else { continue }
            let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha, b = Double(pixels[index + 2]) / 255 / alpha
            let spread = max(r, g, b) - min(r, g, b)
            let weight = alpha * (0.1 + spread * spread)
            red += r * weight; green += g * weight; blue += b * weight; total += weight
        }
        guard total > 0 else { return nil }
        let average = NSColor(srgbRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: max(saturation, 0.45), brightness: min(max(brightness, 0.6), 0.95))
    }
}

/// The project's icon; else its framework's logo on a tinted tile; else a gradient tile with its initial. A tile whose picture is
/// shared with another project (or is a framework logo, which many projects can have) also carries the project's name, and its
/// background takes the project's own colour, so two FastAPI backends do not look alike.
struct CodeOSArtwork: View {
    let project: CodeOSProject
    let art: CodeOSModel.Art?
    var corner: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if let art, let framework = art.framework {
                    // Brand colour from the corner, the project's own colour from the opposite one.
                    LinearGradient(colors: [art.tint, art.tint.opacity(0.55), .black.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(colors: [.clear, project.color.opacity(0.55)], startPoint: .center, endPoint: .bottomTrailing)
                    Image(nsImage: art.image).resizable().scaledToFit()
                        .frame(width: side * 0.42, height: side * 0.42)
                        .offset(y: side >= 110 ? -side * 0.1 : 0)
                        .opacity(0.95)
                        .accessibilityLabel(framework)
                } else if let art {
                    Image(nsImage: art.image).resizable().interpolation(.high).scaledToFill()
                } else {
                    LinearGradient(colors: [project.color, project.color.opacity(0.4), .black.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(project.initial)
                        .font(.system(size: side * 0.5, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
                if side >= 110, art?.framework != nil || art?.shared == true {
                    VStack {
                        Spacer(minLength: 0)
                        Text(project.name)
                            .font(.system(size: max(side * 0.085, 11), weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, side * 0.06).padding(.vertical, side * 0.045)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.5))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}

/// Logos of the three agents, from the same SVGs Jack uses in its provider asset catalog.
enum CodeOSAgentLogo {
    private static let paths: [CodeOSAgent: String] = [
        .claude: "M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z",
        .opencode: "M16 6H8v12h8V6zm4 16H4V2h16v20z",
        .codex: "M8.086 .457a6.105 6.105 0 0 1 3.046 -.415c1.333 .153 2.521 .72 3.564 1.7a.117 .117 0 0 0 .107 .029c1.408 -.346 2.762 -.224 4.061 .366l.063 .03 .154 .076c1.357 .703 2.33 1.77 2.918 3.198 .278 .679 .418 1.388 .421 2.126a5.655 5.655 0 0 1 -.18 1.631 .167 .167 0 0 0 .04 .155 5.982 5.982 0 0 1 1.578 2.891c.385 1.901 -.01 3.615 -1.183 5.14l-.182 .22a6.063 6.063 0 0 1 -2.934 1.851 .162 .162 0 0 0 -.108 .102c-.255 .736 -.511 1.364 -.987 1.992 -1.199 1.582 -2.962 2.462 -4.948 2.451 -1.583 -.008 -2.986 -.587 -4.21 -1.736a.145 .145 0 0 0 -.14 -.032c-.518 .167 -1.04 .191 -1.604 .185a5.924 5.924 0 0 1 -2.595 -.622 6.058 6.058 0 0 1 -2.146 -1.781c-.203 -.269 -.404 -.522 -.551 -.821a7.74 7.74 0 0 1 -.495 -1.283 6.11 6.11 0 0 1 -.017 -3.064 .166 .166 0 0 0 .008 -.074 .115 .115 0 0 0 -.037 -.064 5.958 5.958 0 0 1 -1.38 -2.202 5.196 5.196 0 0 1 -.333 -1.589 6.915 6.915 0 0 1 .188 -2.132c.45 -1.484 1.309 -2.648 2.577 -3.493 .282 -.188 .55 -.334 .802 -.438 .286 -.12 .573 -.22 .861 -.304a.129 .129 0 0 0 .087 -.087A6.016 6.016 0 0 1 5.635 2.31C6.315 1.464 7.132 .846 8.086 .457zm-.804 7.85a.848 .848 0 0 0 -1.473 .842l1.694 2.965 -1.688 2.848a.849 .849 0 0 0 1.46 .864l1.94 -3.272a.849 .849 0 0 0 .007 -.854l-1.94 -3.393zm5.446 6.24a.849 .849 0 0 0 0 1.695h4.848a.849 .849 0 0 0 0 -1.696h-4.848z"
    ]

    /// White template image, so it can be tinted by the view.
    static func image(_ agent: CodeOSAgent) -> NSImage? {
        guard let path = paths[agent] else { return nil }
        let svg = ##"<svg width="96" height="96" fill-rule="evenodd" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#FFFFFF" clip-rule="evenodd" d="\##(path)"/></svg>"##
        return NSImage(data: Data(svg.utf8))
    }
}

struct CodeOSAgentGlyph: View {
    let agent: CodeOSAgent
    var body: some View {
        if let image = CodeOSAgentLogo.image(agent) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "terminal.fill").resizable().scaledToFit()
        }
    }
}
