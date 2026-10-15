import SwiftROS2Messages
import SwiftROS2TestFixtures
import XCTest

@testable import SwiftROS2

/// Publishes an UNBUNDLED type (audio_common_msgs/AudioData — absent from the
/// 12-entry marshal registry) through the real rcl backend. createPublisher
/// misses the registry and falls back to route (b): the CDDSBridge raw-CDR
/// writer below rmw (a sibling CycloneDDS participant on the context domain,
/// keyed by DDS topic + DDS type name). This is the manual LAN proof for the
/// `publish.serialized.non_bundled` matrix row.
///
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable host
/// (LINUX_IP) echoing the topic. Skips in CI (no LINUX_IP). The test fails when no
/// subscription matches within 30 s.
///
/// Host-side verification (run on the host while this publishes):
///   ros2 topic echo /loopback_audio audio_common_msgs/msg/AudioData
///                       -> AudioData with data [222, 173, 190, 239]
final class RclNonbundledPublishIntegrationTests: XCTestCase {
    func testPublishAudioDataOverRclRouteB() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip(
                    "LINUX_IP not set — skipping LAN non-bundled publish integration test. "
                        + "Run on the host: "
                        + "`ros2 topic echo /loopback_audio audio_common_msgs/msg/AudioData`")
            }

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_nonbundled_test", namespace: "/")
            // Unbundled type → route-(b) raw-CDR writer.
            let pub = try await node.createPublisher(AudioData.self, topic: "loopback_audio")
            try await assertHostSubscriberMatches(
                pub, hint: "is `ros2 topic echo /loopback_audio` running on the host?")

            let fixture = AudioData(data: [0xDE, 0xAD, 0xBE, 0xEF])
            for _ in 0..<50 {
                try await pub.publish(fixture)
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(pub.hasMatchedSubscriptions, "the host subscriber went away while publishing")

            await ctx.shutdown()
        #endif
    }
}
