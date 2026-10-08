import XCTest
@testable import JackCore

final class GitTests: XCTestCase {
    func testParsesBranchRenamesConflictsAndUntrackedFiles() {
        let output = [
            "# branch.oid 1234567890abcdef", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaa bbb Sources/a file.swift",
            "1 .M N... 100644 100644 100644 aaa bbb b.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new.swift", "old.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc both.swift",
            "? notes/todo.md",
        ].joined(separator: "\0") + "\0"
        let status = Git.parseStatus(output)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.head, "1234567")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.staged.map(\.path), ["Sources/a file.swift", "new.swift"])
        XCTAssertEqual(status.files.first { $0.path == "new.swift" }?.originalPath, "old.swift")
        XCTAssertEqual(status.unstaged.map(\.path), ["b.swift", "notes/todo.md"])
        XCTAssertEqual(status.conflicted.map(\.path), ["both.swift"])
    }

    func testANewRepositoryHasNoHeadAndADetachedOneNoBranch() {
        XCTAssertNil(Git.parseStatus("# branch.oid (initial)\0# branch.head main\0").head)
        XCTAssertNil(Git.parseStatus("# branch.oid abcdef1234\0# branch.head (detached)\0").branch)
    }

    func testStagesCommitsAndReadsTheLogOfARealRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jack-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let outside = await Git.status(in: directory)
        if outside.isRepository { throw XCTSkip("The temporary folder is inside a repository.") }
        let initialized = await Git.initialize(in: directory).succeeded
        XCTAssertTrue(initialized)
        _ = await Git.run(["config", "user.email", "test@example.com"], in: directory)
        _ = await Git.run(["config", "user.name", "Test"], in: directory)
        try "hola\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)

        var status = await Git.status(in: directory)
        XCTAssertTrue(status.isRepository)
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])
        let value2 = await Git.diff(status.files[0], staged: false, in: directory).contains("+hola")
        XCTAssertTrue(value2)

        let value3 = await Git.stage(["a.txt"], in: directory).succeeded
        XCTAssertTrue(value3)
        status = await Git.status(in: directory)
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])
        let value4 = await Git.unstage(["a.txt"], in: directory).succeeded
        XCTAssertTrue(value4, "unstaging works before the first commit")
        let value5 = await Git.status(in: directory).staged.count
        XCTAssertEqual(value5, 0)

        let value6 = await Git.stageAll(in: directory).succeeded
        XCTAssertTrue(value6)
        let value7 = await Git.commit("Primer commit", in: directory).succeeded
        XCTAssertTrue(value7)
        status = await Git.status(in: directory)
        XCTAssertTrue(status.files.isEmpty)
        XCTAssertNotNil(status.head)
        let log = await Git.log(in: directory)
        XCTAssertEqual(log.map(\.subject), ["Primer commit"])
        XCTAssertEqual(log.first?.author, "Test")

        try "adiós\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        let changed = await Git.status(in: directory).files[0]
        let value8 = await Git.discard(changed, in: directory).succeeded
        XCTAssertTrue(value8)
        XCTAssertEqual(try String(contentsOfFile: directory + "/a.txt", encoding: .utf8), "hola\n")

        let value9 = await Git.createBranch("prueba", in: directory).succeeded
        XCTAssertTrue(value9)
        let value10 = await Git.status(in: directory).branch
        XCTAssertEqual(value10, "prueba")
        let branches = await Git.branches(in: directory)
        XCTAssertEqual(Set(branches), ["prueba", status.branch ?? ""])
    }

    @MainActor func testAutomaticCommitIncludesAllChangesAndUsesOnlyGemmaCloud() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "hola\n".write(toFile: directory + "/nuevo.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        var called = false
        service.streamRequest = { model, messages, _ in
            called = true
            XCTAssertEqual(model.name, "gemma4:31b-cloud")
            XCTAssertTrue(model.isCloud)
            XCTAssertEqual(messages.map(\.role), ["system", "user"])
            XCTAssertTrue(messages[1].content.contains("nuevo.txt"))
            XCTAssertTrue(messages[1].content.contains("+hola"))
            return self.automaticStream("Añade saludo inicial")
        }
        let result = try await service.commit(in: directory) { true }
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertTrue(called)
        let status = await Git.status(in: directory)
        XCTAssertTrue(status.files.isEmpty)
        let log = await Git.log(in: directory)
        XCTAssertEqual(log.first?.subject, "Añade saludo inicial")
    }

    @MainActor func testAutomaticCommitRespectsStagedSubsetAndLeavesOtherChangesUntouched() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "base\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: directory)
        _ = await Git.commit("Base", in: directory)
        try "preparado\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        _ = await Git.stage(["a.txt"], in: directory)
        try "posterior\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        try "secreto sin preparar\n".write(toFile: directory + "/b.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        service.streamRequest = { _, messages, _ in
            XCTAssertTrue(messages[1].content.contains("+preparado"))
            XCTAssertFalse(messages[1].content.contains("posterior"))
            XCTAssertFalse(messages[1].content.contains("secreto sin preparar"))
            return self.automaticStream("Actualiza el saludo")
        }
        let result = try await service.commit(in: directory) { true }
        XCTAssertTrue(result.succeeded, result.message)
        let committed = await Git.run(["show", "HEAD:a.txt"], in: directory)
        XCTAssertEqual(committed.output, "preparado\n")
        let status = await Git.status(in: directory)
        XCTAssertEqual(Set(status.unstaged.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertTrue(status.staged.isEmpty)
    }

    @MainActor func testAutomaticCommitAbortsWhenWorkingFilesChangeDuringCloudRequest() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "antes\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        service.streamRequest = { _, _, _ in
            try "después\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
            return self.automaticStream("Añade archivo")
        }
        do {
            _ = try await service.commit(in: directory) { true }
            XCTFail("A message describing the old snapshot must never commit changed files")
        } catch { XCTAssertTrue(error.localizedDescription.contains("archivos cambiaron")) }
        let status = await Git.status(in: directory)
        XCTAssertNil(status.head)
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: directory + "/a.txt", encoding: .utf8), "después\n")
    }

    @MainActor func testAutomaticCommitPreservesConcurrentStagingAndRejectsLocalModel() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "hola\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        service.inspectModel = {
            _ = await Git.stage(["a.txt"], in: directory)
            return self.automaticCloudModel()
        }
        do {
            _ = try await service.commit(in: directory) { true }
            XCTFail("Concurrent staging must be preserved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("preparados cambiaron")) }
        var status = await Git.status(in: directory)
        XCTAssertNil(status.head)
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])
        service.inspectModel = {
            StellarModel(id: "ollama/gemma4:31b", name: "gemma4:31b", server: StellarServer.builtIn[0], tools: false, isCloud: false)
        }
        service.streamRequest = { _, _, _ in XCTFail("Local Gemma must not be queried"); return self.automaticStream("Mensaje") }
        do {
            _ = try await service.commit(in: directory) { true }
            XCTFail("Only the requested cloud model is allowed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verificado")) }
        status = await Git.status(in: directory)
        XCTAssertNil(status.head)
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])
    }

    @MainActor func testAutomaticCommitRejectsSwitchingToAnotherBranchAtTheSameCommit() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "base\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        _ = await Git.stageAll(in: directory)
        _ = await Git.commit("Base", in: directory)
        try "nuevo\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        service.inspectModel = {
            _ = await Git.createBranch("otra-rama", in: directory)
            return self.automaticCloudModel()
        }
        do { _ = try await service.commit(in: directory) { true }; XCTFail("The chosen branch must remain the same") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rama")) }
        let status = await Git.status(in: directory)
        XCTAssertEqual(status.branch, "otra-rama")
        XCTAssertTrue(status.staged.isEmpty)
        let log = await Git.log(in: directory)
        XCTAssertEqual(log.map(\.subject), ["Base"])
    }

    @MainActor func testAutomaticCommitChecksNormalPolicyBeforeCloudAndBeforeGitCommit() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "hola\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        service.inspectModel = { XCTFail("Light must not inspect cloud models"); return self.automaticCloudModel() }
        do { _ = try await service.commit(in: directory) { false }; XCTFail("Light must reject the action") }
        catch { XCTAssertTrue(error is CancellationError) }
        var allowed = true
        service.inspectModel = { self.automaticCloudModel() }
        service.streamRequest = { _, _, _ in allowed = false; return self.automaticStream("Añade saludo") }
        do { _ = try await service.commit(in: directory) { allowed }; XCTFail("Mode changes must stop the commit") }
        catch { XCTAssertTrue(error is CancellationError) }
        let status = await Git.status(in: directory)
        XCTAssertNil(status.head)
        XCTAssertTrue(status.staged.isEmpty)
    }

    @MainActor func testAutomaticCommitCloudFailuresAndInvalidResponsesLeaveIndexUntouched() async throws {
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "hola\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        for response in ["", "```shell\ngit commit\n```", String(repeating: "é", count: 3000)] {
            let service = automaticService()
            service.streamRequest = { _, _, _ in self.automaticStream(response) }
            do { _ = try await service.commit(in: directory) { true }; XCTFail("Invalid output must not create a commit") }
            catch { XCTAssertTrue(error is GitCommitAutomation.Failure) }
            let status = await Git.status(in: directory)
            XCTAssertNil(status.head)
            XCTAssertTrue(status.staged.isEmpty)
        }
        let service = automaticService()
        service.inspectModel = { throw NSError(domain: "remote secret", code: 403) }
        do { _ = try await service.commit(in: directory) { true }; XCTFail("Cloud failure must be surfaced") }
        catch { XCTAssertFalse(error.localizedDescription.contains("remote secret")) }
        let status = await Git.status(in: directory)
        XCTAssertNil(status.head)
        XCTAssertTrue(status.staged.isEmpty)
    }

    @MainActor func testAutomaticCommitTimesOutAndBoundsEscapedUTF8Evidence() async throws {
        let evidence = try GitCommitAutomation.evidence(summary: String(repeating: "é\n", count: 3000), patch: String(repeating: "\"\\🙂\n", count: 5000), maxBytes: 3000)
        XCTAssertLessThanOrEqual(evidence.utf8.count, 3000)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(evidence.utf8)))
        let directory = try await automaticRepository()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "hola\n".write(toFile: directory + "/a.txt", atomically: true, encoding: .utf8)
        let service = automaticService()
        service.timeout = .milliseconds(10)
        var continuation: AsyncThrowingStream<StellarChunk, Error>.Continuation?
        service.streamRequest = { _, _, _ in AsyncThrowingStream { continuation = $0 } }
        do { _ = try await service.commit(in: directory) { true }; XCTFail("The cloud request needs a deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("tardó demasiado")) }
        continuation?.finish()
        let status = await Git.status(in: directory)
        XCTAssertNil(status.head)
        XCTAssertTrue(status.staged.isEmpty)
    }

    private func automaticRepository() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jack-git-auto-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let result = await Git.initialize(in: directory)
        guard result.succeeded else { throw NSError(domain: result.message, code: 1) }
        _ = await Git.run(["config", "user.email", "test@example.com"], in: directory)
        _ = await Git.run(["config", "user.name", "Test"], in: directory)
        return directory
    }

    @MainActor private func automaticCloudModel() -> StellarModel {
        .init(id: "ollama/gemma4:31b-cloud", name: "gemma4:31b-cloud", server: StellarServer.builtIn[0], tools: false, contextLength: 4096, isCloud: true)
    }

    @MainActor private func automaticService() -> GitCommitAutomation {
        let service = GitCommitAutomation()
        service.inspectModel = { self.automaticCloudModel() }
        service.streamRequest = { _, _, _ in self.automaticStream("Describe los cambios") }
        return service
    }

    private func automaticStream(_ text: String) -> AsyncThrowingStream<StellarChunk, Error> {
        AsyncThrowingStream { continuation in continuation.yield(.text(text)); continuation.finish() }
    }

}
