import Foundation
import Combine
import Darwin

private final class CustomizationWatchers {
    private var sources: [DispatchSourceFileSystemObject] = []
    var isEmpty: Bool { sources.isEmpty }
    func append(_ source: DispatchSourceFileSystemObject) { sources.append(source) }
    func cancelAll() { sources.forEach { $0.cancel() }; sources.removeAll() }
    deinit { cancelAll() }
}

public struct CustomizationPack: Codable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var author: String?
    public var theme: CustomizationTheme?
    public var layout: CustomizationLayout?
    public var commands: [CustomizationCommand]

    public init(schemaVersion: Int = 1, id: String, name: String, author: String? = nil, theme: CustomizationTheme? = nil, layout: CustomizationLayout? = nil, commands: [CustomizationCommand] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.author = author
        self.theme = theme; self.layout = layout; self.commands = commands
    }
}

public struct CustomizationTheme: Codable, Equatable {
    public var appearance: Appearance?
    public var canvas, chrome, panel, selection, accent, text, muted: String?
    public enum Appearance: String, Codable { case system, light, dark }
    public init(appearance: Appearance? = nil, canvas: String? = nil, chrome: String? = nil, panel: String? = nil, selection: String? = nil, accent: String? = nil, text: String? = nil, muted: String? = nil) {
        self.appearance = appearance; self.canvas = canvas; self.chrome = chrome; self.panel = panel
        self.selection = selection; self.accent = accent; self.text = text; self.muted = muted
    }
}

public struct CustomizationLayout: Codable, Equatable {
    public enum Interface: String, Codable { case basic, ice, terminal, office, office2D }
    public enum SidebarPosition: String, Codable { case left, right }
    public enum WorkspacePosition: String, Codable { case right, bottom }
    public var interface: Interface?
    public var sidebarPosition: SidebarPosition?
    public var sidebarWidth: Int?
    public var sidebarVisible: Bool?
    public var statusBarVisible: Bool?
    public var workspacePosition: WorkspacePosition?
    public var workspaceWidth: Int?
    public var workspaceHeight: Int?
    public var explorerVisible: Bool?
    public init(interface: Interface? = nil, sidebarPosition: SidebarPosition? = nil, sidebarWidth: Int? = nil, sidebarVisible: Bool? = nil, statusBarVisible: Bool? = nil, workspacePosition: WorkspacePosition? = nil, workspaceWidth: Int? = nil, workspaceHeight: Int? = nil, explorerVisible: Bool? = nil) {
        self.interface = interface; self.sidebarPosition = sidebarPosition; self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible; self.statusBarVisible = statusBarVisible; self.workspacePosition = workspacePosition
        self.workspaceWidth = workspaceWidth; self.workspaceHeight = workspaceHeight; self.explorerVisible = explorerVisible
    }
}

public struct CustomizationCommand: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case prompt, terminal }
    public var name: String
    public var title: String
    public var kind: Kind
    public var content: String
    public var id: String { name }
    public init(name: String, title: String, kind: Kind, content: String) { self.name = name; self.title = title; self.kind = kind; self.content = content }
    public func expanded(arguments: String) -> String { kind == .prompt ? content.replacingOccurrences(of: "{{args}}", with: arguments) : content }
}

@MainActor public final class CustomizationCenter: ObservableObject {
    public let directory: URL
    @Published public private(set) var packs: [CustomizationPack] = []
    @Published public private(set) var enabledIDs: [String] = []
    @Published public private(set) var error: String?
    @Published public private(set) var revision = 0
    @Published public private(set) var isEnabled = false
    public var effectiveTheme: CustomizationTheme? {
        guard isEnabled else { return nil }
        let values = activePacks.compactMap(\.theme); guard !values.isEmpty else { return nil }
        return .init(appearance: pick(\.appearance, values), canvas: pick(\.canvas, values), chrome: pick(\.chrome, values), panel: pick(\.panel, values), selection: pick(\.selection, values), accent: pick(\.accent, values), text: pick(\.text, values), muted: pick(\.muted, values))
    }
    public var effectiveLayout: CustomizationLayout? {
        guard isEnabled else { return nil }
        let values = activePacks.compactMap(\.layout); guard !values.isEmpty else { return nil }
        return .init(interface: pick(\.interface, values), sidebarPosition: pick(\.sidebarPosition, values), sidebarWidth: pick(\.sidebarWidth, values), sidebarVisible: pick(\.sidebarVisible, values), statusBarVisible: pick(\.statusBarVisible, values), workspacePosition: pick(\.workspacePosition, values), workspaceWidth: pick(\.workspaceWidth, values), workspaceHeight: pick(\.workspaceHeight, values), explorerVisible: pick(\.explorerVisible, values))
    }
    public var commands: [CustomizationCommand] {
        guard isEnabled else { return [] }
        var result: [CustomizationCommand] = []
        for pack in activePacks { for command in pack.commands { if let index = result.firstIndex(where: { $0.name.lowercased() == command.name.lowercased() }) { result[index] = command } else { result.append(command) } } }
        return result
    }

