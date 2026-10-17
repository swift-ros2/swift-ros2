// crcl-graph-loopback — topic graph gate on the RCL backend.
//
// One process, two rcl contexts on one domain. The publisher context runs node
// `graph_pub` in `/graph_ns` with
//
//   /graph_ns/map   std_msgs/msg/String  reliable, transient-local (.latched)
//   /graph_ns/scan  sensor_msgs/msg/Imu  best effort, volatile (.sensorData)
//   a Fibonacci action server `fibonacci` (its hidden
//   /graph_ns/fibonacci/_action/feedback and /_action/status topics)
//
// (the types are ones the test fixtures carry and the RCL registry bundles).
// The observer context creates no node of its own: its topicGraph() calls go
// through the session's internal graph node, the context's only node. The
// observer polls until every expected topic is listed, then asserts the names,
// ROS types, QoS and owning node, that the hidden action topics are listed, and
// that the graph node owns no publisher. Whether /rosout and /parameter_events
// appear is printed, not asserted. Then the publisher context shuts down and
// the observer polls until its topics are gone.
//
// CRCL_ZENOH_LOCATOR runs the same gate over .zenoh(locator:) (the zenoh rmw
// variant rejects .rcl), against a router ci-rcl starts.
//
// On success prints "crcl_graph_loopback OK: …" + flush, then exits 0. ci-rcl
// bounds the run with SIGALRM and decides success on the OK line, like the
// other crcl loopbacks.

import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2TestFixtures

// Last-resort bound: discovery (15 s) + removal (15 s) budgets plus ASan
// slowdown, under ci-rcl's outer bound.
alarm(120)

func fail(_ reason: String) -> Never {
    print("crcl_graph_loopback FAIL: \(reason)")
    fflush(stdout)
    exit(1)
}

/// Accepts every goal and returns at once; only its topics matter here.
actor GraphFibonacciHandler: ActionServerHandler {
    typealias Action = FibonacciAction

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }
    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .accept }
    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
        FibonacciAction.Result(sequence: [0, 1])
    }
}

// Domain 82: kept apart from the other loopbacks and from every test, so a
// stray process on a shared runner cannot add topics to /graph_ns.
let transport: TransportConfig =
    ProcessInfo.processInfo.environment["CRCL_ZENOH_LOCATOR"].map { .zenoh(locator: $0, domainId: 82) }
    ?? .rcl(domainId: 82)

let publisherContext: ROS2Context
let observer: ROS2Context
do {
    publisherContext = try await ROS2Context(transport: transport)
    observer = try await ROS2Context(transport: transport)
} catch {
    fail("ROS2Context creation threw: \(error)")
}

// Read the graph before anything is published: the first call creates the
// observer's graph node, and an early result may be empty.
do {
    _ = try await observer.topicGraph()
} catch {
    fail("the first topicGraph() threw: \(error)")
}

let node: ROS2Node
let mapPublisher: ROS2Publisher<SwiftROS2TestFixtures.StringMsg>
let scanPublisher: ROS2Publisher<Imu>
do {
    node = try await publisherContext.createNode(name: "graph_pub", namespace: "/graph_ns")
    mapPublisher = try await node.createPublisher(SwiftROS2TestFixtures.StringMsg.self, topic: "map", qos: .latched)
    scanPublisher = try await node.createPublisher(Imu.self, topic: "scan", qos: .sensorData)
    _ = try await node.createActionServer(
        FibonacciAction.self, name: "fibonacci", handler: GraphFibonacciHandler())
    try mapPublisher.publish(SwiftROS2TestFixtures.StringMsg(data: "map"))
} catch {
    fail("creating the publishers threw: \(error)")
}

let mapTopic = "/graph_ns/map"
let scanTopic = "/graph_ns/scan"
let feedbackTopic = "/graph_ns/fibonacci/_action/feedback"
let statusTopic = "/graph_ns/fibonacci/_action/status"
let expectedTopics: Set<String> = [mapTopic, scanTopic, feedbackTopic, statusTopic]

