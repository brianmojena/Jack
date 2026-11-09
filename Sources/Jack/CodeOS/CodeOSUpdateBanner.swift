import AppKit
import JackCore
import SwiftUI

/// The "new version" notice at the top of the console. The key (I, or ⌘⇧U inside a project) installs it.
struct CodeOSUpdateBanner: View {
    @ObservedObject var checker: UpdateChecker
    let error: String?

    var body: some View {
        if let release = checker.available {
            let busy = checker.status == .downloading || checker.status == .installing
            HStack(spacing: 12) {
                Image(systemName: busy ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill").foregroundStyle(JackPalette.green)
                Text("Jack \(release.version) disponible").fontWeight(.semibold)
                Text(label(busy: busy)).foregroundStyle(.ink.opacity(0.65))
                if let error { Text(error).foregroundStyle(JackPalette.red).lineLimit(1) }
            }
            .font(.system(size: 14))
            .foregroundStyle(.ink)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.ink.opacity(0.15)))
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func label(busy: Bool) -> String {
        switch checker.status {
        case .downloading: "Descargando…"
        case .installing: "Reiniciando…"
        default: checker.canInstallInPlace ? "Pulsa I para actualizar (⌘⇧U dentro de un proyecto)" : "Pulsa I para descargarla"
        }
    }
}