    private let watchers = CustomizationWatchers()
    private var debounce: Task<Void, Never>?
    private var known: [String: CustomizationPack] = [:]
    private var activePacks: [CustomizationPack] { enabledIDs.compactMap { known[$0] } }
    private var packsURL: URL { directory.appendingPathComponent("Packs", isDirectory: true) }
    private var stateURL: URL { directory.appendingPathComponent("enabled.json") }

    public init(directory: URL, enabled: Bool = false) {
        self.directory = directory
        if enabled { setEnabled(true) }
    }

    public func setEnabled(_ value: Bool) {
        guard value != isEnabled else { return }
        isEnabled = value
        if value { reload(); startWatcher() }
        else { debounce?.cancel(); debounce = nil; watchers.cancelAll() }
    }

    public func reload() {
        guard isEnabled else { return }
        do {
            try ensurePacksDirectory()
            if FileManager.default.fileExists(atPath: stateURL.path) {
                guard try stateURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ValidationError.invalid("ruta simbólica enabled.json") }
                let data = try Self.readBounded(stateURL)
                let ids = try JSONDecoder().decode([String].self, from: data)
                guard ids.allSatisfy(Self.validID), Set(ids).count == ids.count else { throw ValidationError.invalid("enabled.json") }
                enabledIDs = ids
            } else { enabledIDs = [] }
            let files = try FileManager.default.contentsOfDirectory(at: packsURL, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "json" }
            var seen = Set<String>(); var failure: String?
            for file in files {
                let stem = file.deletingPathExtension().lastPathComponent
                guard Self.validID(stem), !seen.contains(stem) else { failure = "Ruta de paquete inválida: \(file.lastPathComponent)"; continue }
                seen.insert(stem)
                do {
                    guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ValidationError.invalid("ruta simbólica") }
                    let pack = try Self.decodePackUnchecked(Self.readBounded(file)); guard pack.id == stem else { throw ValidationError.invalid("id no coincide con archivo") }; known[stem] = pack
                }
                catch { failure = "No se pudo cargar \(file.lastPathComponent): \(error.localizedDescription)" }
            }
            for id in Array(known.keys) where !seen.contains(id) { known.removeValue(forKey: id) }
            error = failure; publish()
        } catch { self.error = error.localizedDescription }
    }

    public func save(_ pack: CustomizationPack) throws {
        try requireEnabled()
        try Self.validate(pack)
        let data = try Self.encoder.encode(pack); guard data.count <= 1_048_576 else { throw ValidationError.invalid("paquete supera 1 MiB") }
        try ensurePacksDirectory()
        try data.write(to: packsURL.appendingPathComponent("\(pack.id).json"), options: .atomic)
        known[pack.id] = pack; error = nil; publish()
    }

    @discardableResult public func importPack(data: Data) throws -> String {
        try requireEnabled()
        let pack = try Self.decodePack(data); try save(pack); return pack.id
    }
    public func exportPack(id: String) throws -> Data {
        try requireEnabled()
        guard Self.validID(id), let pack = known[id] else { throw ValidationError.invalid("paquete no encontrado") }
        return try Self.encoder.encode(pack)
    }
    public func setPackEnabled(_ id: String, _ value: Bool) throws {
        try requireEnabled()
        guard Self.validID(id), known[id] != nil || !value else { throw ValidationError.invalid("paquete no encontrado") }
        var ids = enabledIDs
        if value { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        try persistEnabled(ids); enabledIDs = ids; publish()
    }
    public func removePack(_ id: String) throws {
        try requireEnabled()
        guard Self.validID(id) else { throw ValidationError.invalid("id inválido") }
        try ensurePacksDirectory()
        let file = packsURL.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        known.removeValue(forKey: id)
        let ids = enabledIDs.filter { $0 != id }; try persistEnabled(ids); enabledIDs = ids; error = nil; publish()
    }

    private func persistEnabled(_ ids: [String]) throws {
        try ensurePacksDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(ids).write(to: stateURL, options: .atomic)
    }
    private func ensurePacksDirectory() throws {
        var metadata = stat()
        if lstat(packsURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw ValidationError.invalid("ruta Packs no accesible") }
            try FileManager.default.createDirectory(at: packsURL, withIntermediateDirectories: true)
            guard lstat(packsURL.path, &metadata) == 0 else { throw ValidationError.invalid("ruta Packs no accesible") }
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw ValidationError.invalid("ruta Packs no segura") }
    }
    private func publish() { packs = known.values.sorted { $0.id < $1.id }; revision &+= 1 }
    private func requireEnabled() throws { guard isEnabled else { throw ValidationError.invalid("centro deshabilitado") } }
    private func pick<T>(_ keyPath: KeyPath<CustomizationTheme, T?>, _ values: [CustomizationTheme]) -> T? { values.reversed().compactMap { $0[keyPath: keyPath] }.first }
    private func pick<T>(_ keyPath: KeyPath<CustomizationLayout, T?>, _ values: [CustomizationLayout]) -> T? { values.reversed().compactMap { $0[keyPath: keyPath] }.first }
    private func startWatcher() {
        guard (try? ensurePacksDirectory()) != nil else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: packsURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])) ?? []
        var paths = [directory, packsURL]
        if FileManager.default.fileExists(atPath: stateURL.path),
           let state = try? stateURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
           state.isRegularFile == true, state.isSymbolicLink != true { paths.append(stateURL) }
        paths.append(contentsOf: files.filter {
            $0.pathExtension.lowercased() == "json"
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink) != true
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        })
        for url in Set(paths.map(\.standardizedFileURL)) {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, self.isEnabled else { return }
                self.debounce?.cancel()
                self.debounce = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180)); guard !Task.isCancelled, let self, self.isEnabled else { return }
                    self.reload()
                    if !self.watchers.isEmpty { self.watchers.cancelAll(); self.startWatcher() }
                }
            }
            source.setCancelHandler { close(fd) }; watchers.append(source); source.resume()
        }
    }

    private enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let value): "Paquete de personalización inválido: \(value)" }
        }
    }
    private static let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return value }()
    private static func decodePackUnchecked(_ data: Data) throws -> CustomizationPack {
        guard data.count <= 1_048_576 else { throw ValidationError.invalid("paquete supera 1 MiB") }
        let pack = try JSONDecoder().decode(CustomizationPack.self, from: data); try validate(pack); return pack
    }
    public static func decodePack(_ data: Data) throws -> CustomizationPack {
        try decodePackUnchecked(data)
    }
    private static func readBounded(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw ValidationError.invalid("no se puede abrir el archivo") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), metadata.st_size >= 0,
              metadata.st_size <= 1_048_576 else { throw ValidationError.invalid("el archivo debe ser regular y no superar 1 MiB") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= 1_048_576 {
            let amount = min(buffer.count, 1_048_577 - data.count)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, amount) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ValidationError.invalid("no se pudo leer el archivo")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= 1_048_576 else { throw ValidationError.invalid("archivo supera 1 MiB") }
        return data
    }
    private static func validID(_ id: String) -> Bool { validIdentifier(id) && id == id.lowercased() }
    private static func validCommandName(_ name: String) -> Bool { validIdentifier(name) }
    private static func validIdentifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 } }
    private static func validate(_ pack: CustomizationPack) throws {
        guard pack.schemaVersion == 1 else { throw ValidationError.invalid("schemaVersion") }
        guard validID(pack.id), bounded(pack.name, 120), pack.author.map({ bounded($0, 120) }) ?? true else { throw ValidationError.invalid("id/name/author") }
        if let theme = pack.theme {
            for color in [theme.canvas, theme.chrome, theme.panel, theme.selection, theme.accent, theme.text, theme.muted].compactMap({ $0 }) {
                guard color.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil else { throw ValidationError.invalid("color HEX") }
            }
        }
        if let layout = pack.layout {
            if let v = layout.sidebarWidth, !(210...400).contains(v) { throw ValidationError.invalid("sidebarWidth") }
            if let v = layout.workspaceWidth, !(300...1200).contains(v) { throw ValidationError.invalid("workspaceWidth") }
            if let v = layout.workspaceHeight, !(180...700).contains(v) { throw ValidationError.invalid("workspaceHeight") }
        }
        guard pack.commands.count <= 100 else { throw ValidationError.invalid("máximo 100 comandos") }
        var names = Set<String>()
        for command in pack.commands {
            let normalizedName = command.name.lowercased()
            guard validCommandName(command.name), !JackCommandCatalog.builtins.contains(where: { $0.name == normalizedName }), names.insert(normalizedName).inserted,
                  bounded(command.title, 120), bounded(command.content, command.kind == .prompt ? 20_000 : 8_000) else { throw ValidationError.invalid("command name/title/content") }
        }
    }
    private static func bounded(_ value: String, _ max: Int) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= max }
}
