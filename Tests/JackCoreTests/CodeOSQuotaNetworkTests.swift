import XCTest
@testable import JackCore

@MainActor
final class CodeOSQuotaNetworkTests: XCTestCase {
    func testTwoMacsExchangeStateOverTheLocalNetwork() async throws {
        let code = QuotaNetwork.newGroupCode()
        let first = QuotaNetwork(instance: "test-a-\(UUID().uuidString.prefix(6))")
        let second = QuotaNetwork(instance: "test-b-\(UUID().uuidString.prefix(6))")
        let received = expectation(description: "second hears first")
        let profile = UUID()
        second.onMessage = { message in
            if message.kind == .state, message.state?.profile == profile { received.fulfill() }
        }
        first.start(groupCode: code)
        second.start(groupCode: code)
        defer { first.stop(); second.stop() }
        // Keep sending until the other side has been found and connected.
        let sender = Task { @MainActor in
            while !Task.isCancelled {
                first.send(QuotaMessage(kind: .state, state: QuotaPeerState(instance: "a", profile: profile, name: "Ana", hue: 0.3, active: true, tokens: 7, epoch: "k")))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await fulfillment(of: [received], timeout: 25)
        sender.cancel()
    }

    func testAMacWithAnotherGroupCodeIsNotHeard() async throws {
        let first = QuotaNetwork(instance: "test-c-\(UUID().uuidString.prefix(6))")
        let outsider = QuotaNetwork(instance: "test-d-\(UUID().uuidString.prefix(6))")
        let heard = expectation(description: "outsider hears")
        heard.isInverted = true
        outsider.onMessage = { _ in heard.fulfill() }
        first.start(groupCode: "AAAA-BBBB-CCCC-DDDD")
        outsider.start(groupCode: "ZZZZ-YYYY-XXXX-WWWW")
        defer { first.stop(); outsider.stop() }
        let sender = Task { @MainActor in
            while !Task.isCancelled {
                first.send(QuotaMessage(kind: .decline, declined: UUID()))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await fulfillment(of: [heard], timeout: 8)
        sender.cancel()
    }
}
