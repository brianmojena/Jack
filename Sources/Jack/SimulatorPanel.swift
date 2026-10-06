import AppKit
import JackCore
import QuartzCore
import SwiftUI

/// The iOS simulator shown in the workspace pane. Simulators belong to the Mac, not to an agent,
/// so every agent's "Simulador" tab shows this one session.
@MainActor final class SimulatorSession: ObservableObject {
    enum Phase: Equatable { case loading, off, booting, preparing, running, stopping }

    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var selectedUDID: String?
    @Published private(set) var display: SimulatorDisplay?
    @Published private(set) var error: String?
    @Published private(set) var capturing = false
    private var visiblePanels = 0
    private var polling: Task<Void, Never>?
    private var idleShutdown: Task<Void, Never>?
    /// Devices Jack turned on; only these are turned off when idle or when Jack quits.
    private var bootedHere = Set<String>()
    private static let deviceKey = "simulatorDevice"
    static let lightModeKey = "simulatorLightMode"
    static let idleMinutesKey = "simulatorIdleMinutes"
    static let shutdownOnQuitKey = "simulatorShutdownOnQuit"
    /// Devices whose heavy services are disabled, as "udid" entries.
    private static let lightAppliedKey = "simulatorLightApplied"

    init() {
        UserDefaults.standard.register(defaults: [Self.lightModeKey: true, Self.idleMinutesKey: 10, Self.shutdownOnQuitKey: true])
    }

    var selected: SimulatorDevice? { devices.first { $0.udid == selectedUDID } }

    /// Lists devices while a panel shows, so a simulator an agent boots from the terminal appears here.
    func panelAppeared() {
        visiblePanels += 1
        idleShutdown?.cancel()
        idleShutdown = nil
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        if visiblePanels == 0 {
            polling?.cancel()
            polling = nil
            scheduleIdleShutdown()
        }
    }

    /// Turns off a simulator Jack booted once nobody has looked at it for a while, unless Xcode is using it.
    private func scheduleIdleShutdown() {
        let minutes = UserDefaults.standard.integer(forKey: Self.idleMinutesKey)
        guard minutes > 0, idleShutdown == nil else { return }
        idleShutdown = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled, let self else { return }
                guard self.visiblePanels == 0, let udid = self.selectedUDID, self.bootedHere.contains(udid), self.phase == .running else { break }
                if await Simulators.xcodebuildRunning() { continue }
                guard !Task.isCancelled, self.visiblePanels == 0 else { return }
                self.shutdown()
                break
            }
            self?.idleShutdown = nil
        }
    }

    /// When Jack quits, the simulators it turned on go off with it.
    func shutdownOnQuit() {
        guard UserDefaults.standard.bool(forKey: Self.shutdownOnQuitKey) else { return }
        Simulators.shutdownNow(Array(bootedHere))
    }

    func refresh() async {
        let list = await Simulators.list()
        if list != devices { devices = list }
        if selectedUDID == nil || !list.contains(where: { $0.udid == selectedUDID }) {
            let remembered = UserDefaults.standard.string(forKey: Self.deviceKey)
            selectedUDID = (list.first { $0.booted } ?? list.first { $0.udid == remembered } ?? list.first { $0.name.hasPrefix("iPhone") } ?? list.first)?.udid
        }
        sync()
    }

    func select(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
        UserDefaults.standard.set(udid, forKey: Self.deviceKey)
        display = nil
        error = nil
        sync()
    }

    /// Matches the panel to the device: shows the screen of a booted one, the power button otherwise.
    private func sync() {
        guard phase != .booting, phase != .preparing, phase != .stopping else { return }
        guard let selected else {
            phase = .off
            display = nil
            return
        }
        if selected.booted {
            if display?.udid != selected.udid { display = SimulatorDisplay(udid: selected.udid) }
            if phase != .running { phase = .running }
        } else {
            display = nil
            if phase != .off { phase = .off }
        }
    }

    func boot() {
        guard let udid = selectedUDID, phase == .off else { return }
        phase = .booting
        error = nil
        UserDefaults.standard.set(udid, forKey: Self.deviceKey)
        Task {
            var failure = await Simulators.boot(udid)
            if failure == nil { bootedHere.insert(udid) }
            if failure == nil, await applyLightMode(udid) {
                // The services change takes effect on a fresh boot; this happens once per device.
                await Simulators.shutdown(udid)
                phase = .booting
                failure = await Simulators.boot(udid)
            }
            phase = .off
            error = failure
            await refresh()
        }
    }

    /// Brings the device's services in line with the light-mode setting; true when it needs a reboot.
    private func applyLightMode(_ udid: String) async -> Bool {
        let wanted = UserDefaults.standard.bool(forKey: Self.lightModeKey)
        var applied = Set(UserDefaults.standard.stringArray(forKey: Self.lightAppliedKey) ?? [])
        guard wanted != applied.contains(udid) else { return false }
        phase = .preparing
        await Simulators.setLightModeServices(udid, enabled: !wanted)
        if wanted { applied.insert(udid) } else { applied.remove(udid) }
        UserDefaults.standard.set(Array(applied), forKey: Self.lightAppliedKey)
        return true
    }

    func shutdown() {
        guard let udid = selectedUDID, phase == .running else { return }
        phase = .stopping
        display = nil
        bootedHere.remove(udid)
        Task {
            await Simulators.shutdown(udid)
            phase = .off
            await refresh()
        }
    }

    func screenshot() async -> String? {
        guard let udid = selectedUDID, phase == .running else { return nil }
        capturing = true
        defer { capturing = false }
        return await Simulators.screenshot(udid)
    }

    func openInSimulatorApp() {
        var arguments = ["-a", "Simulator"]
        if let selectedUDID { arguments += ["--args", "-CurrentDeviceUDID", selectedUDID] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try? process.run()
    }
}

