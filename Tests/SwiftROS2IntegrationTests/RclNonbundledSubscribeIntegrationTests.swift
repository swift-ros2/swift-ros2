import SwiftROS2Messages
import SwiftROS2TestFixtures
import XCTest

@testable import SwiftROS2

/// Subscribes to an UNBUNDLED type (audio_common_msgs/AudioData — absent from
/// the 12-entry marshal registry) through the real rcl backend.
/// createSubscription misses the registry and falls back to route (b): the
/// CDDSBridge raw-CDR reader below rmw (a sibling CycloneDDS participant on the
/// context domain). This is the manual LAN proof for the
/// `subscribe.serialized.non_bundled` matrix row.
///
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable host
/// (LINUX_IP) publishing the topic. Skips in CI (no LINUX_IP).
///
/// Host-side driver (run on the host while this subscribes):
///   ros2 topic pub /loopback_audio audio_common_msgs/msg/AudioData \
///       "{data: [222, 173, 190, 239]}" -r 10
final class RclNonbundledSubscribeIntegrationTests: XCTestCase {
    func testSubscribeAudioDataOverRclRouteB() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip(
                    "LINUX_IP not set — skipping LAN non-bundled subscribe integration test. "
                        + "Run on the host: `ros2 topic pub /loopback_audio "
                        + "audio_common_msgs/msg/AudioData \"{data: [222,173,190,239]}\" -r 10`")
            }

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_nonbundled_sub_test", namespace: "/")
            // Unbundled type → route-(b) raw-CDR reader.
            let sub = try await node.createSubscription(AudioData.self, topic: "loopback_audio")

            let received = expectation(description: "received AudioData from host")
            let task = Task {
                for await msg in sub.messages where !msg.data.isEmpty {
                    received.fulfill()
                    break
                }
            }
            await fulfillment(of: [received], timeout: 15)
            task.cancel()
            await ctx.shutdown()
        #endif
    }
}
