import XCTest
@testable import JackCore

final class StellarCodeTests: XCTestCase {
    func testOnlyLocalServersAreAllowed() {
        for local in ["http://127.0.0.1:11434", "http://localhost:8080", "http://mac-studio.local:1234", "http://192.168.1.20:8000", "http://10.0.0.5", "http://172.20.1.1"] {
            XCTAssertTrue(StellarServer.isLocal(URL(string: local)!), local)
        }
        for remote in ["https://api.openai.com", "http://8.8.8.8", "http://172.32.0.1", "ftp://127.0.0.1", "https://ollama.com"] {
            XCTAssertFalse(StellarServer.isLocal(URL(string: remote)!), remote)
        }
    }

    func testModelIDsNameTheirServer() {
        XCTAssertEqual(StellarModels.resolve("ollama/gemma4:e2b")?.name, "gemma4:e2b")
        XCTAssertEqual(StellarModels.resolve("mlx/mlx-community/Qwen3-4B-4bit")?.name, "mlx-community/Qwen3-4B-4bit")
        XCTAssertNil(StellarModels.resolve("gpt-6-luna"))
        XCTAssertNil(StellarModels.resolve("ollama/"))
    }

    func testToolsReadEditAndRefuseAmbiguousEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-tools-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "a\nb\na\n".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        func call(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
            await StellarTools.execute(StellarToolCall(id: "1", name: name, arguments: boundedJSON(input)), root: root) { _ in }
        }
        let read = await call("read_file", ["path": "f.txt"])
        XCTAssertEqual(read.0, "1\ta\n2\tb\n3\ta\n4\t")
        let ambiguous = await call("edit_file", ["path": "f.txt", "old_string": "a", "new_string": "z"])
        XCTAssertTrue(ambiguous.1)
        let edit = await call("edit_file", ["path": "f.txt", "old_string": "b", "new_string": "c"])
        XCTAssertFalse(edit.1)
        XCTAssertEqual(try String(contentsOfFile: root + "/f.txt", encoding: .utf8), "a\nc\na\n")
        let listed = await call("list_files", [:])
        XCTAssertEqual(listed.0, "f.txt", "paths are relative even through /var → /private/var")
        let command = await call("run_command", ["command": "echo hola; exit 3"])
        XCTAssertEqual(command.0, "hola\n\n[exit 3]")
        XCTAssertTrue(command.1)
    }

    func testPathsOutsideTheProjectAreDetected() {
        XCTAssertEqual(StellarTools.resolve("src/../a.swift", root: "/p"), "/p/a.swift")
        XCTAssertTrue(StellarTools.inside("/p/a.swift", roots: ["/p"]))
        XCTAssertFalse(StellarTools.inside("/pp/a.swift", roots: ["/p"]))
        XCTAssertFalse(StellarTools.inside(StellarTools.resolve("../x", root: "/p"), roots: ["/p"]))
    }

    func testMessagesMatchEachAPI() {
        let call = StellarToolCall(id: "c1", name: "read_file", arguments: "{\"path\":\"a\"}")
        let assistant = StellarMessage(role: "assistant", content: "", toolCalls: [call])
        let ollama = StellarClient.ollamaMessage(assistant)["tool_calls"] as? [[String: Any]]
        XCTAssertEqual((ollama?.first?["function"] as? [String: Any])?["arguments"] as? [String: String], ["path": "a"])
        let openAI = StellarClient.openAIMessage(assistant)["tool_calls"] as? [[String: Any]]
        XCTAssertEqual((openAI?.first?["function"] as? [String: Any])?["arguments"] as? String, "{\"path\":\"a\"}")
        let result = StellarMessage(role: "tool", content: "x", toolCallID: "c1", toolName: "read_file")
        XCTAssertEqual(StellarClient.openAIMessage(result)["tool_call_id"] as? String, "c1")
        XCTAssertEqual(StellarClient.ollamaMessage(result)["tool_name"] as? String, "read_file")
    }

    func testStellarIsBuiltInBetaAndAsksPermission() {
        XCTAssertTrue(ChatProvider.stellar.isBeta)
        XCTAssertTrue(ChatProvider.stellar.isBuiltIn)
        XCTAssertEqual(ChatRunMode.choices(for: .stellar).map(\.id), ["manual", "acceptEdits", "auto"])
    }
}
