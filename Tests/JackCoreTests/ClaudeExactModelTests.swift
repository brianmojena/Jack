import XCTest
@testable import JackCore

@MainActor
final class ClaudeExactModelTests: XCTestCase {
    private func makeStore(light: Bool) -> ChatStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("exact-models-\(UUID().uuidString)")
        return ChatStore(archive: ChatArchive(directory: folder), preferences: nil, lightMode: light)
    }

    func testNormalModeOffersExactClaudeVersions() {
        let ids = makeStore(light: false).modelChoices(for: .claude).map(\.id)
        for id in ["fable", "opus", "sonnet", "haiku", "claude-opus-5-5", "claude-opus-4-8", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    func testLightModeKeepsTheFourFamilies() {
        let ids = makeStore(light: true).modelChoices(for: .claude).map(\.id)
        XCTAssertFalse(ids.contains("claude-opus-5-5"))
        XCTAssertTrue(ids.contains("opus"))
    }

    func testExactVersionsHaveTitlesAndEffortsLikeTheirFamily() {
        let choices = makeStore(light: false).modelChoices(for: .claude)
        XCTAssertEqual(choices.first { $0.id == "claude-opus-4-8" }?.title, "Opus 4.8")
        // Efforts follow the version: Haiku takes none, Opus 4.5 has no xhigh.
        XCTAssertEqual(choices.first { $0.id == "claude-haiku-4-5-20251001" }?.efforts, [])
        XCTAssertEqual(choices.first { $0.id == "claude-opus-4-5" }?.efforts, ["low", "medium", "high"])
        XCTAssertEqual(makeStore(light: false).supportedEfforts(provider: .claude, model: "claude-opus-4-5"), ["low", "medium", "high"])
    }
}
