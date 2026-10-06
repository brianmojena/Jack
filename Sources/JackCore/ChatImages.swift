import Foundation

/// An image an agent asked for with `generate_image`. macOS 27 only creates images through Image Playground's
/// own window, so the request waits in the agent's chat until the user picks a result there.
public struct ChatImageRequest: Identifiable, Equatable {
    public enum Style: String, CaseIterable {
        case realistic, animation, illustration, sketch
        public var title: String {
            switch self {
            case .realistic: "Realista"
            case .animation: "Animación"
            case .illustration: "Ilustración"
            case .sketch: "Boceto"
            }
        }
    }

    public enum State: Equatable {
        case pending
        case saved(path: String, width: Int, height: Int)
        /// Image Playground closed without an image: the prompt may not be allowed, or no result was good.
        case cancelled
        /// The user said no from the chat.
        case declined
        case failed(String)
    }

    public var id: String
    public var conversationID: UUID
    /// What the agent asked for, as it wrote it.
    public var prompt: String
    public var style: Style
    public var width: Int
    public var height: Int
    public var destination: URL
    public var referenceImage: String?
    public var createdAt: Date
    public var state: State

    public init(id: String = UUID().uuidString.lowercased(), conversationID: UUID, prompt: String, style: Style = .realistic,
                width: Int = 1024, height: Int = 1024, destination: URL, referenceImage: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.conversationID = conversationID; self.prompt = prompt; self.style = style
        self.width = width; self.height = height; self.destination = destination; self.referenceImage = referenceImage
        self.createdAt = createdAt; self.state = .pending
    }

    public var isPending: Bool { state == .pending }

    /// The text Image Playground receives. Its default model takes any style from the prompt, so a realistic
    /// request says so unless the agent already did.
    public var playgroundPrompt: String {
        guard style == .realistic else { return prompt }
        let lower = prompt.lowercased()
        let realistic = ["photo", "realistic", "foto", "realista", "fotorrealista"].contains { lower.contains($0) }
        return realistic ? prompt : "Photorealistic photo of " + prompt
    }

    /// Where an image goes: `path` if the agent gave one (a folder gets a file named after the prompt),
    /// otherwise `generated-images/` in the project. Existing files are never overwritten.
    public static func destination(for path: String?, prompt: String, project: String, fileManager: FileManager = .default) -> URL {
        let name = ProgressFiles.sanitizedID(String(prompt.prefix(48)))
        var url: URL
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : project + "/" + expanded).standardizedFileURL
            var isDirectory: ObjCBool = false
            if url.pathExtension.isEmpty || (fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                url = url.appendingPathComponent(name + ".png")
            }
        } else {
            url = URL(fileURLWithPath: project).appendingPathComponent("generated-images", isDirectory: true).appendingPathComponent(name + ".png")
        }
        if !["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) { url = url.appendingPathExtension("png") }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var candidate = url, number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// What the agent reads back from `generate_image`.
    public var resultText: (String, Bool) {
        switch state {
        case .pending:
            return ("The user has not created the image yet.", true)
        case .saved(let path, let width, let height):
            return ("Saved the image to \(path) (\(width)×\(height)). Look at it before using it; if it does not fit, call generate_image again with a better prompt.", false)
        case .cancelled:
            return ("Image Playground closed without an image. It refuses some prompts (real people, brands, violence, text…) and the user may not have liked the results. Write a different, simpler prompt that describes only what is visible and call generate_image again; after three failed attempts, tell the user instead.", true)
        case .declined:
            return ("The user declined to create this image. Do not ask again unless they want it; carry on without it.", true)
        case .failed(let reason):
            return ("Could not create the image: \(reason)", true)
        }
    }
}
