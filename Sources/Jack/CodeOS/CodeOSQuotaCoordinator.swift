import JackCore
import SwiftUI

/// The shared-account side of CodeOS: who is playing on this Mac, who else is on the network, how the Claude quota is split and
/// whether this profile may still send messages. Normal mode only; it does nothing until a profile is chosen.
@MainActor final class CodeOSQuotaCoordinator: ObservableObject {
    @Published private(set) var profiles: [QuotaProfile] = []
    @Published private(set) var current: QuotaProfile?
    /// Whether the profile asked to be part of the split. A paused profile gives its share to the others and cannot send.
    @Published private(set) var active = true
    @Published private(set) var shares: [QuotaShare] = []
    @Published private(set) var usedNow: Double?
    @Published private(set) var incoming: [QuotaRequest] = []
    @Published private(set) var peerCount = 0
    @Published private(set) var groupCode: String
    @Published private(set) var message: String?

    private let store: ChatStore
    private let instance = UUID().uuidString
    private let network: QuotaNetwork
    private var peers: [String: QuotaPeerState] = [:]
    private var grants: [QuotaGrant] = []
    private var epoch: QuotaEpoch?
    private var baselineTokens = 0.0
    private var timer: Task<Void, Never>?
    private var lastUsageRefresh = Date.distantPast
    private var lastBroadcast = Date.distantPast

