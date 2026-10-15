import SwiftROS2Messages
import SwiftROS2TestFixtures
import XCTest

@testable import SwiftROS2

/// Publishes sensor_msgs/Imu through the real rcl + rmw_cyclonedds_cpp stack
/// using EXPLICIT unicast discovery (`.rclUnicast`). This exercises the
/// CYCLONEDDS_URI export path in RclClient.createContext: rmw_cyclonedds must
/// reach the host via the static `<Peer>` rather than multicast SPDP — the
/// manual proof for the `transport.dds` matrix row.
///
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable
/// Jazzy host (LINUX_IP) running a CycloneDDS subscriber on domain 0. Because
/// discovery is unicast-only, the LAN does NOT need to carry multicast.
///
/// Host-side verification (run on the Jazzy host while this publishes):
///   ros2 topic echo /swift_ros2_rcl/imu
///                       -> Imu with linear_acceleration {1,2,9.81}
///   ros2 node list      -> shows /swift_ros2_rcl/swift_ros2_rcl_unicast_test
final class RclUnicastIntegrationTests: XCTestCase {
    func testPublishImuOverRclUnicast() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard let linuxIP = ProcessInfo.processInfo.environment["LINUX_IP"] else {
                throw XCTSkip(
                    "LINUX_IP not set — skipping LAN unicast integration test "
                        + "(needs a CycloneDDS subscriber on domain 0 at LINUX_IP)")
            }

            let peer = DDSPeer.peer(address: linuxIP, domainId: 0)
            let ctx = try await ROS2Context(
                transport: .rclUnicast(peers: [peer], domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_unicast_test", namespace: "/swift_ros2_rcl")
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
        #endif
    }
}
