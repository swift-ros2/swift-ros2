import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2TestSupport
import XCTest

/// `ROS2Context.topicGraph()` over wire Zenoh through a real router: a second context
/// sees the first context's publishers, with their QoS, node and ROS type, including an
/// action server's hidden feedback and status topics.
///
/// Requires `ZENOH_ROUTER` (for example `tcp/127.0.0.1:7447`). Skips otherwise. Runs on
/// domain 73, which no other test uses, so the graph holds only this test's publishers.
final class ZenohTopicGraphIntegrationTests: XCTestCase {
    private static let domainId = 73

    private actor IdleFibonacciServer: ActionServerHandler {
        typealias Action = FibonacciAction
        func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .reject }
        func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .reject }
        func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
            FibonacciAction.Result(sequence: [])
        }
    }

    func testSecondContextSeesPublishersWithQoSNodeAndType() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        let transport = TransportConfig.zenoh(locator: router, domainId: Self.domainId)
        let pubCtx = try await ROS2Context(transport: transport, distro: .jazzy)
        let observerCtx = try await ROS2Context(transport: transport, distro: .jazzy)
        let node = try await pubCtx.createNode(
            name: "pub_node", namespace: "/gt", options: ROS2NodeOptions(startParameterServices: false))

        let reliable = try await node.createPublisher(StringMsg.self, topic: "chatter", qos: .reliableSensor)
        let latched = try await node.createPublisher(GoalStatusArray.self, topic: "status_latched", qos: .latched)
        let bestEffort = try await node.createPublisher(StringMsg.self, topic: "chatter_be")
        let server = try await node.createActionServer(
            FibonacciAction.self, name: "fibonacci", handler: IdleFibonacciServer())

        func publisher(
            _ reliability: QoSProfile.Reliability, _ durability: QoSProfile.Durability
        ) -> [EndpointQoS] {
            [EndpointQoS(reliability: reliability, durability: durability, nodeName: "pub_node", nodeNamespace: "/gt")]
        }
        let expected = [
            TopicInfo(
                name: "/gt/chatter", typeName: StringMsg.typeInfo.typeName, publishers: publisher(.reliable, .volatile)),
            TopicInfo(
                name: "/gt/chatter_be", typeName: StringMsg.typeInfo.typeName,
                publishers: publisher(.bestEffort, .volatile)),
            TopicInfo(
                name: "/gt/fibonacci/_action/feedback", typeName: "example_interfaces/action/Fibonacci_FeedbackMessage",
                publishers: publisher(.reliable, .volatile)),
            TopicInfo(
                name: "/gt/fibonacci/_action/status", typeName: "action_msgs/msg/GoalStatusArray",
                publishers: publisher(.reliable, .transientLocal)),
            TopicInfo(
                name: "/gt/status_latched", typeName: "action_msgs/msg/GoalStatusArray",
                publishers: publisher(.reliable, .transientLocal)),
        ]

        // The router learns the tokens asynchronously: poll.
        var seen: [TopicInfo] = []
        await waitUntil("the observer's graph lists the publishers") {
            seen = (try? await observerCtx.topicGraph()) ?? []
            return seen == expected
        }
        XCTAssertEqual(seen, expected)

        // The publishing context lists its own publishers too.
        let own = try await pubCtx.topicGraph()
        XCTAssertEqual(own, expected)

        // A shut-down context's publishers leave the graph; its own call fails.
        _ = (reliable, latched, bestEffort, server)
        await pubCtx.shutdown()
        await waitUntil("the publishers leave the graph") {
            ((try? await observerCtx.topicGraph()) ?? expected).isEmpty
        }
        do {
            _ = try await pubCtx.topicGraph()
            XCTFail("expected notConnected after shutdown")
        } catch TransportError.notConnected {}
        await observerCtx.shutdown()
    }
}
