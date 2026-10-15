import XCTest
@testable import JackCore

@MainActor final class ClaudeArtifactTests: XCTestCase {
    private let fixture = """
    {"artifacts":[{"uuid":"11111111-1111-1111-1111-111111111111","artifact_identifier":"dashboard","artifact_type":"text/html","title":"Dashboard","chat_conversation_uuid":"22222222-2222-2222-2222-222222222222","chat_conversation_name":"Mi proyecto","preview":"truncated","latest_published_artifact_uuid":null}],"next_cursor":"page2"}
    """

    func testGalleryDecodesWithoutUsingPreviewAsContent() throws {
        let page = try JSONDecoder().decode(ClaudeArtifactPage.self, from: Data(fixture.utf8))
        XCTAssertEqual(page.nextCursor, "page2")
        let artifact = try XCTUnwrap(page.artifacts.first)
        XCTAssertEqual(artifact.artifactIdentifier, "dashboard")
        XCTAssertEqual(artifact.sourceURL.host, "claude.ai")
        XCTAssertTrue(ArtifactLibrary.isClaudeArtifactURL(artifact.sourceURL))
        XCTAssertEqual(URLComponents(url: artifact.sourceURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "dashboard")
    }

    func testCopyImportPersistsAndRepeatImportPreservesUserEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var artifact = try XCTUnwrap(JSONDecoder().decode(ClaudeArtifactPage.self, from: Data(fixture.utf8)).artifacts.first)
        artifact.organizationID = "org"
        let library = ArtifactLibrary(directory: directory)
        let imported = try library.importClaudeArtifact(artifact, content: "<h1>Hello</h1>", projectPath: "/project", conversationID: nil)
        XCTAssertEqual(imported.kind, .html)
        _ = try library.update(imported.id, projectPath: "/project", expectedVersion: 1, data: Data("Edited".utf8))
        let repeated = try library.importClaudeArtifact(artifact, content: "New remote content", projectPath: "/project", conversationID: nil)
        XCTAssertEqual(repeated.id, imported.id)
        XCTAssertEqual(library.items.count, 1)
        let reopened = ArtifactLibrary(directory: directory)
        XCTAssertEqual(try reopened.content(imported.id, projectPath: "/project"), Data("Edited".utf8))
        let other = try library.importClaudeArtifact(artifact, content: nil, projectPath: "/other", conversationID: nil)
        XCTAssertEqual(other.kind, .link)
        XCTAssertEqual(try library.content(other.id, projectPath: "/other"), Data(artifact.sourceURL.absoluteString.utf8))
    }

    func testLightCannotImportConnectedArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ArtifactLibrary(directory: directory, enabled: { false })
        let artifact = try XCTUnwrap(JSONDecoder().decode(ClaudeArtifactPage.self, from: Data(fixture.utf8)).artifacts.first)
        XCTAssertThrowsError(try library.importClaudeArtifact(artifact, content: nil, projectPath: "/project", conversationID: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testExtractionChoosesActiveBranchAndDoesNotCopyPartialUpdates() throws {
        let chat = """
        {"current_leaf_message_uuid":"active", "chat_messages":[
          {"uuid":"root","content":[{"type":"tool_use","name":"artifacts","input":{"id":"dashboard","command":"create","content":"first"}}]},
          {"uuid":"active","parent_message_uuid":"root","content":[{"type":"tool_use","name":"artifacts","input":{"id":"dashboard","command":"rewrite","content":"latest"}}]},
          {"uuid":"other","parent_message_uuid":"root","content":[{"type":"tool_use","name":"artifacts","input":{"id":"dashboard","command":"rewrite","content":"wrong branch"}}]}
        ]}
        """
        XCTAssertEqual(try ClaudeArtifactContent.extract(from: Data(chat.utf8), identifier: "dashboard"), "latest")
        XCTAssertNil(try ClaudeArtifactContent.extract(from: Data(chat.utf8), identifier: "missing"))
        let partial = """
        {"chat_messages":[
          {"content":[{"type":"tool_use","name":"artifacts","input":{"id":"a","content":"first"}}]},
          {"content":[{"type":"tool_use","name":"artifacts","input":{"id":"a","command":"update","old_str":"old","new_str":"new"}}]}
        ]}
        """
        XCTAssertNil(try ClaudeArtifactContent.extract(from: Data(partial.utf8), identifier: "a"))
        XCTAssertThrowsError(try ClaudeArtifactContent.extract(from: Data("{}".utf8), identifier: "a"))
    }
}
