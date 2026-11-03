import Foundation
import XCTest
@testable import JackCore

final class WorktreeServiceTests: XCTestCase {
    func testCreatesIsolatedBranchFromConfirmedHeadWithSpaceInPath() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baseHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        try "local edit\n".write(to: URL(fileURLWithPath: fixture.source).appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "untracked local\n".write(to: URL(fileURLWithPath: fixture.source).appendingPathComponent("local-only.txt"), atomically: true, encoding: .utf8)

        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/isolated", at: fixture.destination, normalMode: { true })
        XCTAssertEqual(worktree.path, fixture.destination)
        let worktreeBranch = await git(["branch", "--show-current"], in: fixture.destination)
        let worktreeHead = await git(["rev-parse", "HEAD"], in: fixture.destination)
        let copiedFile = try String(contentsOfFile: fixture.destination + "/tracked.txt", encoding: .utf8)
        let originalFile = try String(contentsOfFile: fixture.source + "/tracked.txt", encoding: .utf8)
        XCTAssertEqual(worktreeBranch, "agent/isolated")
        XCTAssertEqual(worktreeHead, baseHead)
        XCTAssertEqual(copiedFile, "confirmed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination + "/local-only.txt"))
        XCTAssertEqual(originalFile, "local edit\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source + "/local-only.txt"))
    }

    func testReviewAndExplicitIntegrationOnlyFastForwardsCommittedChanges() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/review", at: fixture.destination, normalMode: { true })
        try "new committed work\n".write(to: URL(fileURLWithPath: fixture.destination).appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: fixture.destination)
        _ = await Git.commit("Feature", in: fixture.destination)

        let review = try await WorktreeService.review(worktreePath: worktree.path, normalMode: { true })
        XCTAssertEqual(review.branch, "agent/review")
        XCTAssertEqual(review.baseBranch, "main")
        XCTAssertTrue(review.diff.contains("+new committed work"))
        let encodedBranch = "agent/review".utf8.map { String(format: "%02x", $0) }.joined()
        let metadata = await Git.run(["config", "--local", "--get", "jack.worktree.\(encodedBranch).basecommit"], in: fixture.source)
        XCTAssertTrue(metadata.succeeded, metadata.message)
        try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: review.head, normalMode: { true })
        let integratedFile = try String(contentsOfFile: fixture.source + "/feature.txt", encoding: .utf8)
        XCTAssertEqual(integratedFile, "new committed work\n")
        let integratedHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        XCTAssertEqual(integratedHead, review.head)
    }

    func testEmptyDiffCommitStillCountsAsReviewedCommitAndCanFastForward() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/empty-commit", at: fixture.destination, normalMode: { true })
        _ = await Git.run(["-c", "user.name=Worktree Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Empty change"], in: fixture.destination)

