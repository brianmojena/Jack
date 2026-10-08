import AppKit
import JackCore
import SwiftUI

/// A project's git state for the Git pane, shared by every agent working in that folder.
@MainActor final class GitSession: ObservableObject {
    struct Selection: Equatable {
        let path: String
        let staged: Bool
    }

    let directory: String
    @Published private(set) var status: GitStatus?
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var branches: [String] = []
    /// What is running, such as "Enviando…"; buttons wait while it runs.
    @Published private(set) var busy: String?
    @Published var error: String?
    @Published private(set) var selection: Selection?
    @Published private(set) var diff = ""
    @Published var message = ""
    private var automaticTask: Task<Void, Never>?
    private var shownHead: String?? = .none
    private var shownBranch: String?? = .none

    init(directory: String) {
        self.directory = directory
    }

    /// Reads the status, and the history and branches only when HEAD moved. Publishes only what changed.
    func refresh() async {
        let next = await Git.status(in: directory)
        if next != status { status = next }
        guard next.isRepository else { return }
        if shownHead != .some(next.head) || shownBranch != .some(next.branch) {
            shownHead = .some(next.head)
            shownBranch = .some(next.branch)
            let log = await Git.log(in: directory)
            if log != commits { commits = log }
            let list = await Git.branches(in: directory)
            if list != branches { branches = list }
        }
        await reloadDiff()
    }

    func select(_ file: GitFileChange, staged: Bool) {
        let next = Selection(path: file.path, staged: staged)
        selection = selection == next ? nil : next
        diff = ""
        Task { await reloadDiff() }
    }

    func closeDiff() { selection = nil; diff = "" }

    private func reloadDiff() async {
        guard let selection else { return }
        guard let file = status?.files.first(where: { $0.path == selection.path }),
              selection.staged ? file.staged != nil : (file.unstaged != nil || file.untracked || file.conflicted) else {
            // The change was committed, staged or thrown away: nothing left to show here.
            self.selection = nil
            diff = ""
            return
        }
        let text = await Git.diff(file, staged: selection.staged, in: directory)
        if text != diff { diff = text }
    }

    /// Runs a change, shows git's message if it fails and reads the new state.
    func perform(_ label: String, allowed: (@MainActor () -> Bool)? = nil, _ operation: @escaping (String) async -> GitResult) {
        guard busy == nil, allowed?() != false else { return }
        busy = label
        error = nil
        Task {
            guard allowed?() != false else { busy = nil; return }
            let result = await operation(directory)
            busy = nil
            if !result.succeeded { error = result.message }
            shownHead = .none
            if allowed?() != false { await refresh() }
        }
    }

    func cancelAutomaticCommit() {
        automaticTask?.cancel()
    }

    func automaticCommit(allowed: @escaping @MainActor () -> Bool) {
        guard busy == nil, allowed() else { return }
        busy = "Revisando cambios…"
        error = nil
        automaticTask = Task {
            defer { busy = nil; automaticTask = nil }
            do {
                let result = try await GitCommitAutomation().commit(in: directory, allowed: allowed) { self.busy = $0 }
                if !result.succeeded { error = result.message }
            } catch is CancellationError {
                error = "Commit automático cancelado."
            } catch {
                self.error = error.localizedDescription
            }
            shownHead = .none
            if allowed(), !Task.isCancelled { await refresh() }
        }
    }

    func commit() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let status else { return }
        // With nothing staged, everything is committed, as most people expect from one button.
        let everything = status.staged.isEmpty
        perform("Haciendo commit…") { directory in
            if everything {
                let staged = await Git.stageAll(in: directory)
                guard staged.succeeded else { return staged }
            }
            return await Git.commit(text, in: directory)
        }
        message = ""
    }
}

