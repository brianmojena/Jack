import Foundation

/// Lo que se sabe de la instalación de OpenCode. No todas las versiones aceptan `--pure` (arrancar sin plugins externos): una que no
/// lo conoce se niega a ejecutar el comando entero (imprime su ayuda y sale), así que solo se pasa si la ayuda de `serve` lo menciona.
enum OpenCodeCLI {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Bool] = [:]

    /// Si este `opencode` acepta `--pure`. Se pregunta una vez por ejecutable (su ayuda tarda una fracción de segundo).
    static func supportsPure(executable: String) -> Bool {
        lock.lock()
        if let known = cache[executable] { lock.unlock(); return known }
        lock.unlock()
        let found = helpText(executable: executable).contains("--pure")
        lock.lock()
        cache[executable] = found
        lock.unlock()
        return found
    }

    /// `--pure` solo si el ejecutable lo acepta, para ponerlo entre los argumentos.
    static func pureArguments(executable: String) -> [String] { supportsPure(executable: executable) ? ["--pure"] : [] }

    private static func helpText(executable: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", "--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        process.environment = ExecutableResolver.childEnvironment()
        guard (try? process.run()) != nil else { return "" }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        killer.cancel()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
