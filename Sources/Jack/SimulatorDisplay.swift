import AppKit
import IOSurface
import ObjectiveC

/// A booted simulator's screen and touch input, straight from Xcode's simulator frameworks:
/// the framebuffer is shared memory, so showing it costs no copies and needs no screen-recording
/// permission, and touches go in as the device's own HID events. These are private APIs, so every
/// lookup is checked and a failure only means the panel falls back to Simulator.app.
final class SimulatorDisplay: @unchecked Sendable {
    enum Button: UInt32 { case home = 0x0, lock = 0x1 }
    enum TouchPhase: UInt { case down = 1, up = 2, moved = 6 }

    let udid: String
    /// The framebuffer, an IOSurface; it is replaced when the device rotates or changes size.
    private(set) var surface: AnyObject
    var pixelSize: CGSize {
        let ref = unsafeBitCast(surface, to: IOSurfaceRef.self)
        return CGSize(width: IOSurfaceGetWidth(ref), height: IOSurfaceGetHeight(ref))
    }

    private let screen: AnyObject
    private let hid: AnyObject
    private let callbackID = NSUUID()
    private let queue = DispatchQueue(label: "dev.jack.simulator.hid")
    private let lock = NSLock()
    private var framePending = false
    private var observing = false
    private var onFrame: (() -> Void)?
    private var onSurface: (() -> Void)?

    /// nil when the device is not booted or the frameworks are not what Jack expects.
    init?(udid: String) {
        guard let bridge = SimulatorBridge.shared, let device = bridge.device(udid) else { return nil }
        let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue()
        if let io, io.responds(to: NSSelectorFromString("updateIOPorts")) { _ = io.perform(NSSelectorFromString("updateIOPorts")) }
        let ports = (io?.value(forKey: "ioPorts") as? [AnyObject]) ?? []
        let surfaceSelector = NSSelectorFromString("framebufferSurface")
        var found: (AnyObject, AnyObject)?
        for port in ports {
            guard let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue(),
                  descriptor.responds(to: surfaceSelector),
                  let surface = descriptor.perform(surfaceSelector)?.takeUnretainedValue() else { continue }
            found = (descriptor, surface)
            break
        }
        guard let (screen, surface) = found, let hid = bridge.hidClient(for: device) else { return nil }
        self.udid = udid
        self.screen = screen
        self.surface = surface
        self.hid = hid
    }

    deinit { stop() }

    /// Calls `frame` on the main thread whenever the screen changes, at most once per run loop turn.
    func start(frame: @escaping () -> Void, surfaceChanged: @escaping () -> Void) {
        onFrame = frame
        onSurface = surfaceChanged
        guard !observing else { return }
        observing = true
        let damage: @convention(block) (AnyObject?) -> Void = { [weak self] _ in self?.scheduleFrame() }
        let surfaces: @convention(block) (AnyObject?, AnyObject?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.reloadSurface() }
        }
        register("registerCallbackWithUUID:damageRectanglesCallback:", damage as AnyObject)
        register("registerCallbackWithUUID:ioSurfacesChangeCallback:", surfaces as AnyObject)
    }

    func stop() {
        guard observing else { return }
        observing = false
        onFrame = nil
        onSurface = nil
        for name in ["unregisterDamageRectanglesCallbackWithUUID:", "unregisterIOSurfacesChangeCallbackWithUUID:"] {
            let selector = NSSelectorFromString(name)
            if screen.responds(to: selector) { _ = screen.perform(selector, with: callbackID) }
        }
    }

    private func register(_ name: String, _ block: AnyObject) {
        typealias Register = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
        let selector = NSSelectorFromString(name)
        guard screen.responds(to: selector), let method = class_getMethodImplementation(object_getClass(screen), selector) else { return }
        unsafeBitCast(method, to: Register.self)(screen, selector, callbackID, block)
    }

    private func scheduleFrame() {
        lock.lock()
        let schedule = !framePending
        framePending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.framePending = false
            self.lock.unlock()
            self.onFrame?()
        }
    }

    private func reloadSurface() {
        guard let next = screen.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else { return }
        surface = next
        onSurface?()
    }

    // MARK: Input

    /// A finger at `point`, in framebuffer pixels.
    func touch(_ point: CGPoint, _ phase: TouchPhase) {
        guard let bridge = SimulatorBridge.shared else { return }
        let size = pixelSize
        var location = point
        guard let message = bridge.touchMessage(&location, nil, 0x32, phase.rawValue, 0, size.width, size.height) else { return }
        send(message)
    }

    func press(_ button: Button) {
        guard let bridge = SimulatorBridge.shared else { return }
        for direction: UInt32 in [1, 2] {
            if let message = bridge.buttonMessage(button.rawValue, direction, 0x33) { send(message) }
        }
    }

    /// A key press or release as the Mac keyboard reports it.
    func key(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp, let message = SimulatorBridge.shared?.keyMessage(event) else { return }
        send(message)
    }

    /// Shift, Control, Option and Caps Lock held or released, by their HID usage.
    func modifier(_ usage: UInt32, down: Bool) {
        guard let message = SimulatorBridge.shared?.arbitraryKeyMessage(usage, down ? 1 : 2) else { return }
        send(message)
    }

    private func send(_ message: UnsafeMutableRawPointer) {
        SimulatorBridge.shared?.send(hid, message, queue)
    }
}

