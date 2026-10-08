import Foundation

/// Replaces the installed Jack.app with a downloaded one. A helper script outlives Jack: it waits for Jack to quit,
/// swaps the app's `Contents` (the folder keeps its identity, so the Dock tile stays), and opens the new version.
/// The previous `Contents` are kept in `previousDirectory`; if the swap fails the old one is put back.
public enum AppInstaller {
    public static var updatesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jack/Updates", isDirectory: true)
    }

    public static var previousDirectory: URL { updatesDirectory.appendingPathComponent("previous", isDirectory: true) }
    public static var logFile: URL { updatesDirectory.appendingPathComponent("update.log") }

    /// The running app, only if it can be replaced in place: an app in an Applications folder that the user can write to.
    /// A build run from Xcode or from `build/` is never replaced.
    public static func replaceableLocation(of bundle: URL = Bundle.main.bundleURL, applicationFolders: [URL]? = nil) -> URL? {
        let folders = applicationFolders ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let app = bundle.resolvingSymlinksInPath()
        guard app.pathExtension == "app",
              folders.contains(where: { $0.resolvingSymlinksInPath().path == app.deletingLastPathComponent().path }),
              FileManager.default.isWritableFile(atPath: app.path) else { return nil }
        return app
    }

    /// Unzips a release into `directory` and checks that it is the Jack that was announced. Returns the staged app.
    public static func stage(zip: URL, expected: AppVersion, bundleIdentifier: String, in directory: URL, checkSignature: Bool = true) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        guard unzip.status == 0 else { throw UpdateError("No se pudo descomprimir la actualización.") }
        let entries = try fileManager.contentsOfDirectory(atPath: directory.path).filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
        guard entries == ["Jack.app"] else { throw UpdateError("El archivo de la actualización no contiene solo Jack.app.") }
        let app = directory.appendingPathComponent("Jack.app")
        try verify(app: app, expected: expected, bundleIdentifier: bundleIdentifier, checkSignature: checkSignature)
        return app
    }

    static func verify(app: URL, expected: AppVersion, bundleIdentifier: String, checkSignature: Bool) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError("La actualización no es una app válida.")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw UpdateError("La actualización no es Jack.") }
        guard let shortVersion = info["CFBundleShortVersionString"] as? String, AppVersion(shortVersion) == expected else {
            throw UpdateError("La versión descargada no es la \(expected).")
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/\(executable)").path) else {
            throw UpdateError("La actualización no incluye el ejecutable de Jack.")
        }
        if checkSignature, try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status != 0 {
            throw UpdateError("La firma de la actualización no es válida.")
        }
    }

    /// Starts the helper that replaces `destination` once process `pid` has quit. Quit Jack right after this returns.
    public static func startReplacement(staged: URL, destination: URL, pid: Int32, relaunch: Bool = true, checkSignature: Bool = true,
                                        previous: URL = previousDirectory, log: URL = logFile) throws {
        let directory = log.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("replace-app.sh")
        try replaceScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The inner shell is backgrounded and the outer one exits, so the helper is no child of Jack and survives its quit.
        process.arguments = ["-c", #"nohup /bin/sh "$0" "$@" >/dev/null 2>&1 </dev/null &"#, script.path,
                             String(pid), destination.path, staged.path, previous.path, relaunch ? "1" : "0", checkSignature ? "1" : "0", log.path]
        try process.run()
        process.waitUntilExit()
    }

    /// Arguments: pid, app, staged app, previous folder, relaunch (1/0), verify signature (1/0), log file.
    static let replaceScript = #"""
    #!/bin/sh
    pid=$1; app=$2; staged=$3; previous=$4; relaunch=$5; verify=$6; log=$7
    exec >>"$log" 2>&1
    say() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
    reopen() { [ "$relaunch" = 1 ] && open "$app"; }
    say "Actualización a $staged para $app (Jack pid $pid)"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      waited=$((waited + 1))
      if [ "$waited" -gt 240 ]; then say "Jack no se cerró en 2 minutos: actualización cancelada"; rm -rf "$(dirname "$staged")"; exit 1; fi
      sleep 0.5
    done
    rm -rf "$previous" && mkdir -p "$previous" || { say "No se pudo preparar la copia anterior"; reopen; exit 1; }
    if ! mv "$app/Contents" "$previous/Contents"; then
      say "No se pudo apartar la versión instalada"; rm -rf "$(dirname "$staged")"; reopen; exit 1
    fi
    if mv "$staged/Contents" "$app/Contents" && { [ "$verify" != 1 ] || codesign --verify --deep --strict "$app"; }; then
      xattr -dr com.apple.quarantine "$app" 2>/dev/null
      touch "$app"
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null
      say "Jack actualizado"
    else
      say "La sustitución falló: se restaura la versión anterior"
      rm -rf "$app/Contents"
      mv "$previous/Contents" "$app/Contents"
    fi
    rm -rf "$(dirname "$staged")"
    reopen
    """#

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
