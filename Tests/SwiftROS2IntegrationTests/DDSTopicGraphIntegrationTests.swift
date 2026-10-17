import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2TestSupport
import XCTest

#if canImport(SwiftROS2DDS)
    /// `ROS2Context.topicGraph()` over wire DDS on the loopback: a second context in the
    /// process sees the first context's publishers through CycloneDDS discovery, with
    /// their QoS, node and ROS type, and a late transient-local subscriber gets the latched
    /// sample.
    ///
    /// Runs on domain 78, which no other test uses (and below 101, for the Windows runner).
    /// No RCL test may share it: wire DDS and RCL DDS cannot share a domain in one process
    /// (#296). The assertions only look at this test's namespaces, so a stray participant on
    /// the LAN cannot fail them.
    final class DDSTopicGraphIntegrationTests: XCTestCase {
        private static let domainId = 78

        func testSecondContextSeesPublishersWithQoSNodeAndType() async throws {
            let transport = TransportConfig.ddsMulticast(domainId: Self.domainId)
            let pubCtx = try await ROS2Context(transport: transport, distro: .jazzy)
            let observerCtx = try await ROS2Context(transport: transport, distro: .jazzy)
            try await skipUnlessWireDDS(observerCtx)

            let node = try await pubCtx.createNode(
                name: "talker", namespace: "/dds_graph", options: ROS2NodeOptions(startParameterServices: false))
            let latched = try await node.createPublisher(StringMsg.self, topic: "chatter", qos: .latched)
            let reliable = try await node.createPublisher(
                StringMsg.self, topic: "chatter_reliable", qos: .reliableSensor)
            let bestEffort = try await node.createPublisher(StringMsg.self, topic: "chatter_be")

            func publisher(
                _ reliability: QoSProfile.Reliability, _ durability: QoSProfile.Durability
            ) -> [EndpointQoS] {
                [
                    EndpointQoS(
                        reliability: reliability, durability: durability, nodeName: "talker",
                        nodeNamespace: "/dds_graph")
                ]
            }
            let type = StringMsg.typeInfo.typeName
            let expected = [
                TopicInfo(
                    name: "/dds_graph/chatter", typeName: type, publishers: publisher(.reliable, .transientLocal)),
                TopicInfo(name: "/dds_graph/chatter_be", typeName: type, publishers: publisher(.bestEffort, .volatile)),
                TopicInfo(
                    name: "/dds_graph/chatter_reliable", typeName: type, publishers: publisher(.reliable, .volatile)),
            ]

            // Discovery is asynchronous, even inside one process: poll.
            var seen: [TopicInfo] = []
            await waitUntil("the observer's graph lists the publishers", interval: .milliseconds(100)) {
                seen = Self.ours((try? await observerCtx.topicGraph()) ?? [])
                return seen == expected
            }
            XCTAssertEqual(seen, expected)

            // The publishing context lists its own publishers too.
            let own = Self.ours(try await pubCtx.topicGraph())
            XCTAssertEqual(own, expected)

            // A shut-down context's publishers leave the graph; its own call fails.
            withExtendedLifetime((latched, reliable, bestEffort)) {}
            await pubCtx.shutdown()
            await waitUntil("the publishers leave the graph", interval: .milliseconds(100)) {
                Self.ours((try? await observerCtx.topicGraph()) ?? expected).isEmpty
            }
            do {
                _ = try await pubCtx.topicGraph()
                XCTFail("expected notConnected after shutdown")
            } catch TransportError.notConnected {}
            await observerCtx.shutdown()
        }

        /// A `.latched` publisher publishes once; a context that subscribes later with
        /// `.latched` gets the sample from the writer's transient-local cache.
        func testLateLatchedSubscriberGetsTheSample() async throws {
            let transport = TransportConfig.ddsMulticast(domainId: Self.domainId)
            let pubCtx = try await ROS2Context(transport: transport, distro: .jazzy)
            let subCtx = try await ROS2Context(transport: transport, distro: .jazzy)
            try await skipUnlessWireDDS(subCtx)

            let pubNode = try await pubCtx.createNode(
                name: "map_server", namespace: "/dds_graph_tl", options: ROS2NodeOptions(startParameterServices: false))
            let pub = try await pubNode.createPublisher(StringMsg.self, topic: "map", qos: .latched)
            try pub.publish(StringMsg(data: "latched-map"))

            // The late subscriber's context must have discovered the writer before it
            // subscribes, or the sample would reach it as a live one.
            await waitUntil("the subscriber's context sees the latched writer", interval: .milliseconds(100)) {
                ((try? await subCtx.topicGraph()) ?? []).contains { $0.name == "/dds_graph_tl/map" }
            }

            let subNode = try await subCtx.createNode(
                name: "late_joiner", namespace: "/dds_graph_tl", options: ROS2NodeOptions(startParameterServices: false)
            )
            let sub = try await subNode.createSubscription(StringMsg.self, topic: "map", qos: .latched)
            let received = ReceivedStrings()
            let consumer = Task {
                for await message in sub.messages { await received.append(message.data) }
            }
            await waitUntil("the late subscriber gets the latched sample", interval: .milliseconds(50)) {
                await !received.items.isEmpty
            }
            // The replay during creation is delivered once.
            try await Task.sleep(for: .milliseconds(300))
            let items = await received.items
            XCTAssertEqual(items, ["latched-map"])

            consumer.cancel()
            sub.cancel()
            await subCtx.shutdown()
            await pubCtx.shutdown()
        }

        /// This test's topics: the domain is private, but a participant elsewhere on the
        /// LAN could still publish on it.
        private static func ours(_ graph: [TopicInfo]) -> [TopicInfo] {
            graph.filter { $0.name.hasPrefix("/dds_graph/") }
        }

        /// On Linux RCL builds `.dds` resolves to rcl, whose graph ships separately.
        private func skipUnlessWireDDS(_ context: ROS2Context) async throws {
            do {
                _ = try await context.topicGraph()
            } catch TransportError.unsupportedFeature(let feature) {
                throw XCTSkip("no topic graph on this DDS backend: \(feature)")
            }
        }
    }

    private actor ReceivedStrings {
        private(set) var items: [String] = []
        func append(_ item: String) { items.append(item) }
    }
#endif
