import SwiftROS2
import XCTest

/// 2.0.0: the wire clients are an implementation detail. This file holds the
/// MIGRATION.md "1.x -> 2.0" connectivity-probe recipe — the replacement for a
/// 1.x `ZenohClient` open / close probe — written against the `SwiftROS2`
/// umbrella, imported without `@testable`.
///
/// What it proves: the recipe compiles against the umbrella (it is never run: the probe would
/// need a router). What it cannot prove: that the umbrella API
/// stays `public`. `package` declarations are visible to every module of this
/// package, test targets included, so a demotion of umbrella API would still
/// compile here. The public-surface lock is the API-breakage gate
/// (`Scripts/diagnose-api-breaking-changes.sh` against the previous tag) plus
/// the release checklist's external consumer smoke. The gate catches removals
/// and signature changes, but SwiftPM's ABI digest also lists `package`
/// declarations, so a `public` -> `package` flip only shows up in the
/// external consumer smoke.
final class PublicSurfaceTests: XCTestCase {
    func testConnectivityProbeRecipeCompiles() {
        // Mirrors the MIGRATION "1.x -> 2.0" recipe; compile-only.
        let probe: () async throws -> Void = {
            let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/127.0.0.1:1"))
            _ = ctx.isConnected
            _ = ctx.sessionId
            await ctx.shutdown()
        }
        _ = probe
    }

    /// 3.1: the delivery modes and the two `createSubscription` overloads that take them;
    /// compile-only. A call without `delivery:` still resolves to the 3.0 method.
    func testSubscriptionDeliveryOverloadsCompile() {
        let subscribe: (ROS2Node) async throws -> Void = { node in
            let modes: [SubscriptionDelivery] = [.stream, .latestOnly]
            let plain: ROS2Subscription<GoalStatusArray> = try await node.createSubscription(
                GoalStatusArray.self, topic: "plain")
            let latest = try await node.createSubscription(
                GoalStatusArray.self, topic: "latest", qos: .sensorData, delivery: modes[1])
            let withHandler = try await node.createSubscription(
                GoalStatusArray.self, topic: "handled", qos: .latched, delivery: .stream
            ) { status in
                _ = status.statusList
            }
            latest.onMessage { _ in }
            for sub in [plain, latest, withHandler] { sub.cancel() }
        }
        _ = subscribe
    }

    func testUmbrellaReexportsRosidl() throws {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try Time(sec: 1, nanosec: 2).encode(to: encoder)
        XCTAssertFalse(ROS2Distro.jazzy.isLegacySchema)
        XCTAssertEqual(GoalStatusArray.typeInfo.typeName, "action_msgs/msg/GoalStatusArray")
        XCTAssertEqual(ParameterValue.typeInfo.typeName, "rcl_interfaces/msg/ParameterValue")
        XCTAssertEqual(UniqueIdentifierUUID().uuid.count, 16)
    }

    /// 3.1: the topic graph, its result types and their public initializers; compile-only.
    func testTopicGraphSurfaceCompiles() {
        let read: (ROS2Context) async throws -> Void = { ctx in
            let graph: [TopicInfo] = try await ctx.topicGraph()
            for topic in graph {
                let qos: [EndpointQoS] = topic.publishers
                _ = (
                    topic.name, topic.typeName,
                    qos.map { ($0.reliability, $0.durability, $0.nodeName, $0.nodeNamespace) }
                )
            }
            let built = TopicInfo(
                name: "/map", typeName: "nav_msgs/msg/OccupancyGrid",
                publishers: [
                    EndpointQoS(
                        reliability: .reliable, durability: .transientLocal, nodeName: "map_server", nodeNamespace: "/")
                ])
            _ = graph.contains(built)
        }
        _ = read
    }
}
