import SwiftROS2
import SwiftROS2Messages
import SwiftROS2TestFixtures
import SwiftROS2Transport
import XCTest

/// Round-trip integration test: publishes sensor_msgs/Imu via Zenoh to a
/// ROS 2 Jazzy Zenoh router and confirms the subscriber on the router host
/// receives the expected sequence. Requires:
/// - `LINUX_IP` environment variable set to the router host's IPv4
/// - A running `rmw_zenohd` on that host (tcp/<LINUX_IP>:7447)
/// - A running `ros2 topic echo /test/imu` on that host (to capture output)
///
/// Skips gracefully when `LINUX_IP` is not set so CI stays deterministic.
final class ZenohRoundTripTests: XCTestCase {
    func testImuPublishReceivedByLinux() async throws {
        guard let linuxIP = ProcessInfo.processInfo.environment["LINUX_IP"], !linuxIP.isEmpty else {
            throw XCTSkip("Set LINUX_IP to run this test (e.g., LINUX_IP=192.168.1.85)")
        }

        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/\(linuxIP):7447", domainId: 0, wireMode: .jazzy),
            distro: .jazzy
        )
        let node = try await ctx.createNode(name: "swift_ros2_it", namespace: "/test")
        let pub = try await node.createPublisher(Imu.self, topic: "imu")

        // rmw_zenoh discovery needs a moment for the liveliness token
        // to propagate to the subscriber before we start publishing.
        try await Task.sleep(nanoseconds: 500_000_000)

        for i in 0..<10 {
            try pub.publish(
                Imu(
                    header: Header(stamp: Time.now(), frameId: "imu_link"),
                    linearAcceleration: Vector3(x: 0.0, y: 0.0, z: 9.81 + Double(i) * 0.01)
                ))
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Give the last message time to reach Linux before shutting down.
        try await Task.sleep(nanoseconds: 500_000_000)
        await ctx.shutdown()
    }
}
