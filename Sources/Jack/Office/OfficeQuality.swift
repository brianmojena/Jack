import AppKit
import RealityKit
import SwiftUI

/// Los ajustes gráficos de la oficina 3D. `ultra` es como se ve de siempre; el resto lo recorta para gastar menos batería.
struct OfficeQuality: Codable, Equatable {
    /// Tamaño con el que se dibuja la escena (1 = el de la ventana; menos es más borroso y más ligero).
    var resolution = 1.0
    /// Fotogramas por segundo máximos de toda la escena (también al mover la cámara); 0 deja que mande la pantalla.
    var frameRate = 0
    /// Cuántas veces por segundo se recolocan las burbujas ancladas a los personajes; 0 es en cada fotograma.
    var bubbleRate = 0
    /// Suavizado de bordes: 4 (activado) o 0 (sin él).
    var antialiasing = 4
    /// La oclusión ambiental y el acabado de imagen (rincones y contacto con el suelo oscurecidos).
    var ambientOcclusion = true
    /// Sombras de los focos y de contacto bajo los muebles y los personajes.
    var shadows = true
    /// El reflejo del espejo (dibuja la sala una segunda vez).
    var mirror = true
    /// El brillo de los logos de neón de la pared.
    var neon = true
    /// La iluminación: 3 realista (focos, rellenos y halos), 2 realista sin los halos de los logos y 1 simple (luz natural
    /// pareja, sin focos ni puntos de luz: todo se ve iluminado y ya).
    var lights = 3
    /// Cada cuántos segundos se actualizan los monitores, la tele y los letreros.
    var screenInterval = 0.6
    /// Los monitores muestran el chat real, igual que «Ver pantalla»; si no, un resumen ligero que gasta mucho menos.
    var liveScreens = true
    /// Los personajes del sofá se mueven; si no, se quedan quietos en su postura.
    var idleAnimation = true

    static let ultra = OfficeQuality()
    static let high = OfficeQuality(frameRate: 60, bubbleRate: 60, screenInterval: 1)
    static let medium = OfficeQuality(resolution: 0.75, frameRate: 30, bubbleRate: 30, ambientOcclusion: false, shadows: false,
                                      mirror: false, neon: false, lights: 2, screenInterval: 2, liveScreens: false)
    static let low = OfficeQuality(resolution: 0.5, frameRate: 20, bubbleRate: 15, antialiasing: 0, ambientOcclusion: false, shadows: false,
                                   mirror: false, neon: false, lights: 1, screenInterval: 5, liveScreens: false, idleAnimation: false)

    enum Preset: String, CaseIterable, Identifiable {
        case ultra, high, medium, low

        var id: String { rawValue }
        var title: String {
            switch self { case .ultra: "Ultra"; case .high: "Alto"; case .medium: "Medio"; case .low: "Bajo" }
        }
        var quality: OfficeQuality {
            switch self { case .ultra: .ultra; case .high: .high; case .medium: .medium; case .low: .low }
        }
    }

    /// El predefinido al que se parece exactamente, o `nil` si se tocó algo a mano.
    var preset: Preset? { Preset.allCases.first { $0.quality == self } }

    /// Cuánto trabajo pide a la Mac respecto a Ultra (1 = todo), como una estimación para orientar, no una medida.
    var load: Double {
        var cost = 1.0
        cost *= resolution * resolution * 0.7 + 0.3
        cost *= frameRate == 0 ? 1 : min(1, Double(frameRate) / 60 + 0.1)
        cost *= bubbleRate == 0 ? 1 : 0.97
        cost *= antialiasing == 0 ? 0.8 : 1
        cost *= ambientOcclusion ? 1 : 0.8
        cost *= shadows ? 1 : 0.75
        cost *= mirror ? 1 : 0.6
        cost *= neon ? 1 : 0.95
        cost *= [1: 0.8, 2: 0.92, 3: 1][lights] ?? 1
        cost *= idleAnimation ? 1 : 0.92
        cost *= liveScreens ? 1 : 0.9
        return max(0.03, min(1, cost))
    }

    /// Cada cuánto se redibujan las burbujas ancladas a los personajes (`nil`: en cada fotograma).
    var hudInterval: Double? {
        let rate = [bubbleRate, frameRate].filter { $0 > 0 }.min() ?? 0
        return rate == 0 ? nil : 1 / Double(rate)
    }
}

/// Guarda y publica los ajustes gráficos de la oficina.
@MainActor final class OfficeGraphics: ObservableObject {
    static let key = "officeQuality"

