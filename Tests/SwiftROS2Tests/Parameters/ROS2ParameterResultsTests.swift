import XCTest

@testable import SwiftROS2

final class ROS2ParameterResultsTests: XCTestCase {
    func testSetParametersResultDefaults() {
        let ok = ROS2SetParametersResult.success()
        XCTAssertTrue(ok.successful)
        XCTAssertEqual(ok.reason, "")

        let bad = ROS2SetParametersResult.failure(reason: "out of range")
        XCTAssertFalse(bad.successful)
        XCTAssertEqual(bad.reason, "out of range")
    }
}
