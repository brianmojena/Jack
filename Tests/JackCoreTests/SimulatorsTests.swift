import Foundation
import XCTest
@testable import JackCore

final class SimulatorsTests: XCTestCase {
    func testListsAvailableIOSDevicesBootedAndNewestFirst() {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
            {"udid": "A", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": "B", "name": "iPhone 16", "state": "Shutdown", "isAvailable": true},
            {"udid": "C", "name": "iPad Air", "state": "Shutdown", "isAvailable": true},
            {"udid": "D", "name": "iPhone Gone", "state": "Shutdown", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
            {"udid": "W", "name": "Apple Watch", "state": "Booted", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
            {"udid": "E", "name": "iPhone 14", "state": "Booted", "isAvailable": true}
          ]
        }}
        """
        let devices = Simulators.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.udid), ["E", "C", "B", "A"])
        XCTAssertEqual(devices.first?.runtime, "iOS 18.6")
        XCTAssertTrue(devices.first?.booted == true)
    }

    func testBadOutputGivesNoDevices() {
        XCTAssertEqual(Simulators.parse(Data("xcrun: error".utf8)), [])
    }
}
