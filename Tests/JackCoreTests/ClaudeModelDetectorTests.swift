import XCTest
@testable import JackCore

final class ClaudeModelDetectorTests: XCTestCase {
    func testDetectsModelsFromSessionFiles() throws {
        // Create temporary session files with model IDs
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Match Claude's project-folder name and include the metadata needed to list the session.
        let projectPath = tempDir.appendingPathComponent("test-project").path
        let projectFolder = tempDir.appendingPathComponent(ClaudeSessions.folderName(for: projectPath), isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

        // Create a session file with Opus 5.5
        let sessionData = """
        {"cwd":"\(projectPath)","type":"user","message":{"content":"Prueba"}}
        {"type":"assistant","message":{"model":"claude-opus-5-5"}}
        {"type":"assistant","message":{"model":"claude-sonnet-5-5"}}
        {"type":"assistant","message":{"model":"claude-haiku-5-5"}}
        """.data(using: .utf8)!

        let sessionFile = projectFolder.appendingPathComponent("test-session.jsonl")
        try sessionData.write(to: sessionFile)

        // Detect models
        let (detected, unknownFamilies) = ClaudeModelDetector.detectModels(from: tempDir)

        // Verify detected models
        XCTAssertFalse(detected.isEmpty)
        XCTAssertTrue(detected.contains { $0.id == "opus" })
        XCTAssertTrue(detected.contains { $0.id == "sonnet" })
        XCTAssertTrue(detected.contains { $0.id == "haiku" })
        XCTAssertTrue(unknownFamilies.isEmpty)

        // Verify titles
        let opusModel = detected.first { $0.id == "opus" }
        let haikuModel = detected.first { $0.id == "haiku" }
        XCTAssertEqual(opusModel?.title, "Opus 5.5")
        XCTAssertEqual(opusModel?.subtitle, "Muy capaz")
        XCTAssertEqual(haikuModel?.title, "Haiku 5.5")
        XCTAssertEqual(haikuModel?.subtitle, "Rápido y económico")
    }

    func testDetectsHighestVersionPerFamily() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectPath = tempDir.appendingPathComponent("test-project").path
        let projectFolder = tempDir.appendingPathComponent(ClaudeSessions.folderName(for: projectPath), isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

        // Create session files with different versions - newer one should win
        let sessionData = """
        {"cwd":"\(projectPath)","type":"user","message":{"content":"Prueba"}}
        {"type":"assistant","message":{"model":"claude-opus-4-5"}}
        {"type":"assistant","message":{"model":"claude-opus-5-5"}}
        """.data(using: .utf8)!

        let sessionFile = projectFolder.appendingPathComponent("test-session.jsonl")
        try sessionData.write(to: sessionFile)

        let (detected, _) = ClaudeModelDetector.detectModels(from: tempDir)

        let opusModel = detected.first { $0.id == "opus" }
        XCTAssertEqual(opusModel?.title, "Opus 5.5", "Should detect the highest version (5.5 > 4.5)")
    }

    func testFallsBackToHardcodedCatalog() throws {
        // Create empty temp directory (no session files)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (detected, _) = ClaudeModelDetector.detectModels(from: tempDir)

        // Should return empty when no sessions exist
        XCTAssertTrue(detected.isEmpty)
    }

    func testClaudeEffortsSupportsHaiku5Plus() {
        // Haiku 4.x should not support effort
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "haiku"), [])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-haiku-4-5-20251001"), [])

        // Haiku 5+ should support effort
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "claude-haiku-5-5"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ChatModelChoice.claudeEfforts(for: "haiku-5-5"), ["low", "medium", "high", "xhigh", "max"])
    }

    func testCataloglIncludesVersions() {
        let catalog = ChatModelChoice.claudeCatalog

        // Verify all entries have versions
        XCTAssertTrue(catalog.allSatisfy { $0.title.contains(" ") }, "All titles should include version")

        // Verify subtitles
        XCTAssertTrue(catalog.allSatisfy { $0.subtitle != nil }, "All entries should have subtitles")
    }
}
