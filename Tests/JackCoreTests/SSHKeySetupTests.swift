import XCTest
@testable import JackCore

final class SSHKeySetupTests: XCTestCase {
    func testAuthFailureDetection() {
        XCTAssertTrue(SSHKeySetup.isAuthFailure("ruben@host: Permission denied (publickey,password)."))
        XCTAssertFalse(SSHKeySetup.isAuthFailure("ssh: connect to host 10.0.0.1 port 22: Connection refused"))
    }

    func testInstallScriptQuotesKeyAndIsIdempotent() {
        let script = SSHKeySetup.installScript(publicKey: "ssh-ed25519 AAAA jack's mac\n")
        XCTAssertTrue(script.contains("grep -qxF"))
        XCTAssertTrue(script.contains("'\\''"))
        XCTAssertTrue(script.contains("JACK-KEY-OK"))
    }

    func testInstallArgumentsUsePasswordOnlyAndPort() {
        let args = SSHKeySetup.installArguments(endpoint: ChatRemoteEndpoint(destination: "a@b", sshPort: 2222), publicKey: "k")
        XCTAssertTrue(args.contains("PubkeyAuthentication=no"))
        XCTAssertFalse(args.contains("BatchMode=yes"))
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
    }

    func testSavedRemotesDedupeAndOrder() {
        let defaults = UserDefaults(suiteName: "SSHKeySetupTests-\(UUID().uuidString)")!
        SavedRemotes.remember(SavedRemote(destination: "a@b"), defaults)
        SavedRemotes.remember(SavedRemote(destination: "c@d", sshPort: 2200), defaults)
        SavedRemotes.remember(SavedRemote(destination: "a@b", remotePath: "/x"), defaults)
        let list = SavedRemotes.load(defaults)
        XCTAssertEqual(list.map(\.destination), ["a@b", "c@d"])
        XCTAssertEqual(list.first?.remotePath, "/x")
        SavedRemotes.forget(list[0], defaults)
        XCTAssertEqual(SavedRemotes.load(defaults).map(\.destination), ["c@d"])
    }
}
