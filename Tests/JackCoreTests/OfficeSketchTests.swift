import XCTest
@testable import JackCore

final class OfficeSketchTests: XCTestCase {
    private let octopus = """
    Título: un pulpo con sombrero
    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 500">
      <defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient></defs>
      <circle cx="400" cy="250" r="100" fill="none" stroke="#222" stroke-width="6"/>
      <path d="M300 300 Q250 400 200 420" stroke="#1e66f5" fill="none"/>
      <g stroke="#e53935"><line x1="0" y1="0" x2="10" y2="10"/><rect x="1" y="2" width="3" height="4"/></g>
    </svg>
    ```
    """

    func testParsesTitleAndShapes() throws {
        let sketch = try OfficeSketch.parse(octopus)
        XCTAssertEqual(sketch.title, "un pulpo con sombrero")
        XCTAssertEqual(sketch.shapeCount, 3)
        XCTAssertTrue(sketch.source.contains("viewBox=\"0 0 800 500\""))
        XCTAssertTrue(sketch.source.contains("linearGradient"))
    }

    func testKeepsRequiredNamespaceAndExplicitSize() throws {
        let sketch = try OfficeSketch.parse("<svg viewBox=\"0 0 100 50\"><circle cx=\"5\" cy=\"5\" r=\"2\"/></svg>")
        XCTAssertTrue(sketch.source.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(sketch.source.contains("width=\"100\""))
        XCTAssertTrue(sketch.source.contains("height=\"50\""))
    }

    func testWithoutViewBoxFallsBackToDefaultCanvas() throws {
        let sketch = try OfficeSketch.parse("<svg width=\"40\" height=\"30\"><rect width=\"4\" height=\"4\"/></svg>")
        XCTAssertTrue(sketch.source.contains("viewBox=\"0 0 800 500\""))
    }

    func testStripsEverythingThatIsNotAShape() throws {
        let raw = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 500" onload="evil()">
          <script>alert(1)</script>
          <image href="https://example.com/x.png" width="10" height="10"/>
          <foreignObject><div/></foreignObject>
          <text x="1" y="1">hola</text>
          <style>circle { fill: red }</style>
          <circle cx="5" cy="5" r="2" onclick="evil()" fill="url(https://example.com/a)" style="fill:url(https://example.com/a)"/>
        </svg>
        """
        let sketch = try OfficeSketch.parse(raw)
        for forbidden in ["script", "image", "foreignObject", "<text", "<style", "onload", "onclick", "example.com"] {
            XCTAssertFalse(sketch.source.contains(forbidden), forbidden)
        }
        XCTAssertEqual(sketch.shapeCount, 1)
    }

    func testRejectsWhatIsNotAnSVG() {
        XCTAssertThrowsError(try OfficeSketch.parse("No puedo dibujar eso."))
        XCTAssertThrowsError(try OfficeSketch.parse("<svg><circle></svg>"))
        XCTAssertThrowsError(try OfficeSketch.parse("<svg xmlns=\"http://www.w3.org/2000/svg\"><defs/></svg>")) { XCTAssertEqual($0 as? OfficeSketch.Failure, .empty) }
        // Entidades y definiciones de tipo: nada (lo que haya antes del `<svg` ni se lee).
        XCTAssertThrowsError(try OfficeSketch.parse("<svg [<!ENTITY a \"x\">]><circle r=\"1\"/></svg>"))
        XCTAssertThrowsError(try OfficeSketch.parse("<svg><!DOCTYPE x><circle r=\"1\"/></svg>"))
        XCTAssertFalse(try OfficeSketch.parse("<!DOCTYPE svg [<!ENTITY a \"x\">]><svg><circle r=\"1\"/></svg>").source.contains("ENTITY"))
    }

    func testRejectsTooMuchSVG() {
        let shapes = String(repeating: "<circle cx=\"1\" cy=\"1\" r=\"1\"/>", count: OfficeSketch.shapeLimit + 1)
        XCTAssertThrowsError(try OfficeSketch.parse("<svg viewBox=\"0 0 800 500\">\(shapes)</svg>")) { XCTAssertEqual($0 as? OfficeSketch.Failure, .tooLarge) }
        let huge = "<svg viewBox=\"0 0 800 500\"><path d=\"\(String(repeating: "M0 0 ", count: OfficeSketch.sizeLimit))\"/></svg>"
        XCTAssertThrowsError(try OfficeSketch.parse(huge)) { XCTAssertEqual($0 as? OfficeSketch.Failure, .tooLarge) }
    }

    func testProgressiveStepsAddShapesUntilTheWholeDrawing() throws {
        let sketch = try OfficeSketch.parse(octopus)
        let frames = sketch.progressive(steps: 3)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map { $0.components(separatedBy: "<circle").count - 1 + $0.components(separatedBy: "<path").count - 1 + $0.components(separatedBy: "<g").count - 1 }, [1, 2, 3])
        // El degradado de `defs` está desde el primer paso.
        XCTAssertTrue(frames.allSatisfy { $0.contains("linearGradient") })
        XCTAssertEqual(sketch.progressive(steps: 10).count, 3)
        XCTAssertEqual(sketch.progressive(steps: 0).count, 1)
    }

    func testTitleCleaning() {
        XCTAssertEqual(OfficeSketch.title(from: "**Título:** «un gato»\n"), "un gato")
        XCTAssertEqual(OfficeSketch.title(from: "```xml\n"), "")
        XCTAssertEqual(OfficeSketch.title(from: String(repeating: "a", count: 200)).count, 70)
    }

    func testEveryFallbackIsAValidSketch() throws {
        for fallback in OfficeSketch.fallbacks {
            let svg = "<svg viewBox=\"0 0 800 500\" xmlns=\"http://www.w3.org/2000/svg\">\(fallback.shapes)</svg>"
            let sketch = try OfficeSketch.parse("\(fallback.title)\n\(svg)")
            XCTAssertGreaterThan(sketch.shapeCount, 3, fallback.title)
        }
        let picked = OfficeSketch.fallback(excluding: OfficeSketch.fallbacks[0].title)
        XCTAssertNotEqual(picked.title, OfficeSketch.fallbacks[0].title)
    }
}

final class OfficeInspirationTests: XCTestCase {
    private func page(_ title: String, index: Int, mime: String = "image/jpeg", url: String = "https://upload.wikimedia.org/x/512px-a.jpg", width: Int = 512) -> String {
        "\"\(index)\": {\"title\": \"\(title)\", \"index\": \(index), \"imageinfo\": [{\"thumburl\": \"\(url)\", \"thumbwidth\": \(width), \"mime\": \"\(mime)\"}]}"
    }

    func testCandidatesKeepOnlyUsableThumbnailsInSearchOrder() {
        let json = """
        {"query": {"pages": {
        \(page("File:Second_cat.jpg", index: 2)),
        \(page("File:First cat.png", index: 1, mime: "image/png")),
        \(page("File:Drawing.svg", index: 3, mime: "image/svg+xml")),
        \(page("File:Elsewhere.jpg", index: 4, url: "https://evil.example.com/a.jpg")),
        \(page("File:Insecure.jpg", index: 5, url: "http://upload.wikimedia.org/a.jpg")),
        \(page("File:Tiny.jpg", index: 6, width: 90)),
        \(page("File:Thumb served.jpg", index: 7, url: "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a4/x.jpg/512px-x.jpg"))
        }}}
        """
        let found = OfficeInspirationFinder.candidates(from: Data(json.utf8))
        XCTAssertEqual(found.map(\.title), ["First cat", "Second cat", "Thumb served"])
    }

    func testCandidatesFromGarbageAreEmpty() {
        XCTAssertTrue(OfficeInspirationFinder.candidates(from: Data("no json".utf8)).isEmpty)
        XCTAssertTrue(OfficeInspirationFinder.candidates(from: Data("{\"batchcomplete\": \"\"}".utf8)).isEmpty)
    }

    func testTitleCleaning() {
        XCTAssertEqual(OfficeInspirationFinder.cleanTitle("File:Octopus_vulgaris_02.jpg"), "Octopus vulgaris 02")
        XCTAssertEqual(OfficeInspirationFinder.cleanTitle("File:" + String(repeating: "a", count: 200) + ".jpg").count, 80)
    }

    func testOnlyRealImagesAreAccepted() {
        XCTAssertTrue(OfficeInspirationFinder.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])))
        XCTAssertTrue(OfficeInspirationFinder.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])))
        XCTAssertFalse(OfficeInspirationFinder.isImage(Data("<html>error</html>".utf8)))
    }

    func testRequestAsksForBitmapsAndIdentifiesItself() throws {
        let request = OfficeInspirationFinder.request(searching: "The Starry Night Van Gogh")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://commons.wikimedia.org/w/api.php?"))
        XCTAssertTrue(url.contains("filetype:bitmap") || url.contains("filetype%3Abitmap"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    func testFindsThePaintingAndDownloadsItsThumbnail() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 800))
        let json = "{\"query\": {\"pages\": {\(page("File:Mona_Lisa.jpg", index: 1))}}}"
        let finder = OfficeInspirationFinder { request in
            let url = try XCTUnwrap(request.url)
            let body = url.host == "commons.wikimedia.org" ? Data(json.utf8) : jpeg
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let found = try await finder.inspire(by: OfficeInspirationFinder.works[0])
        XCTAssertEqual(found.fileTitle, "Mona Lisa")
        XCTAssertEqual(found.image, jpeg)
    }

    func testWithoutConnectionThePaintingIsDoneFromMemory() async throws {
        let finder = OfficeInspirationFinder { _ in throw URLError(.notConnectedToInternet) }
        let found = try await finder.inspire(by: OfficeInspirationFinder.works[1])
        XCTAssertNil(found.image)
        XCTAssertNil(found.fileTitle)
        XCTAssertEqual(found.artwork, OfficeInspirationFinder.works[1])
    }

    func testAnErrorPageIsNotAnImage() async throws {
        let json = "{\"query\": {\"pages\": {\(page("File:A.jpg", index: 1))}}}"
        let finder = OfficeInspirationFinder { request in
            let body = request.url?.host == "commons.wikimedia.org" ? Data(json.utf8) : Data(String(repeating: "<html>error</html>", count: 60).utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let found = try await finder.inspire(by: OfficeInspirationFinder.works[2])
        XCTAssertNil(found.image)
    }

    func testWorksAreUniqueAndPickingAvoidsTheRecentOnes() {
        let titles = OfficeInspirationFinder.works.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertGreaterThan(titles.count, 30)
        let recent = Array(titles.dropLast())
        for _ in 0..<20 { XCTAssertEqual(OfficeInspirationFinder.pick(excluding: recent).title, titles.last) }
        // Si ya se han hecho todos, se repite alguno en vez de quedarse sin cuadro.
        XCTAssertTrue(titles.contains(OfficeInspirationFinder.pick(excluding: titles).title))
        XCTAssertEqual(OfficeInspirationFinder.works[1].label, "«La noche estrellada», de Vincent van Gogh")
    }
}

final class OfficeCanvasTests: XCTestCase {
    private let reply = """
    «La noche estrellada», de Vincent van Gogh
    ```js
    function pintar(ctx, w, h, p) {
      const total = 40;
      for (let i = 0; i < Math.ceil(p * total); i++) { ctx.fillStyle = '#1e3a8a'; ctx.fillRect(i * 10, 0, 10, h); }
    }
    ```
    """

    func testParsesTitleAndCode() throws {
        let program = try OfficeCanvasProgram.parse(reply)
        XCTAssertEqual(program.title, "«La noche estrellada», de Vincent van Gogh")
        XCTAssertTrue(program.code.hasPrefix("function pintar"))
        XCTAssertFalse(program.code.contains("```"))
    }

    func testAcceptsTheLanguageLineAndAFunctionWithoutFence() throws {
        XCTAssertTrue(try OfficeCanvasProgram.parse("Un cielo\n```javascript\nfunction pintar(ctx, w, h, p) {}\n```").code.hasPrefix("function pintar"))
        let loose = try OfficeCanvasProgram.parse("Título: Un cielo\nfunction pintar(ctx, w, h, p) { ctx.fillRect(0, 0, w, h) }")
        XCTAssertEqual(loose.title, "Un cielo")
    }

    func testRejectsWhatIsNotAProgram() {
        XCTAssertThrowsError(try OfficeCanvasProgram.parse("No puedo pintar eso.")) { XCTAssertEqual($0 as? OfficeCanvasProgram.Failure, .noCode) }
        XCTAssertThrowsError(try OfficeCanvasProgram.parse("```js\nconsole.log(1)\n```")) { XCTAssertEqual($0 as? OfficeCanvasProgram.Failure, .missingFunction) }
        XCTAssertThrowsError(try OfficeCanvasProgram.parse("```js\n\(String(repeating: "// x\n", count: 20_000))function pintar() {}\n```")) { XCTAssertEqual($0 as? OfficeCanvasProgram.Failure, .tooLarge) }
    }

    func testRejectsNetworkStorageAndDynamicCode() {
        for bad in ["fetch('https://example.com')", "new XMLHttpRequest()", "eval('1')", "new Function('return 1')()", "localStorage.x = 1",
                    "setTimeout(() => {}, 5)", "import('x')", "while(true) {}", "document.cookie", "const s = '</script><script>x</script>'"] {
            let source = "```js\nfunction pintar(ctx, w, h, p) { \(bad) }\n```"
            XCTAssertThrowsError(try OfficeCanvasProgram.parse(source), bad) { error in
                guard case .forbidden = error as? OfficeCanvasProgram.Failure else { return XCTFail("\(bad): \(error)") }
            }
        }
    }

    func testForbiddenWordsAreOnlyMatchedAsWholeIdentifiers() throws {
        // «important», «Functional» o «locationX» no son `import`, `Function` ni `location`.
        let program = try OfficeCanvasProgram.parse("```js\nfunction pintar(ctx, w, h, p) { const important = 1, Functional = 2, locationX = 3, imports = 4; ctx.fillRect(0, 0, important, locationX) }\n```")
        XCTAssertTrue(program.code.contains("important"))
    }

    func testPageIsLockedDownAndRunsTheCode() throws {
        let page = try OfficeCanvasProgram.parse(reply).html
        XCTAssertTrue(page.contains("default-src 'none'"))
        XCTAssertTrue(page.contains("function pintar"))
        XCTAssertTrue(page.contains("window.__frame"))
        XCTAssertTrue(page.contains("width=\"\(OfficeCanvasProgram.width)\""))
    }

    func testDrawingExposesTitleAndInspiration() throws {
        var program = try OfficeCanvasProgram.parse(reply)
        program.inspiration = "La noche estrellada"
        XCTAssertEqual(OfficeDrawing.program(program).inspiration, "La noche estrellada")
        let vector = OfficeSketch.fallback()
        XCTAssertEqual(OfficeDrawing.vector(vector).title, vector.title)
    }
}
