import XCTest
@testable import JackCore

final class CodeOSQuotaTests: XCTestCase {
    private let ana = UUID(), luis = UUID(), eva = UUID()

    private func state(_ id: UUID, _ name: String, tokens: Double, epoch: String, active: Bool = true) -> QuotaPeerState {
        QuotaPeerState(instance: name, profile: id, name: name, hue: 0.5, active: active, tokens: tokens, epoch: epoch)
    }

    func testRemainingIsSplitAmongActiveProfiles() {
        // 60 % of the window is left (40 % used) and three profiles are active: 20 points each.
        let key = "w|a"
        let epoch = QuotaEpoch(key: key, usedAtStart: 40, active: [ana, luis, eva])
        let states = [state(ana, "Ana", tokens: 0, epoch: key), state(luis, "Luis", tokens: 0, epoch: key), state(eva, "Eva", tokens: 0, epoch: key)]
        let shares = QuotaPool.shares(epoch: epoch, states: states, grants: [], usedNow: 40)
        XCTAssertEqual(shares.map(\.base), [20, 20, 20])
        XCTAssertEqual(shares.map(\.remaining), [20, 20, 20])
    }

    func testSpentIsAttributedByTokens() {
        let key = "w|a"
        let epoch = QuotaEpoch(key: key, usedAtStart: 40, active: [ana, luis])
        // The account went from 40 to 52: 12 points, three quarters of them Ana's tokens.
        let states = [state(ana, "Ana", tokens: 3_000, epoch: key), state(luis, "Luis", tokens: 1_000, epoch: key)]
        let shares = QuotaPool.shares(epoch: epoch, states: states, grants: [], usedNow: 52)
        let anaShare = shares.first { $0.profile == ana }!
        let luisShare = shares.first { $0.profile == luis }!
        XCTAssertEqual(anaShare.spent, 9, accuracy: 0.001)
        XCTAssertEqual(luisShare.spent, 3, accuracy: 0.001)
        XCTAssertEqual(anaShare.remaining, 30 - 9, accuracy: 0.001)
    }

    func testReportsFromAnotherEpochAreIgnored() {
        let epoch = QuotaEpoch(key: "w|a,b", usedAtStart: 0, active: [ana, luis])
        let states = [state(ana, "Ana", tokens: 5_000, epoch: "old"), state(luis, "Luis", tokens: 1_000, epoch: "w|a,b")]
        let shares = QuotaPool.shares(epoch: epoch, states: states, grants: [], usedNow: 10)
        XCTAssertEqual(shares.first { $0.profile == ana }!.spent, 0, accuracy: 0.001)
        XCTAssertEqual(shares.first { $0.profile == luis }!.spent, 10, accuracy: 0.001)
    }

    func testGrantMovesPointsBetweenProfiles() {
        let key = "w|a"
        let epoch = QuotaEpoch(key: key, usedAtStart: 50, active: [ana, luis])
        let states = [state(ana, "Ana", tokens: 0, epoch: key), state(luis, "Luis", tokens: 0, epoch: key)]
        let grant = QuotaGrant(from: luis, to: ana, percent: 5, epoch: key)
        let shares = QuotaPool.shares(epoch: epoch, states: states, grants: [grant], usedNow: 50)
        XCTAssertEqual(shares.first { $0.profile == ana }!.base, 30)
        XCTAssertEqual(shares.first { $0.profile == luis }!.base, 20)
    }

    func testRefusalWhenShareIsGone() {
        let share = QuotaShare(profile: ana, name: "Ana", hue: 0, active: true, base: 10, spent: 10)
        XCTAssertNotNil(QuotaPool.refusal(for: ana, active: true, shares: [share]))
        XCTAssertNil(QuotaPool.refusal(for: ana, active: true, shares: [QuotaShare(profile: ana, name: "Ana", hue: 0, active: true, base: 10, spent: 4)]))
        XCTAssertNotNil(QuotaPool.refusal(for: ana, active: false, shares: []))
    }

    func testEpochKeyChangesWithWindowAndActiveSet() {
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let one = QuotaEpoch.key(windowResetsAt: reset, active: [ana, luis])
        XCTAssertEqual(one, QuotaEpoch.key(windowResetsAt: reset, active: [luis, ana]))
        XCTAssertNotEqual(one, QuotaEpoch.key(windowResetsAt: reset, active: [ana]))
        XCTAssertNotEqual(one, QuotaEpoch.key(windowResetsAt: reset.addingTimeInterval(18_000), active: [ana, luis]))
    }

    func testMessageRoundTrip() throws {
        let message = QuotaMessage(kind: .state, state: state(ana, "Ana", tokens: 12.5, epoch: "k"))
        let data = try JSONEncoder.quota.encode(message)
        XCTAssertEqual(try JSONDecoder.quota.decode(QuotaMessage.self, from: data).state?.tokens, 12.5)
    }
}
