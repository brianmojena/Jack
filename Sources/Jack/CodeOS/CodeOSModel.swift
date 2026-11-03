import AppKit
import Combine
import JackCore
import SwiftUI

/// A project shown as a "game" tile: a folder Claude Code was last opened in, with that session's title and date.
struct CodeOSProject: Identifiable, Equatable {
    let id: String
    let name: String
    let hue: Double
    let title: String
    let updatedAt: Date
    /// Sessions Claude Code has had in this folder over the last weeks: how much it is used.
    let visits: Int

    init(path: String, title: String = "", updatedAt: Date = .distantPast, visits: Int = 0) {
        id = path
        name = (path as NSString).lastPathComponent
        self.title = title
        self.updatedAt = updatedAt
        self.visits = visits
        // djb2: `hashValue` changes between launches and the tile colours must not.
        let seed = name.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        hue = Double(seed % 360) / 360
    }

    /// A session file written to in the last two minutes: an agent is probably working there right now.
    var isLive: Bool { -updatedAt.timeIntervalSinceNow < 120 }
    var color: Color { Color(hue: hue, saturation: 0.6, brightness: 0.8) }
    var initial: String { String(name.first ?? "?").uppercased() }

    var ago: String {
        guard updatedAt != .distantPast else { return "Proyecto de ejemplo" }
        if isLive { return "Activo ahora" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "es")
        return formatter.localizedString(for: updatedAt, relativeTo: .now).prefix(1).uppercased() + formatter.localizedString(for: updatedAt, relativeTo: .now).dropFirst()
    }
}

enum CodeOSCategory: CaseIterable {
    case featured, recent, today, week

    var title: String {
        switch self {
        case .featured: "DESTACADOS"
        case .recent: "RECIENTES"
        case .today: "HOY"
        case .week: "ESTA SEMANA"
        }
    }

    /// The date-based tabs; "featured" and "recent" pick from the whole list instead (see `CodeOSModel.visible`).
    func accepts(_ project: CodeOSProject) -> Bool {
        let age = -project.updatedAt.timeIntervalSinceNow
        switch self {
        case .today: return age < 86_400
        case .week: return age < 7 * 86_400
        case .featured, .recent: return true
        }
    }
}

enum CodeOSAgent: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"
    case opencode = "OpenCode"

    var id: String { rawValue }

    var provider: ChatProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}

struct CodeOSLine: Identifiable {
    enum Role { case user, agent, tool }

    let id = UUID()
    let role: Role
    let text: String
}

/// Navigation state of the console: shelf, open project and control center. Every move has its sound.
@MainActor final class CodeOSModel: ObservableObject {
    struct Art {
        let image: NSImage
        let tint: Color
        /// Set when the image is a framework's logo (the folder had no icon of its own): its name.
        var framework: String? = nil
        /// Identifies the picture, so projects that end up with the same one can be told apart.
        var fingerprint: Int = 0
        var shared = false
    }

    /// Every folder Claude Code was opened in; `allProjects` is what is left after the ones the user removed from the list.
    @Published private(set) var catalog: [CodeOSProject] = []
    /// False until the project list has been read: the shelf stays empty, with no "see all" tile either.
    @Published private(set) var loaded = false
    @Published private(set) var hidden: Set<String> = []
    var allProjects: [CodeOSProject] { catalog.filter { !hidden.contains($0.id) } }
    // The "see all" grid.
    @Published private(set) var gridVisible = false
    @Published private(set) var gridFocus = 0
    @Published private(set) var showHidden = false
    /// Cells per row in the grid, reported by the view so up and down move a whole row.
    var gridColumns = 6
    @Published var category: CodeOSCategory = .featured
    @Published private(set) var focus = 0
    @Published private(set) var open: CodeOSProject?
    @Published private(set) var controlCenter = false
    @Published private(set) var ccRow = 0
    @Published private(set) var ccCol = 0
    @Published var agent: CodeOSAgent = .claude
    @Published private(set) var art: [String: Art] = [:]
    @Published var covers: [String: NSImage] = [:]
    @Published var generating: Set<String> = []
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    private let store: ChatStore
    private let sound = CodeOSSound.shared
    private static let samples = ["Jack", "BuildCloud", "Financia", "Revolico", "Portfolio", "Sandbox"].map { CodeOSProject(path: "/Users/demo/\($0)") }
    /// Row 0 of the control center: the three agents and "leave CodeOS".
    static let controlItems = CodeOSAgent.allCases.count + 1

