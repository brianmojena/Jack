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
}
