import Foundation
import JackCore

/// Read-only smoke check against an existing socket. Never starts or stops Herdr.
@main
struct JackProbe {
    @MainActor
    static func main() async {
        let path = CommandLine.arguments.dropFirst().first ?? ExecutableResolver.defaultSocketPath
        let store = SessionStore(socketPath: path)
        do {
            try await store.refresh()
            let baseline = store.snapshot
            print("Snapshot decoded: \(baseline.workspaces.count) workspaces, \(baseline.panes.count) panes, \(baseline.agents.count) agents")
            store.connect()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard store.connectionState == .connected else {
                throw ProbeError.failed(store.errorMessage ?? "Subscription did not connect")
            }
            // The idle window exceeds the original short query timeout.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            guard store.connectionState == .connected else {
                throw ProbeError.failed(store.errorMessage ?? "Subscription did not remain connected")
            }
            store.disconnect()
            store.connect()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard store.connectionState == .connected else {
                throw ProbeError.failed(store.errorMessage ?? "Reconnect did not complete")
            }
            store.disconnect()
            print("PASS: live bootstrap, idle subscription, disconnect and reconnect; no mutations sent")
        } catch {
            store.disconnect()
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private enum ProbeError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case let .failed(message): message }
    }
}
