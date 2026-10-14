import SwiftROS2Wire
import XCTest

final class ROS2DistroWireTests: XCTestCase {
    func testWireFactsFollowTheLegacySchema() {
        for distro in ROS2Distro.allCases {
            XCTAssertEqual(distro.wireGroup == .legacy, distro.isLegacySchema)
            XCTAssertEqual(distro.alwaysIncludeTypeHashInKey, distro.isLegacySchema)
            XCTAssertEqual(
                distro.formatTypeHash("RIHS01_x"), distro.isLegacySchema ? "TypeHashNotSupported" : "RIHS01_x")
            XCTAssertEqual(distro.formatTypeHash(nil), distro.isLegacySchema ? "TypeHashNotSupported" : "")
        }
        XCTAssertEqual(ROS2Distro.WireGroup.legacy.distros, [.humble])
        XCTAssertEqual(ROS2Distro.WireGroup.modern.distros, [.jazzy, .kilted, .lyrical, .rolling])
    }
}
