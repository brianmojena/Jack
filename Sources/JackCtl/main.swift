import Foundation
import JackCore

// jack-ctl: controla los mods de Jack desde scripts. Opera sobre el mismo directorio que vigila la app
// (CustomizationCenter), así que Jack aplica los cambios con su file watcher. Los mods solo existen en modo Normal:
// en Light Jack los desactiva, así que la CLI tampoco los toca.

let usage = """
usage: jack-ctl mod list [--json]
       jack-ctl mod install <archivo.json>
       jack-ctl mod enable <id>
       jack-ctl mod disable <id>
       jack-ctl mod remove <id>
       jack-ctl mod export <id>
       jack-ctl mod dir

Variables: JACK_CUSTOMIZATION_DIR (directorio de mods); JACK_DATA_DIR (mueve los datos de Jack, y con ellos los mods).
"""

struct ModRow: Encodable {
    let id: String
    let name: String
    let enabled: Bool
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("jack-ctl: \(message)\n".utf8))
    exit(status)
}

func usageError() -> Never {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}
guard args.count >= 2, args[0] == "mod" else { usageError() }

let verb = args[1]
let rest = Array(args.dropFirst(2))
let wantsJSON = rest.contains("--json")
let operands = rest.filter { $0 != "--json" }
let operandCounts = ["list": 0, "install": 1, "enable": 1, "disable": 1, "remove": 1, "export": 1, "dir": 0]
guard let expectedCount = operandCounts[verb], operands.count == expectedCount, !wantsJSON || verb == "list" else { usageError() }

// Jack guarda el modo Light en sus preferencias (dev.jack.desktop) y entonces desactiva los mods.
let lightMode = CFPreferencesCopyAppValue("lightModeEnabled" as CFString, "dev.jack.desktop" as CFString) as? Bool ?? false
if lightMode { fail("Jack está en modo Light; los mods solo se gestionan en modo Normal") }

let environment = ProcessInfo.processInfo.environment
let customizationDirectory = environment["JACK_CUSTOMIZATION_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? ChatArchive(directory: environment["JACK_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        .directory.appendingPathComponent("Customization", isDirectory: true)

// CustomizationCenter es @MainActor; el código de nivel superior de main.swift no lo está en Swift 5.
MainActor.assumeIsolated {
    // enabled: true: en Normal la app siempre activa el centro (ChatStore.applyCustomization). Sin ello, las
    // operaciones de escritura lanzan "centro deshabilitado".
    let center = CustomizationCenter(directory: customizationDirectory, enabled: true)
    func run<T>(_ body: () throws -> T) -> T {
        do { return try body() } catch { fail(error.localizedDescription) }
    }

    switch verb {
    case "list":
        if let error = center.error { FileHandle.standardError.write(Data("jack-ctl: aviso: \(error)\n".utf8)) }
        let rows = center.packs.map { ModRow(id: $0.id, name: $0.name, enabled: center.enabledIDs.contains($0.id)) }
        if wantsJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: run { try encoder.encode(rows) }, as: UTF8.self))
        } else {
            for row in rows { print("\(row.id)\t\(row.enabled ? "enabled" : "disabled")\t\(row.name)") }
        }
    case "install":
        let id = run { try center.importPack(data: CustomizationCenter.packData(at: URL(fileURLWithPath: operands[0]))) }
        print(id)
    case "enable": run { try center.setPackEnabled(operands[0], true) }
    case "disable": run { try center.setPackEnabled(operands[0], false) }
    case "remove": run { try center.removePack(operands[0]) }
    case "export":
        let data = run { try center.exportPack(id: operands[0]) }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    case "dir": print(center.directory.path)
    default: usageError()
    }
}
