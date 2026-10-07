import XCTest
@testable import JackCore

final class LightModeTests: XCTestCase {
    func testTranscriptExcludesThinkingAndToolsBeforeLimitingHistory() {
        let messages = [ChatMessage(role: "user", text: "hola"), ChatMessage(role: "assistant", text: "respuesta"),
                        ChatMessage(role: "reasoning", text: "pensando"), ChatMessage(role: "tool", text: "comando"),
                        ChatMessage(role: "error", text: "falló")]
        let chat = ChatConversation(projectPath: "/tmp", messages: messages)
        XCTAssertEqual(LightTranscript.messages(in: chat).map(\.role), ["user", "assistant", "error"])
        XCTAssertEqual(LightTranscript.messages(in: chat, limit: 2).map(\.text), ["respuesta", "falló"])
        XCTAssertTrue(LightTranscript.messages(in: chat, limit: 0).isEmpty)
    }
    func testPlainTextPreservesUnicodeAndAttachmentPaths() {
        let message = ChatMessage(role: "user", text: "café 🙂", attachments: ["/tmp/foto.png"])
        XCTAssertEqual(LightTranscript.text(of: message), "Tú\ncafé 🙂\nAdjunto: /tmp/foto.png\n\n")
    }
    @MainActor func testLightMonitorsCanRemainManualAndResumeNormalWatching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jack-light-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let progress = ProgressMonitor(root: root, watching: false)
        let servers = ServerMonitor(projects: { [] }, watching: false)
        defer { progress.stop(); servers.stop() }
        XCTAssertFalse(progress.isWatching)
        XCTAssertFalse(servers.isWatching)
        progress.scan()
        XCTAssertFalse(progress.isWatching, "manual refresh does not start periodic work")
        progress.setWatching(true); servers.setWatching(true)
        XCTAssertTrue(progress.isWatching)
        XCTAssertTrue(servers.isWatching)
        progress.setWatching(false); servers.setWatching(false)
        XCTAssertFalse(progress.isWatching)
        XCTAssertFalse(servers.isWatching)
    }
}
