import XCTest
@testable import JackCore

@MainActor final class ArtifactTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("jack-artifact-tests-" + UUID().uuidString) }

    func testSnapshotsPersistAndRejectStaleUpdatesAcrossAgents() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = ArtifactLibrary(directory: directory)
        let artifact = try library.create(title: "Dashboard", kind: .html, data: Data("first".utf8), projectPath: "/project", author: "Claude")
        let second = try library.update(artifact.id, projectPath: "/project", expectedVersion: 1, data: Data("second".utf8), author: "Codex")
        XCTAssertEqual(second.version, 2)
        XCTAssertThrowsError(try library.update(artifact.id, projectPath: "/project", expectedVersion: 1, data: Data("stale".utf8)))
        let reopened = ArtifactLibrary(directory: directory)
        XCTAssertEqual(try reopened.content(artifact.id, projectPath: "/project", version: 1), Data("first".utf8))
        XCTAssertEqual(try reopened.content(artifact.id, projectPath: "/project"), Data("second".utf8))
        XCTAssertEqual(try reopened.find(artifact.id, projectPath: "/project").revisions.map(\.author), ["Claude", "Codex"])
        XCTAssertThrowsError(try reopened.find(artifact.id, projectPath: "/other"))
    }

    func testFileImportIsIndependentAndRetainsOriginalFormat() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("picture.jpg")
        try Data([1, 2, 3]).write(to: file)
        let library = ArtifactLibrary(directory: directory.appendingPathComponent("library"))
        let imported = try library.importFile(file, projectPath: "/project")
        try Data([4, 5]).write(to: file)
        XCTAssertEqual(imported.kind, .image); XCTAssertEqual(imported.fileExtension, "jpg")
        XCTAssertEqual(try library.content(imported.id, projectPath: "/project"), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: file), Data([4, 5]))
    }

    func testClaudeLinksAreValidatedDeduplicatedAndExtractedFromToolResults() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = ArtifactLibrary(directory: directory)
        let url = URL(string: "https://claude.ai/code/artifact/abc123")!
        let first = try library.importLink(url, title: "Claude", projectPath: "/project")
        let second = try library.importLink(url, title: "Again", projectPath: "/project")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(ArtifactLibrary.claudeLinks(in: [.init(role: "assistant", text: "[View](\(url))"), .init(role: "tool", text: "Artifact", detail: url.absoluteString)]), [url])
        for invalid in ["https://claude.ai.evil.test/code/artifact/x", "file:///tmp/a", "https://claude.ai/settings", "https://user:pass@claude.ai/code/artifact/x"] {
            XCTAssertThrowsError(try library.importLink(URL(string: invalid)!, title: "Bad", projectPath: "/project"))
        }
    }

    func testLightDoesNotLoadPersistOrExposeArtifactTools() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var enabled = false
        let library = ArtifactLibrary(directory: directory, enabled: { enabled })
        XCTAssertThrowsError(try library.create(title: "No", kind: .html, data: Data(), projectPath: "/project"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        enabled = true
        let artifact = try library.create(title: "Yes", kind: .code, data: Data("ok".utf8), projectPath: "/project")
        enabled = false
        XCTAssertThrowsError(try library.content(artifact.id, projectPath: "/project"))
        XCTAssertThrowsError(try library.update(artifact.id, projectPath: "/project", expectedVersion: 1, data: Data()))
        let store = ChatStore(archive: ChatArchive(directory: directory.appendingPathComponent("chats")), preferences: nil)
        defer { store.shutdown(); store.bridge.stop() }
        let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: .codex))
        _ = try await store.bridge.delegation(for: id)
        store.setLightMode(true)
        let rawResponse = await store.bridge.rpc(["id": 1, "method": "tools/list"], caller: id)
        let response = try XCTUnwrap(rawResponse)
        let names = ((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("artifact_") }))
        let (_, failed) = await store.bridge.call("artifact_create", arguments: ["title": "No", "kind": "html", "content": "x"], caller: id)
        XCTAssertTrue(failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chats/Artifacts").path))
        XCTAssertFalse(ChatRunConfiguration.agentInstructions(delegating: false, normalMode: false)?.contains("artifact_create") ?? false)
    }

    func testMCPProjectScopeBoundedReadsAndAuthorizedFileImports() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ChatStore(archive: ChatArchive(directory: directory.appendingPathComponent("chats")), preferences: nil)
        defer { store.shutdown(); store.bridge.stop() }
        let id = try XCTUnwrap(store.create(projectPath: directory.path, provider: .codex))
        _ = try await store.bridge.delegation(for: id, delegates: false)
        let (created, failure) = await store.bridge.call("artifact_create", arguments: ["title": "Test", "kind": "html", "content": "abcdef"], caller: id)
        XCTAssertFalse(failure, created)
        let artifact = try XCTUnwrap(store.artifacts.items.first)
        let (read, readFailed) = await store.bridge.call("artifact_read", arguments: ["artifact_id": artifact.id.uuidString, "offset": 2, "limit": 2], caller: id)
        XCTAssertFalse(readFailed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        XCTAssertEqual(json["content"] as? String, "cd")
        XCTAssertEqual(json["next_offset"] as? Int, 4)
        let outsider = try store.artifacts.create(title: "Private", kind: .code, data: Data(), projectPath: "/other")
        let (_, denied) = await store.bridge.call("artifact_read", arguments: ["artifact_id": outsider.id.uuidString], caller: id)
        XCTAssertTrue(denied)
        let (_, outside) = await store.bridge.call("artifact_create", arguments: ["path": "/etc/hosts"], caller: id)
        XCTAssertTrue(outside)
        let escape = directory.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(atPath: escape.path, withDestinationPath: "/etc/hosts")
        let (_, escaped) = await store.bridge.call("artifact_create", arguments: ["path": escape.path], caller: id)
        XCTAssertTrue(escaped)
    }

    func testStellarArtifactsDisappearInLight() {
        let driver = StellarChatDriver()
        driver.artifactHandler = { _, _, _ in ("ok", false) }
        XCTAssertEqual(driver.artifactDefinitions.count, 4)
        driver.setEnergySaving(true)
        XCTAssertTrue(driver.artifactDefinitions.isEmpty)
    }

    func testSessionDiscoveryListsCandidatesWithoutReadingFiles() {
        let messages: [ChatMessage] = [
            .init(role: "tool", text: "Write", detail: "{\"file_path\":\"dashboard.html\",\"content\":\"hello\"}\nSaved"),
            .init(role: "tool", text: "Read", detail: "{\"path\":\"/tmp/export.svg\"}"),
            .init(role: "user", text: "Attached", attachments: ["dashboard.html", "/tmp/unknown.bin"]),
        ]
        XCTAssertEqual(ArtifactLibrary.sessionFiles(in: messages, projectPath: "/missing-project").map(\.path),
                       ["/missing-project/dashboard.html", "/tmp/export.svg"])
    }
}
