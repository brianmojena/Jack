import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ServerModel

    var body: some View {
        Form {
            TextField("Puerto HTTPS (iPhone)", value: $model.httpsPort, format: .number.grouping(.never))
            TextField("Puerto HTTP (certificado, Android, Tailscale)", value: $model.port, format: .number.grouping(.never))
            HStack {
                TextField("Carpeta de builds", text: $model.dataPath)
                Button("Elegir…", action: chooseFolder)
            }
            Text("iOS solo instala apps por HTTPS. BuildCloud firma su propio certificado; cada iPhone lo instala una vez desde \(model.certificateURL).")
                .font(.caption).foregroundStyle(.secondary)
            Button("Mostrar certificados en Finder") { NSWorkspace.shared.open(model.authority.directory) }
            HStack {
                Spacer()
                Button("Aplicar y reiniciar servidor") { model.start() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (model.dataPath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { model.dataPath = url.path }
    }
}
