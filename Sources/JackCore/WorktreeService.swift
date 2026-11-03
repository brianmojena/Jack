import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct GitWorktree: Equatable, Sendable {
    public let path: String
    public let branch: String?
    public let head: String?
    public init(path: String, branch: String?, head: String?) { self.path = path; self.branch = branch; self.head = head }
}

public struct WorktreeReview: Equatable, Sendable {
    public let branch: String
    public let basePath: String
    public let baseBranch: String
    public let baseCommit: String
    public let head: String
    public let diff: String
    public var hasReviewedCommits: Bool { head != baseCommit }
    public init(branch: String, basePath: String, baseBranch: String, baseCommit: String, head: String, diff: String) {
        self.branch = branch; self.basePath = basePath; self.baseBranch = baseBranch; self.baseCommit = baseCommit; self.head = head; self.diff = diff
    }
}

public typealias WorktreeModeCheck = @MainActor @Sendable () -> Bool

public enum WorktreeError: LocalizedError, Equatable {
    case notRepository(String)
    case noCommit
    case normalOnly
    case invalidBranch(String)
    case branchExists(String)
    case destinationExists(String)
    case invalidPath(String)
    case unsafeDestination(String)
    case notManagedWorktree
    case dirtyBase([String])
    case dirtyWorktree([String])
    case gitStatusFailed(String)
    case divergedHistory
    case baseChanged(expected: String, actual: String)
    case reviewedHeadChanged(expected: String, actual: String)
    case modeChangedDuringIntegration
    case operation(String)
    case rollback(String)

    public var errorDescription: String? {
        switch self {
        case .notRepository(let path): return "La carpeta no es un repositorio Git: \(path)"
        case .noCommit: return "El repositorio todavía no tiene un commit confirmado (HEAD)."
        case .normalOnly: return "Los worktrees de agentes solo están disponibles en el modo Normal."
        case .invalidBranch(let name): return "El nombre de rama no es válido: \(name)"
        case .branchExists(let name): return "La rama ya existe: \(name)"
        case .destinationExists(let path): return "La ruta de destino ya existe: \(path)"
        case .invalidPath(let path): return "La ruta debe ser absoluta: \(path)"
        case .unsafeDestination(let path): return "La ruta debe estar fuera de la carpeta del proyecto: \(path)"
        case .notManagedWorktree: return "No se encontraron metadatos de worktree creados por Jack."
        case .dirtyBase(let paths): return "La carpeta base tiene cambios locales. Confírmalos o guárdalos antes de integrar. Archivos: \(paths.joined(separator: ", "))"
        case .dirtyWorktree(let paths): return "La rama del agente tiene cambios sin confirmar. Confírmalos o guárdalos y vuelve a revisar antes de integrar. Archivos: \(paths.joined(separator: ", "))"
        case .gitStatusFailed(let message): return "No se pudo comprobar el estado de Git; no se puede confirmar que la carpeta esté limpia. \(message)"
        case .divergedHistory: return "La rama del agente ya no desciende de la base revisada. Revisa ambas historias e intégralas manualmente; Jack no puede hacer fast-forward seguro."
        case .baseChanged(let expected, let actual): return "La rama base cambió desde que se creó este worktree (base guardada \(expected.prefix(10)), actual \(actual.prefix(10))). Revisa los cambios antes de integrar."
        case .reviewedHeadChanged(let expected, let actual): return "La rama del agente cambió después de la revisión (revisado \(expected.prefix(10)), actual \(actual.prefix(10))). Vuelve a revisar el diff antes de integrar."
        case .modeChangedDuringIntegration: return "Jack cambió a Light mientras Git integraba. Comprueba la rama base antes de repetir la acción."
        case .operation(let message): return message
        case .rollback(let message): return message
        }
    }
}

