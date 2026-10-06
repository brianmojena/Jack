import AppKit
import ImageIO
import ImagePlayground
import JackCore
import SwiftUI
import UniformTypeIdentifiers

/// Colors of the glow shown while an image is on its way, in the spirit of Apple Intelligence.
private let glowColors: [Color] = [
    Color(red: 1.00, green: 0.62, blue: 0.04), Color(red: 1.00, green: 0.22, blue: 0.37), Color(red: 0.75, green: 0.35, blue: 0.95),
    Color(red: 0.04, green: 0.52, blue: 1.00), Color(red: 0.39, green: 0.82, blue: 1.00), Color(red: 1.00, green: 0.22, blue: 0.37),
    Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 1.00, green: 0.62, blue: 0.04), Color(red: 0.04, green: 0.52, blue: 1.00),
]

/// A slowly moving mesh of warm and cool colors.
private struct IntelligenceGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            MeshGradient(width: 3, height: 3, points: points(at: context.date.timeIntervalSinceReferenceDate), colors: glowColors)
        }
    }

    private func points(at time: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double) -> Float { reduceMotion ? 0 : Float(sin(time * speed + phase)) * 0.14 }
        return [
            [0, 0], [0.5 + wave(0.9, 0), 0], [1, 0],
            [0, 0.5 + wave(1.1, 1)], [0.5 + wave(0.7, 2), 0.5 + wave(0.8, 3)], [1, 0.5 + wave(1.3, 4)],
            [0, 1], [0.5 + wave(1.0, 5), 1], [1, 1],
        ]
    }
}

/// A border that turns slowly around the card while the image is pending.
private struct GlowBorder: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) * 60
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AngularGradient(colors: glowColors + [glowColors[0]], center: .center, angle: .degrees(angle)), lineWidth: 1.5)
                .opacity(0.85)
        }
        .allowsHitTesting(false)
    }
}

/// An image an agent asked for: a glowing placeholder until the user creates it, then the image itself.
struct ImageRequestCard: View {
    let request: ChatImageRequest
    let projectPath: String
    let onCreate: () -> Void
    let onDecline: () -> Void
    let onDismiss: () -> Void
    private static let previewHeight: CGFloat = 112

    private var savedPath: String? {
        if case .saved(let path, _, _) = request.state { return path }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            preview
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: savedPath == nil ? "wand.and.sparkles" : "photo")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [glowColors[0], glowColors[1], glowColors[3]], startPoint: .leading, endPoint: .trailing))
                    Text(savedPath == nil ? "El agente quiere crear una imagen" : "Imagen creada")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    if savedPath != nil {
                        Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.borderless).foregroundStyle(JackPalette.muted).help("Quitar")
                    }
                }
                Text(request.prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(JackPalette.secondaryText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    chip(request.style.title)
                    chip(sizeText)
                    chip(displayPath(savedPath ?? request.destination.path, project: projectPath), monospaced: true)
                }
                actions.padding(.top, 2)
            }
        }
        .padding(12)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if request.isPending {
                GlowBorder(cornerRadius: 12)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(JackPalette.hairline, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(savedPath == nil ? "Imagen pendiente: \(request.prompt)" : "Imagen creada: \(request.prompt)")
    }

    private var sizeText: String {
        if case .saved(_, let width, let height) = request.state { return "\(width) × \(height)" }
        return "\(request.width) × \(request.height)"
    }

    /// The placeholder keeps the requested proportions, so the card does not jump when the image arrives.
    private var aspectRatio: CGFloat {
        if case .saved(_, let width, let height) = request.state, height > 0 { return CGFloat(width) / CGFloat(height) }
        return CGFloat(request.width) / CGFloat(max(request.height, 1))
    }

    private var preview: some View {
        let width = min(max(Self.previewHeight * aspectRatio, 72), 200)
        return ZStack {
            if let savedPath, let image = NSImage(contentsOfFile: savedPath) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                IntelligenceGlow().blur(radius: 6).opacity(0.9)
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
        .frame(width: width, height: Self.previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .onTapGesture { if let savedPath { NSWorkspace.shared.open(URL(fileURLWithPath: savedPath)) } }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var actions: some View {
        if let savedPath {
            HStack(spacing: 8) {
                Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: savedPath)) }
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: savedPath)]) }
            }
            .controlSize(.small)
        } else {
            HStack(spacing: 8) {
                Button(action: onCreate) { Label("Crear en Image Playground", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .tint(JackPalette.accent)
                Button("Ahora no", action: onDecline)
                    .help("El agente seguirá sin la imagen")
            }
            .controlSize(.small)
        }
    }

    private func chip(_ text: String, monospaced: Bool = false) -> some View {
        Text(text)
            .font(monospaced ? .system(size: 10.5, design: .monospaced) : .system(size: 10.5, weight: .medium))
            .foregroundStyle(JackPalette.muted)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(JackPalette.panelStrong, in: Capsule())
    }
}

