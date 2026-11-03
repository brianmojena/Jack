import JackCore
import SwiftUI

/// "Who's playing?": the profile screen, like a console's. Each person of the group has a profile; the chosen one is metered against
/// the shared Claude account. Arrows move, Enter chooses, Delete (twice) removes.
struct CodeOSProfilesView: View {
    @ObservedObject var model: CodeOSModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            VStack(spacing: 56 * u) {
                Spacer(minLength: 0)
                Text("¿Quién juega?").font(.system(size: 54 * u, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 60 * u) {
                    ForEach(Array(model.quota.profiles.enumerated()), id: \.element.id) { index, profile in
                        avatar(profile, focused: index == model.profileCursor, u: u)
                            .onTapGesture { if index == model.profileCursor { model.activateProfile() } else { model.moveProfile(index - model.profileCursor) } }
                    }
                    addTile(focused: model.profileCursor == model.quota.profiles.count, u: u)
                        .onTapGesture {
                            if model.profileCursor == model.quota.profiles.count { model.activateProfile() } else { model.moveProfile(model.quota.profiles.count - model.profileCursor) }
                        }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.profileCursor)
                if model.addingProfile {
                    VStack(spacing: 12 * u) {
                        TextField("Nombre del perfil", text: $model.newProfileName)
                            .textFieldStyle(.plain).font(.system(size: 30 * u, weight: .medium)).multilineTextAlignment(.center)
                            .focused($nameFocused).onSubmit { model.commitNewProfile() }
                            .padding(.horizontal, 30 * u).padding(.vertical, 14 * u).frame(width: 520 * u)
                            .background(.white.opacity(0.14), in: Capsule())
                        Text("ENTER para crear · ESC para cancelar").font(.system(size: 16 * u, weight: .bold)).tracking(1.5 * u).foregroundStyle(.white.opacity(0.6))
                    }
                    .onAppear { nameFocused = true }
                } else if model.confirmingRemoval {
                    Text("Pulsa BORRAR otra vez para eliminar este perfil").font(.system(size: 20 * u, weight: .semibold)).foregroundStyle(.orange)
                } else {
                    HStack(spacing: 38 * u) {
                        hint("FLECHAS", "ELEGIR", u)
                        hint("ENTER", "ENTRAR", u)
                        hint("BORRAR", "ELIMINAR PERFIL", u)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func avatar(_ profile: QuotaProfile, focused: Bool, u: CGFloat) -> some View {
        VStack(spacing: 18 * u) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hue: profile.hue, saturation: 0.65, brightness: 0.95), Color(hue: profile.hue, saturation: 0.8, brightness: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(profile.name.first ?? "?").uppercased()).font(.system(size: 92 * u, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 210 * u, height: 210 * u)
            .overlay { Circle().strokeBorder(.white.opacity(focused ? 0.75 : 0), lineWidth: 14 * u).blur(radius: 10 * u) }
            .overlay { Circle().strokeBorder(.white.opacity(focused ? 1 : 0), lineWidth: 4 * u) }
            .scaleEffect(focused ? 1.12 : 1)
            Text(profile.name).font(.system(size: 26 * u, weight: .semibold)).foregroundStyle(.white.opacity(focused ? 1 : 0.6))
        }
    }

    private func addTile(focused: Bool, u: CGFloat) -> some View {
        VStack(spacing: 18 * u) {
            Image(systemName: "plus").font(.system(size: 70 * u, weight: .light))
                .frame(width: 210 * u, height: 210 * u)
                .background(Circle().fill(.white.opacity(0.1)))
                .overlay { Circle().strokeBorder(.white.opacity(focused ? 0.75 : 0), lineWidth: 14 * u).blur(radius: 10 * u) }
                .overlay { Circle().strokeBorder(.white.opacity(focused ? 1 : 0.15), lineWidth: focused ? 4 * u : 1.5 * u) }
                .scaleEffect(focused ? 1.12 : 1)
            Text("Añadir perfil").font(.system(size: 26 * u, weight: .semibold)).foregroundStyle(.white.opacity(focused ? 1 : 0.6))
        }
        .foregroundStyle(.white)
    }

    private func hint(_ key: String, _ label: String, _ u: CGFloat) -> some View {
        HStack(spacing: 12 * u) {
            Text(key).font(.system(size: 15 * u, weight: .bold)).padding(.horizontal, 12 * u).frame(minWidth: 34 * u, minHeight: 34 * u)
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 2 * u))
            Text(label).font(.system(size: 17 * u, weight: .bold)).tracking(1.5 * u)
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// The quota panel (key U): how the Claude 5-hour window is split among the active profiles, who is connected and the group code.
struct CodeOSQuotaPanel: View {
    @ObservedObject var model: CodeOSModel
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var quota: CodeOSQuotaCoordinator { model.quota }

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { model.closeQuotaPanel() }
                VStack(alignment: .leading, spacing: 22 * u) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Cuota de Claude").font(.system(size: 32 * u, weight: .heavy))
                        Text("ventana de 5 horas").font(.system(size: 20 * u, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        if let used = quota.usedNow {
                            Text("Cuenta: \(Int(used.rounded())) % gastado").font(.system(size: 20 * u, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        } else {
                            Text("Sin lectura de la cuenta todavía").font(.system(size: 18 * u)).foregroundStyle(.orange)
                        }
                    }
                    if quota.shares.isEmpty {
                        Text(quota.active ? "Esperando la lectura de la cuenta para repartirla." : "Estás en pausa: nadie cuenta contigo en el reparto.")
                            .font(.system(size: 20 * u)).foregroundStyle(.white.opacity(0.7))
                    }
                    ForEach(quota.shares) { share in row(share, u: u) }
                    if let request = quota.incoming.first {
                        HStack {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                            Text("\(request.fromName) te pide \(Int(request.percent)) % de tu parte").font(.system(size: 21 * u, weight: .semibold))
                            Spacer()
                            keycap("Y", "CEDER", u) { model.quota.acceptFirstRequest() }
                            keycap("N", "RECHAZAR", u) { model.quota.declineFirstRequest() }
                        }
                        .padding(16 * u).background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 14 * u, style: .continuous))
                    }
                    Divider().overlay(.white.opacity(0.2))
                    HStack(spacing: 18 * u) {
                        Label("\(quota.peerCount) Mac\(quota.peerCount == 1 ? "" : "s") conectada\(quota.peerCount == 1 ? "" : "s")", systemImage: "wifi")
                        Text("Código del grupo").foregroundStyle(.white.opacity(0.55))
                        if model.editingCode {
                            TextField("XXXX-XXXX-XXXX-XXXX", text: $code).textFieldStyle(.plain).font(.system(size: 20 * u, design: .monospaced))
                                .focused($codeFocused).onSubmit { quota.setGroupCode(code); model.endEditingCode() }
                                .padding(.horizontal, 14 * u).padding(.vertical, 8 * u).background(.white.opacity(0.14), in: Capsule()).frame(width: 380 * u)
                                .onAppear { code = ""; codeFocused = true }
                        } else {
                            Text(quota.groupCode).font(.system(size: 20 * u, weight: .semibold, design: .monospaced))
                        }
                        Spacer()
                    }
                    .font(.system(size: 18 * u, weight: .medium))
                    if let message = quota.message { Text(message).font(.system(size: 18 * u, weight: .medium)).foregroundStyle(.cyan) }
                    HStack(spacing: 30 * u) {
                        keycap("A", quota.active ? "PAUSAR MI PERFIL" : "ACTIVAR MI PERFIL", u) { quota.setActive(!quota.active) }
                        keycap("R", "PEDIR CUOTA", u) { quota.requestShare() }
                        keycap("C", "CAMBIAR CÓDIGO", u) { model.beginEditingCode() }
                        keycap("P", "CAMBIAR DE PERFIL", u) { model.changeProfile() }
                        keycap("ESC", "CERRAR", u) { model.closeQuotaPanel() }
                    }
                }
                .foregroundStyle(.white)
                .padding(40 * u)
                .frame(width: min(1100 * u, geo.size.width - 80))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30 * u, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30 * u, style: .continuous).strokeBorder(.white.opacity(0.15)))
            }
        }
    }

    private func row(_ share: QuotaShare, u: CGFloat) -> some View {
        let mine = share.profile == quota.current?.id
        let fraction = share.base > 0 ? min(max(share.spent / share.base, 0), 1) : 1
        return HStack(spacing: 18 * u) {
            Circle().fill(Color(hue: share.hue, saturation: 0.65, brightness: 0.9)).frame(width: 40 * u, height: 40 * u)
                .overlay(Text(String(share.name.first ?? "?").uppercased()).font(.system(size: 20 * u, weight: .bold)))
            Text(share.name + (mine ? " (tú)" : "")).font(.system(size: 22 * u, weight: .semibold)).frame(width: 260 * u, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(share.remaining <= 0 ? Color.red : (fraction > 0.8 ? Color.orange : Color(hue: share.hue, saturation: 0.6, brightness: 0.95)))
                    .frame(width: max(CGFloat(fraction) * 420 * u, 8 * u))
            }
            .frame(width: 420 * u, height: 14 * u)
            Text(share.remaining <= 0 ? "agotada" : "queda \(Int(share.remaining.rounded())) % de \(Int(share.base.rounded())) %")
                .font(.system(size: 19 * u, weight: .medium)).foregroundStyle(share.remaining <= 0 ? .red : .white.opacity(0.8))
        }
    }

    private func keycap(_ key: String, _ label: String, _ u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10 * u) {
                Text(key).font(.system(size: 14 * u, weight: .bold)).padding(.horizontal, 10 * u).frame(minWidth: 30 * u, minHeight: 30 * u)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.8 * u))
                Text(label).font(.system(size: 15 * u, weight: .bold)).tracking(1.2 * u)
            }
            .foregroundStyle(.white.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
