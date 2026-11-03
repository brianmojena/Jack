import XCTest
@testable import JackCore

final class ChatTurnClosureTests: XCTestCase {
    func testOnlyCapturedExitStatusesProduceObservedCheckOutcomes() {
        let now = Date(timeIntervalSince1970: 100)
        let closure = ChatTurnClosureEvaluator.evaluate(
            conversationID: UUID(), completedAt: now, ending: .completed,
            events: [
                ChatTurnCapturedEvent(id: "passed", kind: .check, title: "Pruebas", command: "swift test", exitStatus: 0, observedAt: now),
                ChatTurnCapturedEvent(id: "failed", kind: .check, title: "Build", command: "swift build", exitStatus: 1, observedAt: now),
                ChatTurnCapturedEvent(id: "unknown", kind: .check, title: "Lint", command: "lint", observedAt: now),
                ChatTurnCapturedEvent(id: "tool", kind: .tool, title: "Ejecución de comando", command: "swift test", exitStatus: 0, observedAt: now)
            ], gitBefore: nil, gitAfter: nil,
            agentSummary: "Las pruebas pasaron; ejecuté swift test.")

        XCTAssertEqual(closure.checks.map(\.status), [.passed, .failed, .unknown])
        XCTAssertEqual(closure.checks.map(\.exitStatus), [0, 1, nil])
        XCTAssertEqual(closure.agentStatements.map(\.text), ["Las pruebas pasaron; ejecuté swift test."])
        XCTAssertEqual(closure.agentStatements.first?.source, .agent)
        XCTAssertFalse(closure.checks.contains { $0.eventID == "tool" }, "A successful generic command is not automatically a verified test")
    }

    func testGitDiffIsAComparisonObservationWithoutCausalAttribution() {
        let before = ChatTurnGitSnapshot(observedAt: Date(timeIntervalSince1970: 1), files: [
            ChatTurnGitFile(path: "edited.swift", status: " M"),
            ChatTurnGitFile(path: "removed.swift", status: " D"),
            ChatTurnGitFile(path: "same.swift", status: " M")
        ])
        let after = ChatTurnGitSnapshot(observedAt: Date(timeIntervalSince1970: 2), files: [
            ChatTurnGitFile(path: "edited.swift", status: "M "),
            ChatTurnGitFile(path: "added.swift", status: "??"),
            ChatTurnGitFile(path: "same.swift", status: " M")
        ])

        let closure = ChatTurnClosureEvaluator.evaluate(conversationID: UUID(), completedAt: Date(), ending: .completed,
                                                        events: [], gitBefore: before, gitAfter: after)
        XCTAssertEqual(closure.observedFileChanges.map(\.path), ["added.swift", "edited.swift", "removed.swift"])
        XCTAssertEqual(closure.observedFileChanges.first { $0.path == "added.swift" }?.beforeStatus, nil)
        XCTAssertEqual(closure.observedFileChanges.first { $0.path == "added.swift" }?.afterStatus, "??")
        XCTAssertTrue(closure.observedFileChanges.allSatisfy { $0.attribution == .notEstablished })
        XCTAssertEqual(closure.gitComparison.status, .compared)
        XCTAssertEqual(closure.gitComparison.beforeObservedAt, before.observedAt)
    }

    func testRealGitSnapshotsDetectContentChangesWithSameStatusAndCommitsDuringTurn() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("jack-turn-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func run(_ args: [String]) async throws -> String {
            let result = await Git.run(args, in: repo.path, timeout: .seconds(10))
            XCTAssertTrue(result.succeeded, "git \(args.joined(separator: " ")): \(result.message)")
            return result.output
        }
        _ = try await run(["init"])
        _ = try await run(["config", "user.name", "Jack Tests"])
        _ = try await run(["config", "user.email", "jack-tests@example.invalid"])
        let tracked = repo.appendingPathComponent("already-modified.txt")
        let nestedDirectory = repo.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedFile = nestedDirectory.appendingPathComponent("nested-file.txt")
        try Data("nested base\n".utf8).write(to: nestedFile)
        try Data("committed base\n".utf8).write(to: tracked)
        _ = try await run(["add", "already-modified.txt", "nested/nested-file.txt"])
        _ = try await run(["commit", "-m", "base"])

