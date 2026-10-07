import XCTest
@testable import JackCore

final class PlanFlowTests: XCTestCase {
    func testNumberedStepsBecomeTheFlowWithSubstepsAndFiles() throws {
        let flow = try XCTUnwrap(PlanFlow.parse("""
        # Plan: añadir el diagrama

        ## Contexto
        Texto suelto que no es un paso.

        1. Crear **`Sources/JackCore/PlanFlow.swift`** con el parser
           - Leer el Markdown
           - Devolver los pasos
        2. ¿El plan tiene dos pasos o más?
        3. Probar con `swift test`
        """))
        XCTAssertEqual(flow.title, "añadir el diagrama")
        XCTAssertEqual(flow.steps.map(\.title), ["Crear Sources/JackCore/PlanFlow.swift con el parser", "¿El plan tiene dos pasos o más?", "Probar con swift test"])
        XCTAssertEqual(flow.steps[0].details, ["Leer el Markdown", "Devolver los pasos"])
        XCTAssertEqual(flow.steps[0].files, ["Sources/JackCore/PlanFlow.swift"])
        XCTAssertEqual(flow.steps[1].isDecision, true)
        XCTAssertEqual(flow.steps[2].files, [])
        XCTAssertNil(flow.steps[0].phase, "one section is not a phase")
    }

    func testSectionsWithStepsBecomePhases() throws {
        let flow = try XCTUnwrap(PlanFlow.parse("""
        ## Núcleo
        - Parser
        - Tests
        ## Interfaz
        - Pestaña
        """))
        XCTAssertEqual(flow.steps.map(\.phase), ["Núcleo", "Núcleo", "Interfaz"])
    }

    func testHeadingsAreTheLastResort() throws {
        let flow = try XCTUnwrap(PlanFlow.parse("## Investigar\ntexto\n## Implementar\ntexto\n## Verificar\ntexto"))
        XCTAssertEqual(flow.steps.map(\.title), ["Investigar", "Implementar", "Verificar"])
    }

    func testASingleStepIsNotAFlow() {
        XCTAssertNil(PlanFlow.parse("1. Hacer todo"))
        XCTAssertNil(PlanFlow.parse("Solo texto, sin pasos."))
    }

    func testMermaid() throws {
        let flow = try XCTUnwrap(PlanFlow.parse("# Plan: x\n1. Uno\n2. ¿Dos \"a\"?\n3. Tres"))
        XCTAssertEqual(flow.mermaid, """
        flowchart TD
            start(["x"])
            s1["1. Uno"]
            start --> s1
            s2{"¿Dos 'a'?"}
            s1 --> s2
            s3["3. Tres"]
            s2 -->|sí| s3
            done(["Listo"])
            s3 --> done
        """)
    }

    func testClaudePlanToolCallInTheCurrentTurn() {
        let detail = #"{"plan":"1. A\n2. B"} Plan aprobado"#
        let messages = [
            ChatMessage(role: "user", text: "planifica"),
            ChatMessage(role: "tool", text: "ExitPlanMode", detail: detail, status: "completed")
        ]
        XCTAssertEqual(PlanSource.latest(in: messages, mode: nil)?.markdown, "1. A\n2. B")
        // A later user message starts a new turn without a plan.
        XCTAssertNil(PlanSource.latest(in: messages + [ChatMessage(role: "user", text: "sigue")], mode: nil))
    }

    func testPlainTextPlansCountOnlyInPlanMode() {
        let messages = [ChatMessage(role: "user", text: "planifica"), ChatMessage(role: "assistant", text: "1. A\n2. B")]
        XCTAssertEqual(PlanSource.latest(in: messages, mode: "plan")?.markdown, "1. A\n2. B")
        XCTAssertNil(PlanSource.latest(in: messages, mode: "default"))
    }
}
