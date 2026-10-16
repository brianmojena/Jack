import JackCore
import SwiftUI

/// El letrero de la pared sobre un escritorio: el nombre del chat en neón rojo sobre una placa oscura.
struct OfficeLabelView: View {
    let title: String

    static let size = CGSize(width: 1024, height: 220)
    private static let neon = Color(red: 1.0, green: 0.27, blue: 0.33)

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.05, blue: 0.07)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Self.neon.opacity(0.55), lineWidth: 5)
                .shadow(color: Self.neon, radius: 14)
                .padding(16)
            Text(Self.short(title))
                .font(.system(size: 92, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 1.0, green: 0.86, blue: 0.87))
                .shadow(color: Self.neon, radius: 6)
                .shadow(color: Self.neon, radius: 22)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 60)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// Un nombre largo se queda en sus primeras palabras.
    static func short(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 26 else { return clean }
        var result = ""
        for word in clean.split(separator: " ") {
            guard result.count + word.count + 1 <= 25 else { break }
            result += (result.isEmpty ? "" : " ") + word
        }
        return (result.isEmpty ? String(clean.prefix(25)) : result) + "…"
    }

    @MainActor static func image(title: String) -> CGImage? {
        let renderer = ImageRenderer(content: OfficeLabelView(title: title))
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// La tele de la oficina: cuánto queda de los límites de Claude (la sesión de 5 h y la semana), con la estética de una
/// plataforma de streaming: fondo negro, rojo intenso, tipografía condensada y barras de progreso finas.
struct OfficeTVView: View {
    let session: UsageWindow?
    let week: UsageWindow?
    let now: Date

    static let size = CGSize(width: 1600, height: 900)
    static let red = Color(red: 0.898, green: 0.035, blue: 0.078)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            RadialGradient(colors: [Self.red.opacity(0.38), .clear], center: .topTrailing, startRadius: 40, endRadius: 1100)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("JACK")
                        .font(.system(size: 76, weight: .black).width(.condensed))
                        .foregroundStyle(Self.red)
                        .tracking(3)
                    Spacer()
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 34, weight: .semibold).width(.condensed))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Text("EN PANTALLA: TU USO DE CLAUDE")
                    .font(.system(size: 30, weight: .bold).width(.condensed))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 10)
                Text("Límites de uso")
                    .font(.system(size: 112, weight: .black).width(.condensed))
                    .foregroundStyle(.white)
                    .padding(.bottom, 44)
                HStack(alignment: .top, spacing: 44) {
                    card(title: "SESIÓN DE 5 HORAS", window: session)
                    card(title: "SEMANA", window: week)
                }
            }
            .padding(.horizontal, 90).padding(.top, 70).padding(.bottom, 80)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func card(title: String, window: UsageWindow?) -> some View {
        let used = window?.remainingPercent.map { 100 - $0 } ?? (window?.resetsAt.map { $0 <= now } == true ? 0 : nil)
        return VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 30, weight: .bold).width(.condensed))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(used.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 130, weight: .black).width(.condensed))
                    .foregroundStyle(.white)
                Text(used == nil ? "sin datos todavía" : "usado")
                    .font(.system(size: 34, weight: .semibold).width(.condensed))
                    .foregroundStyle(.white.opacity(0.55))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.22))
                    Rectangle().fill(Self.red).frame(width: proxy.size.width * CGFloat(min(max((used ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 12)
            Text(renewal(window))
                .font(.system(size: 30, weight: .medium).width(.condensed))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func renewal(_ window: UsageWindow?) -> String {
        guard let resetsAt = window?.resetsAt else { return "Se renueva cuando empiece la siguiente" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Ya se renovó" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Se renueva en \(max(minutes, 1)) min" }
        if minutes < 24 * 60 { return "Se renueva en \(minutes / 60) h \(minutes % 60) min" }
        return "Se renueva el " + resetsAt.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    @MainActor static func image(usage: ProviderUsage?, now: Date) -> CGImage? {
        let windows = usage?.windows ?? []
        let view = OfficeTVView(session: windows.first { $0.id == "five_hour" }, week: windows.first { $0.id == "seven_day" }, now: now)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }
}
