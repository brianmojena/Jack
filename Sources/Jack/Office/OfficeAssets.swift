import CryptoKit
import Foundation
import SwiftUI

/// Los modelos 3D de la oficina (la sala, los personajes, las luces horneadas: ~100 MB) no viajan dentro de la app de la Mac.
/// Se bajan de GitHub la primera vez que se abre la oficina y se guardan en Application Support; las actualizaciones de Jack no
/// los vuelven a bajar mientras `version` no cambie. En el iPhone siguen dentro de la app, así que allí siempre están.
@MainActor final class OfficeAssets: ObservableObject {
    enum State: Equatable {
        case ready, missing
        case downloading(Double)
        case failed(String)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Sube con cada cambio de los modelos: es el número del release `office-assets-<version>` y el nombre de la carpeta local.
    static let version = 1
    /// Lo que pesa la descarga, para avisar antes de empezar.
    static let megabytes = 78
    /// SHA-256 del zip publicado: se comprueba antes de abrir nada, así un archivo cambiado en el camino no se usa.
    static let sha256 = "0c927e5c56a55ee332c16035708934d32fa3c280cfb689744d9b89f362cdd863"
    static let url = URL(string: "https://github.com/brianmojena/Jack/releases/download/office-assets-\(version)/Jack-Office-Assets-\(version).zip")!
    static let shared = OfficeAssets()

    /// Los archivos del release, o la carpeta de la que se leen. Quien llama busca aquí antes que en la app.
    nonisolated static func folder(version: Int = OfficeAssets.version) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jack/OfficeAssets/v\(version)", isDirectory: true)
    }
    nonisolated static func installedURL(_ name: String, _ ext: String) -> URL? {
        let url = folder().appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Published private(set) var state: State
    private let source: URL, checksum: String, destination: URL
    #if os(macOS)
    private var task: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    private var running: Task<Void, Never>?
    #endif

    init(source: URL = OfficeAssets.url, checksum: String = OfficeAssets.sha256, destination: URL = OfficeAssets.folder()) {
        self.source = source; self.checksum = checksum; self.destination = destination
        #if os(macOS)
        state = FileManager.default.fileExists(atPath: destination.appendingPathComponent("OfficeRoom.usdz").path) ? .ready : .missing
        #else
        state = .ready
        #endif
    }

    #if os(macOS)
    func download() {
        guard running == nil else { return }
        state = .downloading(0)
        running = Task { [source, checksum, destination] in
            defer { running = nil }
            do {
                let zip = try await fetch(source)
                defer { try? FileManager.default.removeItem(at: zip) }
                try await Task.detached { try Self.install(zip, checksum: checksum, into: destination) }.value
                state = .ready
            } catch is CancellationError {
                state = .missing
            } catch let error as URLError where error.code == .cancelled {
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { running?.cancel() }

    private func fetch(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard let location, status == 200 else { continuation.resume(throwing: Failure("GitHub respondió \(status): la descarga todavía no está publicada.")); return }
                    // URLSession borra su archivo al salir de este cierre: hay que moverlo ya.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent("jack-office-\(UUID().uuidString).zip")
                    do { try FileManager.default.moveItem(at: location, to: kept); continuation.resume(returning: kept) }
                    catch { continuation.resume(throwing: error) }
                }
                progress = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(progress.fractionCompleted) } }
                }
                self.task = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in self.task?.cancel() }
        }
    }

    /// Comprueba el zip, lo extrae aparte y solo entonces lo pone en su sitio: una descarga a medias nunca deja una carpeta usable.
    nonisolated static func install(_ zip: URL, checksum: String, into destination: URL) throws {
        let fileManager = FileManager.default
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else {
            throw Failure("El archivo descargado no es el esperado (la suma de comprobación no coincide). No se ha instalado.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, fileManager.fileExists(atPath: staging.appendingPathComponent("OfficeRoom.usdz").path) else {
            throw Failure("No se pudo abrir el archivo descargado.")
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
    }
    #endif
}

/// Lo que se ve en lugar de la escena mientras faltan los modelos: qué es, cuánto pesa y el botón para bajarlos.
struct OfficeAssetsCard: View {
    @ObservedObject var assets: OfficeAssets

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 30, weight: .light)).foregroundStyle(JackPalette.muted)
            Text("La oficina 3D es una descarga opcional").font(.system(size: 15, weight: .semibold))
            Text("Ocupa unos \(OfficeAssets.megabytes) MB. Se baja de GitHub una sola vez y se guarda en tu Mac; Jack no la lleva dentro para pesar mucho menos.")
                .font(.system(size: 12)).foregroundStyle(JackPalette.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
            switch assets.state {
            case .downloading(let fraction):
                VStack(spacing: 6) {
                    ProgressView(value: fraction).frame(width: 260)
                    Text("Descargando… \(Int(fraction * 100)) %").font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    #if os(macOS)
                    Button("Cancelar") { assets.cancel() }
                    #endif
                }
            case .failed(let message):
                Text(message).font(.system(size: 11.5)).foregroundStyle(JackPalette.red).multilineTextAlignment(.center).frame(maxWidth: 380)
                button("Reintentar")
            case .missing, .ready:
                button("Descargar (\(OfficeAssets.megabytes) MB)")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func button(_ title: String) -> some View {
        #if os(macOS)
        Button(title) { assets.download() }.buttonStyle(.borderedProminent).controlSize(.large)
        #endif
    }
}
