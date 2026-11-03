import AppKit
import JackCore
import SwiftUI

/// Toolbar button that lists the folders an agent may use besides its project.
struct AgentFoldersButton: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    @State private var showing = false

    var body: some View {
        let count = conversation.additionalDirectories.count
        Button { showing.toggle() } label: {
            Label(count == 0 ? "Carpetas" : "Carpetas (\(count + 1))", systemImage: count == 0 ? "folder.badge.plus" : "folder.fill.badge.plus")
        }
        .help(count == 0 ? "Dar acceso a más carpetas" : "El agente tiene acceso a \(count + 1) carpetas")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AgentFoldersPanel(store: store, conversation: conversation)
        }
    }
}

private struct AgentFoldersPanel: View {
    @ObservedObject var store: ChatStore
    let conversation: ChatConversation
    @State private var branch = "agent/nuevo"
    @State private var destination = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var review: WorktreeReview?
    @State private var showingIntegrationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Carpetas del agente").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                row(conversation.projectPath, note: "Proyecto", removable: false)
                ForEach(conversation.additionalDirectories, id: \.self) { row($0, note: nil, removable: true) }
            }
            HStack {
                Button("Añadir carpeta…", systemImage: "plus", action: add)
                Spacer()
            }
            if !store.lightModeEnabled {
                Divider().padding(.vertical, 2)
                worktreeControls
            }
            Text("El agente podrá leer y editar estas carpetas a partir de su próximo mensaje.")
                .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: store.lightModeEnabled ? 380 : 440)
        .alert("Integrar cambios confirmados", isPresented: $showingIntegrationConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Integrar con fast-forward") { if let reviewedHead = review?.head { integrate(reviewedHead: reviewedHead) } }
        } message: {
            Text("Jack integrará únicamente commits de la rama \(review?.branch ?? "") si la carpeta base sigue limpia y en su commit original. Los cambios locales de la carpeta base se conservan y bloquean la integración.")
        }
    }

    @ViewBuilder private var worktreeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agente aislado (worktree)").font(.system(size: 13, weight: .semibold))
            if conversation.remote != nil {
                Text("Los worktrees solo están disponibles para agentes locales. No se usará la ruta local de este agente remoto.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Crea otro agente en una rama separada, desde el HEAD confirmado actual. Los cambios locales sin confirmar no se copian.")
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Rama nueva", text: $branch).textFieldStyle(.roundedBorder)
                TextField("Ruta del worktree (opcional)", text: $destination).textFieldStyle(.roundedBorder)
                Text("Si la dejas vacía, se creará junto al repositorio.")
                    .font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                HStack {
                    Button("Crear agente aislado", systemImage: "arrow.branch") { createWorktreeAgent() }
                        .disabled(busy || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Revisar rama y diff", systemImage: "doc.text.magnifyingglass") { loadReview() }
                        .disabled(busy)
                    Spacer()
                }
            }
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(notice.hasPrefix("Error") ? .red : JackPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let review, conversation.remote == nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(review.branch) → \(review.baseBranch)").font(.system(size: 11, weight: .semibold))
                    Text("Base: \(review.basePath)").font(.system(size: 10)).foregroundStyle(JackPalette.muted).textSelection(.enabled)
                    Text("Base: \(review.baseCommit.prefix(12)) · HEAD: \(review.head.prefix(12))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(JackPalette.muted)
                    ScrollView([.vertical, .horizontal]) {
                        Text(review.diff.isEmpty ? "No hay commits nuevos respecto a la base." : review.diff)
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140).padding(6).background(JackPalette.panel, in: RoundedRectangle(cornerRadius: JackPalette.radius(6)))
                    Button("Integrar con fast-forward…", systemImage: "arrow.merge") { showingIntegrationConfirmation = true }
                        .disabled(busy || !review.hasReviewedCommits)
                    Text("Si no es viable ahora, asegúrate de que la base no tenga cambios locales sin confirmar y ejecuta en Terminal: `cd \(shellArgument(review.basePath)) && git switch \(shellArgument(review.baseBranch)) && git merge --ff-only \(shellArgument(review.head))`. Integra exactamente el commit revisado.")
                        .font(.system(size: 10)).foregroundStyle(JackPalette.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).background(JackPalette.panelStrong, in: RoundedRectangle(cornerRadius: JackPalette.radius(8)))
            }
        }
    }

    private func row(_ path: String, note: String?, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(JackPalette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium))
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(JackPalette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(JackPalette.faint) }
            if removable {
                Button { set(conversation.additionalDirectories.filter { $0 != path }) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless).foregroundStyle(JackPalette.muted)
                .help("Quitar acceso a esta carpeta")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: JackPalette.radius(6)))
        .help(path)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.title = "Dar acceso a carpetas"
        panel.prompt = "Añadir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: conversation.projectPath).deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        set(conversation.additionalDirectories + panel.urls.map { $0.standardizedFileURL.path })
    }

    private func set(_ directories: [String]) {
        var updated = conversation
        updated.extraDirectories = directories
        store.updateDirectories(id: conversation.id, directories: updated.additionalDirectories)
    }

    @MainActor private func createWorktreeAgent() {
        guard !store.lightModeEnabled, conversation.remote == nil else { return }
        let cleanBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; notice = nil
        Task {
            guard !store.lightModeEnabled else { busy = false; return }
            do {
                let chosenPath = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                let folder: String
                if chosenPath.isEmpty {
                    let root = await Git.run(["rev-parse", "--show-toplevel"], in: conversation.projectPath, timeout: .seconds(20))
                    guard !store.lightModeEnabled else { busy = false; return }
                    guard root.succeeded else { throw WorktreeError.notRepository(conversation.projectPath) }
                    let rootURL = URL(fileURLWithPath: root.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
                    folder = rootURL.deletingLastPathComponent().appendingPathComponent("\(rootURL.lastPathComponent)-\(cleanBranch.replacingOccurrences(of: "/", with: "-"))").path
                } else { folder = chosenPath }
                let worktree = try await WorktreeService.create(from: conversation.projectPath, branch: cleanBranch, at: folder, normalMode: { !store.lightModeEnabled })
                guard !store.lightModeEnabled else {
                    do { try await WorktreeService.rollbackCreated(worktree, sourcePath: conversation.projectPath) }
                    catch { notice = "Error al retirar el worktree recién creado: \(error.localizedDescription)" }
                    busy = false
                    return
                }
                guard store.create(projectPath: worktree.path, provider: conversation.provider,
                                   model: conversation.model, effort: conversation.effort,
                                   title: "\(conversation.title) · \(cleanBranch)", remote: nil) != nil else {
                    do { try await WorktreeService.rollbackCreated(worktree, sourcePath: conversation.projectPath) }
                    catch { notice = "Error al crear el agente. \(error.localizedDescription)"; busy = false; return }
                    notice = "Error al crear el agente. Se retiraron la rama y el worktree recién creados."
                    busy = false
                    return
                }
                notice = "Agente creado en \(worktree.path). Los cambios locales no confirmados no se copiaron."
            } catch {
                notice = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    @MainActor private func loadReview() {
        guard !store.lightModeEnabled, conversation.remote == nil else { return }
        busy = true; notice = nil
        Task {
            guard !store.lightModeEnabled else { busy = false; return }
            do { review = try await WorktreeService.review(worktreePath: conversation.projectPath, normalMode: { !store.lightModeEnabled }) }
            catch { review = nil; notice = "Error: \(error.localizedDescription)" }
            busy = false
        }
    }

    @MainActor private func integrate(reviewedHead: String) {
        guard !store.lightModeEnabled, conversation.remote == nil else { return }
        busy = true; notice = nil
        Task {
            guard !store.lightModeEnabled else { busy = false; return }
            do {
                try await WorktreeService.integrate(worktreePath: conversation.projectPath, reviewedHead: reviewedHead, normalMode: { !store.lightModeEnabled })
                notice = "Cambios confirmados integrados con fast-forward."
                loadReview()
            } catch { notice = "Error: \(error.localizedDescription)"; busy = false }
        }
    }

    private func shellArgument(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

}
