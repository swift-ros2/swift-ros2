import SwiftROS2
import SwiftROS2Transport
import XCTest

/// `ROS2Context.topicGraph()`: the umbrella groups a session's publishers by topic name
/// and type and sorts them, the same way for every transport.
final class TopicGraphTests: XCTestCase {
    private func endpoint(
        _ topic: String, type: String = "std_msgs/msg/String",
        _ reliability: TransportQoS.Reliability = .reliable, _ durability: TransportQoS.Durability = .volatile,
        node: String = "talker", namespace: String = "/"
    ) -> GraphPublisherEndpoint {
        GraphPublisherEndpoint(
            topicName: topic, typeName: type, reliability: reliability, durability: durability, nodeName: node,
            nodeNamespace: namespace)
    }

    private func context(_ session: MockTransportSession) async throws -> ROS2Context {
        try await ROS2Context(transport: .zenoh(locator: "tcp/m:7447"), session: session)
    }

    func testGroupsByNameAndTypeAndSorts() async throws {
        let session = MockTopicGraphSession()
        session.endpoints = [
            endpoint("/scan", type: "sensor_msgs/msg/LaserScan", .bestEffort, node: "lidar", namespace: "/b"),
            endpoint("/map", type: "nav_msgs/msg/OccupancyGrid", .reliable, .transientLocal, node: "map_server"),
            endpoint("/scan", type: "sensor_msgs/msg/LaserScan", .reliable, node: "lidar", namespace: "/a"),
            endpoint("/chatter", node: "z_talker"),
            endpoint("/chatter", node: "talker", namespace: "/ns"),
            endpoint("/chatter", .bestEffort, .transientLocal, node: "talker"),
            endpoint("/chatter", .bestEffort, .volatile, node: "talker"),
            endpoint("/chatter", .reliable, .transientLocal, node: "talker"),
            // A second publisher with the same node and QoS is kept.
            endpoint("/chatter", .reliable, .transientLocal, node: "talker"),
        ]
        let ctx = try await context(session)

        let graph = try await ctx.topicGraph()

        XCTAssertEqual(
            graph,
            [
                TopicInfo(
                    name: "/chatter", typeName: "std_msgs/msg/String",
                    publishers: [
                        EndpointQoS(
                            reliability: .reliable, durability: .transientLocal, nodeName: "talker", nodeNamespace: "/"),
                        EndpointQoS(
                            reliability: .reliable, durability: .transientLocal, nodeName: "talker", nodeNamespace: "/"),
                        EndpointQoS(
                            reliability: .bestEffort, durability: .volatile, nodeName: "talker", nodeNamespace: "/"),
                        EndpointQoS(
                            reliability: .bestEffort, durability: .transientLocal, nodeName: "talker",
                            nodeNamespace: "/"),
                        EndpointQoS(
                            reliability: .reliable, durability: .volatile, nodeName: "z_talker", nodeNamespace: "/"),
                        EndpointQoS(
                            reliability: .reliable, durability: .volatile, nodeName: "talker", nodeNamespace: "/ns"),
                    ]),
                TopicInfo(
                    name: "/map", typeName: "nav_msgs/msg/OccupancyGrid",
                    publishers: [
                        EndpointQoS(
                            reliability: .reliable, durability: .transientLocal, nodeName: "map_server",
                            nodeNamespace: "/")
                    ]),
                TopicInfo(
                    name: "/scan", typeName: "sensor_msgs/msg/LaserScan",
                    publishers: [
                        EndpointQoS(
                            reliability: .reliable, durability: .volatile, nodeName: "lidar", nodeNamespace: "/a"),
                        EndpointQoS(
                            reliability: .bestEffort, durability: .volatile, nodeName: "lidar", nodeNamespace: "/b"),
                    ]),
            ])
        await ctx.shutdown()
    }

    /// A name published with two types gives two entries, sorted by type.
    func testTwoTypesOnOneNameGiveTwoEntries() async throws {
        let session = MockTopicGraphSession()
        session.endpoints = [
            endpoint("/data", type: "std_msgs/msg/String", node: "b"),
            endpoint("/data", type: "std_msgs/msg/Int32", node: "a"),
        ]
        let ctx = try await context(session)

        let graph = try await ctx.topicGraph()

        XCTAssertEqual(graph.map(\.name), ["/data", "/data"])
        XCTAssertEqual(graph.map(\.typeName), ["std_msgs/msg/Int32", "std_msgs/msg/String"])
        XCTAssertEqual(graph.map { $0.publishers.map(\.nodeName) }, [["a"], ["b"]])
        await ctx.shutdown()
    }

    func testUnknownNodeStringsAreKept() async throws {
        let session = MockTopicGraphSession()
        session.endpoints = [
            endpoint(
                "/rt", node: GraphPublisherEndpoint.unknownNodeName,
                namespace: GraphPublisherEndpoint.unknownNodeNamespace)
        ]
        let ctx = try await context(session)

        let graph = try await ctx.topicGraph()

        XCTAssertEqual(graph.first?.publishers.first?.nodeName, "_NODE_NAME_UNKNOWN_")
        XCTAssertEqual(graph.first?.publishers.first?.nodeNamespace, "_NODE_NAMESPACE_UNKNOWN_")
        await ctx.shutdown()
    }

    func testEmptyGraph() async throws {
        let ctx = try await context(MockTopicGraphSession())
        let graph = try await ctx.topicGraph()
        XCTAssertEqual(graph, [])
        await ctx.shutdown()
    }

    func testSessionErrorsPassThrough() async throws {
        let session = MockTopicGraphSession()
        let ctx = try await context(session)
        for error in [TransportError.sessionUnhealthy("slow router"), .notConnected] {
            session.graphError = error
            do {
                _ = try await ctx.topicGraph()
                XCTFail("expected \(error)")
            } catch let thrown as TransportError {
                XCTAssertEqual(thrown.errorDescription, error.errorDescription)
            }
        }
        XCTAssertEqual(session.graphCalls, 2)
        await ctx.shutdown()
    }

    func testSessionWithoutGraphSupportThrowsUnsupportedFeature() async throws {
        let ctx = try await context(MockTransportSession())
        do {
            _ = try await ctx.topicGraph()
            XCTFail("expected unsupportedFeature")
        } catch TransportError.unsupportedFeature(let feature) {
            XCTAssertEqual(feature, "topic graph")
        }
        await ctx.shutdown()
    }

    func testPublicInitializersAndEquality() {
        let qos = EndpointQoS(reliability: .reliable, durability: .volatile, nodeName: "n", nodeNamespace: "/")
        XCTAssertEqual(
            qos, EndpointQoS(reliability: .reliable, durability: .volatile, nodeName: "n", nodeNamespace: "/"))
        XCTAssertNotEqual(
            qos, EndpointQoS(reliability: .bestEffort, durability: .volatile, nodeName: "n", nodeNamespace: "/"))
        let topic = TopicInfo(name: "/t", typeName: "std_msgs/msg/String", publishers: [qos])
        XCTAssertEqual(topic, TopicInfo(name: "/t", typeName: "std_msgs/msg/String", publishers: [qos]))
        XCTAssertNotEqual(topic, TopicInfo(name: "/t", typeName: "std_msgs/msg/String", publishers: []))
    }
}
