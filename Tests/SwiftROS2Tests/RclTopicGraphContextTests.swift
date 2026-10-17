import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

/// `ROS2Context.topicGraph()` on an RCL session: the session takes part in the topic
/// graph (no `.unsupportedFeature`), rmw's QoS values reach the public enums, and the
/// umbrella groups and sorts as on every transport. Backed by the recording rcl seam
/// (no xcframework), so it runs in ordinary CI; the live half is crcl-graph-loopback.
final class RclTopicGraphContextTests: XCTestCase {
    func testTopicGraphOnRclGroupsAndMapsRmwQoS() async throws {
        let seam = RecordingRclSeamClient()
        seam.graphRecords = [
            // rmw values: reliability 1 reliable, 2 best effort, 0 system default;
            // durability 1 transient local, 2 volatile, 3 unknown.
            RclGraphPublisherRecord(
                topicName: "/graph_ns/scan", typeName: "sensor_msgs/msg/LaserScan", reliability: 2,
                durability: 2, nodeName: "graph_pub", nodeNamespace: "/graph_ns"),
            RclGraphPublisherRecord(
                topicName: "/graph_ns/map", typeName: "nav_msgs/msg/OccupancyGrid", reliability: 1,
                durability: 1, nodeName: "graph_pub", nodeNamespace: "/graph_ns"),
            RclGraphPublisherRecord(
                topicName: "/graph_ns/map", typeName: "nav_msgs/msg/OccupancyGrid", reliability: 0,
                durability: 3, nodeName: "_NODE_NAME_UNKNOWN_", nodeNamespace: "_NODE_NAMESPACE_UNKNOWN_"),
        ]
        let ctx = try await ROS2Context(
            transport: .rcl(domainId: 0), session: RclTransportSession(client: seam))
        defer { Task { await ctx.shutdown() } }

        let graph = try await ctx.topicGraph()

        XCTAssertEqual(
            graph,
            [
                TopicInfo(
                    name: "/graph_ns/map", typeName: "nav_msgs/msg/OccupancyGrid",
                    publishers: [
                        EndpointQoS(
                            reliability: .reliable, durability: .transientLocal, nodeName: "graph_pub",
                            nodeNamespace: "/graph_ns"),
                        EndpointQoS(
                            reliability: .bestEffort, durability: .volatile, nodeName: "_NODE_NAME_UNKNOWN_",
                            nodeNamespace: "_NODE_NAMESPACE_UNKNOWN_"),
                    ]),
                TopicInfo(
                    name: "/graph_ns/scan", typeName: "sensor_msgs/msg/LaserScan",
                    publishers: [
                        EndpointQoS(
                            reliability: .bestEffort, durability: .volatile, nodeName: "graph_pub",
                            nodeNamespace: "/graph_ns")
                    ]),
            ])
        XCTAssertEqual(seam.nodesCreated, ["/_swift_ros2_graph"])
    }

    func testTopicGraphAfterShutdownIsNotConnected() async throws {
        let seam = RecordingRclSeamClient()
        let ctx = try await ROS2Context(
            transport: .rcl(domainId: 0), session: RclTransportSession(client: seam))
        _ = try await ctx.topicGraph()
        await ctx.shutdown()

        do {
            _ = try await ctx.topicGraph()
            XCTFail("expected notConnected")
        } catch TransportError.notConnected {
        }
    }
}
