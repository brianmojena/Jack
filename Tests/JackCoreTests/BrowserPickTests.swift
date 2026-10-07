import XCTest
@testable import JackCore

final class BrowserPickTests: XCTestCase {
    func testReadsWhatThePickerScriptPosts() throws {
        let pick = try XCTUnwrap(BrowserPick(message: [
            "selector": "main > button.buy", "tag": "<button class=\"buy\">", "text": "  Comprar ", "html": "<button class=\"buy\">Comprar</button>",
            "component": "BuyButton", "source": "src/BuyButton.tsx:12", "url": "http://localhost:3000/",
            "rect": ["x": 10, "y": 20, "width": 120.4, "height": 40],
        ]))
        XCTAssertEqual(pick.text, "Comprar")
        XCTAssertEqual(pick.rect, CGRect(x: 10, y: 20, width: 120.4, height: 40))
        XCTAssertEqual(pick.label, "<BuyButton>")
        XCTAssertNil(BrowserPick(message: ["tag": "<div>"]), "without a selector the agent could not find it")
    }

    func testTheMessageDescribesEachElementUnderWhatTheUserWrote() {
        let buy = BrowserPick(selector: "main > button.buy", tag: "<button class=\"buy\">", text: "Comprar", html: "<button class=\"buy\">Comprar</button>",
                              component: "BuyButton", source: "src/BuyButton.tsx:12", rect: CGRect(x: 0, y: 0, width: 120, height: 40),
                              url: "http://localhost:3000/", snapshot: "/tmp/a.png")
        let title = BrowserPick(selector: "h1", tag: "<h1>", text: "", html: "", component: nil, source: nil,
                                rect: CGRect(x: 0, y: 0, width: 300, height: 50), url: "http://localhost:3000/")
        XCTAssertEqual(title.label, "<h1>")
        let message = BrowserPick.message("Hazlo más grande", picks: [buy, title])
        XCTAssertTrue(message.hasPrefix("Hazlo más grande\n\nElementos que seleccioné en el navegador de Jack (http://localhost:3000/):"))
        XCTAssertTrue(message.contains("1. <button class=\"buy\">\n  Componente: BuyButton (src/BuyButton.tsx:12)\n  Selector: main > button.buy"))
        XCTAssertTrue(message.contains("2. <h1>\n  Selector: h1\n  Tamaño: 300×50 px"))
        XCTAssertTrue(message.hasSuffix("Adjunto una captura de cada elemento."))
        XCTAssertEqual(BrowserPick.message("hola", picks: []), "hola")
    }
}
