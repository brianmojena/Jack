import Foundation
import Network
import XCTest
@testable import JackCore

final class AntigravityMCPTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("jack-antigravity-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testRegistrationCreatesMissingConfigWithoutPersistingSecrets() throws {
        let config = folder.appendingPathComponent(".gemini/config/mcp_config.json")
        let helper = try makeHelper()
        try AntigravityIntegration.register(helper: helper, to: config)

        let root = try json(config)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers[AntigravityIntegration.serverName] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, helper.path)
        XCTAssertEqual(entry["args"] as? [String], [AntigravityIntegration.helperCommand])
        XCTAssertEqual(entry["disabled"] as? Bool, false)
        XCTAssertNil(entry["env"])

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(text.contains("JACK_MCP_URL"))
        XCTAssertFalse(text.contains("JACK_MCP_TOKEN"))
        XCTAssertFalse(text.contains("Bearer"))

        let attributes = try FileManager.default.attributesOfItem(atPath: config.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
    }

    func testRegistrationAcceptsAnEmptyFileAndPreservesOtherContent() throws {
        let config = folder.appendingPathComponent("nested/mcp_config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: config)
        let helper = try makeHelper()
        try AntigravityIntegration.register(helper: helper, to: config)
        XCTAssertNotNil(try json(config)["mcpServers"])

        let original: [String: Any] = [
            "theme": "dark",
            "mcpServers": ["other": ["command": "/bin/echo", "args": ["hello"]]],
            "extra": ["keep": true],
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: config)
        try AntigravityIntegration.register(helper: helper, to: config)

        let root = try json(config)
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual((root["extra"] as? [String: Any])?["keep"] as? Bool, true)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["command"] as? String, "/bin/echo")
        XCTAssertNotNil(servers[AntigravityIntegration.serverName])
    }

    func testRegistrationReplacesOnlyItsOwnEntry() throws {
        let config = folder.appendingPathComponent("mcp_config.json")
        let helper = try makeHelper()
        let original: [String: Any] = [
            "mcpServers": [AntigravityIntegration.serverName: [
                "command": helper.path,
                "args": [AntigravityIntegration.helperCommand],
                "disabled": true,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        try AntigravityIntegration.register(helper: helper, to: config)

        let servers = try XCTUnwrap(try json(config)["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers[AntigravityIntegration.serverName] as? [String: Any])
        XCTAssertEqual(entry["disabled"] as? Bool, false)
    }

    func testRegistrationRefusesAForeignServerWithTheSameName() throws {
        let config = folder.appendingPathComponent("mcp_config.json")
        let original: [String: Any] = [
            "mcpServers": [AntigravityIntegration.serverName: ["command": "/usr/bin/other", "args": []]],
        ]
        let before = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try before.write(to: config)

        XCTAssertThrowsError(try AntigravityIntegration.register(helper: try makeHelper(), to: config)) { error in
            guard case AntigravityIntegrationError.nameConflict(let name) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(name, AntigravityIntegration.serverName)
        }
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testRegistrationRefusesInvalidMcpServers() throws {
        let config = folder.appendingPathComponent("mcp_config.json")
        try JSONSerialization.data(withJSONObject: ["mcpServers": []]).write(to: config)
        XCTAssertThrowsError(try AntigravityIntegration.register(helper: try makeHelper(), to: config)) { error in
            guard case AntigravityIntegrationError.configuration = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testEnvironmentRequiresNormalModeAndALoopbackHTTPEndpoint() {
        let good = ChatDelegation(url: URL(string: "http://127.0.0.1:4567/mcp")!, token: "token", normalMode: true)
        XCTAssertNoThrow(try AntigravityIntegration.validateEndpoint(good.url))
        XCTAssertThrowsError(try AntigravityIntegration.environment(
            delegation: ChatDelegation(url: good.url, token: good.token, normalMode: false)
        )) { error in
            XCTAssertEqual(error as? AntigravityIntegrationError, .normalModeRequired)
        }
        XCTAssertThrowsError(try AntigravityIntegration.environment(
            delegation: ChatDelegation(url: good.url, token: "", normalMode: true)
        )) { error in
            XCTAssertEqual(error as? AntigravityIntegrationError, .invalidEndpoint)
        }
        for value in ["https://127.0.0.1:4567/mcp", "http://example.com:4567/mcp", "http://127.0.0.1/mcp"] {
            let url = URL(string: value)!
            XCTAssertThrowsError(try AntigravityIntegration.validateEndpoint(url), value)
        }
    }

    func testAutoModeDoesNotBypassPermissions() {
        var conversation = ChatConversation(projectPath: "/tmp", provider: .antigravity)
        conversation.mode = "auto"
        let arguments = ChatRunConfiguration.antigravityArguments(conversation)
        XCTAssertTrue(arguments.contains("--mode"))
        XCTAssertTrue(arguments.contains("auto"))
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
    }

    func testProxyOutsideJackInitializesWithNoTools() async throws {
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].joined(separator: "\n") + "\n"
        let output = try await proxyOutput(Data(input.utf8), environment: [:])
        let messages = try jsonLines(output)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["id"] as? Int, 1)
        let initialize = try XCTUnwrap(messages[0]["result"] as? [String: Any])
        XCTAssertEqual((initialize["capabilities"] as? [String: Any])?.count, 0)
        XCTAssertTrue(((messages[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.isEmpty == true)
    }

    @MainActor
    func testProxyForwardsNormalToolsToAgentBridge() async throws {
        let store = ChatStore(archive: ChatArchive(directory: folder),
                              preferences: UserDefaults(suiteName: "antigravity-mcp-" + UUID().uuidString),
                              driverFactory: { _ in StellarChatDriver() })
        defer { store.bridge.stop(); store.shutdown() }
        let delegation: ChatDelegation
        do {
            delegation = try await store.bridge.delegation(for: UUID(), delegates: true, notebooks: true)
        } catch let error as Network.NWError {
            if case .posix(.EPERM) = error { throw XCTSkip("El sandbox impide abrir el listener loopback del MCP") }
            throw error
        }
        XCTAssertTrue(delegation.normalMode)

        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].joined(separator: "\n") + "\n"
        let environment = [
            "JACK_MCP_URL": delegation.url.absoluteString,
            "JACK_MCP_TOKEN": delegation.token,
        ]
        let output = try await proxyOutput(Data(input.utf8), environment: environment)
        let messages = try jsonLines(output)
        XCTAssertEqual(messages.count, 2)
        let tools = try XCTUnwrap((messages[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "create_agent" })
    }

    // MARK: - Helpers

    func testHTTPFramingPreservesSessionAndHandlesChunkedResponses() throws {
        for response in [
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nMcp-Session-Id: session-1\r\n\r\n{}",
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nMcp-Session-Id: session-1\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        ] {
            var descriptors: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&descriptors), 0)
            let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
            let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
            try writer.write(contentsOf: Data(response.utf8)); try writer.close()
            var sessionID: String?
            let data = try AntigravityIntegration.readResponse(from: descriptors[0], sessionID: &sessionID)
            XCTAssertEqual(data, Data("{}".utf8))
            XCTAssertEqual(sessionID, "session-1")
            try reader.close()
        }
    }

    private func makeHelper() throws -> URL {
        let helper = folder.appendingPathComponent("jack-progress")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func jsonLines(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func proxyOutput(_ input: Data, environment: [String: String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var inputFDs: [Int32] = [0, 0]
                var outputFDs: [Int32] = [0, 0]
                guard pipe(&inputFDs) == 0, pipe(&outputFDs) == 0 else {
                    return continuation.resume(throwing: AntigravityIntegrationError.proxy("no se pudo crear la tubería de prueba"))
                }
                let writer = FileHandle(fileDescriptor: inputFDs[1], closeOnDealloc: true)
                let reader = FileHandle(fileDescriptor: outputFDs[0], closeOnDealloc: true)
                do {
                    try writer.write(contentsOf: input)
                    try writer.close()
                } catch {
                    close(inputFDs[0]); close(outputFDs[1])
                    return continuation.resume(throwing: error)
                }
                let status = AntigravityIntegration.runMCPProxy(input: inputFDs[0], output: outputFDs[1], environment: environment)
                close(inputFDs[0])
                close(outputFDs[1])
                let data = reader.readDataToEndOfFile()
                try? reader.close()
                guard status == 0 else {
                    return continuation.resume(throwing: AntigravityIntegrationError.proxy("el proxy terminó con estado \(status)"))
                }
                continuation.resume(returning: data)
            }
        }
    }
}