        let review = try await WorktreeService.review(worktreePath: worktree.path, normalMode: { true })
        XCTAssertTrue(review.diff.isEmpty)
        XCTAssertTrue(review.hasReviewedCommits)
        try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: review.head, normalMode: { true })
        let integratedHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        XCTAssertEqual(integratedHead, review.head)
    }

    func testStatusFailureCannotBeParsedAsCleanDuringIntegration() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/status-error", at: fixture.destination, normalMode: { true })
        let index = await git(["rev-parse", "--git-path", "index"], in: fixture.destination)
        let indexPath = URL(fileURLWithPath: index, relativeTo: URL(fileURLWithPath: fixture.destination)).standardizedFileURL
        try Data("corrupt index".utf8).write(to: indexPath)
        do {
            try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: worktree.head ?? "", normalMode: { true })
            XCTFail("A failed git status must not be treated as a clean worktree")
        } catch let error as WorktreeError {
            guard case .gitStatusFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let baseHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        XCTAssertEqual(baseHead, worktree.head)

        let baseIndex = await git(["rev-parse", "--git-path", "index"], in: fixture.source)
        let baseIndexPath = URL(fileURLWithPath: baseIndex, relativeTo: URL(fileURLWithPath: fixture.source)).standardizedFileURL
        try Data("corrupt index".utf8).write(to: baseIndexPath)
        do {
            try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: worktree.head ?? "", normalMode: { true })
            XCTFail("A failed base git status must not be treated as a clean base")
        } catch let error as WorktreeError {
            guard case .gitStatusFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testReviewRejectsDivergentHistoryInsteadOfDiffingFromMergeBase() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "base history\n".write(to: URL(fileURLWithPath: fixture.source).appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: fixture.source)
        _ = await Git.commit("Base history", in: fixture.source)
        let baseHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        let baseParent = await git(["rev-parse", "HEAD^"], in: fixture.source)
        let parentTree = await git(["rev-parse", "\(baseParent)^{tree}"], in: fixture.source)
        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/diverged", at: fixture.destination, normalMode: { true })
        let sibling = await git(["commit-tree", parentTree, "-p", baseParent, "-m", "Sibling history"], in: fixture.destination)
        XCTAssertFalse(sibling.isEmpty)
        let moved = await Git.run(["update-ref", "refs/heads/agent/diverged", sibling], in: fixture.destination)
        XCTAssertTrue(moved.succeeded, moved.message)
        XCTAssertNotEqual(sibling, baseHead)

        do {
            _ = try await WorktreeService.review(worktreePath: worktree.path, normalMode: { true })
            XCTFail("A diverged branch must not be represented as a review diff from the merge base")
        } catch let error as WorktreeError {
            guard case .divergedHistory = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testIntegrationRefusesDirtyBaseAndLeavesItsChangesAlone() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/blocked", at: fixture.destination, normalMode: { true })
        let originalHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        try "base local change\n".write(to: URL(fileURLWithPath: fixture.source).appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        do {
            try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: originalHead, normalMode: { true })
            XCTFail("Expected dirty base to block integration")
        } catch let error as WorktreeError {
            guard case .dirtyBase = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let preservedLocalFile = try String(contentsOfFile: fixture.source + "/local.txt", encoding: .utf8)
        XCTAssertEqual(preservedLocalFile, "base local change\n")
        let baseHead = await git(["rev-parse", "HEAD"], in: fixture.source)
        let worktreeHead = await git(["rev-parse", "HEAD"], in: fixture.destination)
        XCTAssertEqual(baseHead, originalHead)
        XCTAssertEqual(worktreeHead, originalHead)
    }

    func testIntegrationRejectsWorktreeChangesAndCommitsAfterReview() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worktree = try await WorktreeService.create(from: fixture.source, branch: "agent/pinned", at: fixture.destination, normalMode: { true })
        try "reviewed\n".write(to: URL(fileURLWithPath: fixture.destination).appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: fixture.destination)
        _ = await Git.commit("Reviewed", in: fixture.destination)
        let review = try await WorktreeService.review(worktreePath: worktree.path, normalMode: { true })

        try "uncommitted\n".write(to: URL(fileURLWithPath: fixture.destination).appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        do {
            try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: review.head, normalMode: { true })
            XCTFail("Expected worktree changes to block integration")
        } catch let error as WorktreeError {
            guard case .dirtyWorktree = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try FileManager.default.removeItem(atPath: fixture.destination + "/local.txt")

        try "later committed work\n".write(to: URL(fileURLWithPath: fixture.destination).appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: fixture.destination)
        _ = await Git.commit("After review", in: fixture.destination)
        do {
            try await WorktreeService.integrate(worktreePath: worktree.path, reviewedHead: review.head, normalMode: { true })
            XCTFail("Expected newer HEAD to require a new review")
        } catch let error as WorktreeError {
            guard case .reviewedHeadChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source + "/feature.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source + "/later.txt"))
    }

    func testValidationAndRollbackUseOnlyTheRequestedResources() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "bad branch", at: fixture.destination, normalMode: { true })
            XCTFail("Expected invalid branch")
        } catch let error as WorktreeError {
            guard case .invalidBranch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await WorktreeService.create(from: "relative/project", branch: "agent/relative", at: fixture.destination, normalMode: { true })
            XCTFail("Expected relative source path to be rejected")
        } catch let error as WorktreeError {
            guard case .invalidPath = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "agent/relative-path", at: "relative/worktree", normalMode: { true })
            XCTFail("Expected relative destination to be rejected")
        } catch let error as WorktreeError {
            guard case .invalidPath = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "agent/unsafe", at: fixture.source + "/nested", normalMode: { true })
            XCTFail("Expected in-repository destination to be rejected")
        } catch let error as WorktreeError {
            guard case .unsafeDestination = error else { return XCTFail("Unexpected error: \(error)") }
        }
        _ = try await WorktreeService.create(from: fixture.source, branch: "agent/exists", at: fixture.destination, normalMode: { true })
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "agent/exists", at: fixture.root.appendingPathComponent("other-worktree").path, normalMode: { true })
            XCTFail("Expected duplicate branch error")
        } catch let error as WorktreeError {
            guard case .branchExists = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try await WorktreeService.rollbackCreated(GitWorktree(path: fixture.destination, branch: "agent/exists", head: nil), sourcePath: fixture.source)
        _ = try await WorktreeService.create(from: fixture.source, branch: "agent/existing", at: fixture.destination, normalMode: { true })
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "agent/other", at: fixture.destination, normalMode: { true })
            XCTFail("Expected existing destination error")
        } catch let error as WorktreeError {
            guard case .destinationExists = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let info = try await WorktreeService.review(worktreePath: fixture.destination, normalMode: { true })
        XCTAssertEqual(info.branch, "agent/existing")
        let created = GitWorktree(path: fixture.destination, branch: "agent/existing", head: info.head)
        try await WorktreeService.rollbackCreated(created, sourcePath: fixture.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination))
        let branches = await Git.branches(in: fixture.source)
        let originalBranch = await git(["branch", "--show-current"], in: fixture.source)
        XCTAssertFalse(branches.contains("agent/existing"))
        XCTAssertEqual(originalBranch, "main")
    }

    func testSourceSymlinkUsesCanonicalRepositoryRoot() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("source alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let worktree = try await WorktreeService.create(from: alias, branch: "agent/symlink", at: fixture.destination, normalMode: { true })
        let review = try await WorktreeService.review(worktreePath: worktree.path, normalMode: { true })
        let canonicalSource = URL(fileURLWithPath: fixture.source).resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(review.basePath, canonicalSource)
        try await WorktreeService.rollbackCreated(worktree, sourcePath: alias)
    }

    private struct Fixture { let root: URL; let source: String; let destination: String }

    @MainActor private final class ModeGate {
        private let turnOffAtCheck: Int
        private(set) var checkCount = 0
        private var enabled = true
        init(turnOffAtCheck: Int) { self.turnOffAtCheck = turnOffAtCheck }
        func check() -> Bool {
            checkCount += 1
            if checkCount >= turnOffAtCheck { enabled = false }
            return enabled
        }
    }

    func testLightModeCannotCreateReviewOrIntegrateWorktrees() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "agent/light", at: fixture.destination, normalMode: { false })
            XCTFail("Light mode must not create a worktree")
        } catch let error as WorktreeError {
            guard case .normalOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await WorktreeService.review(worktreePath: fixture.source, normalMode: { false })
            XCTFail("Light mode must not query worktree metadata")
        } catch let error as WorktreeError {
            guard case .normalOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await WorktreeService.integrate(worktreePath: fixture.source, reviewedHead: "", normalMode: { false })
            XCTFail("Light mode must not integrate")
        } catch let error as WorktreeError {
            guard case .normalOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination))
        let branches = await Git.branches(in: fixture.source)
        XCTAssertFalse(branches.contains("agent/light"))
    }

    @MainActor func testModeChangeAfterGitAwaitPreventsTheNextCommand() async throws {
        let fixture = try await repository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ModeGate(turnOffAtCheck: 3)
        do {
            _ = try await WorktreeService.create(from: fixture.source, branch: "agent/mode-change", at: fixture.destination, normalMode: { gate.check() })
            XCTFail("Expected mode switch to stop worktree creation")
        } catch let error as WorktreeError {
            guard case .normalOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(gate.checkCount, 3, "No Git command should start after the mode check fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination))
    }

    private func repository() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-worktree fixture \(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source repo with spaces", isDirectory: true)
        let destination = root.appendingPathComponent("worktree path with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        guard (await Git.initialize(in: source.path)).succeeded else { throw WorktreeError.operation("git init failed") }
        _ = await Git.run(["config", "user.email", "test@example.com"], in: source.path)
        _ = await Git.run(["config", "user.name", "Worktree Test"], in: source.path)
        try "confirmed\n".write(to: source.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: source.path)
        _ = await Git.commit("Base", in: source.path)
        _ = await Git.run(["branch", "-M", "main"], in: source.path)
        return Fixture(root: root, source: source.path, destination: destination.path)
    }

    private func git(_ arguments: [String], in directory: String) async -> String {
        let result = await Git.run(arguments, in: directory)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