/// The Git pane: branch, changes with their diff, commit, push and pull, and recent history.
struct GitPanel: View {
    @ObservedObject var session: GitSession
    /// Asks the agent of this chat to do something with git, such as writing the commit.
    let onAskAgent: (String) -> Void
    @State private var discarding: GitFileChange?
    @State private var newBranch: String?
    @State private var showingHistory = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        Group {
            if let status = session.status {
                if status.isRepository { repository(status) } else { notRepository }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Reads git every few seconds while the pane is on screen and Jack is in front: agents change files.
        .task(id: session.directory) {
            while !Task.isCancelled {
                if NSApp.isActive || session.status == nil { await session.refresh() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("¿Descartar los cambios de \(discarding.map { ($0.path as NSString).lastPathComponent } ?? "")?",
                            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
            if let file = discarding {
                Button(file.untracked ? "Mover a la papelera" : "Descartar cambios", role: .destructive) {
                    session.perform("Descartando…") { await Git.discard(file, in: $0) }
                    discarding = nil
                }
                Button("Cancelar", role: .cancel) { discarding = nil }
            }
        } message: {
            Text(discarding?.untracked == true ? "El archivo es nuevo: irá a la papelera." : "Se perderán los cambios que no estén preparados.")
        }
        .alert("Nueva rama", isPresented: Binding(get: { newBranch != nil }, set: { if !$0 { newBranch = nil } })) {
            TextField("nombre-de-la-rama", text: Binding(get: { newBranch ?? "" }, set: { newBranch = $0 }))
            Button("Crear y cambiar") {
                let name = (newBranch ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
                newBranch = nil
                guard !name.isEmpty else { return }
                session.perform("Creando rama…") { await Git.createBranch(name, in: $0) }
            }
            Button("Cancelar", role: .cancel) { newBranch = nil }
        } message: {
            Text("Se crea desde el commit actual y te cambias a ella; tus cambios vienen contigo.")
        }
    }

    // MARK: Repository

    private func repository(_ status: GitStatus) -> some View {
        VStack(spacing: 0) {
            toolbar(status)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            if let error = session.error { errorBanner(error) }
            commitBox(status)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            if session.selection != nil {
                PaneStack(.vertical, count: 2, key: "gitDiffSplit") {
                    changes(status)
                    diffView
                }
            } else {
                changes(status)
            }
        }
    }

    private func toolbar(_ status: GitStatus) -> some View {
        HStack(spacing: 4) {
            Menu {
                Section("Cambiar a") {
                    ForEach(session.branches.filter { $0 != status.branch }, id: \.self) { branch in
                        Button(branch) { session.perform("Cambiando de rama…") { await Git.checkout(branch, in: $0) } }
                    }
                }
                Divider()
                Button("Nueva rama…", systemImage: "plus") { newBranch = "" }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .medium))
                    Text(status.branch ?? "HEAD \(status.head ?? "")").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(status.upstream.map { "Sigue a \($0)" } ?? "Sin rama remota: el primer push la crea")
            if status.ahead > 0 || status.behind > 0 {
                Text([status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JackPalette.muted)
            }
            Spacer(minLength: 4)
            if let busy = session.busy {
                ProgressView().controlSize(.mini)
                Text(busy).font(.system(size: 11)).foregroundStyle(JackPalette.muted).lineLimit(1)
            }
            toolButton("arrow.triangle.2.circlepath", help: "Traer cambios del remoto (fetch)") {
                session.perform("Trayendo…") { await Git.fetch(in: $0) }
            }
            toolButton("arrow.down", count: status.behind, help: "Bajar cambios (pull, solo si no hay que fusionar)") {
                session.perform("Bajando…") { await Git.pull(in: $0) }
            }
            toolButton("arrow.up", count: status.ahead, help: status.upstream == nil ? "Publicar la rama (push)" : "Subir commits (push)") {
                session.perform("Subiendo…") { await Git.push(status, in: $0) }
            }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .disabled(session.busy != nil)
    }

    private func toolButton(_ symbol: String, count: Int = 0, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                if count > 0 { Text("\(count)").font(.system(size: 10.5, weight: .semibold)) }
            }
            .padding(.horizontal, 5).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(count > 0 ? JackPalette.accent : JackPalette.secondaryText)
        .help(help)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
            Text(error).font(.system(size: 11, design: .monospaced)).foregroundStyle(JackPalette.secondaryText)
                .lineLimit(6).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { onAskAgent("Al usar git en este proyecto falló esto. Revísalo y arréglalo:\n\n\(error)") } label: {
                Text("Pedir ayuda").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(JackPalette.accent)
            Button { session.error = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(JackPalette.muted)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
    }

    private func commitBox(_ status: GitStatus) -> some View {
        let nothingStaged = status.staged.isEmpty
        let canCommit = !session.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.files.isEmpty
            && status.conflicted.isEmpty && session.busy == nil
        return VStack(alignment: .leading, spacing: 7) {
            TextField(status.files.isEmpty ? "Nada que confirmar" : "Mensaje del commit", text: $session.message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .focused($messageFocused)
                .onSubmit { if canCommit { session.commit() } }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(messageFocused ? JackPalette.accent.opacity(0.6) : JackPalette.hairline, lineWidth: 1))
            HStack(spacing: 8) {
                Button(nothingStaged ? "Commit de todo" : "Commit") { session.commit() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                    .help(nothingStaged ? "No hay nada preparado: se incluyen todos los cambios" : "Confirmar los cambios preparados")
                Button("Que lo haga el agente") {
                    onAskAgent("Revisa los cambios del proyecto con git (status y diff) y haz un commit con un mensaje claro que los describa.")
                }
                .controlSize(.small)
                .disabled(status.files.isEmpty)
                .help("Le pide al agente de este chat que revise los cambios y escriba el commit")
                Spacer()
                if !status.conflicted.isEmpty {
                    Text("Resuelve los conflictos antes del commit").font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
    }

    private func changes(_ status: GitStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if status.files.isEmpty {
                    Text("Sin cambios: todo está confirmado.")
                        .font(.system(size: 12)).foregroundStyle(JackPalette.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                if !status.conflicted.isEmpty {
                    sectionHeader("Conflictos", count: status.conflicted.count)
                    ForEach(status.conflicted) { row($0, staged: false) }
                }
                if !status.staged.isEmpty {
                    sectionHeader("Preparados", count: status.staged.count, action: ("Quitar todo", {
                        let paths = status.staged.map(\.path)
                        session.perform("Quitando…") { await Git.unstage(paths, in: $0) }
                    }))
                    ForEach(status.staged) { row($0, staged: true) }
                }
                if !status.unstaged.isEmpty {
                    sectionHeader("Cambios", count: status.unstaged.count, action: ("Preparar todo", {
                        session.perform("Preparando…") { await Git.stageAll(in: $0) }
                    }))
                    ForEach(status.unstaged) { row($0, staged: false) }
                }
                history
            }
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ title: String, count: Int, action: (String, () -> Void)? = nil) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(JackPalette.muted)
            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(JackPalette.faint)
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(JackPalette.accent)
                    .disabled(session.busy != nil)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ file: GitFileChange, staged: Bool) -> some View {
        GitChangeRow(file: file, staged: staged,
                     selected: session.selection == GitSession.Selection(path: file.path, staged: staged),
                     busy: session.busy != nil,
                     onSelect: { session.select(file, staged: staged) },
                     onStage: { session.perform("Preparando…") { await Git.stage([file.path], in: $0) } },
                     onUnstage: { session.perform("Quitando…") { await Git.unstage([file.path], in: $0) } },
                     onDiscard: { discarding = file },
                     onOpen: { NSWorkspace.shared.open(URL(fileURLWithPath: session.directory).appendingPathComponent(file.path)) },
                     onReveal: {
                         NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory).appendingPathComponent(file.path)])
                     })
    }

    @ViewBuilder private var history: some View {
        if !session.commits.isEmpty {
            Button { showingHistory.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showingHistory ? 90 : 0))
                    Text("HISTORIAL").font(.system(size: 10, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(JackPalette.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
            if showingHistory {
                ForEach(session.commits) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(commit.shortHash).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(JackPalette.accent)
                        Text(commit.subject).font(.system(size: 11.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.system(size: 10)).foregroundStyle(JackPalette.faint)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .help("\(commit.author) · \(commit.hash)")
                    .contextMenu {
                        Button("Copiar hash") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private var diffView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(session.selection.map { ($0.path as NSString).lastPathComponent } ?? "")
                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(session.selection?.staged == true ? "preparado" : "sin preparar")
                    .font(.system(size: 10.5)).foregroundStyle(JackPalette.muted)
                Spacer()
                Button { session.closeDiff() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(JackPalette.muted).help("Cerrar el diff")
            }
            .padding(.horizontal, 10).frame(height: 28)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            GitDiffView(diff: session.diff).equatable()
        }
    }

    private var notRepository: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 26, weight: .light)).foregroundStyle(JackPalette.faint)
            Text("Esta carpeta no usa git").font(.system(size: 13, weight: .semibold))
            Text(session.directory).font(.system(size: 11, design: .monospaced)).foregroundStyle(JackPalette.muted)
                .lineLimit(1).truncationMode(.middle)
            Button("Crear un repositorio aquí") { session.perform("Creando…") { await Git.initialize(in: $0) } }
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitChangeRow: View {
    let file: GitFileChange
    let staged: Bool
    let selected: Bool
    let busy: Bool
    let onSelect: () -> Void
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscard: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    @State private var hovering = false

    private var letter: Character {
        if file.conflicted { return "!" }
        if file.untracked { return "U" }
        return (staged ? file.staged : file.unstaged) ?? "M"
    }

    private var color: Color {
        switch letter {
        case "A", "U": .green
        case "D", "!": .red
        case "R", "C": JackPalette.accent
        default: .orange
        }
    }

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 7) {
            Text(String(letter)).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 12)
            Text(name).font(.system(size: 12)).lineLimit(1)
                .strikethrough(letter == "D", color: JackPalette.muted)
            if !folder.isEmpty {
                Text(folder).font(.system(size: 10.5)).foregroundStyle(JackPalette.faint).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering && !busy {
                if !staged && !file.conflicted {
                    icon("arrow.uturn.backward", help: file.untracked ? "Mover a la papelera" : "Descartar cambios", action: onDiscard)
                }
                if staged { icon("minus", help: "Quitar de preparados", action: onUnstage) }
                else { icon("plus", help: file.conflicted ? "Marcar como resuelto" : "Preparar", action: onStage) }
            }
        }
        .padding(.horizontal, 12).frame(height: 24)
        .background(selected ? JackPalette.accent.opacity(0.16) : hovering ? JackPalette.panel : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            Button("Ver cambios", action: onSelect)
            if staged { Button("Quitar de preparados", action: onUnstage) } else { Button("Preparar", action: onStage) }
            if !staged && !file.conflicted { Button(file.untracked ? "Mover a la papelera…" : "Descartar cambios…", role: .destructive, action: onDiscard) }
            Divider()
            if letter != "D" { Button("Abrir", action: onOpen) }
            Button("Mostrar en Finder", action: onReveal)
        }
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(JackPalette.secondaryText).help(help)
    }
}

/// A file's diff, line by line, coloured like a code review.
struct GitDiffView: View, Equatable {
    let diff: String
    /// Past this a diff is a generated or minified file; the rest is not worth drawing.
    private static let maxLines = 3000

    private var lines: [Substring] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { !$0.hasPrefix("@@") && !$0.isEmpty }
            .prefix(Self.maxLines).map { $0 }
    }

    var body: some View {
        let lines = lines
        if diff.isEmpty {
            Text("Sin diferencias de texto (archivo binario o solo cambió el modo).")
                .font(.system(size: 11.5)).foregroundStyle(JackPalette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("@@") ? JackPalette.accent : JackPalette.secondaryText)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                            .background(background(line))
                    }
                    if lines.count == Self.maxLines {
                        Text("Diff recortado a \(Self.maxLines) líneas.").font(.system(size: 11)).foregroundStyle(JackPalette.muted).padding(10)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
        }
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("+") { return Color.green.opacity(0.14) }
        if line.hasPrefix("-") { return Color.red.opacity(0.14) }
        if line.hasPrefix("@@") { return JackPalette.accent.opacity(0.07) }
        return .clear
    }
}

/// The Git button's right-click menu, shown only by the Normal workspace.
struct GitQuickActionsMenu: View {
    @ObservedObject var session: GitSession
    let allowed: @MainActor () -> Bool
    let onShowGit: () -> Void

    var body: some View {
        Group {
            Button("Commit", systemImage: "checkmark.circle") {
                guard allowed() else { return }
                onShowGit()
                session.automaticCommit(allowed: allowed)
            }
            .help("Genera el mensaje y hace commit con Gemma 4 31B Cloud. El diff se envía a Ollama Cloud.")
            Button("Push", systemImage: "arrow.up") {
                guard allowed() else { return }
                onShowGit()
                session.perform("Subiendo…", allowed: allowed) { directory in
                    guard allowed() else { return GitResult(status: 1, output: "", error: "Acción cancelada.") }
                    let status = await Git.status(in: directory)
                    guard allowed(), status.isRepository, status.branch != nil else {
                        return GitResult(status: 1, output: "", error: "Push requiere una rama de un repositorio Git en modo Normal.")
                    }
                    return await Git.push(status, in: directory)
                }
            }
            Button("Pull", systemImage: "arrow.down") {
                guard allowed() else { return }
                onShowGit()
                session.perform("Bajando…", allowed: allowed) { directory in
                    guard allowed() else { return GitResult(status: 1, output: "", error: "Acción cancelada.") }
                    return await Git.pull(in: directory)
                }
            }
            .help("Descarga los cambios con pull --ff-only")
        }
        .disabled(session.busy != nil)
    }
}
