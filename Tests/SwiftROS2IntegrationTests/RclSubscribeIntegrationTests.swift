import SwiftROS2Messages
import SwiftROS2TestFixtures
import XCTest

@testable import SwiftROS2

/// Subscribes to sensor_msgs/Temperature through the real rcl +
/// rmw_cyclonedds_cpp stack and asserts receipt + decoded field values
/// (plan task T5: host publishes a registry type, macOS asserts receipt).
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable
/// Jazzy host (LINUX_IP) that is actively publishing — start the host-side
/// publisher BEFORE running this test:
///
///   ros2 topic pub -r 10 /swift_ros2_rcl/temperature sensor_msgs/msg/Temperature \
///     "{header: {frame_id: probe}, temperature: 36.5, variance: 0.25}"
final class RclSubscribeIntegrationTests: XCTestCase {
    func testSubscribeTemperatureOverRcl() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip("LINUX_IP not set — skipping LAN integration test")
            }

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_sub_test", namespace: "/swift_ros2_rcl")
            // Reliable to match the `ros2 topic pub` default writer QoS.
            let qos = QoSProfile(
                reliability: .reliable, durability: .volatile, history: .keepLast(10))
            let sub = try await node.createSubscription(
                Temperature.self, topic: "temperature", qos: qos)

            // First message within 30 s — covers discovery + one publish period.
            let receiveTask = Task { () -> Temperature? in
                for await message in sub.messages { return message }
                return nil
            }
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(30))
                receiveTask.cancel()
            }
            let received = await receiveTask.value
            timeoutTask.cancel()

            guard let received else {
                await ctx.shutdown()
                return XCTFail(
                    "no Temperature received within 30 s — is the host publishing on "
                        + "/swift_ros2_rcl/temperature? (see the header of this file)")
            }

            // Decode gate: values must match the documented host-side command.
            XCTAssertEqual(received.temperature, 36.5, accuracy: 1e-9)
            XCTAssertEqual(received.variance, 0.25, accuracy: 1e-9)
            XCTAssertEqual(received.header.frameId, "probe")

            await ctx.shutdown()
        #endif
    }
}
