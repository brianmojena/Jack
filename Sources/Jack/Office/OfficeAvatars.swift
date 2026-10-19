import AppKit
import SwiftUI

/// Un personaje que se puede poner a un puesto de la oficina: su modelo (`<id>.usdz`) y su miniatura (`Avatar_<id>.png`),
/// ambos salidos de Blender (ver `scripts/office_add_character.py` y `scripts/office_avatar_thumbnails.py`).
struct OfficeCharacter: Identifiable, Equatable {
    let id: String
    let name: String

    static let all = [
        OfficeCharacter(id: "REMY", name: "Remy"),
        OfficeCharacter(id: "CH31", name: "Ch31"),
        OfficeCharacter(id: "GIRL", name: "Chica"),
        OfficeCharacter(id: "DEADPOOL", name: "Deadpool"),
        OfficeCharacter(id: "LAMINE", name: "Lamine"),
        OfficeCharacter(id: "FRANKLIN", name: "Franklin"),
    ]

    var thumbnail: NSImage? {
        Bundle.main.url(forResource: "Avatar_\(id)", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

/// Qué avatar lleva cada puesto; el que no se cambió lleva el suyo de siempre. Se recuerda entre sesiones.
@MainActor final class OfficeAvatarChoices: ObservableObject {
    static let key = "officeAvatars"

    @Published private(set) var chosen: [String: String]

    init() {
        chosen = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    func avatar(for slot: OfficeLayout.Slot) -> String { chosen[slot.id] ?? slot.file }

    func choose(_ avatar: String, for slot: OfficeLayout.Slot) {
        chosen[slot.id] = avatar
        UserDefaults.standard.set(chosen, forKey: Self.key)
    }
}

/// El cuadro con los personajes disponibles, junto al personaje que se va a cambiar. Los que ya lleva otro puesto no se pueden elegir.
struct OfficeAvatarPicker: View {
    let current: String
    /// Los avatares que ya llevan otros puestos.
    let taken: Set<String>
    let anchor: CGPoint
    let bounds: CGSize
    let onPick: (String) -> Void
    let onClose: () -> Void

    @State private var shown = false
    @State private var hovered: String?

    /// Dos columnas hasta cuatro personajes; con más, tres.
    private var columnCount: Int { OfficeCharacter.all.count > 4 ? 3 : 2 }
    private var columns: [GridItem] { Array(repeating: GridItem(.fixed(92), spacing: 10), count: columnCount) }
    private var size: CGSize {
        let rows = (OfficeCharacter.all.count + columnCount - 1) / columnCount
        return CGSize(width: CGFloat(columnCount) * 92 + CGFloat(columnCount - 1) * 10 + 28, height: CGFloat(rows) * 150 + CGFloat(rows - 1) * 10 + 64)
    }

    var body: some View {
        let x = min(max(anchor.x, size.width / 2 + 12), max(size.width / 2 + 12, bounds.width - size.width / 2 - 12))
        let y = min(max(anchor.y - 30 - size.height / 2, size.height / 2 + 12), max(size.height / 2 + 12, bounds.height - size.height / 2 - 12))
        card
            .frame(width: size.width, height: size.height)
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
            .position(x: x, y: y)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { shown = true } }
    }

    private var card: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Elige avatar").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color(red: 0.11, green: 0.25, blue: 0.46))
                Spacer()
                Button {
                    OfficeSound.back.play()
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.11, green: 0.25, blue: 0.46).opacity(0.7))
                        .frame(width: 22, height: 22).background(Color(red: 0.9, green: 0.93, blue: 0.97), in: Circle())
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(OfficeCharacter.all) { avatar in tile(avatar) }
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    private func tile(_ avatar: OfficeCharacter) -> some View {
        let isCurrent = avatar.id == current
        let unavailable = taken.contains(avatar.id) && !isCurrent
        return Button {
            guard !unavailable else { return }
            OfficeSound.select.play()
            onPick(avatar.id)
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = avatar.thumbnail {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: "person.fill").font(.system(size: 34)).foregroundStyle(Color(red: 0.6, green: 0.68, blue: 0.8))
                        }
                    }
                    .frame(width: 92, height: 118)
                    .background(LinearGradient(colors: [Color(red: 0.93, green: 0.96, blue: 1), Color(red: 0.82, green: 0.88, blue: 0.96)],
                                               startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if isCurrent {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Color(red: 0.22, green: 0.55, blue: 0.95), in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5)).padding(5)
                    }
                }
                Text(unavailable ? "En uso" : avatar.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.25, blue: 0.46).opacity(unavailable ? 0.45 : 1))
            }
            .padding(4)
            .background(hovered == avatar.id && !unavailable ? Color(red: 0.88, green: 0.95, blue: 1) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isCurrent ? Color(red: 0.22, green: 0.55, blue: 0.95) : .clear, lineWidth: 2))
            .opacity(unavailable ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside, !unavailable, hovered != avatar.id { OfficeSound.hover.play() }
            if inside { hovered = avatar.id } else if hovered == avatar.id { hovered = nil }
        }
    }
}
