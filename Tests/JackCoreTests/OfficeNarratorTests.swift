import XCTest
@testable import JackCore

final class OfficeNarratorTests: XCTestCase {
    @MainActor func testNewAgentDefaultModeChangesOnlyInNormal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for lightMode in [false, true] {
            let store = ChatStore(archive: ChatArchive(directory: folder.appendingPathComponent(String(lightMode))),
                                  preferences: nil, lightMode: lightMode)
            defer { store.shutdown() }
            for provider in [ChatProvider.codex, .claude] {
                let id = try XCTUnwrap(store.create(projectPath: NSTemporaryDirectory(), provider: provider))
                let conversation = try XCTUnwrap(store.conversations.first { $0.id == id })
                XCTAssertEqual(conversation.mode, lightMode ? nil : "auto")
            }
        }
    }

    @MainActor func testLightRejectsEveryNarrationPathBeforeAccessingTheModel() async {
        let narrator = OfficeNarrator()
        narrator.inspectModel = {
            XCTFail("La oficina no debe consultar modelos en Light")
            throw CancellationError()
        }
        let worker = OfficeWorker(tool: "Codex", status: .running, messages: [])
        do {
            _ = try await narrator.reply(as: "Ana", history: [], worker: worker, team: "", catalog: "", lightMode: true)
            XCTFail("Light debe rechazar la conversación con la oficina")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await narrator.report(as: "Ana", history: [], worker: worker, lightMode: true)
            XCTFail("Light debe rechazar los informes de la oficina")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await narrator.summary(as: "Ana", tool: "Codex", of: [], previous: nil, lightMode: true)
            XCTFail("Light debe rechazar los resúmenes de la oficina")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testDelegatedTaskCannotBeInterpretedAsAJackCommand() {
        let decision = OfficeNarrator.decision(from: #"{"reply":"Lo reviso.","task":"!!revisa el proyecto"}"#)
        XCTAssertEqual(decision.reply, "Lo reviso.")
        XCTAssertEqual(decision.task, "revisa el proyecto")
        XCTAssertNil(OfficeNarrator.decision(from: "Solo estoy saludando.").task)
    }
}
