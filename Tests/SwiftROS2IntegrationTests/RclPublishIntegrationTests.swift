import SwiftROS2Messages
import SwiftROS2TestFixtures
import XCTest

@testable import SwiftROS2

/// Publishes sensor_msgs/Imu through the real rcl + rmw_cyclonedds_cpp stack.
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable
/// Jazzy host (LINUX_IP). Host-side verification is documented at the bottom.
final class RclPublishIntegrationTests: XCTestCase {
    func testPublishImuOverRcl() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip("LINUX_IP not set — skipping LAN integration test")
            }

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_test", namespace: "/swift_ros2_rcl")
            let pub = try await node.createPublisher(Imu.self, topic: "imu")

            var imu = Imu()
            imu.linearAcceleration.x = 1.0
            imu.linearAcceleration.y = 2.0
            imu.linearAcceleration.z = 9.81
            imu.angularVelocity.z = 0.5

            for _ in 0..<50 {
                try await pub.publish(imu)
                try await Task.sleep(for: .milliseconds(100))
            }

            await ctx.shutdown()

        // pub.publish(imu) encodes with SwiftROS2CDR and publishes through the
        // serialized seam (rcl_publish_serialized_message). The on-wire result
        // matches rmw_serialize (M2 proved SwiftROS2CDR == rmw_serialize); this
        // confirms it end-to-end on a host.
        //
        // Host-side verification (run on the Jazzy host while this publishes):
        //   ros2 node list            -> shows /swift_ros2_rcl/swift_ros2_rcl_test
        //   ros2 topic echo /swift_ros2_rcl/imu
        //                             -> Imu with linear_acceleration {1,2,9.81}
        //   ros2 topic info /swift_ros2_rcl/imu --verbose
        //                             -> type sensor_msgs/msg/Imu, 1 publisher
        #endif
    }
}