// MARK: - Panel

struct SimulatorPanel: View {
    @ObservedObject var session: SimulatorSession
    let onAttach: ([String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            ZStack {
                JackPalette.canvas
                content
            }
        }
        .onAppear(perform: session.panelAppeared)
        .onDisappear(perform: session.panelDisappeared)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            deviceMenu
            Spacer(minLength: 6)
            toolButton("house", help: "Inicio (⇧⌘H)", enabled: session.display != nil) { session.display?.press(.home) }
            toolButton("lock", help: "Bloquear pantalla", enabled: session.display != nil) { session.display?.press(.lock) }
            toolButton(session.capturing ? "hourglass" : "camera", help: "Enviar una captura al chat del agente", enabled: session.phase == .running && !session.capturing) {
                Task { if let path = await session.screenshot() { onAttach([path]) } }
            }
            toolButton("macwindow", help: "Abrir en Simulator.app", enabled: session.selected != nil) { session.openInSimulatorApp() }
            toolButton("power", help: session.phase == .running ? "Apagar" : "Encender", enabled: session.phase == .running || session.phase == .off && session.selected != nil,
                       tint: session.phase == .running ? JackPalette.green : nil) {
                session.phase == .running ? session.shutdown() : session.boot()
            }
        }
        .padding(.horizontal, 6).frame(height: 36)
    }

    private var deviceMenu: some View {
        Menu {
            let runtimes = session.devices.reduce(into: [String]()) { list, device in if !list.contains(device.runtime) { list.append(device.runtime) } }
            ForEach(runtimes, id: \.self) { runtime in
                Section(runtime) {
                    ForEach(session.devices.filter { $0.runtime == runtime }) { device in
                        Button { session.select(device.udid) } label: {
                            if device.udid == session.selectedUDID { Label(device.name, systemImage: "checkmark") }
                            else { Text(device.booted ? "\(device.name) · encendido" : device.name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.selected?.name.hasPrefix("iPad") == true ? "ipad" : "iphone").font(.system(size: 11.5))
                Text(session.selected?.name ?? "Sin simulador").font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let runtime = session.selected?.runtime {
                    Text(runtime).font(.system(size: 11)).foregroundStyle(JackPalette.muted).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(JackPalette.muted)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(session.devices.isEmpty)
        .help("Elegir simulador")
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .booting, .preparing, .stopping:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(phaseTitle).font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                if session.phase == .preparing {
                    Text("Desactivando Siri, Apple Intelligence y otros servicios que no necesitas para probar tu app. Solo la primera vez.")
                        .font(.system(size: 11)).foregroundStyle(JackPalette.faint)
                        .multilineTextAlignment(.center).frame(maxWidth: 280)
                }
            }
        case .running:
            if let display = session.display {
                SimulatorScreen(display: display).padding(14)
            } else {
                message("rectangle.slash", "La pantalla no se puede mostrar aquí",
                        "Esta versión de Xcode no expone la pantalla del simulador. Puedes seguir usándolo en Simulator.app.") {
                    Button("Abrir en Simulator.app", action: session.openInSimulatorApp)
                }
            }
        case .off:
            if session.devices.isEmpty {
                message("iphone.slash", "No hay simuladores de iOS",
                        "Instala Xcode y un runtime de iOS desde Xcode › Ajustes › Componentes.") { EmptyView() }
            } else {
                message(session.selected?.name.hasPrefix("iPad") == true ? "ipad" : "iphone", "\(session.selected?.name ?? "El simulador") está apagado",
                        session.error ?? "Enciéndelo para ver y tocar la app aquí mismo, junto al agente.") {
                    Button("Encender", action: session.boot).controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var phaseTitle: String {
        switch session.phase {
        case .preparing: "Preparando el modo ligero…"
        case .stopping: "Apagando…"
        default: "Encendiendo \(session.selected?.name ?? "el simulador")…"
        }
    }

    private func message<Actions: View>(_ symbol: String, _ title: String, _ detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(JackPalette.faint)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .padding(20).frame(maxWidth: 340)
    }

    private func toolButton(_ symbol: String, help: String, enabled: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? tint ?? JackPalette.secondaryText : JackPalette.faint)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Screen

private struct SimulatorScreen: NSViewRepresentable {
    let display: SimulatorDisplay
    func makeNSView(context: Context) -> SimulatorScreenView { SimulatorScreenView(display: display) }
    func updateNSView(_ view: SimulatorScreenView, context: Context) { view.display = display }
    static func dismantleNSView(_ view: SimulatorScreenView, coordinator: ()) { view.display.stop() }
}

/// Shows the framebuffer in a layer, so each frame is composited on the GPU without copying,
/// and turns clicks, drags, scrolling and typing into touches and key presses on the device.
final class SimulatorScreenView: NSView {
    var display: SimulatorDisplay {
        didSet {
            guard display !== oldValue else { return }
            oldValue.stop()
            attach()
        }
    }
    private let screenLayer = CALayer()
    private var touching = false
    private var scrollPoint: CGPoint?

    init(display: SimulatorDisplay) {
        self.display = display
        super.init(frame: .zero)
        wantsLayer = true
        screenLayer.contentsGravity = .resize
        screenLayer.masksToBounds = true
        screenLayer.backgroundColor = NSColor.black.cgColor
        screenLayer.borderColor = NSColor.separatorColor.cgColor
        screenLayer.borderWidth = 1
        layer?.addSublayer(screenLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { display.stop() } else { attach() }
    }

    private func attach() {
        guard window != nil else { return }
        showSurface()
        display.start(frame: { [weak self] in self?.frameChanged() }, surfaceChanged: { [weak self] in self?.showSurface() })
    }

    private func showSurface() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.contents = display.surface
        CATransaction.commit()
        needsLayout = true
    }

    /// The surface is drawn in place by the simulator; the layer only needs to know it changed.
    private func frameChanged() {
        let selector = NSSelectorFromString("setContentsChanged")
        if screenLayer.responds(to: selector) {
            screenLayer.perform(selector)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            screenLayer.contents = nil
            screenLayer.contents = display.surface
            CATransaction.commit()
        }
    }

    /// Where the device screen sits: as large as fits, keeping its proportions.
    private var screenRect: CGRect {
        let size = display.pixelSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return CGRect(x: ((bounds.width - fitted.width) / 2).rounded(), y: ((bounds.height - fitted.height) / 2).rounded(),
                      width: fitted.width, height: fitted.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = screenRect
        screenLayer.frame = rect
        // Recent iPhones and iPads have rounded displays.
        screenLayer.cornerRadius = min(rect.width, rect.height) * (rect.height > rect.width * 1.8 || rect.width > rect.height * 1.8 ? 0.14 : 0.05)
        screenLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { screenLayer.borderColor = NSColor.separatorColor.cgColor }
    }

    // MARK: Touch

    private func devicePoint(_ event: NSEvent) -> CGPoint? {
        let location = convert(event.locationInWindow, from: nil)
        return devicePoint(location, clamped: touching)
    }

    private func devicePoint(_ location: CGPoint, clamped: Bool) -> CGPoint? {
        let rect = screenRect
        guard rect.width > 0 else { return nil }
        if !clamped && !rect.contains(location) { return nil }
        let size = display.pixelSize
        let x = min(max(location.x - rect.minX, 0), rect.width) / rect.width * size.width
        let y = min(max(location.y - rect.minY, 0), rect.height) / rect.height * size.height
        return CGPoint(x: x, y: y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = devicePoint(event) else { return }
        touching = true
        display.touch(point, .down)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let point = devicePoint(event) else { return }
        display.touch(point, .moved)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { return }
        if let point = devicePoint(event) { display.touch(point, .up) }
        touching = false
    }

    /// Two-finger scrolling becomes a finger dragging the content, as on the device.
    override func scrollWheel(with event: NSEvent) {
        guard !touching else { return }
        let size = display.pixelSize
        let rect = screenRect
        guard rect.width > 0 else { return }
        let factor = size.width / rect.width
        let delta = CGPoint(x: event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 12) * factor,
                            y: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12) * factor)
        let clampedPoint = { (point: CGPoint) in
            CGPoint(x: min(max(point.x, 1), size.width - 1), y: min(max(point.y, 1), size.height - 1))
        }
        switch event.phase {
        case .began:
            guard let start = devicePoint(convert(event.locationInWindow, from: nil), clamped: false) else { return }
            scrollPoint = start
            display.touch(start, .down)
        case .changed:
            guard let current = scrollPoint else { return }
            let next = clampedPoint(CGPoint(x: current.x + delta.x, y: current.y + delta.y))
            scrollPoint = next
            display.touch(next, .moved)
        case .ended, .cancelled:
            if let current = scrollPoint { display.touch(current, .up) }
            scrollPoint = nil
        default:
            // A mouse wheel has no phases: a short swipe per notch.
            guard event.phase.isEmpty, event.momentumPhase.isEmpty,
                  let start = devicePoint(convert(event.locationInWindow, from: nil), clamped: false) else { return }
            display.touch(start, .down)
            display.touch(clampedPoint(CGPoint(x: start.x + delta.x, y: start.y + delta.y)), .moved)
            display.touch(clampedPoint(CGPoint(x: start.x + delta.x, y: start.y + delta.y)), .up)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⇧⌘H is the simulator's Home shortcut; other ⌘ shortcuts stay with Jack.
            if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "h" { display.press(.home); return }
            super.keyDown(with: event)
            return
        }
        display.key(event)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyUp(with: event); return }
        display.key(event)
    }

    private var heldModifiers: NSEvent.ModifierFlags = []
    private static let modifierUsages: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0xE1), (.control, 0xE0), (.option, 0xE2), (.capsLock, 0x39)]

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .capsLock])
        for (flag, usage) in Self.modifierUsages where flags.contains(flag) != heldModifiers.contains(flag) {
            // Caps Lock toggles on each press, so it is a full press either way.
            if flag == .capsLock { display.modifier(usage, down: true); display.modifier(usage, down: false) }
            else { display.modifier(usage, down: flags.contains(flag)) }
        }
        heldModifiers = flags
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // Keys held while focus moves away must not stay pressed on the device.
        for (flag, usage) in Self.modifierUsages where flag != .capsLock && heldModifiers.contains(flag) { display.modifier(usage, down: false) }
        heldModifiers.remove([.shift, .control, .option])
        return super.resignFirstResponder()
    }
}
