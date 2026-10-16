import BuildCloudCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ServerModel
    @State private var dropTargeted = false
    @State private var pendingDrop: [URL] = []
    @State private var showQR = false

    var body: some View {
        VStack(spacing: 0) {
            header
            certificateHint
            Divider()
            buildList
        }
        .frame(minWidth: 520, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .confirmationDialog("¿Dónde publicar?", isPresented: Binding(get: { !pendingDrop.isEmpty }, set: { if !$0 { pendingDrop = [] } })) {
            Button("Debug") { model.publish(pendingDrop, to: .debug); pendingDrop = [] }
            Button("Release") { model.publish(pendingDrop, to: .release); pendingDrop = [] }
        } message: {
            Text(pendingDrop.map(\.lastPathComponent).joined(separator: ", "))
        }
        .alert("No se pudo completar", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(model.isRunning && model.isHTTPSRunning ? Color.green
                          : model.state == .stopped ? Color.secondary : Color.orange)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText).font(.headline)
                Text(model.shareURL).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if model.publishing > 0 { ProgressView().controlSize(.small) }
            Button { showQR.toggle() } label: { Image(systemName: "qrcode") }
                .help("Código QR para abrir la web en el móvil")
                .popover(isPresented: $showQR) { qrPopover }
            Button("Abrir web", action: model.openWeb).disabled(!model.isRunning)
            Button(model.isRunning ? "Detener" : "Iniciar") { model.isRunning ? model.stop() : model.start() }
        }
        .padding(14)
    }

    private var certificateHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
            Text("¿Un iPhone nuevo? Primero instala el certificado en")
            Text(model.certificateURL).textSelection(.enabled)
        }
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var qrPopover: some View {
        HStack(alignment: .top, spacing: 24) {
            qrCode(title: "1. Certificado (una vez)", url: model.certificateURL)
            qrCode(title: "2. Instalar apps", url: model.shareURL)
        }
        .padding(16)
    }

    private func qrCode(title: String, url: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            if let image = model.qrImage(for: url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
            }
            Text(url).font(.caption).textSelection(.enabled)
        }
    }

    private var buildList: some View {
        List {
            ForEach(BuildChannel.allCases, id: \.self) { channel in
                Section(channel.title) {
                    let builds = model.builds[channel] ?? []
                    if builds.isEmpty {
                        Text(channel == .debug ? "Arrastra aquí un .ipa o .apk, o publica con `buildcloud publish`."
                                               : "Arrastra aquí un .ipa o .aab de Release.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(builds) { record in
                        BuildRow(record: record)
                            .contextMenu {
                                Button("Mostrar en Finder") { model.reveal(record) }
                                Button("Copiar enlace") { model.copyLink(record) }
                                Divider()
                                Button("Eliminar", role: .destructive) { model.remove(record) }
                            }
                    }
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let allowed: Set<String> = ["ipa", "apk", "aab"]
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadFileURL(), allowed.contains(url.pathExtension.lowercased()) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else {
                model.lastError = "Solo se pueden publicar archivos .ipa, .apk o .aab."
                return
            }
            // An .aab is always a Play Store release; anything else asks.
            if urls.allSatisfy({ $0.pathExtension.lowercased() == "aab" }) {
                model.publish(urls, to: .release)
            } else {
                pendingDrop = urls
            }
        }
        return true
    }
}

private struct BuildRow: View {
    let record: BuildRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.platform == .ios ? "apple.logo" : "smartphone")
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .foregroundStyle(.white)
                .background(record.platform == .ios ? Color.blue : Color.green, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).fontWeight(.medium)
                Text("\(record.version) (\(record.build)) · \(record.bundleId)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.createdAt, format: .relative(presentation: .named)).font(.caption)
                Text(BuildCloudSite.size(record.size)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }
}