        try Data("dirty version one\n".utf8).write(to: tracked)
        let untracked = repo.appendingPathComponent("new-file.txt")
        try Data("untracked one\n".utf8).write(to: untracked)
        // Conversations may point below the repository root; porcelain paths must still map
        // against --show-toplevel so the snapshot reads the same files Git reported.
        let beforeValue = await ChatTurnGitSnapshot.capture(in: nestedDirectory.path)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.files.first(where: { $0.path == "already-modified.txt" })?.status, "M")
        XCTAssertNotNil(before.files.first(where: { $0.path == "nested/nested-file.txt" }))

        // Its status stays modified/untracked; the content hashes must still notice both edits.
        try Data("dirty version two\n".utf8).write(to: tracked)
        try Data("untracked two\n".utf8).write(to: untracked)
        let afterValue = await ChatTurnGitSnapshot.capture(in: nestedDirectory.path)
        let after = try XCTUnwrap(afterValue)
        let workingChanges = ChatTurnClosureEvaluator.evaluate(conversationID: UUID(), completedAt: Date(), ending: .completed,
                                                                 events: [], gitBefore: before, gitAfter: after)
        XCTAssertEqual(workingChanges.observedFileChanges.map(\.path), ["already-modified.txt", "new-file.txt"])

        // Stage and commit while the turn is still in progress. The worktree is clean after;
        // comparing the captured HEAD trees must still report both paths.
        _ = try await run(["add", "already-modified.txt", "new-file.txt"])
        _ = try await run(["commit", "-m", "during turn"])
        let committedValue = await ChatTurnGitSnapshot.capture(in: nestedDirectory.path)
        let committed = try XCTUnwrap(committedValue)
        XCTAssertNotEqual(after.head, committed.head)
        let committedChanges = ChatTurnClosureEvaluator.evaluate(conversationID: UUID(), completedAt: Date(), ending: .completed,
                                                                  events: [], gitBefore: after, gitAfter: committed)
        XCTAssertEqual(committedChanges.observedFileChanges.map(\.path), ["already-modified.txt", "new-file.txt"])
        XCTAssertEqual(committedChanges.observedFileChanges.map(\.afterStatus), ["HEAD", "HEAD"])
        XCTAssertTrue(committedChanges.observedFileChanges.allSatisfy { $0.attribution == .notEstablished })
    }

    func testWorkingFingerprintStreamsOnlyBoundedPrefix() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("jack-turn-bounded-hash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func run(_ args: [String]) async throws {
            let result = await Git.run(args, in: repo.path, timeout: .seconds(10))
            XCTAssertTrue(result.succeeded, "git \(args.joined(separator: " ")): \(result.message)")
        }
        try await run(["init"])
        try await run(["config", "user.name", "Jack Tests"])
        try await run(["config", "user.email", "jack-tests@example.invalid"])
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try await run(["add", "tracked.txt"])
        try await run(["commit", "-m", "base"])

        let large = repo.appendingPathComponent("large-download.bin")
        let block = Data(repeating: 0xA5, count: 256 * 1024)
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        defer { try? handle.close() }
        for _ in 0..<12 { try handle.write(contentsOf: block) }

        let snapshotValue = await ChatTurnGitSnapshot.capture(in: repo.path)
        let snapshot = try XCTUnwrap(snapshotValue)
        let fingerprint = try XCTUnwrap(snapshot.files.first(where: { $0.path == "large-download.bin" })?.fingerprint)
        XCTAssertTrue(fingerprint.contains("size=3145728"))
        XCTAssertTrue(fingerprint.contains("prefix-bytes=1048576"))
        XCTAssertTrue(fingerprint.contains("prefix-sha256="))
    }

    @MainActor
    func testModeChangeAbortsSnapshotBeforeStartingNextGitCommand() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("jack-turn-light-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let initResult = await Git.run(["init"], in: repo.path, timeout: .seconds(10))
        XCTAssertTrue(initResult.succeeded)

        let gate = SnapshotModeGate(allowedChecks: 2)
        let snapshot = await ChatTurnGitSnapshot.capture(in: repo.path, normalMode: { gate.check() })
        XCTAssertNil(snapshot, "The mode guard turns false after the top-level lookup, before status starts")
        XCTAssertEqual(gate.checkCount, 3, "Capture should stop as soon as the permission closure reports Light")
    }

    func testTreeLookupFailureMakesSnapshotUnavailable() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("jack-turn-tree-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func run(_ args: [String]) async throws {
            let result = await Git.run(args, in: repo.path, timeout: .seconds(10))
            XCTAssertTrue(result.succeeded, "git \(args.joined(separator: " ")): \(result.message)")
        }
        try await run(["init"])
        try await run(["config", "user.name", "Jack Tests"])
        try await run(["config", "user.email", "jack-tests@example.invalid"])
        try Data("tracked\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try await run(["add", "tracked.txt"])
        try await run(["commit", "-m", "base"])

        let shim = repo.appendingPathComponent("git-shim")
        try Data("#!/bin/sh\nif [ \"$1\" = \"ls-tree\" ]; then echo tree unavailable >&2; exit 9; fi\nexec /usr/bin/git \"$@\"\n".utf8)
            .write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let originalExecutable = Git.executable
        Git.executable = shim.path
        defer { Git.executable = originalExecutable }

        let snapshot = await ChatTurnGitSnapshot.capture(in: repo.path)
        XCTAssertNil(snapshot, "A failed tree read must be unavailable, never an empty/clean snapshot")
    }

    func testSameStatusStillChangesWhenFingerprintChanges() {
        let before = ChatTurnGitSnapshot(observedAt: Date(timeIntervalSince1970: 1), files: [
            ChatTurnGitFile(path: "already-dirty.swift", status: " M", fingerprint: "bytes-1")
        ])
        let after = ChatTurnGitSnapshot(observedAt: Date(timeIntervalSince1970: 2), files: [
            ChatTurnGitFile(path: "already-dirty.swift", status: " M", fingerprint: "bytes-2")
        ])
        XCTAssertEqual(ChatTurnClosureEvaluator.evaluate(conversationID: UUID(), completedAt: Date(), ending: .completed,
                                                          events: [], gitBefore: before, gitAfter: after)
            .observedFileChanges.map(\.path), ["already-dirty.swift"])
    }

    func testAgentPendingItemsRemainSeparatelyLabeledStatements() {
        let closure = ChatTurnClosureEvaluator.evaluate(
            conversationID: UUID(), completedAt: Date(), ending: .completed,
            events: [], gitBefore: nil, gitAfter: nil,
            agentSummary: "Implementación terminada.",
            agentPendingItems: ["Falta ejecutar las pruebas.", "   "])

        XCTAssertEqual(closure.agentStatements.map(\.kind), [.summary, .pending])
        XCTAssertEqual(closure.declaredPendingItems.map(\.text), ["Falta ejecutar las pruebas."])
        XCTAssertTrue(closure.declaredPendingItems.allSatisfy { $0.source == .agent })
        XCTAssertTrue(closure.checks.isEmpty, "An agent claim that tests remain is not a captured test result")
        XCTAssertEqual(closure.gitComparison.status, .unavailable, "No snapshots must not look like a clean diff")
    }

    func testOnlyExplicitAgentPendingSectionIsExtractedAsAnAttributedClaim() {
        let summary = """
        Listo; las pruebas parecen correctas.

        Pendientes:
        - Revisar el diff con el equipo.
        2. Ejecutar pruebas en CI.
        """
        let closure = ChatTurnClosureEvaluator.evaluate(conversationID: UUID(), completedAt: Date(), ending: .completed,
                                                        events: [], gitBefore: nil, gitAfter: nil, agentSummary: summary)

        XCTAssertEqual(closure.declaredPendingItems.map(\.text), ["Revisar el diff con el equipo.", "Ejecutar pruebas en CI."])
        XCTAssertTrue(closure.declaredPendingItems.allSatisfy { $0.source == .agent })
        XCTAssertTrue(closure.checks.isEmpty, "Free text in the summary cannot count as a passed check")
    }

    func testClosureRoundTripsThroughCodableWithoutMixingEvidenceAndClaims() throws {
        let timestamp = Date(timeIntervalSince1970: 1234)
        let closure = ChatTurnClosureEvaluator.evaluate(
            conversationID: UUID(), completedAt: timestamp, ending: .failed,
            events: [ChatTurnCapturedEvent(id: "check", kind: .check, title: "Build", command: "build", exitStatus: 2, observedAt: timestamp)],
            gitBefore: nil, gitAfter: nil,
            agentSummary: "El build pasó.", agentPendingItems: ["Revisar el diff."])
        let decoded = try JSONDecoder().decode(ChatTurnClosure.self, from: JSONEncoder().encode(closure))

        XCTAssertEqual(decoded, closure)
        XCTAssertEqual(decoded.checks.first?.status, .failed)
        XCTAssertEqual(decoded.agentStatements.map(\.kind), [.summary, .pending])
    }
}

@MainActor
private final class SnapshotModeGate {
    private let allowedChecks: Int
    private(set) var checkCount = 0

    init(allowedChecks: Int) { self.allowedChecks = allowedChecks }

    func check() -> Bool {
        checkCount += 1
        return checkCount <= allowedChecks
    }
}
