import Foundation

public enum AgentKind: String, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
}

public enum AgentStatus: String, Codable, CaseIterable {
    case working
    case blocked
    case done
    case idle
    case unknown

    public var displayName: String {
        switch self {
        case .working: "Trabajando"
        case .blocked: "Bloqueado"
        case .done: "Hecho"
        case .idle: "En espera"
        case .unknown: "Desconocido"
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: value.lowercased()) ?? .unknown
    }
}

public struct WorkspaceInfo: Identifiable, Codable, Equatable {
    public var id: String
    public var label: String
    public var cwd: String

    public init(id: String, label: String, cwd: String) {
        self.id = id
        self.label = label
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey { case id, workspaceID = "workspace_id", label, cwd }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .workspaceID) ?? c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(cwd, forKey: .cwd)
    }
}

public struct TabInfo: Identifiable, Codable, Equatable {
    public var id: String
    public var workspaceID: String
    public var label: String

    public init(id: String, workspaceID: String, label: String) {
        self.id = id
        self.workspaceID = workspaceID
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case id, tabID = "tab_id", workspaceID = "workspace_id", label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .tabID) ?? c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(label, forKey: .label)
    }
}

public struct PaneInfo: Identifiable, Codable, Equatable {
    public var id: String
    public var workspaceID: String
    public var tabID: String
    public var label: String
    public var cwd: String

    public init(id: String, workspaceID: String, tabID: String, label: String, cwd: String) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.label = label
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey { case id, paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id", label, cwd }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .paneID) ?? c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        tabID = try c.decode(String.self, forKey: .tabID)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(tabID, forKey: .tabID)
        try c.encode(label, forKey: .label)
        try c.encode(cwd, forKey: .cwd)
    }
}

public struct AgentInfo: Identifiable, Codable, Equatable {
    public var id: String
    public var workspaceID: String
    public var tabID: String
    public var kind: String
    public var name: String
    public var status: AgentStatus

    public init(id: String, workspaceID: String, tabID: String, kind: String, name: String, status: AgentStatus) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.kind = kind
        self.name = name
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case id, paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id", kind, agent, name, title, terminalTitle = "terminal_title_stripped", status, agentStatus = "agent_status" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .paneID) ?? c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        tabID = try c.decode(String.self, forKey: .tabID)
        kind = try c.decodeIfPresent(String.self, forKey: .agent) ?? c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .title)
            ?? c.decodeIfPresent(String.self, forKey: .terminalTitle)
            ?? kind
        status = try c.decodeIfPresent(AgentStatus.self, forKey: .agentStatus)
            ?? c.decodeIfPresent(AgentStatus.self, forKey: .status)
            ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(tabID, forKey: .tabID)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
    }
}

public struct HerdrSnapshot: Codable, Equatable {
    public var workspaces: [WorkspaceInfo]
    public var tabs: [TabInfo]
    public var panes: [PaneInfo]
    public var agents: [AgentInfo]
    public var focusedWorkspaceID: String?
    public var focusedTabID: String?
    public var focusedPaneID: String?

    public init() {
        workspaces = []
        tabs = []
        panes = []
        agents = []
        focusedWorkspaceID = nil
        focusedTabID = nil
        focusedPaneID = nil
    }

    public init(workspaces: [WorkspaceInfo], tabs: [TabInfo], panes: [PaneInfo], agents: [AgentInfo], focusedWorkspaceID: String? = nil, focusedTabID: String? = nil, focusedPaneID: String? = nil) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.focusedWorkspaceID = focusedWorkspaceID
        self.focusedTabID = focusedTabID
        self.focusedPaneID = focusedPaneID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, tabs, panes, agents
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wireWorkspaces = try c.decodeIfPresent([WorkspaceInfo].self, forKey: .workspaces) ?? []
        let wireTabs = try c.decodeIfPresent([TabInfo].self, forKey: .tabs) ?? []
        let wirePanes = try c.decodeIfPresent([PaneInfo].self, forKey: .panes) ?? []
        workspaces = wireWorkspaces.map { workspace in
            var value = workspace
            if value.cwd.isEmpty {
                value.cwd = wirePanes.first(where: { $0.workspaceID == value.id })?.cwd ?? ""
            }
            return value
        }
        tabs = wireTabs
        panes = wirePanes
        agents = try c.decodeIfPresent([AgentInfo].self, forKey: .agents) ?? []
        focusedWorkspaceID = try c.decodeIfPresent(String.self, forKey: .focusedWorkspaceID)
        focusedTabID = try c.decodeIfPresent(String.self, forKey: .focusedTabID)
        focusedPaneID = try c.decodeIfPresent(String.self, forKey: .focusedPaneID)
    }
}

public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    public var displayName: String {
        switch self {
        case .disconnected: "Desconectado"
        case .connecting: "Conectando"
        case .connected: "Conectado"
        case .reconnecting: "Reconectando"
        }
    }
}

extension HerdrSnapshot {
    static func decodeAPIResponse(_ data: Data) throws -> HerdrSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw HerdrTransportError.invalidResponse }
        if let result = root["result"] as? [String: Any] {
            if let snapshot = result["snapshot"] { return SnapshotReconciler.reconcile(try decodeSnapshot(snapshot)) }
            if result["workspaces"] != nil { return SnapshotReconciler.reconcile(try decodeSnapshot(result)) }
        }
        if let snapshot = root["snapshot"] { return SnapshotReconciler.reconcile(try decodeSnapshot(snapshot)) }
        if root["workspaces"] != nil { return SnapshotReconciler.reconcile(try decodeSnapshot(root)) }
        if let error = root["error"] as? [String: Any] {
            throw HerdrTransportError.serverError(error["message"] as? String ?? "Error de Herdr")
        }
        throw HerdrTransportError.invalidResponse
    }

    private static func decodeSnapshot(_ value: Any) throws -> HerdrSnapshot {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(HerdrSnapshot.self, from: data)
    }
}

enum SnapshotReconciler {
    static func reconcile(_ input: HerdrSnapshot) -> HerdrSnapshot {
        var snapshot = input
        let workspaceIDs = Set(snapshot.workspaces.map(\.id))
        let tabIDs = Set(snapshot.tabs.filter { workspaceIDs.contains($0.workspaceID) }.map(\.id))
        let panesByID = Dictionary(snapshot.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        snapshot.tabs = snapshot.tabs.filter { workspaceIDs.contains($0.workspaceID) }
        snapshot.panes = snapshot.panes.filter {
            workspaceIDs.contains($0.workspaceID) && tabIDs.contains($0.tabID)
        }
        let validPaneIDs = Set(snapshot.panes.map(\.id))
        snapshot.agents = snapshot.agents.filter { agent in
            guard let pane = panesByID[agent.id] else { return validPaneIDs.contains(agent.id) }
            return validPaneIDs.contains(agent.id) && pane.workspaceID == agent.workspaceID && pane.tabID == agent.tabID
        }

        if let id = snapshot.focusedWorkspaceID, !workspaceIDs.contains(id) { snapshot.focusedWorkspaceID = nil }
        if let id = snapshot.focusedTabID, !tabIDs.contains(id) { snapshot.focusedTabID = nil }
        if let id = snapshot.focusedPaneID, !validPaneIDs.contains(id) { snapshot.focusedPaneID = nil }
        return snapshot
    }
}
