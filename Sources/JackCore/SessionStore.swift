import Combine
import Foundation

@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var snapshot = HerdrSnapshot()
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public var errorMessage: String?

    private let client: HerdrAPIClient
    private var subscriptionTask: Task<Void, Never>?
    private var coalescingTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var disconnected = true
    private var subscribedPaneIDs: Set<String> = []
    private var isReconfiguringSubscription = false

    public init(socketPath: String = ExecutableResolver.defaultSocketPath) {
        client = HerdrAPIClient(socketPath: socketPath)
    }

    public func connect() {
        guard subscriptionTask == nil else { return }
        disconnected = false
        generation &+= 1
        let token = generation
        connectionState = .connecting
        errorMessage = nil
        subscriptionTask = Task { [weak self] in
            await self?.subscriptionLoop(generation: token)
        }
    }

    public func disconnect() {
        disconnected = true
        generation &+= 1
        subscriptionTask?.cancel()
        subscriptionTask = nil
        coalescingTask?.cancel()
        coalescingTask = nil
        subscribedPaneIDs = []
        isReconfiguringSubscription = false
        client.cancelSubscription()
        connectionState = .disconnected
    }

    public func refresh() async throws {
        let requestGeneration = generation
        let response = try await client.request(method: "session.snapshot", params: [:])
        guard generation == requestGeneration else { return }
        let updatedSnapshot = try HerdrSnapshot.decodeAPIResponse(response)
        // Terminal output can emit updates without changing sidebar facts.
        // Avoid invalidating the entire SwiftUI tree for identical snapshots.
        if snapshot != updatedSnapshot { snapshot = updatedSnapshot }
        errorMessage = nil
        reconcileSubscriptionScopes()
    }

    public func createWorkspace(path: String, label: String) async throws {
        try await perform("workspace.create", ["cwd": path, "label": label, "focus": true])
    }

    public func focusWorkspace(_ id: String) async throws {
        try await perform("workspace.focus", ["workspace_id": id])
    }

    public func focusAgent(_ paneID: String) async throws {
        try await perform("agent.focus", ["target": paneID])
    }

    public func focusTab(_ id: String) async throws {
        try await perform("tab.focus", ["tab_id": id])
    }

    public func createTab(workspaceID: String) async throws {
        try await perform("tab.create", ["workspace_id": workspaceID, "focus": true])
    }

    public func startAgent(kind: AgentKind, paneID: String) async throws {
        let shortUUID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        let uniqueName = "\(kind.rawValue)-\(shortUUID)"
        try await perform(
            "agent.start",
            ["kind": kind.rawValue, "name": uniqueName, "pane_id": paneID, "timeout_ms": 120_000],
            timeout: 125
        )
    }

    @discardableResult
    public func createAgentTab(kind: AgentKind, workspaceID: String) async throws -> String {
        let response = try await client.request(
            method: "tab.create",
            params: ["workspace_id": workspaceID, "focus": true]
        )
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let pane = result["root_pane"] as? [String: Any],
              let paneID = pane["pane_id"] as? String else {
            throw HerdrTransportError.invalidResponse
        }
        try await refresh()
        try await startAgent(kind: kind, paneID: paneID)
        return paneID
    }

    public func splitPane(_ paneID: String, direction: String) async throws {
        let normalized: String
        switch direction.lowercased() {
        case "horizontal", "right": normalized = "right"
        case "vertical", "down": normalized = "down"
        default: normalized = direction
        }
        try await perform("pane.split", ["target_pane_id": paneID, "direction": normalized, "focus": true])
    }

    public func renameWorkspace(_ id: String, label: String) async throws {
        try await perform("workspace.rename", ["workspace_id": id, "label": label])
    }

    public func renamePane(_ id: String, label: String) async throws {
        try await perform("pane.rename", ["pane_id": id, "label": label])
    }

    public func closePane(_ id: String) async throws {
        try await perform("pane.close", ["pane_id": id])
    }

    public func closeTab(_ id: String) async throws {
        try await perform("tab.close", ["tab_id": id])
    }

    public func closeWorkspace(_ id: String) async throws {
        try await perform("workspace.close", ["workspace_id": id])
    }

    private func perform(_ method: String, _ params: [String: Any], timeout: TimeInterval? = nil) async throws {
        _ = try await client.request(method: method, params: params, timeout: timeout)
        try await refresh()
    }

    private func subscriptionLoop(generation token: UInt64) async {
        var failures = 0
        while !Task.isCancelled && isCurrent(token) {
            let paneIDs = snapshot.panes.map(\.id).sorted()
            let subscriptionLease = client.makeSubscriptionLease()
            if failures > 0 { connectionState = .reconnecting }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let apiClient = client
                    DispatchQueue.global(qos: .utility).async { [weak self, apiClient, paneIDs, token, subscriptionLease] in
                        do {
                            try apiClient.subscribe(lease: subscriptionLease, paneIDs: paneIDs, onReady: { [weak self] in
                                Task { @MainActor in
                                    guard let self, self.isCurrent(token) else { return }
                                    self.subscribedPaneIDs = Set(paneIDs)
                                    self.isReconfiguringSubscription = false
                                    self.connectionState = .connected
                                    Task {
                                        do { try await self.refresh(generation: token) }
                                        catch { self.setBackgroundError(error, generation: token) }
                                    }
                                }
                            }, onEvent: { [weak self] event in
                                Task { @MainActor in
                                    guard let self, self.isCurrent(token) else { return }
                                    self.received(event: event, generation: token)
                                }
                            })
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled && isCurrent(token) else { break }
                if isReconfiguringSubscription {
                    isReconfiguringSubscription = false
                    failures = 0
                    continue
                }
                setBackgroundError(error, generation: token)
                connectionState = .reconnecting
                failures += 1
                let delay = min(20.0, 0.5 * pow(2.0, Double(min(failures - 1, 6))))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            guard !Task.isCancelled && isCurrent(token) else { break }
            connectionState = .reconnecting
            failures += 1
            let delay = min(20.0, 0.5 * pow(2.0, Double(min(failures - 1, 6))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if isCurrent(token) {
            if disconnected { connectionState = .disconnected }
            subscriptionTask = nil
        }
    }

    private func received(event: [String: Any], generation token: UInt64) {
        guard event["event"] is String, isCurrent(token), coalescingTask == nil else { return }
        coalescingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled, self.isCurrent(token) else { return }
            self.coalescingTask = nil
            do { try await self.refresh(generation: token) }
            catch { self.setBackgroundError(error, generation: token) }
        }
    }

    private func reconcileSubscriptionScopes() {
        guard connectionState == .connected else { return }
        let latest = Set(snapshot.panes.map(\.id))
        guard latest != subscribedPaneIDs, !isReconfiguringSubscription else { return }
        isReconfiguringSubscription = true
        client.cancelSubscription()
    }

    private func refresh(generation token: UInt64) async throws {
        let response = try await client.request(method: "session.snapshot", params: [:])
        guard isCurrent(token) else { return }
        snapshot = try HerdrSnapshot.decodeAPIResponse(response)
        errorMessage = nil
        reconcileSubscriptionScopes()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generation == token && !disconnected
    }

    private func setBackgroundError(_ error: Error, generation token: UInt64) {
        guard isCurrent(token) else { return }
        errorMessage = error.localizedDescription
    }
}
