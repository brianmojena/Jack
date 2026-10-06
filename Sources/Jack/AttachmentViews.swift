import AppKit
import JackCore
import SwiftUI
import UniformTypeIdentifiers

/// One attached file: a thumbnail for images, the Finder icon for anything else.
struct AttachmentChip: View {
    let path: String
    var onRemove: (() -> Void)? = nil
    @State private var thumbnail: NSImage?

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill) }
                else { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable() }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(JackPalette.muted)
                    .help("Quitar adjunto")
            }
        }
        .padding(.leading, 4).padding(.trailing, onRemove == nil ? 9 : 6).padding(.vertical, 4)
        .background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        .contextMenu {
            Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("Copiar ruta") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        }
        .help(path)
        .task(id: path) { thumbnail = await Self.thumbnail(path) }
    }

    /// Small, decoded off the main thread so large photos do not stall scrolling.
    private static func thumbnail(_ path: String) async -> NSImage? {
        guard ChatAttachments.imageType(path) != nil || ["heic", "tiff", "tif", "bmp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return nil }
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
    }
}

/// Shown over the conversation while files are dragged onto it.
struct AttachmentDropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JackPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(JackPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "paperclip").font(.system(size: 26, weight: .medium))
                    Text("Suelta para adjuntar").font(.system(size: 14, weight: .semibold))
                    Text("Imágenes, documentos, carpetas…").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                }
                .foregroundStyle(JackPalette.accent)
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

enum AttachmentDrop {
    static let types: [UTType] = [.fileURL, .image]

    /// Turns dropped items into paths: files keep their location, bare image data is saved by Jack.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [Int: String] = [:]
        func add(_ index: Int, _ path: String?) {
            guard let path else { return }
            lock.lock(); paths[index] = path; lock.unlock()
        }
        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    add(index, url.map(ChatAttachments.persist))
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ? UTType.png : UTType.image
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    add(index, data.flatMap(storeImage))
                    group.leave()
                }
            } else { group.leave() }
        }
        group.notify(queue: .main) {
            let ordered = paths.keys.sorted().compactMap { paths[$0] }
            MainActor.assumeIsolated { completion(ordered) }
        }
    }

    /// Image data saved as PNG, the format every agent accepts.
    private static func storeImage(_ data: Data) -> String? {
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        return try? ChatAttachments.store(png, fileExtension: "png")
    }

    /// Lets the user pick files with the open panel.
    @MainActor static func choose(from directory: String) -> [String] {
        let panel = NSOpenPanel()
        panel.title = "Adjuntar archivos"
        panel.prompt = "Adjuntar"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: directory)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.standardizedFileURL.path }
    }
}

/// Wraps its children onto new lines, aligned to the trailing edge like a sent message.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