func pollGraph(until done: ([TopicInfo]) -> Bool, budget: Duration) async -> [TopicInfo]? {
    let deadline = ContinuousClock.now + budget
    var last: [TopicInfo] = []
    while ContinuousClock.now < deadline {
        do {
            last = try await observer.topicGraph()
        } catch {
            fail("topicGraph() threw while polling: \(error)")
        }
        if done(last) { return last }
        try? await Task.sleep(for: .milliseconds(100))
    }
    print("last graph: \(last)")
    return nil
}

/// The graph_pub publishers the observer has attributed. A publisher listed
/// before its node's discovery record arrived carries the unknown strings, so
/// polling waits for the attribution too.
func attributed(_ graph: [TopicInfo]) -> Set<String> {
    Set(
        graph.filter { info in
            info.publishers.contains { $0.nodeName == "graph_pub" && $0.nodeNamespace == "/graph_ns" }
        }.map(\.name))
}

guard
    let graph = await pollGraph(
        until: { attributed($0).isSuperset(of: expectedTopics) }, budget: .seconds(15))
else {
    fail("the observer did not list every graph_pub topic within 15 s")
}

func topic(_ name: String) -> TopicInfo {
    guard let info = graph.first(where: { $0.name == name }) else { fail("\(name) is not listed") }
    return info
}

func expect(_ name: String, type: String, _ qos: EndpointQoS) {
    let info = topic(name)
    guard info.typeName == type else { fail("\(name) has type \(info.typeName), expected \(type)") }
    guard info.publishers == [qos] else { fail("\(name) publishers are \(info.publishers), expected [\(qos)]") }
}

expect(
    mapTopic, type: "std_msgs/msg/String",
    EndpointQoS(reliability: .reliable, durability: .transientLocal, nodeName: "graph_pub", nodeNamespace: "/graph_ns"))
expect(
    scanTopic, type: "sensor_msgs/msg/Imu",
    EndpointQoS(reliability: .bestEffort, durability: .volatile, nodeName: "graph_pub", nodeNamespace: "/graph_ns"))
// rcl_action's status topic is reliable and transient-local.
expect(
    statusTopic, type: "action_msgs/msg/GoalStatusArray",
    EndpointQoS(reliability: .reliable, durability: .transientLocal, nodeName: "graph_pub", nodeNamespace: "/graph_ns"))
let feedback = topic(feedbackTopic)
guard feedback.typeName == "example_interfaces/action/Fibonacci_FeedbackMessage" else {
    fail("\(feedbackTopic) has type \(feedback.typeName)")
}
guard feedback.publishers.map(\.nodeName) == ["graph_pub"] else {
    fail("\(feedbackTopic) publishers are \(feedback.publishers)")
}
guard graph == graph.sorted(by: { ($0.name, $0.typeName) < ($1.name, $1.typeName) }) else {
    fail("the graph is not sorted by name and type")
}
guard !graph.contains(where: { $0.publishers.contains { $0.nodeName == "_swift_ros2_graph" } }) else {
    fail("the internal graph node owns a publisher")
}

func owners(_ name: String) -> String {
    guard let info = graph.first(where: { $0.name == name }) else { return "not listed" }
    return info.publishers.map { "\($0.nodeNamespace)|\($0.nodeName)" }.joined(separator: ",")
}
print("graph: \(graph.count) topics; /rosout: \(owners("/rosout")); /parameter_events: \(owners("/parameter_events"))")

withExtendedLifetime((mapPublisher, scanPublisher)) {}
await publisherContext.shutdown()

// Every name, attributed or not: a closed context disposes its endpoints.
guard
    await pollGraph(
        until: { Set($0.map(\.name)).isDisjoint(with: expectedTopics) }, budget: .seconds(15)) != nil
else {
    fail("graph_pub's topics were still listed 15 s after its context shut down")
}

print("crcl_graph_loopback OK: \(expectedTopics.count) topics with QoS and node, removed after shutdown")
fflush(stdout)

// Best-effort teardown after the OK line, as in the other crcl loopbacks.
await observer.shutdown()
exit(0)
