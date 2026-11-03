import SwiftUI

private let psBlue = Color(red: 0.1, green: 0.45, blue: 1)

/// The home screen, laid out like the PlayStation 5 one: key art behind, categories on top, a shelf of square tiles
/// where the focused one grows and stays at a fixed spot while the rest slide past it.
struct CodeOSHomeView: View {
    @ObservedObject var model: CodeOSModel

    var body: some View {
        GeometryReader { geo in
            let u = max(geo.size.width / 2000, 0.45)
            ZStack(alignment: .topLeading) {
                heroArt(size: geo.size)
                topBar(u)
                categories(u)
                info(u, size: geo.size)
                shelf(u, size: geo.size)
                hints(u)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: Key art

    private func heroArt(size: CGSize) -> some View {
        ZStack {
            if let project = model.focused {
                Group {
                    if let cover = model.covers[project.id] {
                        // A cover is key art: it fills the screen and stays at full strength on the right, where nothing covers it.
                        Image(nsImage: cover).resizable().interpolation(.high).scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .overlay {
                                LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0), .init(color: .black.opacity(0.35), location: 0.32), .init(color: .clear, location: 0.58)],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                            .overlay {
                                LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black.opacity(0.6), location: 1)], startPoint: .top, endPoint: .bottom)
                            }
                            .overlay {
                                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2))
                            }
                    } else {
                        ZStack(alignment: .trailing) {
                            if let art = model.art[project.id] {
                                Image(nsImage: art.image).resizable().interpolation(.high).scaledToFill()
                                    .frame(width: size.height * 1.15, height: size.height * 1.15)
                            } else {
                                Text(project.initial)
                                    .font(.system(size: size.height * 0.9, weight: .black, design: .rounded))
                                    .foregroundStyle(project.color.opacity(0.4))
                                    .padding(.trailing, size.width * 0.08)
                            }
                        }
                        .frame(width: size.width, height: size.height, alignment: .trailing)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.9), location: 0.75)], startPoint: .leading, endPoint: .trailing))
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.45), .init(color: .clear, location: 0.95)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .id(project.id)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.55), value: model.focused?.id)
        .allowsHitTesting(false)
        // On a Mac with a notch the art runs up behind it; the controls stay below, inside the safe area.
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Top

    private func topBar(_ u: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 14 * u) {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 26 * u, weight: .regular)).monospacedDigit()
                }
                Image(systemName: "wifi").font(.system(size: 22 * u))
            }
            Spacer()
            HStack(spacing: 30 * u) {
                counter("bolt.fill", model.allProjects.filter(\.isLive).count, u)
                counter("clock.fill", model.allProjects.filter { CodeOSCategory.today.accepts($0) }.count, u)
                profileBadge(u)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 90 * u)
        .padding(.top, 52 * u)
    }

    /// Who is playing on this Mac and what is left of their share of the Claude quota. Clicking it opens the quota panel.
    private func profileBadge(_ u: CGFloat) -> some View {
        let profile = model.quota.current
        let remaining = model.quota.ownRemaining
        return HStack(spacing: 14 * u) {
            Circle().fill(LinearGradient(colors: [Color(hue: profile?.hue ?? 0.6, saturation: 0.65, brightness: 0.95), Color(hue: profile?.hue ?? 0.6, saturation: 0.8, brightness: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56 * u, height: 56 * u)
                .overlay(Text(String(profile?.name.first ?? "J")).font(.system(size: 26 * u, weight: .bold)))
            VStack(alignment: .leading, spacing: 2 * u) {
                Text(profile?.name ?? "Jugador").font(.system(size: 26 * u, weight: .semibold))
                if !model.quota.active {
                    Label("En pausa", systemImage: "pause.fill").font(.system(size: 17 * u, weight: .medium)).foregroundStyle(.orange)
                } else if let remaining {
                    Label(remaining <= 0 ? "Sin cuota" : "Queda \(Int(remaining.rounded())) %", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 17 * u, weight: .medium)).foregroundStyle(remaining <= 0 ? .red : .white.opacity(0.75))
                } else {
                    Label("\(model.allProjects.count) proyectos", systemImage: "folder.fill").font(.system(size: 17 * u, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleQuotaPanel() }
    }

    private func counter(_ symbol: String, _ count: Int, _ u: CGFloat) -> some View {
        HStack(spacing: 8 * u) {
            Image(systemName: symbol).font(.system(size: 24 * u))
            Text("\(count)").font(.system(size: 22 * u, weight: .semibold))
        }
    }

    private func categories(_ u: CGFloat) -> some View {
        HStack(spacing: 34 * u) {
            Button { model.shiftCategory(-1) } label: { keycap("Q", u) }.buttonStyle(.plain)
            ForEach(CodeOSCategory.allCases, id: \.self) { category in
                Button { model.selectCategory(category) } label: {
                    Text(category.title)
                        .font(.system(size: 22 * u, weight: .heavy)).tracking(1.5 * u)
                        .padding(.horizontal, 20 * u).padding(.vertical, 9 * u)
                        .overlay(Capsule().strokeBorder(psBlue, lineWidth: model.category == category ? 3.5 * u : 0))
                        .opacity(model.category == category ? 1 : 0.85)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { model.shiftCategory(1) } label: { keycap("E", u) }.buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: model.category)
        .offset(x: 120 * u, y: 150 * u)
    }

    private func keycap(_ label: String, _ u: CGFloat) -> some View {
        Text(label).font(.system(size: 15 * u, weight: .bold))
            .padding(.horizontal, 12 * u).padding(.vertical, 4 * u)
            .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1.6 * u))
            .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Info

    @ViewBuilder private func info(_ u: CGFloat, size: CGSize) -> some View {
        if model.loaded, model.focused == nil, model.focus == model.visible.count {
            VStack(alignment: .leading, spacing: 14 * u) {
                Text("Todos los proyectos").font(.system(size: 62 * u, weight: .heavy)).lineLimit(1)
                Text("\(model.allProjects.count) proyectos en una cuadrícula")
                    .font(.system(size: 23 * u, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .frame(width: size.width * 0.5, alignment: .leading)
            .offset(x: 190 * u, y: size.height - 280 * u - 130 * u - 360 * u)
        } else if let project = model.focused {
            VStack(alignment: .leading, spacing: 14 * u) {
                Text(project.name)
                    .font(.system(size: 62 * u, weight: .heavy)).lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 12 * u)
                Label(project.ago, systemImage: project.isLive ? "bolt.fill" : "clock")
                    .font(.system(size: 23 * u, weight: .semibold)).foregroundStyle(project.isLive ? Color.cyan : .white.opacity(0.75))
                if !project.title.isEmpty {
                    Text("«\(project.title)»")
                        .font(.system(size: 20 * u)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
                Text(project.id)
                    .font(.system(size: 17 * u, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).truncationMode(.head)
                Button { model.openFocused() } label: {
                    HStack(spacing: 12 * u) {
                        Image(systemName: "play.fill")
                        Text("Abrir proyecto").fontWeight(.bold)
                    }
                    .font(.system(size: 23 * u))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 36 * u).padding(.vertical, 16 * u)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 10 * u)
                if let notice = model.notice {
                    Text(notice).font(.system(size: 17 * u, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(.top, 6 * u)
                }
            }
            .foregroundStyle(.white)
            .frame(width: size.width * 0.5, alignment: .leading)
            .offset(x: 190 * u, y: size.height - 280 * u - 130 * u - 360 * u)
            .id(project.id)
            .transition(.opacity.combined(with: .offset(y: 14)))
            .animation(.easeOut(duration: 0.3), value: model.focus)
        }
    }

    // MARK: Shelf

    private func shelf(_ u: CGFloat, size: CGSize) -> some View {
        let normal = 215 * u, big = 262 * u, gap = 30 * u
        let baseX = 190 * u, centerY = size.height - 280 * u
        let projects = model.visible
        /// Where the tile at `index` sits: the focused one keeps a fixed spot and the rest slide past it.
        func place(_ index: Int) -> (x: CGFloat, side: CGFloat) {
            let focused = index == model.focus
            let x = index < model.focus
                ? baseX - CGFloat(model.focus - index) * (normal + gap)
                : (focused ? baseX : baseX + big + gap + CGFloat(index - model.focus - 1) * (normal + gap))
            return (x, focused ? big : normal)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                let spot = place(index)
                CodeOSTile(project: project, art: model.art[project.id], focused: index == model.focus, u: u)
                    .frame(width: spot.side, height: spot.side)
                    .offset(x: spot.x, y: centerY - spot.side / 2)
                    .onTapGesture { if index == model.focus { model.openFocused() } else { model.moveFocus(index - model.focus) } }
            }
            if model.loaded {
                // The last tile opens the grid of every project.
                let all = place(projects.count)
                CodeOSSeeAllTile(count: model.allProjects.count, focused: model.focus == projects.count, u: u)
                    .frame(width: all.side, height: all.side)
                    .offset(x: all.x, y: centerY - all.side / 2)
                    .onTapGesture { if model.focus == projects.count { model.openGrid() } else { model.moveFocus(projects.count - model.focus) } }
                Text((model.focused?.name ?? "Ver todos").uppercased())
                    .font(.system(size: 16 * u, weight: .heavy)).tracking(2 * u)
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(x: baseX, y: centerY + big / 2 + 18 * u)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.focus)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.category)
    }

    // MARK: Hints

    private func hints(_ u: CGFloat) -> some View {
        HStack(spacing: 38 * u) {
            hint("TAB", "CENTRO DE CONTROL", u) { model.toggleControlCenter() }
            hint("G", model.generating.isEmpty ? "GENERAR PORTADA" : "GENERANDO…", u) { model.generateFocusedCover() }
            hint("U", "CUOTA", u) { model.toggleQuotaPanel() }
            hint("V", "VER TODOS", u) { model.openGrid() }
            hint("BORRAR", "QUITAR", u) { model.removeFocused() }
            hint("F", "PANTALLA COMPLETA", u) { if let window = NSApp.keyWindow { CodeOSWindow.toggleFullScreen(window) } }
            hint("ENTER", "ABRIR", u) { model.openFocused() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 110 * u)
        .padding(.bottom, 44 * u)
    }

    /// A key hint that is also a button: the same action by mouse.
    private func hint(_ key: String, _ label: String, _ u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12 * u) {
                Text(key).font(.system(size: 15 * u, weight: .bold)).padding(.horizontal, 12 * u).frame(minWidth: 34 * u, minHeight: 34 * u)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 2 * u))
                Text(label).font(.system(size: 17 * u, weight: .bold)).tracking(1.5 * u)
            }
            .foregroundStyle(.white.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CodeOSTile: View {
    let project: CodeOSProject
    let art: CodeOSModel.Art?
    let focused: Bool
    let u: CGFloat

    var body: some View {
        CodeOSArtwork(project: project, art: art, corner: 7 * u)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13 * u, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30 * u, height: 30 * u)
                    .background(Color.cyan, in: Circle())
                    .padding(10 * u)
                    .opacity(project.isLive ? 1 : 0)
            }
            .focusRing(focused, u: u)
            .shadow(color: .black.opacity(focused ? 0.55 : 0.25), radius: focused ? 26 * u : 10 * u, y: 10 * u)
            .brightness(focused ? 0 : -0.12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(project.name), \(project.ago)")
            .accessibilityAddTraits(.isButton)
    }
}

/// The last tile of the shelf: opens the grid with every project.
struct CodeOSSeeAllTile: View {
    let count: Int
    let focused: Bool
    let u: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7 * u, style: .continuous).fill(.white.opacity(0.1))
            VStack(spacing: 14 * u) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 54 * u))
                Text("VER TODOS").font(.system(size: 17 * u, weight: .heavy)).tracking(2 * u)
                Text("\(count)").font(.system(size: 15 * u, weight: .medium)).opacity(0.6)
            }
            .foregroundStyle(.white)
        }
        .focusRing(focused, u: u)
        .shadow(color: .black.opacity(focused ? 0.5 : 0.2), radius: focused ? 24 * u : 8 * u, y: 10 * u)
        .brightness(focused ? 0 : -0.1)
    }
}

extension View {
    /// The focus ring of a shelf tile: a thick white border with a soft glow around it, so the selection reads from across the room.
    func focusRing(_ focused: Bool, u: CGFloat, corner: CGFloat = 7) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner * u, style: .continuous)
        return self
            .overlay { shape.strokeBorder(.white.opacity(focused ? 0.75 : 0), lineWidth: 10 * u).blur(radius: 9 * u) }
            .overlay { shape.strokeBorder(.white.opacity(focused ? 1 : 0.08), lineWidth: focused ? 3 * u : 1.5 * u) }
    }
}