    @Published var quality: OfficeQuality {
        didSet { if let data = try? JSONEncoder().encode(quality) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }
    @Published var panelOpen = false
    /// Enseñar los fotogramas por segundo de la escena.
    @Published var showFPS: Bool {
        didSet { UserDefaults.standard.set(showFPS, forKey: "officeShowFPS") }
    }
    /// Los fotogramas por segundo medidos en el último segundo.
    @Published var fps = 0.0

    init() {
        showFPS = UserDefaults.standard.bool(forKey: "officeShowFPS")
        quality = UserDefaults.standard.data(forKey: Self.key).flatMap(Self.decode) ?? .ultra
    }

    /// Los ajustes guardados; a los de una versión anterior se les completan las opciones nuevas con su valor de Ultra.
    private static func decode(_ data: Data) -> OfficeQuality? {
        if let saved = try? JSONDecoder().decode(OfficeQuality.self, from: data) { return saved }
        guard var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(OfficeQuality.ultra))) as? [String: Any] else { return nil }
        for (key, value) in defaults where saved[key] == nil { saved[key] = value }
        return (try? JSONSerialization.data(withJSONObject: saved)).flatMap { try? JSONDecoder().decode(OfficeQuality.self, from: $0) }
    }
}

// MARK: - Botón y panel

/// El engranaje de arriba a la derecha y, al pulsarlo, el panel de gráficos al estilo de un videojuego.
struct OfficeGraphicsMenu: View {
    @ObservedObject var graphics: OfficeGraphics

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                if graphics.showFPS {
                    Text("\(Int(graphics.fps.rounded())) FPS")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(graphics.fps >= 50 ? Color.green : graphics.fps >= 25 ? Color.yellow : Color.orange)
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(.black.opacity(0.55), in: Capsule())
                        .transition(.opacity)
                }
                gear
            }
            if graphics.panelOpen {
                OfficeGraphicsPanel(graphics: graphics)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .padding(.top, 10).padding(.trailing, 12)
    }

    private var gear: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { graphics.panelOpen.toggle() } } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(graphics.panelOpen ? OfficeGraphicsStyle.accent : .white.opacity(0.9))
                    .rotationEffect(.degrees(graphics.panelOpen ? 60 : 0))
                    .frame(width: 32, height: 32)
                    .modifier(OfficeGlassCircle())
            }
            .buttonStyle(.plain)
            .help("Gráficos")
        }
    }
}

/// El botón redondo: Liquid Glass en macOS 26 y, antes, un círculo oscuro translúcido.
private struct OfficeGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
    }
}

private struct OfficeGraphicsPanel: View {
    @ObservedObject var graphics: OfficeGraphics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gráficos").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(graphics.quality.preset?.title ?? "Personalizado")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(OfficeGraphicsStyle.accent)
            }
            Picker("Calidad", selection: Binding(get: { graphics.quality.preset }, set: { if let preset = $0 { graphics.quality = preset.quality } })) {
                ForEach(OfficeQuality.Preset.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented).labelsHidden()
            loadMeter
            Divider()
            VStack(spacing: 8) {
                choice("Resolución", $graphics.quality.resolution, [(1.0, "100 %"), (0.75, "75 %"), (0.5, "50 %")])
                choice("Fotogramas", $graphics.quality.frameRate, [(0, "Auto"), (60, "60"), (30, "30"), (20, "20")])
                choice("Burbujas", $graphics.quality.bubbleRate, [(0, "Fluidas"), (30, "Normales"), (15, "Lentas")])
                choice("Suavizado de bordes", $graphics.quality.antialiasing, [(4, "Sí"), (0, "No")])
                toggle("Oclusión ambiental", $graphics.quality.ambientOcclusion)
                toggle("Sombras", $graphics.quality.shadows)
                toggle("Espejo", $graphics.quality.mirror)
                toggle("Neón de los logos", $graphics.quality.neon)
                choice("Iluminación", $graphics.quality.lights, [(3, "Realista"), (2, "Sin halos"), (1, "Simple")])
                choice("Pantallas", $graphics.quality.liveScreens, [(true, "En vivo"), (false, "Ahorro")])
                choice("Refresco", $graphics.quality.screenInterval, [(0.6, "Rápido"), (2.0, "Normal"), (5.0, "Lento")])
                toggle("Personajes en reposo", $graphics.quality.idleAnimation)
                Divider()
                toggle("Mostrar FPS", $graphics.showFPS)
            }
            Text("«En vivo» muestra en los monitores el chat real, como «Ver pantalla»; «Ahorro», un resumen ligero. Bajo ahorra mucha batería; Ultra es como se ve de siempre.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .tint(OfficeGraphicsStyle.accent)
        .modifier(OfficeGlassPanel())
        .environment(\.colorScheme, .dark)
    }

    /// Una barra con lo que gasta la configuración actual.
    private var loadMeter: some View {
        let load = graphics.quality.load
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Consumo estimado").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((load * 100).rounded())) %").font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            ProgressView(value: load).progressViewStyle(.linear)
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
    }

    private func choice<Value: Hashable>(_ title: String, _ value: Binding<Value>, _ options: [(Value, String)]) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            Picker(title, selection: value) {
                ForEach(options, id: \.1) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        }
    }
}

/// El fondo del panel: Liquid Glass en macOS 26 y, antes, un material translúcido.
private struct OfficeGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        }
    }
}

private enum OfficeGraphicsStyle {
    /// El naranja de Jack: el del nodo activo del icono de la app.
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.16)
}