// MARK: - Image Playground

enum ImagePlaygroundSupport {
    /// Image Playground can run here: Apple Intelligence is on and the language and region are supported.
    @MainActor static var isAvailable: Bool {
        if #available(macOS 15.4, *) { return ImagePlaygroundViewController.isAvailable }
        return false
    }

    /// Copies Image Playground's result to where the agent wants it, converted to that file's format.
    static func save(_ source: URL, to destination: URL) throws -> (width: Int, height: Int) {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
            throw failure("Image Playground devolvió un archivo que no es una imagen.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let type: UTType = switch destination.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic": .heic
        default: .png
        }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw failure("No se puede escribir en \(destination.path).")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw failure("No se pudo guardar \(destination.path).") }
        return (image.width, image.height)
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Jack.ImagePlayground", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Presents Image Playground for `request`, prefilled with the agent's prompt, style and size.
struct ImagePlaygroundPresenter: ViewModifier {
    @Binding var request: ChatImageRequest?
    let onFinish: (ChatImageRequest, URL?) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.4, *) {
            content.modifier(PlaygroundSheet(request: $request, onFinish: onFinish))
        } else {
            content
        }
    }
}

@available(macOS 15.4, *)
private struct PlaygroundSheet: ViewModifier {
    @Binding var request: ChatImageRequest?
    let onFinish: (ChatImageRequest, URL?) -> Void
    /// The request on screen, kept until Image Playground reports how it ended.
    @State private var shown: ChatImageRequest?

    func body(content: Content) -> some View {
        let current = request ?? shown
        content
            .imagePlaygroundSheet(
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                concepts: [.text(current?.playgroundPrompt ?? "")],
                sourceImage: current?.referenceImage.flatMap(NSImage.init(contentsOfFile:)).map(Image.init(nsImage:)),
                onCompletion: { url in finish(url) },
                onCancellation: { finish(nil) }
            )
            .imagePlaygroundGenerationStyle(Self.style(current?.style ?? .realistic), in: ImagePlaygroundStyle.all)
            .modifier(PlaygroundOptions(width: current?.width ?? 1024, height: current?.height ?? 1024, editing: current?.referenceImage != nil))
            .onChange(of: request?.id, initial: true) { _, _ in if let request { shown = request } }
    }

    private func finish(_ url: URL?) {
        guard let finished = shown else { return }
        shown = nil
        request = nil
        onFinish(finished, url)
    }

    /// Realistic is macOS 27's default model, which takes its style from the prompt.
    static func style(_ style: ChatImageRequest.Style) -> ImagePlaygroundStyle {
        switch style {
        case .realistic:
            if #available(macOS 27, *) { return .any }
            return .illustration
        case .animation: return .animation
        case .illustration: return .illustration
        case .sketch: return .sketch
        }
    }
}

@available(macOS 15.4, *)
private struct PlaygroundOptions: ViewModifier {
    let width: Int
    let height: Int
    let editing: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.4, *) {
            content.imagePlaygroundOptions(options)
        } else {
            content
        }
    }

    @available(macOS 26.4, *)
    private var options: ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        // An agent's picture should not pick up people from the user's photo library.
        options.personalization = .disabled
        if #available(macOS 27, *) {
            options.sizeSpecification = .closest(to: CGSize(width: width, height: height))
            options.creationStrategy = editing ? .automatic : .generateNew
        }
        return options
    }
}
