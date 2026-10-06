import Foundation
import JackCore

/// The project folders on this Mac, kept between launches. Scanning the disk takes seconds,
/// so it runs in the background and at most every ten minutes; the cached list is used meanwhile.
@MainActor final class ProjectIndex: ObservableObject {
    static let shared = ProjectIndex()

    @Published private(set) var projects: [String]
    private var scanning = false
    private static let cacheKey = "knownProjects"
    private static let scannedKey = "knownProjectsScannedAt"

    private init() {
        projects = UserDefaults.standard.stringArray(forKey: Self.cacheKey) ?? []
    }

    func refreshIfStale() {
        let last = UserDefaults.standard.double(forKey: Self.scannedKey)
        guard !scanning, Date().timeIntervalSince1970 - last > 600 || projects.isEmpty else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .utility) { ProjectFinder.scan(roots: ProjectFinder.defaultRoots) }.value
            scanning = false
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.scannedKey)
            UserDefaults.standard.set(found, forKey: Self.cacheKey)
            if found != projects { projects = found }
        }
    }

    /// `recent` first, so a name shared by two folders resolves to the one in use.
    func ordered(recent: [String]) -> [String] {
        var seen = Set<String>()
        return (recent + projects).filter { seen.insert($0).inserted }
    }
}
