import XCTest
import Darwin
@testable import Jack

final class ProcessCPUUsageTests: XCTestCase {
    func testSystemCPUUsesBusyTicksOverAllTicks() throws {
        var sampler = SystemCPUUsageSampler()
        XCTAssertNil(sampler.sample(ticks: [100, 100, 100, 100]))
        // User, system, idle, nice: 40 busy ticks out of 100.
        XCTAssertEqual(try XCTUnwrap(sampler.sample(ticks: [120, 115, 160, 105])), 40, accuracy: 0.0001)
        XCTAssertNil(sampler.sample(ticks: [120, 115, 160, 105]))
    }

    func testSystemCountersWrapWithoutSpikes() throws {
        var sampler = SystemCPUUsageSampler()
        _ = sampler.sample(ticks: [.max - 9, 0, .max - 29, 0])
        XCTAssertEqual(try XCTUnwrap(sampler.sample(ticks: [10, 0, 30, 0])), 25, accuracy: 0.0001)
    }

    func testSystemSamplerReadsKernelCounters() throws {
        var sampler = SystemCPUUsageSampler()
        XCTAssertNil(sampler.sample())
        // Allow the kernel's cached host statistics to advance before taking a real second reading.
        Thread.sleep(forTimeInterval: 1.1)
        let value = try XCTUnwrap(sampler.sample())
        XCTAssertTrue((0...100).contains(value))
    }

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
