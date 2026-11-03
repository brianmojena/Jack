import Foundation
import JackCore

/// En la Mac, los agentes de la oficina son los chats de Jack.
extension ChatStore: OfficeHost {
    var officeUsage: ProviderUsage? { usage[.claude] }

    func officeCreate(_ task: String, provider: ChatProvider, model: String?) async -> UUID? {
        createLocating(task, provider: provider, model: model, projects: ProjectIndex.shared.ordered(recent: recentProjects))
    }

    func officeSend(_ text: String, to id: UUID) {
        send(text, to: id)
    }

    /// Las carpetas de proyecto usadas hace poco, para que Jack sitúe los encargos nuevos.
    private var recentProjects: [String] {
        var seen = Set<String>()
        var paths = conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.projectPath)
        if let last = UserDefaults.standard.string(forKey: "lastProjectPath") { paths.append(last) }
        return paths.filter { $0 != ProjectLocator.unplacedFolder && FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
    }
}
