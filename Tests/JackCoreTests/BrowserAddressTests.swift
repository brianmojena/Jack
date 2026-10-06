import XCTest
@testable import JackCore

final class BrowserAddressTests: XCTestCase {
    func testAddressBarInput() {
        XCTAssertEqual(BrowserAddress.url(from: "3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserAddress.url(from: "localhost:5173/app")?.absoluteString, "http://localhost:5173/app")
        XCTAssertEqual(BrowserAddress.url(from: "127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(BrowserAddress.url(from: "192.168.1.20:4000")?.absoluteString, "http://192.168.1.20:4000")
        XCTAssertEqual(BrowserAddress.url(from: "apple.com")?.absoluteString, "https://apple.com")
        XCTAssertEqual(BrowserAddress.url(from: "https://example.org/x")?.absoluteString, "https://example.org/x")
        XCTAssertEqual(BrowserAddress.url(from: "  ")?.absoluteString, nil)
        XCTAssertEqual(BrowserAddress.url(from: "swift concurrency")?.host, "www.google.com")
    }
}