/// The loaded frameworks and the few entry points Jack uses.
final class SimulatorBridge: @unchecked Sendable {
    typealias TouchMessage = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, UInt, UInt, Double, Double) -> UnsafeMutableRawPointer?
    typealias ButtonMessage = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias KeyMessage = @convention(c) (NSEvent) -> UnsafeMutableRawPointer?
    typealias ArbitraryKeyMessage = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?, (@convention(block) (NSError?) -> Void)?) -> Void
    private typealias HIDInit = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?

    static let shared = SimulatorBridge()

    let touchMessage: TouchMessage
    let buttonMessage: ButtonMessage
    let keyMessage: KeyMessage
    let arbitraryKeyMessage: ArbitraryKeyMessage
    private let deviceSet: AnyObject
    private let hidClass: AnyClass
    private let sendMethod: Send
    private let sendSelector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")

    private init?() {
        let developer = Self.developerDirectory
        let simulatorKit = URL(fileURLWithPath: developer).deletingLastPathComponent()
            .appendingPathComponent("SharedFrameworks/SimulatorKit.framework/SimulatorKit").path
        guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil,
              let kit = dlopen(simulatorKit, RTLD_NOW),
              let touch = dlsym(kit, "IndigoHIDMessageForMouseNSEvent"),
              let button = dlsym(kit, "IndigoHIDMessageForButton"),
              let key = dlsym(kit, "IndigoHIDMessageForKeyboardNSEvent"),
              let arbitraryKey = dlsym(kit, "IndigoHIDMessageForKeyboardArbitrary"),
              let contextClass = NSClassFromString("SimServiceContext") as AnyObject?,
              let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient"),
              let sendIMP = class_getMethodImplementation(hidClass, NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")),
              contextClass.responds(to: NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")),
              let context = contextClass.perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"), with: developer, with: nil)?.takeUnretainedValue(),
              let set = context.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue()
        else { return nil }
        touchMessage = unsafeBitCast(touch, to: TouchMessage.self)
        buttonMessage = unsafeBitCast(button, to: ButtonMessage.self)
        keyMessage = unsafeBitCast(key, to: KeyMessage.self)
        arbitraryKeyMessage = unsafeBitCast(arbitraryKey, to: ArbitraryKeyMessage.self)
        self.hidClass = hidClass
        sendMethod = unsafeBitCast(sendIMP, to: Send.self)
        deviceSet = set
    }

    func device(_ udid: String) -> AnyObject? {
        (deviceSet.value(forKey: "devices") as? [AnyObject])?.first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
    }

    func hidClient(for device: AnyObject) -> AnyObject? {
        let selector = NSSelectorFromString("initWithDevice:error:")
        guard let allocated = (hidClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let method = class_getMethodImplementation(hidClass, selector) else { return nil }
        var error: NSError?
        return unsafeBitCast(method, to: HIDInit.self)(allocated, selector, device, &error)
    }

    func send(_ client: AnyObject, _ message: UnsafeMutableRawPointer, _ queue: DispatchQueue) {
        sendMethod(client, sendSelector, message, true, queue, nil)
    }

    /// The Xcode that `xcode-select` points at, as simctl uses it, when it still exists.
    private static var developerDirectory: String {
        let candidates = [
            ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
            try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode-beta.app/Contents/Developer",
        ]
        return candidates.compactMap { $0 }.first { path in
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("SharedFrameworks/SimulatorKit.framework").path)
        } ?? "/Applications/Xcode.app/Contents/Developer"
    }
}