    /// Where profiles and the group code live: beside the other CodeOS files, or in `JACK_DATA_DIR` for a copy of Jack running on its own.
    private static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["JACK_DATA_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom).appendingPathComponent("CodeOS") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jack/CodeOS")
    }
    private static var profilesFile: URL { directory.appendingPathComponent("profiles.json") }
    private static var groupFile: URL { directory.appendingPathComponent("quota-group.txt") }

    init(store: ChatStore) {
        self.store = store
        network = QuotaNetwork(instance: instance)
        groupCode = (try? String(contentsOf: Self.groupFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if groupCode.isEmpty {
            groupCode = QuotaNetwork.newGroupCode()
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? groupCode.write(to: Self.groupFile, atomically: true, encoding: .utf8)
        }
        if let data = try? Data(contentsOf: Self.profilesFile), let saved = try? JSONDecoder().decode([QuotaProfile].self, from: data) { profiles = saved }
        network.onMessage = { [weak self] message in self?.receive(message) }
        network.onPeerReady = { [weak self] in self?.broadcast(force: true) }
    }

    deinit { MainActor.assumeIsolated { stop() } }

    // MARK: Profiles

    func addProfile(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !profiles.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        // Spread the avatar colours: each new profile takes the hue farthest from those already used.
        let used = profiles.map(\.hue)
        let hue = (0..<24).map { Double($0) / 24 }.max { a, b in
            (used.map { abs($0 - a) }.min() ?? 1) < (used.map { abs($0 - b) }.min() ?? 1)
        } ?? Double.random(in: 0...1)
        profiles.append(QuotaProfile(name: clean, hue: hue))
        saveProfiles()
    }

    func removeProfile(_ profile: QuotaProfile) {
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    private func saveProfiles() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profiles) { try? data.write(to: Self.profilesFile) }
    }

    /// Starts playing as `profile`: joins the group on the network and begins to meter this Mac's use.
    func choose(_ profile: QuotaProfile) {
        stop()
        current = profile
        active = true
        peers = [:]; grants = []; incoming = []; epoch = nil; shares = []
        network.start(groupCode: groupCode)
        store.sendGate = { [weak self] _ in self?.refusal() }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Back to the profile screen.
    func leave() {
        stop()
        current = nil
    }

    func stop() {
        timer?.cancel(); timer = nil
        network.stop()
        store.sendGate = nil
        peers = [:]; shares = []; peerCount = 0
    }

    func setActive(_ value: Bool) {
        guard current != nil, active != value else { return }
        active = value
        Task { await tick(forceBroadcast: true) }
    }

    func setGroupCode(_ code: String) {
        let normalized = QuotaNetwork.normalize(code)
        guard normalized.count >= 6 else { notify("El código del grupo debe tener al menos 6 letras o números."); return }
        groupCode = normalized.count == 16 ? stride(from: 0, to: 16, by: 4).map { i in String(normalized[normalized.index(normalized.startIndex, offsetBy: i)..<normalized.index(normalized.startIndex, offsetBy: i + 4)]) }.joined(separator: "-") : normalized
        try? groupCode.write(to: Self.groupFile, atomically: true, encoding: .utf8)
        if current != nil { network.start(groupCode: groupCode) }
        notify("Código del grupo cambiado: las demás Macs deben usar el mismo.")
    }

    // MARK: Requests and grants

    /// Asks the profile with the most left to give up `percent` points of its share.
    func requestShare(_ percent: Double = 5) {
        guard let current, let epoch else { return }
        guard let donor = shares.filter({ $0.profile != current.id && $0.remaining > percent }).max(by: { $0.remaining < $1.remaining }) else {
            notify("Nadie tiene tanto de sobra ahora mismo.")
            return
        }
        network.send(QuotaMessage(kind: .request, request: QuotaRequest(from: current.id, fromName: current.name, to: donor.profile, percent: percent, epoch: epoch.key)))
        notify("Pedido a \(donor.name): \(Int(percent)) %.")
    }

    func acceptFirstRequest() {
        guard let current, let epoch, let request = incoming.first, request.epoch == epoch.key else { incoming.removeFirst(min(1, incoming.count)); return }
        incoming.removeFirst()
        guard let own = shares.first(where: { $0.profile == current.id }), own.remaining > request.percent else { notify("No te queda tanto para ceder."); return }
        let grant = QuotaGrant(from: current.id, to: request.from, percent: request.percent, epoch: epoch.key)
        grants.append(grant)
        network.send(QuotaMessage(kind: .grant, grant: grant))
        notify("Cediste \(Int(request.percent)) % a \(request.fromName).")
        recompute()
    }

    func declineFirstRequest() {
        guard let request = incoming.first else { return }
        incoming.removeFirst()
        network.send(QuotaMessage(kind: .decline, declined: request.id))
    }

    // MARK: Network

    private func receive(_ message: QuotaMessage) {
        switch message.kind {
        case .state:
            guard let state = message.state, state.instance != instance else { return }
            peers[state.instance] = state
            recompute()
        case .request:
            guard let request = message.request, request.to == current?.id, !incoming.contains(where: { $0.id == request.id }) else { return }
            incoming.append(request)
            CodeOSSound.shared.play(.notify)
        case .grant:
            guard let grant = message.grant, !grants.contains(where: { $0.id == grant.id }) else { return }
            grants.append(grant)
            if grant.to == current?.id { notify("Te han cedido \(Int(grant.percent)) %.") }
            recompute()
        case .decline:
            if message.declined != nil { notify("Tu petición fue rechazada.") }
        }
    }

    private func broadcast(force: Bool = false) {
        guard let state = ownState() else { return }
        guard force || Date().timeIntervalSince(lastBroadcast) > 3 else { return }
        lastBroadcast = Date()
        network.send(QuotaMessage(kind: .state, state: state))
    }

    private func ownState() -> QuotaPeerState? {
        guard let current else { return nil }
        return QuotaPeerState(instance: instance, profile: current.id, name: current.name, hue: current.hue, active: active,
                              tokens: max(0, weightedTokens() - baselineTokens), epoch: epoch?.key ?? "")
    }

    // MARK: Metering

    /// Claude tokens this Mac has spent in all its chats, weighted by how much each kind counts against the quota.
    private func weightedTokens() -> Double {
        store.conversations.filter { $0.provider == .claude }.reduce(0) { sum, conversation in
            guard let usage = conversation.tokenUsage else { return sum }
            return sum + QuotaPool.weightedTokens(input: usage.input, output: usage.output, cached: usage.cached)
        }
    }

    private func fiveHourWindow() -> UsageWindow? { store.usage[.claude]?.windows.first { $0.id == "five_hour" } }

    private func tick(forceBroadcast: Bool = false) async {
        guard current != nil else { return }
        // Claude Code reports its quota as it works; between turns it is asked for now and then.
        if Date().timeIntervalSince(lastUsageRefresh) > 60 {
            lastUsageRefresh = Date()
            await store.refreshUsage([.claude])
        }
        recompute()
        broadcast(force: forceBroadcast)
    }

    /// Recomputes the split: a new epoch whenever the 5-hour window or the set of active profiles changes.
    private func recompute() {
        guard let current, let ownState = ownState() else { return }
        let window = fiveHourWindow()
        usedNow = window?.usedPercent
        peerCount = peers.values.filter { Date().timeIntervalSince($0.updatedAt) < 20 }.count
        // Peers' `updatedAt` is their clock: use when it arrived instead.
        let fresh = peers.values
        var states = [ownState] + fresh
        states = states.filter { $0.active }
        let activeIDs = Array(Set(states.map(\.profile)))
        let key = QuotaEpoch.key(windowResetsAt: window?.resetsAt, active: active ? activeIDs : activeIDs.filter { $0 != current.id })
        if epoch?.key != key {
            let ids = active ? activeIDs : activeIDs.filter { $0 != current.id }
            epoch = QuotaEpoch(key: key, usedAtStart: window?.usedPercent ?? 0, active: ids)
            baselineTokens = weightedTokens()
            grants = []
            incoming = incoming.filter { $0.epoch == key }
        }
        guard let epoch, let used = window?.usedPercent else { shares = []; return }
        let all = [ownState] + peers.values
        shares = QuotaPool.shares(epoch: epoch, states: all, grants: grants, usedNow: used)
    }

    private func refusal() -> String? {
        guard let current else { return nil }
        // Without a reading of the account's quota there is nothing to measure against: do not block.
        guard usedNow != nil else { return active ? nil : QuotaPool.refusal(for: current.id, active: false, shares: shares) }
        return QuotaPool.refusal(for: current.id, active: active, shares: shares)
    }

    /// This profile's remaining share, in points of the 5-hour window, when it can be told.
    var ownRemaining: Double? { current.flatMap { me in shares.first { $0.profile == me.id }?.remaining } }

    func notify(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(6))
            if message == text { message = nil }
        }
    }
}
