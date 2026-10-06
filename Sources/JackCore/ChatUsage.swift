import Foundation

enum UsageDecoder {
    static func codex(_ data: [String: Any], observedAt: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        let buckets = data["rateLimitsByLimitId"] as? [String: [String: Any]]
        let values: [(String, [String: Any])]
        if let buckets, !buckets.isEmpty { values = buckets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
        else { values = [("codex", data["rateLimits"] as? [String: Any] ?? data)] }
        for (key, bucket) in values {
            let name = bucket["limitName"] as? String ?? (key == "codex" ? "Codex" : key)
            for field in ["primary", "secondary"] {
                guard let value = bucket[field] as? [String: Any], let percent = (value["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (value["windowDurationMins"] as? NSNumber)?.intValue
                let period = minutes.map { $0 >= 1440 && $0 % 1440 == 0 ? "\($0 / 1440) d" : ($0 >= 60 && $0 % 60 == 0 ? "\($0 / 60) h" : "\($0) min") } ?? (field == "primary" ? "Sesión" : "Semanal")
                windows.append(UsageWindow(id: "\(key):\(field)", title: "\(name) · \(period)", usedPercent: percent, resetsAt: date(value["resetsAt"]), observedAt: observedAt))
            }
        }
        return ProviderUsage(provider: .codex, windows: windows, note: windows.isEmpty ? "La cuenta no expone cuotas de ChatGPT. Puede usar una API o un proveedor externo." : "Cuota de la cuenta compartida con las demás aplicaciones.")
    }
    static func claudeCache(_ data: [String: Any]) -> ProviderUsage {
        guard let cache = data["cachedUsageUtilization"] as? [String: Any], let stamp = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue, let limits = cache["utilization"] as? [String: Any] else {
            return ProviderUsage(provider: .claude, note: "Claude aún no tiene una lectura local de cuotas. Se actualizará con los eventos de uso de Claude Code.", isCached: true)
        }
        var windows: [UsageWindow] = []
        let observed = Date(timeIntervalSince1970: stamp / 1000)
        if let cachedAccount = cache["accountUuid"] as? String, let currentAccount = (data["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, cachedAccount != currentAccount {
            return ProviderUsage(provider: .claude, note: "La lectura local pertenece a otra cuenta. Esperando cuotas de la cuenta actual.", isCached: true)
        }
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] {
            guard let window = limits[key] as? [String: Any], let percent = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(id: key, title: claudeWindowTitles[key] ?? key, usedPercent: percent, resetsAt: date(window["resets_at"]), observedAt: observed))
        }
        // Weekly limits scoped to one model (e.g. Fable) only appear in the `limits` list.
        for limit in limits["limits"] as? [[String: Any]] ?? [] where limit["kind"] as? String == "weekly_scoped" {
            guard let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
            let id = "seven_day_" + model.lowercased()
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(UsageWindow(id: id, title: "\(model) · 7 d", usedPercent: percent, resetsAt: date(limit["resets_at"]), observedAt: observed))
        }
        let fresh = Date().timeIntervalSince(observed) < 120
        return ProviderUsage(provider: .claude, windows: windows, note: fresh ? "Cuota de la cuenta compartida con las demás aplicaciones." : "Última lectura guardada por Claude Code; no es una consulta en vivo.", isCached: !fresh)
    }
    static let claudeWindowTitles = ["five_hour": "5 h", "seven_day": "7 d", "seven_day_opus": "Opus · 7 d", "seven_day_sonnet": "Sonnet · 7 d", "overage": "Uso adicional"]
    static func claudeEvent(_ data: [String: Any]) -> ProviderUsage? {
        let value = data["rate_limit_info"] as? [String: Any] ?? data["rateLimitInfo"] as? [String: Any] ?? data
        var windows: [UsageWindow] = []
        // Current Claude Code reports every window under `unifiedWindows`; the top level only names the one that applies.
        if let unified = value["unifiedWindows"] as? [String: [String: Any]] {
            for (kind, window) in unified.sorted(by: { $0.key < $1.key }) {
                guard let fraction = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
                windows.append(UsageWindow(id: kind, title: claudeWindowTitles[kind] ?? kind, usedPercent: fraction * 100, resetsAt: date(window["resetsAt"] ?? window["resets_at"])))
            }
        }
        if let kind = value["rateLimitType"] as? String ?? value["rate_limit_type"] as? String, !windows.contains(where: { $0.id == kind }) {
            let fraction = (value["utilization"] as? NSNumber)?.doubleValue
            // A window without a percentage would hide the last known reading, so it is only kept when it is exhausted.
            if let percent = fraction.map({ $0 * 100 }) ?? (value["status"] as? String == "rejected" ? 100 : nil) {
                windows.append(UsageWindow(id: kind, title: claudeWindowTitles[kind] ?? kind, usedPercent: percent, resetsAt: date(value["resetsAt"] ?? value["resets_at"])))
            }
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(provider: .claude, windows: windows, note: "Actualizado por Claude Code.")
    }
    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        if let string = value as? String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}

@MainActor public enum ChatUsageService {
    public static func read(_ provider: ChatProvider) async -> ProviderUsage {
        switch provider {
        case .codex:
            do { return try await readCodex() }
            catch {
                JackLog.write("cuota de Codex: \(error.localizedDescription)")
                return ProviderUsage(provider: .codex, note: "No se pudo consultar la cuota: \(error.localizedDescription)")
            }
        case .claude:
            await refreshClaudeCache()
            return await Task.detached(priority: .utility) {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
                guard let bytes = try? Data(contentsOf: url), let data = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return UsageDecoder.claudeCache([:]) }
                return UsageDecoder.claudeCache(data)
            }.value
        case .stellar:
            return ProviderUsage(provider: .stellar, note: "Stellar Code usa modelos locales: sin cuotas ni coste.")
        case .opencode:
            return ProviderUsage(provider: .opencode, note: "OpenCode no expone una cuota unificada: depende de la cuenta del proveedor del modelo. El consumo de tokens y coste se muestra en cada conversación.")
        }
    }
    /// `/usage` is answered locally by Claude Code, without inference, and stores a fresh reading in `~/.claude.json`.
    private static func refreshClaudeCache() async {
        guard let executable = ExecutableResolver.resolve("claude", override: UserDefaults.standard.string(forKey: "providerExecutablePath.claude")),
              let process = try? StructuredChild(executable: executable, arguments: [
                "--print", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                // Project-only settings in a temporary folder: the user's hooks do not run for this query.
                "--no-session-persistence", "--setting-sources", "project"], directory: NSTemporaryDirectory()) else { return }
        let deadline = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { JackLog.write("cuota de Claude: sin respuesta en 45 s"); process.terminate() } }
        defer { deadline.cancel() }
        try? process.writeJSON(["type": "user", "message": ["role": "user", "content": "/usage"], "parent_tool_use_id": NSNull()])
        let reader = StructuredLineReader(process.lines)
        while let line = try? await reader.next() {
            if (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["type"] as? String == "result" { break }
        }
        process.terminate(); await process.waitForExit()
    }
    private static func readCodex() async throws -> ProviderUsage {
        guard let executable = ExecutableResolver.resolve("codex", override: UserDefaults.standard.string(forKey: "providerExecutablePath.codex")) else { throw CocoaError(.fileNoSuchFile) }
        let process = try StructuredChild(executable: executable, arguments: ["app-server", "--listen", "stdio://"], directory: NSTemporaryDirectory())
        let deadline = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { process.terminate() } }
        defer { deadline.cancel() }
        let reader = StructuredLineReader(process.lines)
        do {
            try process.writeJSON(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "jack_usage", "version": "1"], "capabilities": ["experimentalApi": true]]])
            _ = try await response(1, reader: reader)
            try process.writeJSON(["method": "initialized"])
            try process.writeJSON(["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
            let value = UsageDecoder.codex(try await response(2, reader: reader))
            process.terminate(); await process.waitForExit()
            return value
        } catch { process.terminate(); await process.waitForExit(); throw error }
    }
    private static func response(_ id: Int, reader: StructuredLineReader) async throws -> [String: Any] {
        while let line = try await reader.next() {
            guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], value["id"] as? Int == id else { continue }
            if let error = value["error"] as? [String: Any] { throw NSError(domain: "Codex", code: -1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Cuota no disponible"]) }
            return value["result"] as? [String: Any] ?? [:]
        }
        throw NSError(domain: "Codex", code: -1, userInfo: [NSLocalizedDescriptionKey: "Codex cerró la consulta sin datos de cuota."])
    }
}
