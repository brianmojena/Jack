import XCTest
@testable import Jack

final class ProcessCPUUsageTests: XCTestCase {
    func testFirstReadingNeedsABaselineAndIdleUsesZeroCPU() {
        var sampler = ProcessCPUUsageSampler()
        XCTAssertNil(sampler.sample(cpuSeconds: 50, uptime: 100))
        XCTAssertEqual(sampler.sample(cpuSeconds: 50, uptime: 102), 0)
    }

    func testActualElapsedTimeIncludesDelayedUpdates() throws {
        var sampler = ProcessCPUUsageSampler()
        _ = sampler.sample(cpuSeconds: 50, uptime: 100)
        // A scheduled two-second update ran five seconds late: use seven seconds.
        XCTAssertEqual(try XCTUnwrap(sampler.sample(cpuSeconds: 50.7, uptime: 107)), 10, accuracy: 0.0001)
    }

    func testRepeatedReadingsDoNotReplaceTheBaseline() throws {
        var sampler = ProcessCPUUsageSampler()
        _ = sampler.sample(cpuSeconds: 50, uptime: 100)
        XCTAssertNil(sampler.sample(cpuSeconds: 50.1, uptime: 100.01))
        XCTAssertEqual(try XCTUnwrap(sampler.sample(cpuSeconds: 50.2, uptime: 102)), 10, accuracy: 0.0001)
    }

    func testMultipleCoresCanLegitimatelyExceed100Percent() {
        var sampler = ProcessCPUUsageSampler()
        _ = sampler.sample(cpuSeconds: 50, uptime: 100)
        XCTAssertEqual(sampler.sample(cpuSeconds: 53, uptime: 102), 150)
    }

    func testInvalidCountersResetTheBaseline() throws {
        var sampler = ProcessCPUUsageSampler()
        _ = sampler.sample(cpuSeconds: 50, uptime: 100)
        XCTAssertNil(sampler.sample(cpuSeconds: 49, uptime: 102))
        XCTAssertEqual(try XCTUnwrap(sampler.sample(cpuSeconds: 49.2, uptime: 104)), 10, accuracy: 0.0001)
        XCTAssertNil(sampler.sample(cpuSeconds: .nan, uptime: 106))
        XCTAssertNil(sampler.sample(cpuSeconds: 50, uptime: 108))
        XCTAssertNil(sampler.sample(cpuSeconds: 51, uptime: 107))
    }
}
