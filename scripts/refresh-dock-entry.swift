import AppKit
import Foundation

// Preserve the user's Dock order and every other tile. Replacing an app can leave
// its pinned tile classified as a directory (file-type 1) with zero modification dates.
let application = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/Applications/Jack.app", isDirectory: true)
guard let bundle = Bundle(url: application), bundle.bundleIdentifier == "dev.jack.desktop" else {
    fatalError("La ruta no contiene la aplicación Jack.")
}
let domain = "com.apple.dock" as CFString
guard var tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] else {
    print("No hay accesos guardados que actualizar en el Dock.")
    exit(0)
}
let folder = try application.resourceValues(forKeys: [.contentModificationDateKey])
let parent = try application.deletingLastPathComponent().resourceValues(forKeys: [.contentModificationDateKey])
func dockDate(_ date: Date?) -> UInt64 {
    // Dock stores HFS timestamps, measured from January 1, 1904.
    UInt64(max(0, (date ?? Date()).timeIntervalSince1970 + 2_082_844_800))
}
let bookmark = try application.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
var changed = false
for index in tiles.indices {
    guard var data = tiles[index]["tile-data"] as? [String: Any],
          data["bundle-identifier"] as? String == bundle.bundleIdentifier,
          let file = data["file-data"] as? [String: Any],
          let path = file["_CFURLString"] as? String,
          URL(string: path)?.standardizedFileURL == application.standardizedFileURL else { continue }
    data["book"] = bookmark
    data["file-type"] = 41
    data["file-mod-date"] = dockDate(folder.contentModificationDate)
    data["parent-mod-date"] = dockDate(parent.contentModificationDate)
    tiles[index]["tile-data"] = data
    changed = true
}
if changed {
    CFPreferencesSetAppValue("persistent-apps" as CFString, tiles as CFArray, domain)
    guard CFPreferencesAppSynchronize(domain) else { fatalError("No se pudo guardar el acceso de Jack en el Dock.") }
    print("Acceso de Jack actualizado como aplicación. Se conserva su posición en el Dock.")
} else {
    print("Jack no tiene un acceso guardado en el Dock para esta ruta.")
}
