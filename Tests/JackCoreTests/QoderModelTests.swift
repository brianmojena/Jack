import XCTest
@testable import JackCore

final class QoderModelTests: XCTestCase {
    func testHeaderAndBlankLinesAreSkippedAndHeadlineTiersGetSubtitles() {
        let models = ChatModelCatalog.parseQoderModels("""
        MODEL
        Auto
        Ultimate
        Fast
        Efficient
        Qwen3.8-Max

        """)
        XCTAssertEqual(models.map(\.id), ["Auto", "Ultimate", "Fast", "Efficient", "Qwen3.8-Max"])
        XCTAssertEqual(models.map(\.title), models.map(\.id))
        XCTAssertEqual(models.map(\.subtitle), ["Elige el modelo por ti", "El más capaz", "Rápido", "Económico", nil])
        XCTAssertEqual(models.first?.efforts, ChatModelChoice.qoderEfforts)
    }

    func testCacheRoundTripRestoresNamesAndSubtitles() {
        let models = ChatModelCatalog.parseQoderModels("MODEL\nAuto\nGLM-5.3\n")
        let cached = ChatModelCatalog.decodeQoderModels(ChatModelCatalog.encodeQoderModels(models))
        XCTAssertEqual(cached, models)
        XCTAssertEqual(cached.first?.subtitle, "Elige el modelo por ti")
    }

    func testRunModesMirrorClaudeModes() {
        XCTAssertEqual(ChatRunMode.choices(for: .qoder).map(\.id), ["manual", "plan", "acceptEdits", "auto", "dontAsk"])
    }
}