    /// Shared-account profiles and quota. Its changes also refresh the views that watch the model.
    let quota: CodeOSQuotaCoordinator
    private var quotaObserver: AnyCancellable?
    // Profile screen and quota panel.
    @Published private(set) var profileCursor = 0
    @Published private(set) var addingProfile = false
    @Published var newProfileName = ""
    @Published private(set) var confirmingRemoval = false
    @Published private(set) var quotaPanel = false
    @Published private(set) var editingCode = false

    init(store: ChatStore) {
        self.store = store
        quota = CodeOSQuotaCoordinator(store: store)
        quotaObserver = quota.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Task { await load() }
    }

    /// Each profile keeps its own list of removed projects.
    private var hiddenKey: String { "codeOSHiddenProjects" + (quota.current.map { "." + $0.id.uuidString } ?? "") }

    /// The folders Claude Code was opened in, most recent first, from its own session files.
    private func load() async {
        let found = await Task.detached(priority: .userInitiated) { () -> [CodeOSProject] in
            var seen = Set<String>()
            let home = NSHomeDirectory()
            let sessions = ClaudeSessions.list(limit: 600)
            // How often each folder is used: its sessions from the last 60 days.
            let cutoff = Date().addingTimeInterval(-60 * 86_400)
            var visits: [String: Int] = [:]
            for session in sessions where session.updatedAt > cutoff { visits[session.projectPath, default: 0] += 1 }
            var projects: [CodeOSProject] = []
            for session in sessions {
                let path = session.projectPath
                guard path != home, path != "/", seen.insert(path).inserted else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                projects.append(CodeOSProject(path: path, title: session.title, updatedAt: session.updatedAt, visits: visits[path] ?? 0))
                if projects.count == 60 { break }
            }
            return projects
        }.value
        catalog = found.isEmpty ? Self.samples : found
        loaded = true
        for project in catalog { if let cover = CodeOSCoverStore.existing(for: project) { covers[project.id] = cover } }
        await loadArt()
    }

