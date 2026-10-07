import Foundation

/// Where the chats sit in the window: columns side by side, each a stack of chats one above another.
/// One slot is the main chat, whichever agent is selected; the others hold agents opened beside it.
public struct PaneLayout: Equatable, Sendable {
    public enum Slot: Hashable, Sendable {
        case main
        case agent(UUID)
    }

    /// Where a chat dropped on another one goes.
    public enum Zone: Sendable {
        case left, right, top, bottom
        /// In its place.
        case center
    }

    public private(set) var columns: [[Slot]]

    /// More agents than this beside the main chat leaves each one too small on a laptop screen.
    public static let limit = 3

    public init(columns: [[Slot]] = [[.main]]) {
        self.columns = columns
        normalize()
    }

    /// The agents beside the main chat, column by column, top to bottom.
    public var agents: [UUID] {
        columns.flatMap { $0 }.compactMap { if case .agent(let id) = $0 { id } else { nil } }
    }

    public func contains(_ id: UUID) -> Bool { agents.contains(id) }

    /// The column and row of a slot.
    public func position(of slot: Slot) -> (column: Int, row: Int)? {
        for (column, slots) in columns.enumerated() {
            if let row = slots.firstIndex(of: slot) { return (column, row) }
        }
        return nil
    }

    /// Opens an agent in a new column at the right, unless it is already open.
    public func opening(_ id: UUID) -> PaneLayout {
        guard !contains(id) else { return self }
        var next = self
        next.columns.append([.agent(id)])
        next.enforceLimit(keeping: id)
        return next
    }

    /// Opens an agent under another one, as a sub-agent under the agent that started it.
    public func opening(_ id: UUID, under parent: Slot) -> PaneLayout {
        guard !contains(id) else { return self }
        guard position(of: parent) != nil else { return opening(id) }
        return placing(.agent(id), at: parent, .bottom)
    }

    /// Moves `slot` next to `target` or into its place; a slot not yet in the layout is added.
    /// Dropping an agent in the main chat's place is not handled here: the caller selects it instead.
    public func placing(_ slot: Slot, at target: Slot, _ zone: Zone) -> PaneLayout {
        guard slot != target, let targetPosition = position(of: target) else { return self }
        var next = self
        if zone == .center {
            // The two trade places, or the new one takes the target's place and the target closes.
            let origin = position(of: slot)
            next.columns[targetPosition.column][targetPosition.row] = slot
            if let origin { next.columns[origin.column][origin.row] = target }
            next.normalize()
            if case .agent(let id) = slot { next.enforceLimit(keeping: id) }
            return next
        }
        next.remove(slot)
        guard let (column, row) = next.position(of: target) else { return self }
        switch zone {
        case .left: next.columns.insert([slot], at: column)
        case .right: next.columns.insert([slot], at: column + 1)
        case .top: next.columns[column].insert(slot, at: row)
        case .bottom: next.columns[column].insert(slot, at: row + 1)
        case .center: break
        }
        next.normalize()
        if case .agent(let id) = slot { next.enforceLimit(keeping: id) }
        return next
    }

    public func removing(_ id: UUID) -> PaneLayout {
        var next = self
        next.remove(.agent(id))
        next.normalize()
        return next
    }

    /// The same layout without agents that no longer exist.
    public func keeping(_ ids: Set<UUID>) -> PaneLayout {
        var next = self
        next.columns = columns.map { $0.filter { if case .agent(let id) = $0 { ids.contains(id) } else { true } } }
        next.normalize()
        return next
    }

    /// Puts `id` in the slot of `other`, which closes; used when the main chat's agent changes places with a pane.
    public func replacing(_ other: UUID, with id: UUID) -> PaneLayout {
        var next = self
        next.remove(.agent(id))
        guard let (column, row) = next.position(of: .agent(other)) else { return self }
        next.columns[column][row] = .agent(id)
        next.normalize()
        return next
    }

    /// The columns that fit when only `count` can be shown: the main chat's and the nearest ones to it.
    public func visibleColumns(_ count: Int) -> [Int] {
        let main = position(of: .main)?.column ?? 0
        let wanted = max(1, count)
        var chosen = [main]
        var distance = 1
        while chosen.count < min(wanted, columns.count) {
            if main + distance < columns.count { chosen.append(main + distance) }
            if chosen.count < wanted, main - distance >= 0 { chosen.append(main - distance) }
            distance += 1
        }
        return chosen.sorted()
    }

    private mutating func remove(_ slot: Slot) {
        columns = columns.map { $0.filter { $0 != slot } }
    }

    /// No empty columns, and the main chat always somewhere.
    private mutating func normalize() {
        var seen = Set<Slot>()
        columns = columns.map { $0.filter { seen.insert($0).inserted } }.filter { !$0.isEmpty }
        if position(of: .main) == nil { columns.insert([.main], at: 0) }
    }

    /// Past the limit the agents opened longest ago close, never the one just placed.
    private mutating func enforceLimit(keeping id: UUID) {
        var extra = agents.count - Self.limit
        for other in agents where extra > 0 && other != id {
            remove(.agent(other))
            extra -= 1
        }
        normalize()
    }

    // MARK: Storage

    /// Columns separated by "|", slots by ",", the main chat as "main".
    public var encoded: String {
        columns.map { $0.map { if case .agent(let id) = $0 { id.uuidString } else { "main" } }.joined(separator: ",") }
            .joined(separator: "|")
    }

    public init(encoded: String) {
        let columns: [[Slot]] = encoded.split(separator: "|").map { column in
            column.split(separator: ",").compactMap { item in
                item == "main" ? .main : UUID(uuidString: String(item)).map { .agent($0) }
            }
        }
        self.init(columns: columns)
    }
}
