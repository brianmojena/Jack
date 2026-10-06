import XCTest
@testable import JackCore

final class OpenCodeModelTests: XCTestCase {
    func testOnlyConnectedProvidersAppearWithTheirModels() throws {
        let data = Data("""
        {"connected":["openai","custom"],"all":[
          {"id":"openai","name":"OpenAI","models":{"gpt-test":{"id":"gpt-test","name":"GPT Test"}}},
          {"id":"custom","name":"Custom","models":{"local-model":{"name":"Local Model"}}},
          {"id":"unconnected","models":{"other":{"id":"other"}}}
        ]}
        """.utf8)
        let providers = try OpenCodeModelService.connectedModels(from: data)
        XCTAssertEqual(providers.map(\.id), ["custom", "openai"])
        XCTAssertEqual(providers[0].models[0].id, "custom/local-model")
        XCTAssertEqual(providers[1].models[0].id, "openai/gpt-test")
        XCTAssertEqual(providers[1].models[0].title, "GPT Test")
    }

    func testNoConnectedProvidersProducesEmptyCatalog() throws {
        let data = Data("{\"connected\":[],\"all\":[]}".utf8)
        XCTAssertTrue(try OpenCodeModelService.connectedModels(from: data).isEmpty)
    }

    func testInvalidCatalogReportsError() {
        XCTAssertThrowsError(try OpenCodeModelService.connectedModels(from: Data("{}".utf8)))
    }
    func testCatalogExposesOnlyEnabledVariantsInEffortOrder() throws {
        let data = Data("""
        {"connected":["test"],"all":[{"id":"test","models":{"model":{
          "variants":{"high":{},"low":{},"thinking":{},"off":{"disabled":true}}
        }}}]}
        """.utf8)
        XCTAssertEqual(try OpenCodeModelService.connectedModels(from: data)[0].models[0].efforts, ["low", "high", "thinking"])
    }
    func testModesExcludeHiddenAndSubagents() throws {
        let data = Data("""
        [{"name":"plan","mode":"primary"},{"name":"build","mode":"primary"},
         {"name":"review","mode":"all"},{"name":"explore","mode":"subagent"},
         {"name":"title","mode":"primary","hidden":true}]
        """.utf8)
        XCTAssertEqual(try OpenCodeModelService.primaryModes(from: data).map(\.id), ["build", "plan", "review"])
    }
}