    /// What the shelf shows. "Destacados" is the home default: the few projects worked on in the last hours come first and always
    /// appear (up to three), and the rest of the six places go to the most used ones.
    var visible: [CodeOSProject] {
        let pool = allProjects
        switch category {
        case .featured:
            let fresh = pool.filter { -$0.updatedAt.timeIntervalSinceNow < 6 * 3_600 }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3)
            let taken = Set(fresh.map(\.id))
            let frequent = pool.filter { !taken.contains($0.id) }.sorted { ($0.visits, $0.updatedAt) > ($1.visits, $1.updatedAt) }.prefix(Self.shelfSize - fresh.count)
            return Array(fresh) + Array(frequent)
        case .recent:
            return Array(pool.sorted { $0.updatedAt > $1.updatedAt }.prefix(10))
        case .today, .week:
            return pool.filter(category.accepts)
        }
    }
    static let shelfSize = 10
    var focused: CodeOSProject? { visible.indices.contains(focus) ? visible[focus] : nil }

    func tint(_ project: CodeOSProject) -> Color { art[project.id]?.tint ?? project.color }

    // MARK: Shelf

    func moveFocus(_ delta: Int) {
        // One past the last project is the "see all" tile, once the projects are there.
        let target = min(max(focus + delta, 0), loaded ? visible.count : 0)
        guard target != focus else { return }
        focus = target
        sound.move(forward: delta > 0)
    }

    /// Clicking a tab of the top bar.
    func selectCategory(_ target: CodeOSCategory) {
        guard target != category else { return }
        category = target
        focus = 0
        sound.play(.tab)
    }

    func shiftCategory(_ delta: Int) {
        let all = CodeOSCategory.allCases
        guard let index = all.firstIndex(of: category) else { return }
        let target = min(max(index + delta, 0), all.count - 1)
        guard target != index else { return }
        category = all[target]
        focus = 0
        sound.play(.tab)
    }

    func openFocused() {
        guard let focused else {
            if loaded, focus == visible.count { openGrid() }
            return
        }
        launch(focused)
    }

    /// Takes the focused project off the list. It stays in the grid's hidden set, where it can be put back.
    func removeFocused() {
        guard let project = focused else { return }
        hide(project)
        focus = min(focus, visible.count)
        notify("«\(project.name)» quitado de la lista. En «Ver todos», H muestra los quitados.")
    }

    private func hide(_ project: CodeOSProject) {
        hidden.insert(project.id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
        sound.play(.back)
    }

    private func restore(_ project: CodeOSProject) {
        hidden.remove(project.id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
        sound.play(.select)
    }

    // MARK: Grid ("see all")

    /// What the grid lists: every project, with the removed ones only while they are shown.
    var gridProjects: [CodeOSProject] { showHidden ? catalog : allProjects }

    func openGrid() {
        guard loaded else { return }
        gridFocus = 0
        showHidden = false
        gridVisible = true
        sound.play(.panel)
    }

    func closeGrid() {
        guard gridVisible else { return }
        gridVisible = false
        sound.play(.panelClose)
    }

    func moveGrid(dx: Int, dy: Int) {
        let count = gridProjects.count
        guard count > 0 else { return }
        let target = min(max(gridFocus + dx + dy * gridColumns, 0), count - 1)
        guard target != gridFocus else { return }
        gridFocus = target
        sound.move(forward: target > gridFocus)
    }

    func activateGrid() {
        guard gridProjects.indices.contains(gridFocus) else { return }
        let project = gridProjects[gridFocus]
        guard !hidden.contains(project.id) else { return }
        gridVisible = false
        launch(project)
    }

    /// Removes the project under the cursor from the list, or puts it back if it was removed.
    func toggleGridHidden() {
        guard gridProjects.indices.contains(gridFocus) else { return }
        let project = gridProjects[gridFocus]
        if hidden.contains(project.id) { restore(project) } else { hide(project) }
        gridFocus = min(gridFocus, max(gridProjects.count - 1, 0))
    }

    func toggleShowHidden() {
        showHidden.toggle()
        gridFocus = min(gridFocus, max(gridProjects.count - 1, 0))
        sound.play(.tab)
    }

    func goHome() {
        guard open != nil else { return }
        open = nil
        sound.play(.home)
    }

    private func launch(_ project: CodeOSProject) {
        if let index = visible.firstIndex(of: project) { focus = index }
        open = project
        controlCenter = false
        sound.play(.launch)
    }

    // MARK: Conversations

    /// A fresh chat for a project with the chosen agent: an empty one already there is reused, so opening a project
    /// twice does not pile up blank chats. Selecting it shows it in the chat beside the history.
    func conversation(for project: CodeOSProject) -> UUID? {
        let provider = agent.provider
        let blank = store.conversations.first { $0.projectPath == project.id && $0.provider == provider && $0.parentID == nil && $0.messages.isEmpty && $0.sessionID == nil }
        let id = blank?.id ?? store.create(projectPath: project.id, provider: provider)
        if let id { store.select(id) }
        return id
    }

    // MARK: Control center

    func toggleControlCenter() {
        controlCenter.toggle()
        sound.play(controlCenter ? .panel : .panelClose)
        if controlCenter {
            ccRow = 1
            ccCol = open.flatMap { allProjects.firstIndex(of: $0) } ?? 0
        }
    }

    func closeControlCenter() {
        guard controlCenter else { return }
        controlCenter = false
        sound.play(.panelClose)
    }

    func moveControl(dx: Int, dy: Int) {
        let row = min(max(ccRow + dy, 0), 1)
        let count = row == 0 ? Self.controlItems : allProjects.count
        let col = min(max((row == ccRow ? ccCol : min(ccCol, count - 1)) + dx, 0), max(count - 1, 0))
        guard row != ccRow || col != ccCol else { return }
        ccRow = row
        ccCol = col
        sound.move(forward: dx >= 0)
    }

    /// Clicking an item of the control center: the same as moving to it and pressing Enter.
    func selectControl(row: Int, col: Int) {
        ccRow = row
        ccCol = col
        activateControl()
    }

    func activateControl() {
        if ccRow == 1 {
            guard allProjects.indices.contains(ccCol) else { return }
            launch(allProjects[ccCol])
        } else if ccCol < CodeOSAgent.allCases.count {
            agent = CodeOSAgent.allCases[ccCol]
            sound.play(.select)
        } else {
            exit()
        }
    }

    /// Warms up the sound engine so the first key press is not late, and plays the entry sound.
    func enter() {
        sound.prepare()
        sound.play(.enter)
    }

    /// A short message for the home screen that fades after a few seconds.
    func notify(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { notice = nil }
        }
    }

    func generateFocusedCover() {
        if let focused { generateCover(for: focused) }
    }

    func shutDown() {
        quota.stop()
        sound.stopAll()
    }

    // MARK: Profiles

    /// Entries on the profile screen: the profiles, then "add".
    var profileSlots: Int { quota.profiles.count + 1 }

    func moveProfile(_ delta: Int) {
        let target = min(max(profileCursor + delta, 0), profileSlots - 1)
        guard target != profileCursor else { return }
        profileCursor = target
        confirmingRemoval = false
        sound.move(forward: delta > 0)
    }

    func activateProfile() {
        if profileCursor < quota.profiles.count {
            let profile = quota.profiles[profileCursor]
            quota.choose(profile)
            hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
            focus = 0
            sound.play(.enter)
        } else {
            addingProfile = true
            newProfileName = ""
            sound.play(.select)
        }
    }

    func commitNewProfile() {
        quota.addProfile(named: newProfileName)
        addingProfile = false
        newProfileName = ""
        profileCursor = max(quota.profiles.count - 1, 0)
        sound.play(.select)
    }

    func cancelNewProfile() {
        guard addingProfile else { return }
        addingProfile = false
        sound.play(.back)
    }

    /// Delete asks twice, so a profile is not lost by a stray key.
    func removeProfileUnderCursor() {
        guard profileCursor < quota.profiles.count else { return }
        if confirmingRemoval {
            quota.removeProfile(quota.profiles[profileCursor])
            profileCursor = min(profileCursor, quota.profiles.count)
            confirmingRemoval = false
            sound.play(.back)
        } else {
            confirmingRemoval = true
            sound.play(.tab)
        }
    }

    func changeProfile() {
        open = nil
        gridVisible = false
        controlCenter = false
        quotaPanel = false
        quota.leave()
        hidden = []
        sound.play(.back)
    }

    /// Leaves CodeOS for the style Jack had before: the window goes back to normal.
    func exit() {
        sound.play(.back)
        shutDown()
        let before = UserDefaults.standard.string(forKey: "interfaceStyleBeforeCodeOS").flatMap(InterfaceStyleChoice.init(rawValue:)) ?? .basic
        UserDefaults.standard.set(before.rawValue, forKey: "interfaceStyle")
    }

    // MARK: Quota panel

    func toggleQuotaPanel() {
        quotaPanel.toggle()
        editingCode = false
        sound.play(quotaPanel ? .panel : .panelClose)
    }

    func closeQuotaPanel() {
        guard quotaPanel else { return }
        if editingCode { editingCode = false; return }
        quotaPanel = false
        sound.play(.panelClose)
    }

    func beginEditingCode() { editingCode = true }
    func endEditingCode() { editingCode = false }

    // MARK: Artwork

    private func loadArt() async {
        for project in catalog {
            let urls = await Task.detached(priority: .utility) { CodeOSIconFinder.candidates(in: project.id) }.value
            var found = false
            for url in urls {
                guard let image = NSImage(contentsOf: url), image.size.width >= 24, image.isRoughlySquare else { continue }
                let fingerprint = (try? Data(contentsOf: url))?.hashValue ?? 0
                art[project.id] = Art(image: image, tint: image.codeOSTint() ?? project.color, fingerprint: fingerprint)
                found = true
                break
            }
            // No icon of its own: the logo of the framework it is built with.
            if !found, let logo = await CodeOSFramework.logo(for: project.id) {
                let seed = logo.slug.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
                art[project.id] = Art(image: logo.image, tint: logo.tint, framework: logo.name, fingerprint: seed)
            }
            markShared()
        }
    }

    /// Projects whose pictures are the same (two FastAPI backends) are flagged, and their tiles show the project's name too.
    private func markShared() {
        var counts: [Int: Int] = [:]
        for value in art.values { counts[value.fingerprint, default: 0] += 1 }
        for (id, value) in art {
            let isShared = (counts[value.fingerprint] ?? 0) > 1
            if isShared != value.shared { art[id]?.shared = isShared }
        }
    }
}

/// The interface styles CodeOS can return to (the raw values of `InterfaceStyle`, which the model does not need to import).
private enum InterfaceStyleChoice: String { case basic, ice, terminal, office }
