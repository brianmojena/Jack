import XCTest
@testable import JackCore

final class UpdateCheckerTests: XCTestCase {
    private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false, assets: String = #"[{"name":"Jack-0.3.35.zip","browser_download_url":"https://example.com/Jack-0.3.35.zip"}]"#) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/brianmojena/Jack/releases/tag/\#(tag)","body":"Novedades\n","draft":\#(draft),"prerelease":\#(prerelease),"assets":\#(assets)}"#.utf8)
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(AppVersion("0.3.9")! < AppVersion("0.3.10")!)
        XCTAssertTrue(AppVersion("0.3.34")! < AppVersion("v0.4")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertEqual(AppVersion("v0.3.35-beta")!.description, "0.3.35")
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testParsesLatestReleaseAndItsZip() throws {
        let release = try XCTUnwrap(AppRelease.parse(releaseJSON(tag: "v0.3.35")))
        XCTAssertEqual(release.version, AppVersion("0.3.35"))
        XCTAssertEqual(release.notes, "Novedades")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://example.com/Jack-0.3.35.zip")
        XCTAssertEqual(release.downloadName, "Jack-0.3.35.zip")
    }

    func testIgnoresDraftsPrereleasesAndUnreadableTags() {
        XCTAssertNil(AppRelease.parse(releaseJSON(tag: "v0.3.35", draft: true)))
        XCTAssertNil(AppRelease.parse(releaseJSON(tag: "v0.3.35", prerelease: true)))
        XCTAssertNil(AppRelease.parse(releaseJSON(tag: "latest")))
        XCTAssertNil(AppRelease.parse(Data("not json".utf8)))
    }

    func testReleaseWithoutZipStillParses() throws {
        let release = try XCTUnwrap(AppRelease.parse(releaseJSON(tag: "v0.3.35", assets: "[]")))
        XCTAssertNil(release.downloadURL)
    }

    @MainActor private func checker(current: String, status: Int = 200, body: Data, defaults: UserDefaults) -> UpdateChecker {
        UpdateChecker(currentVersion: current, defaults: defaults, fetch: { url in
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func freshDefaults() -> UserDefaults {
        let name = "UpdateCheckerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor func testOffersANewerRelease() async {
        let checker = checker(current: "0.3.34", body: releaseJSON(tag: "v0.3.35"), defaults: freshDefaults())
        await checker.check(manual: false)
        XCTAssertEqual(checker.available?.version, AppVersion("0.3.35"))
    }

    @MainActor func testSameOrOlderReleaseOffersNothing() async {
        let checker = checker(current: "0.3.35", body: releaseJSON(tag: "v0.3.35"), defaults: freshDefaults())
        await checker.check(manual: true)
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.status, .upToDate)
    }

    @MainActor func testSkippedReleaseStaysHiddenUntilManualCheck() async {
        let checker = checker(current: "0.3.34", body: releaseJSON(tag: "v0.3.35"), defaults: freshDefaults())
        await checker.check(manual: false)
        checker.skipAvailable()
        XCTAssertNil(checker.available)
        await checker.check(manual: false)
        XCTAssertNil(checker.available)
        await checker.check(manual: true)
        XCTAssertEqual(checker.available?.version, AppVersion("0.3.35"))
    }

    @MainActor func testAutomaticFailureIsSilentAndManualFailureIsReported() async {
        let checker = checker(current: "0.3.34", status: 404, body: Data(), defaults: freshDefaults())
        await checker.check(manual: false)
        XCTAssertEqual(checker.status, .idle)
        await checker.check(manual: true)
        guard case .failed(let message) = checker.status else { return XCTFail("Expected a failure") }
        XCTAssertTrue(message.contains("privado"))
    }
}