/// Creates isolated agent worktrees and records their integration base in the shared Git config.
/// Every Git invocation passes an argument vector directly to Process; no shell is involved.
public enum WorktreeService {
    public static func create(from sourcePath: String, branch: String, at destination: String, normalMode: @escaping WorktreeModeCheck) async throws -> GitWorktree {
        try await ensureNormal(normalMode)
        guard sourcePath.hasPrefix("/") else { throw WorktreeError.invalidPath(sourcePath) }
        guard destination.hasPrefix("/") else { throw WorktreeError.invalidPath(destination) }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL.path
        let requestedTarget = URL(fileURLWithPath: destination).standardizedFileURL
        let resolvedParent = requestedTarget.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = resolvedParent.appendingPathComponent(requestedTarget.lastPathComponent).standardizedFileURL.path
        let sourceRoot = try await repositoryRoot(source, normalMode: normalMode)
        guard !isWithin(target, sourceRoot) else { throw WorktreeError.unsafeDestination(target) }
        guard !pathEntryExists(target) else { throw WorktreeError.destinationExists(target) }
        let check = try await run(["check-ref-format", "--branch", branch], in: sourceRoot, timeout: .seconds(20), normalMode: normalMode)
        guard check.succeeded, check.output.trimmingCharacters(in: .whitespacesAndNewlines) == branch else { throw WorktreeError.invalidBranch(branch) }
        let exists = try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: sourceRoot, timeout: .seconds(20), normalMode: normalMode)
        guard exists.status == 1 else {
            if exists.succeeded { throw WorktreeError.branchExists(branch) }
            throw WorktreeError.operation(exists.message)
        }
        let head = try await run(["rev-parse", "--verify", "HEAD^{commit}"], in: sourceRoot, timeout: .seconds(20), normalMode: normalMode)
        guard head.succeeded else { throw WorktreeError.noCommit }
        let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBranchResult = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: sourceRoot, timeout: .seconds(20), normalMode: normalMode)
        let baseBranch = currentBranchResult.succeeded ? currentBranchResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : "(HEAD separado)"

        let keys = metadataKeys(encoded(branch))
        for key in keys {
            let existingMetadata = try await run(["config", "--local", "--get", key], in: sourceRoot, timeout: .seconds(20), normalMode: normalMode)
            guard existingMetadata.status == 1 else {
                throw WorktreeError.operation("Ya hay metadatos locales para esta rama. Elige otro nombre de rama.")
            }
        }

        try await ensureNormal(normalMode)
        let added = await Git.run(["worktree", "add", "-b", branch, target, commit], in: sourceRoot, timeout: .seconds(120))
        guard await normalMode() else {
            if added.succeeded {
                let cleanup = await rollback(source: sourceRoot, path: target, branch: branch)
                throw WorktreeError.rollback([WorktreeError.normalOnly.errorDescription ?? "Solo Normal.", cleanup].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            throw WorktreeError.normalOnly
        }
        guard added.succeeded else {
            // Git owns rollback for a failed `worktree add`. Do not touch paths or refs here:
            // another process may have claimed them after our validation.
            throw WorktreeError.operation(added.message)
        }

        let values = [target, sourceRoot, baseBranch, commit]
        for (key, value) in zip(keys, values) {
            do { try await ensureNormal(normalMode) }
            catch {
                let cleanup = await rollback(source: sourceRoot, path: target, branch: branch)
                let metadataCleanup = cleanup.isEmpty ? await removeMetadata(keys, in: sourceRoot) : ""
                throw WorktreeError.rollback([error.localizedDescription, metadataCleanup, cleanup].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            let result = await Git.run(["config", "--local", key, value], in: sourceRoot, timeout: .seconds(20))
            guard await normalMode() else {
                let cleanup = await rollback(source: sourceRoot, path: target, branch: branch)
                let metadataCleanup = cleanup.isEmpty ? await removeMetadata(keys, in: sourceRoot) : ""
                throw WorktreeError.rollback([WorktreeError.normalOnly.errorDescription ?? "Solo Normal.", metadataCleanup, cleanup].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            if !result.succeeded {
                let cleanup = await rollback(source: sourceRoot, path: target, branch: branch)
                let metadataCleanup = cleanup.isEmpty ? await removeMetadata(keys, in: sourceRoot) : ""
                let details = [result.message, metadataCleanup, cleanup].filter { !$0.isEmpty }.joined(separator: "\n")
                throw WorktreeError.rollback("No se pudieron guardar los metadatos del worktree. \(details)")
            }
        }
        return GitWorktree(path: target, branch: branch, head: commit)
    }

    public static func review(worktreePath: String, normalMode: @escaping WorktreeModeCheck) async throws -> WorktreeReview {
        try await ensureNormal(normalMode)
        guard worktreePath.hasPrefix("/") else { throw WorktreeError.invalidPath(worktreePath) }
        let path = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().standardizedFileURL.path
        let root = try await repositoryRoot(path, normalMode: normalMode)
        guard let metadata = try await readMetadata(worktreePath: root, normalMode: normalMode) else { throw WorktreeError.notManagedWorktree }
        let headResult = try await run(["rev-parse", "--verify", "HEAD^{commit}"], in: root, timeout: .seconds(20), normalMode: normalMode)
        guard headResult.succeeded else { throw WorktreeError.noCommit }
        let head = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if head != metadata.baseCommit {
            let ancestor = try await run(["merge-base", "--is-ancestor", metadata.baseCommit, head], in: root, timeout: .seconds(20), normalMode: normalMode)
            guard ancestor.succeeded else { throw WorktreeError.divergedHistory }
        }
        let diff = try await run(["diff", "--no-ext-diff", "--no-color", "--no-renames", "\(metadata.baseCommit)..\(head)", "--"], in: root, timeout: .seconds(60), normalMode: normalMode, outputLimit: 500_000)
        guard diff.succeeded else { throw WorktreeError.operation(diff.message) }
        return WorktreeReview(branch: metadata.branch, basePath: metadata.basePath, baseBranch: metadata.baseBranch,
                              baseCommit: metadata.baseCommit, head: head, diff: diff.output)
    }

    /// Integrates only committed work, and only when the recorded base is still clean and unchanged.
    public static func integrate(worktreePath: String, reviewedHead: String, normalMode: @escaping WorktreeModeCheck) async throws {
        try await ensureNormal(normalMode)
        guard worktreePath.hasPrefix("/") else { throw WorktreeError.invalidPath(worktreePath) }
        let worktreePath = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().standardizedFileURL.path
        let root = try await repositoryRoot(worktreePath, normalMode: normalMode)
        guard let metadata = try await readMetadata(worktreePath: root, normalMode: normalMode) else { throw WorktreeError.notManagedWorktree }
        let worktreeStatusResult = try await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root, timeout: .seconds(30), normalMode: normalMode)
        guard worktreeStatusResult.succeeded else { throw WorktreeError.gitStatusFailed(worktreeStatusResult.message) }
        let worktreeStatus = Git.parseStatus(worktreeStatusResult.output)
        guard worktreeStatus.files.isEmpty else { throw WorktreeError.dirtyWorktree(worktreeStatus.files.map(\.path)) }
        let worktreeHeadResult = try await run(["rev-parse", "--verify", "HEAD^{commit}"], in: root, timeout: .seconds(20), normalMode: normalMode)
        guard worktreeHeadResult.succeeded else { throw WorktreeError.noCommit }
        let worktreeHead = worktreeHeadResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard worktreeHead == reviewedHead else { throw WorktreeError.reviewedHeadChanged(expected: reviewedHead, actual: worktreeHead) }
        let reviewedCommit = try await run(["rev-parse", "--verify", "\(reviewedHead)^{commit}"], in: root, timeout: .seconds(20), normalMode: normalMode)
        guard reviewedCommit.succeeded, reviewedCommit.output.trimmingCharacters(in: .whitespacesAndNewlines) == reviewedHead else {
            throw WorktreeError.operation("El HEAD revisado ya no es un commit válido. Vuelve a revisar el diff.")
        }
        let baseRoot = metadata.basePath
        let baseBranchResult = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: baseRoot, timeout: .seconds(20), normalMode: normalMode)
        let currentBranch = baseBranchResult.succeeded ? baseBranchResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : "(HEAD separado)"
        guard currentBranch == metadata.baseBranch else {
            throw WorktreeError.operation("La carpeta base ya no está en la rama \(metadata.baseBranch). Está en \(currentBranch). Revisa el diff e integra manualmente con fast-forward.")
        }
        let statusResult = try await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: baseRoot, timeout: .seconds(30), normalMode: normalMode)
        guard statusResult.succeeded else { throw WorktreeError.gitStatusFailed(statusResult.message) }
        let status = Git.parseStatus(statusResult.output)
        guard status.isRepository else { throw WorktreeError.notRepository(baseRoot) }
        guard status.files.isEmpty else { throw WorktreeError.dirtyBase(status.files.map(\.path)) }
        let baseHead = try await run(["rev-parse", "--verify", "HEAD^{commit}"], in: baseRoot, timeout: .seconds(20), normalMode: normalMode)
        guard baseHead.succeeded else { throw WorktreeError.noCommit }
        let actual = baseHead.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == metadata.baseCommit else { throw WorktreeError.baseChanged(expected: metadata.baseCommit, actual: actual) }
        if reviewedHead != metadata.baseCommit {
            let ancestor = try await run(["merge-base", "--is-ancestor", metadata.baseCommit, reviewedHead], in: root, timeout: .seconds(20), normalMode: normalMode)
            guard ancestor.succeeded else { throw WorktreeError.divergedHistory }
        }
        try await ensureNormal(normalMode)
        let merged = await Git.run(["merge", "--ff-only", reviewedHead], in: baseRoot, timeout: .seconds(120))
        guard await normalMode() else { throw WorktreeError.modeChangedDuringIntegration }
        guard merged.succeeded else {
            throw WorktreeError.operation("No se pudo integrar con fast-forward. No se aplicaron cambios a la base. \(merged.message)")
        }
        let updatedBase: GitResult
        do {
            updatedBase = try await run(["rev-parse", "--verify", "HEAD^{commit}"], in: baseRoot, timeout: .seconds(20), normalMode: normalMode)
        } catch WorktreeError.normalOnly {
            throw WorktreeError.modeChangedDuringIntegration
        }
        guard updatedBase.succeeded else { throw WorktreeError.operation("Los commits se integraron, pero no se pudo leer el nuevo HEAD de la base.") }
        let metadataKey = metadataKeys(encoded(metadata.branch))[3]
        let savedBase: GitResult
        do {
            savedBase = try await run(["config", "--local", metadataKey, updatedBase.output.trimmingCharacters(in: .whitespacesAndNewlines)], in: baseRoot, timeout: .seconds(20), normalMode: normalMode)
        } catch WorktreeError.normalOnly {
            throw WorktreeError.modeChangedDuringIntegration
        }
        guard savedBase.succeeded else { throw WorktreeError.operation("Los commits se integraron, pero no se pudo actualizar el metadato de base: \(savedBase.message)") }
    }

    /// Removes the new worktree/branch after Jack could not create its agent. No force option is used.
    public static func rollbackCreated(_ worktree: GitWorktree, sourcePath: String) async throws {
        let rootResult = await Git.run(["rev-parse", "--show-toplevel"], in: URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL.path, timeout: .seconds(20))
        guard rootResult.succeeded else { throw WorktreeError.notRepository(sourcePath) }
        let source = URL(fileURLWithPath: rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardizedFileURL.path
        guard let branch = worktree.branch else { throw WorktreeError.rollback("No se puede verificar la rama creada.") }
        let metadata = metadataKeys(encoded(branch))
        var values: [String] = []
        for key in metadata {
            let result = await Git.run(["config", "--local", "--get", key], in: source, timeout: .seconds(15))
            guard result.succeeded else { throw WorktreeError.rollback("No se encontraron metadatos verificables para retirar este worktree.") }
            values.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard values.count == 4 else { throw WorktreeError.rollback("Los metadatos del worktree están incompletos.") }
        let path = URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().standardizedFileURL.path
        let recordedPath = URL(fileURLWithPath: values[0]).resolvingSymlinksInPath().standardizedFileURL.path
        guard path == recordedPath, source == URL(fileURLWithPath: values[1]).resolvingSymlinksInPath().standardizedFileURL.path else {
            throw WorktreeError.rollback("La ruta o el repositorio no coinciden con el worktree creado por Jack.")
        }
        let worktreeRoot = await Git.run(["rev-parse", "--show-toplevel"], in: recordedPath, timeout: .seconds(20))
        let worktreeBranch = await Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: recordedPath, timeout: .seconds(20))
        guard worktreeRoot.succeeded, worktreeBranch.succeeded,
              URL(fileURLWithPath: worktreeRoot.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardizedFileURL.path == recordedPath,
              worktreeBranch.output.trimmingCharacters(in: .whitespacesAndNewlines) == branch else {
            throw WorktreeError.rollback("La ruta ya no apunta a la rama worktree creada por Jack.")
        }
        let cleanupError = await rollback(source: source, path: recordedPath, branch: branch)
        guard cleanupError.isEmpty else { throw WorktreeError.rollback(cleanupError) }
        let metadataError = await removeMetadata(metadata, in: source)
        if !metadataError.isEmpty { throw WorktreeError.rollback(metadataError) }
    }

    private struct Metadata { let path: String; let basePath: String; let baseBranch: String; let baseCommit: String; let branch: String }

    private static func readMetadata(worktreePath: String, normalMode: @escaping WorktreeModeCheck) async throws -> Metadata? {
        let branchResult = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: worktreePath, timeout: .seconds(15), normalMode: normalMode)
        guard branchResult.succeeded else { return nil }
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = metadataKeys(encoded(branch))
        var values: [String] = []
        for key in keys {
            let result = try await run(["config", "--local", "--get", key], in: worktreePath, timeout: .seconds(15), normalMode: normalMode)
            guard result.succeeded else { return nil }
            values.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard values.count == 4, URL(fileURLWithPath: values[0]).resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().standardizedFileURL.path,
              let worktreeCommon = try await commonDirectory(in: worktreePath, normalMode: normalMode),
              let baseCommon = try await commonDirectory(in: values[1], normalMode: normalMode), worktreeCommon == baseCommon else { return nil }
        return Metadata(path: values[0], basePath: values[1], baseBranch: values[2], baseCommit: values[3], branch: branch)
    }

    private static func commonDirectory(in root: String, normalMode: @escaping WorktreeModeCheck) async throws -> String? {
        let result = try await run(["rev-parse", "--git-common-dir"], in: root, timeout: .seconds(15), normalMode: normalMode)
        guard result.succeeded else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: root)).standardizedFileURL.resolvingSymlinksInPath().path
        return path
    }

    private static func repositoryRoot(_ path: String, normalMode: @escaping WorktreeModeCheck) async throws -> String {
        let result = try await run(["rev-parse", "--show-toplevel"], in: path, timeout: .seconds(20), normalMode: normalMode)
        guard result.succeeded else { throw WorktreeError.notRepository(path) }
        return URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func metadataKeys(_ id: String) -> [String] {
        ["jack.worktree.\(id).path", "jack.worktree.\(id).basepath", "jack.worktree.\(id).basebranch", "jack.worktree.\(id).basecommit"]
    }

    private static func encoded(_ value: String) -> String { value.utf8.map { String(format: "%02x", $0) }.joined() }

    private static func removeMetadata(_ keys: [String], in directory: String) async -> String {
        var failures: [String] = []
        for key in keys {
            let result = await Git.run(["config", "--local", "--unset-all", key], in: directory, timeout: .seconds(15))
            if !result.succeeded && result.status != 5 { failures.append(result.message) }
        }
        return failures.joined(separator: "; ")
    }

    private static func rollback(source: String, path: String, branch: String) async -> String {
        var failures: [String] = []
        if FileManager.default.fileExists(atPath: path) {
            let removed = await Git.run(["worktree", "remove", path], in: source, timeout: .seconds(60))
            if !removed.succeeded { failures.append(removed.message) }
        }
        let exists = await Git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: source, timeout: .seconds(15))
        if exists.succeeded {
            let deleted = await Git.run(["branch", "-d", branch], in: source, timeout: .seconds(20))
            if !deleted.succeeded { failures.append(deleted.message) }
        }
        return failures.joined(separator: "; ")
    }

    private static func ensureNormal(_ normalMode: @escaping WorktreeModeCheck) async throws {
        guard await normalMode() else { throw WorktreeError.normalOnly }
    }

    private static func run(_ arguments: [String], in directory: String, timeout: Duration,
                            normalMode: @escaping WorktreeModeCheck, outputLimit: Int? = nil) async throws -> GitResult {
        try await ensureNormal(normalMode)
        let result = await Git.run(arguments, in: directory, timeout: timeout, outputLimit: outputLimit)
        try await ensureNormal(normalMode)
        return result
    }

    private static func isWithin(_ child: String, _ parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        return lstat(path, &info) == 0
        #else
        return FileManager.default.fileExists(atPath: path)
        #endif
    }
}
