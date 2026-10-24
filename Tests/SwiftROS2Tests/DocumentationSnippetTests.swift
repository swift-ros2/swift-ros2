import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2TestFixtures
import XCTest

/// The 3.1 snippets of README.md, MIGRATION.md and the DocC articles (Receiving Messages,
/// Discovering Topics, Actions), compile-only: they are never run, since they need a live transport.
/// The fixture `Image` stands in for `nav_msgs/msg/OccupancyGrid` where a snippet subscribes
/// to a map; only the type changes.
final class DocumentationSnippetTests: XCTestCase {
    /// README "Subscription delivery", DocC "Latest-only delivery".
    func testLatestOnlySnippetCompiles() {
        let snippet: (ROS2Node, @escaping @Sendable (Image) -> Void) async throws -> Void = { node, render in
            let camera = try await node.createSubscription(
                Image.self, topic: "camera/image_raw", qos: .sensorData, delivery: .latestOnly
            ) { image in
                render(image)
            }
            camera.cancel()
        }
        _ = snippet
    }

    /// DocC "Stream delivery" and "Attaching the handler at creation".
    func testStreamAndHandlerSnippetsCompile() {
        let snippet: (ROS2Node, @escaping @Sendable ([TransformStamped]) -> Void) async throws -> Void = {
            node, store in
            let sub = try await node.createSubscription(Imu.self, topic: "imu")
            for await imu in sub.messages {
                print(imu.linearAcceleration)
            }
            let staticTransforms = try await node.createSubscription(
                TFMessage.self, topic: "/tf_static", qos: .latched, delivery: .stream
            ) { message in
                store(message.transforms)
            }
            staticTransforms.cancel()
        }
        _ = snippet
    }

    /// README "Topic graph", DocC "Discovering Topics" overview.
    func testTopicGraphListingSnippetsCompile() {
        let snippet: (ROS2Context) async throws -> Void = { context in
            for topic in try await context.topicGraph() {
                let latched = topic.publishers.allSatisfy { $0.durability == .transientLocal }
                print(topic.name, topic.typeName, topic.publishers.count, latched ? "latched" : "")
            }
            for topic in try await context.topicGraph() {
                print(topic.name, topic.typeName)
                for publisher in topic.publishers {
                    print(
                        "  \(publisher.nodeNamespace) \(publisher.nodeName)",
                        publisher.reliability, publisher.durability)
                }
            }
        }
        _ = snippet
    }

    /// DocC "Choosing a subscriber QoS" and the MIGRATION "3.0 → 3.1" recipe.
    func testSubscriberQoSFromGraphSnippetCompiles() {
        let snippet: (ROS2Context, ROS2Node, @escaping @Sendable (Image) -> Void) async throws -> Void = {
            context, node, show in
            let ownNamespace = "/viewer"
            let graph = try await context.topicGraph()
            guard
                let map = graph.first(where: { $0.name == "/map" && $0.typeName == "nav_msgs/msg/OccupancyGrid" })
            else { return }

            // Drop this app's own publishers; the graph lists them too.
            let publishers = map.publishers.filter { $0.nodeNamespace != ownNamespace }
            guard !publishers.isEmpty else { return }

            let qos = QoSProfile(
                reliability: publishers.allSatisfy { $0.reliability == .reliable } ? .reliable : .bestEffort,
                durability: publishers.allSatisfy { $0.durability == .transientLocal } ? .transientLocal : .volatile,
                history: .keepLast(1))
            let subscription = try await node.createSubscription(
                Image.self, topic: map.name, qos: qos, delivery: .latestOnly
            ) { grid in
                show(grid)
            }
            subscription.cancel()
        }
        _ = snippet
    }

    /// MIGRATION "3.0 → 3.1": a graph poll that keeps the last good graph on a missed poll.
    func testGraphPollSnippetCompiles() {
        let snippet: (ROS2Context) async throws -> Void = { context in
            var lastGraph: [TopicInfo] = []
            do {
                lastGraph = try await context.topicGraph()
            } catch TransportError.sessionUnhealthy {
                // A missed poll: keep `lastGraph` and try again on the next tick.
            }
            _ = lastGraph
        }
        _ = snippet
    }

    /// DocC "Actions" client side and the MIGRATION "3.0 → 3.1" recipe: the result of a goal
    /// that did not succeed.
    func testActionOutcomeSnippetCompiles() {
        let snippet: (ActionGoalHandle<FibonacciAction>) async throws -> Void = { handle in
            let outcome = try await handle.outcome(timeout: .seconds(30))
            if outcome.status != .succeeded, let result = outcome.result {
                print("Goal \(outcome.status): \(result)")
            }
        }
        _ = snippet
    }
}
