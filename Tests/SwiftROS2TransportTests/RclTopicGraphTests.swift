import Foundation
import XCTest

@testable import SwiftROS2Transport

/// The topic graph of an RCL session over `MockRclClient`: rmw QoS values mapped to
/// the graph's reliability and durability, the internal graph node and its lifetime,
/// and the serial graph queue.
final class RclTopicGraphTests: XCTestCase {
    // rmw_qos_reliability_policy_e / rmw_qos_durability_policy_e values.
    private static let systemDefault: Int32 = 0
    private static let reliable: Int32 = 1
    private static let bestEffort: Int32 = 2
    private static let unknown: Int32 = 3
    private static let bestAvailable: Int32 = 4
    private static let transientLocal: Int32 = 1
    private static let volatile: Int32 = 2

    private func openSession(_ client: MockRclClient) async throws -> RclTransportSession {
        let session = RclTransportSession(client: client)
        try await session.open(config: .rcl(domainId: 0))
        return session
    }

    private func record(
        _ topic: String, type: String = "std_msgs/msg/String", reliability: Int32 = reliable,
        durability: Int32 = volatile, node: String = "talker", namespace: String = "/"
    ) -> RclGraphPublisherRecord {
        RclGraphPublisherRecord(
            topicName: topic, typeName: type, reliability: reliability, durability: durability,
            nodeName: node, nodeNamespace: namespace)
    }

    func testRmwConstantsMatchTheRmwEnums() {
        XCTAssertEqual(RclGraphPublisherRecord.rmwReliabilityReliable, Self.reliable)
        XCTAssertEqual(RclGraphPublisherRecord.rmwDurabilityTransientLocal, Self.transientLocal)
    }

    func testOnlyReliableReadsAsReliable() async throws {
        let client = MockRclClient()
        client.graphRecords = [
            Self.systemDefault, Self.reliable, Self.bestEffort, Self.unknown, Self.bestAvailable, 99, -1,
        ].map { record("/r\($0)", reliability: $0) }
        let session = try await openSession(client)

        let endpoints = try await session.publisherEndpoints()

        let reliability = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.topicName, $0.reliability) })
        XCTAssertEqual(
            reliability,
            [
                "/r0": .bestEffort, "/r1": .reliable, "/r2": .bestEffort, "/r3": .bestEffort, "/r4": .bestEffort,
                "/r99": .bestEffort, "/r-1": .bestEffort,
            ])
    }

    func testOnlyTransientLocalReadsAsTransientLocal() async throws {
        let client = MockRclClient()
        client.graphRecords = [
            Self.systemDefault, Self.transientLocal, Self.volatile, Self.unknown, Self.bestAvailable, 99,
        ].map { record("/d\($0)", durability: $0) }
        let session = try await openSession(client)

        let endpoints = try await session.publisherEndpoints()

        let durability = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.topicName, $0.durability) })
        XCTAssertEqual(
            durability,
            [
                "/d0": .volatile, "/d1": .transientLocal, "/d2": .volatile, "/d3": .volatile, "/d4": .volatile,
                "/d99": .volatile,
            ])
    }

    func testNamesTypesAndNodesPassThroughInOrder() async throws {
        let client = MockRclClient()
        client.graphRecords = [
            record(
                "/graph_ns/map", type: "nav_msgs/msg/OccupancyGrid", durability: Self.transientLocal,
                node: "graph_pub", namespace: "/graph_ns"),
            record(
                "/fibonacci/_action/feedback", type: "example_interfaces/action/Fibonacci_FeedbackMessage",
                node: "graph_pub", namespace: "/graph_ns"),
            // Two types on one name are two endpoints; the umbrella groups them apart.
            record("/chatter", type: "std_msgs/msg/String"),
            record("/chatter", type: "std_msgs/msg/Int32"),
            // rmw's strings for a writer it cannot attribute are kept as they are.
            record(
                "/raw", reliability: Self.bestEffort, node: GraphPublisherEndpoint.unknownNodeName,
                namespace: GraphPublisherEndpoint.unknownNodeNamespace),
        ]
        let session = try await openSession(client)

        let endpoints = try await session.publisherEndpoints()

        XCTAssertEqual(
            endpoints,
            [
                GraphPublisherEndpoint(
                    topicName: "/graph_ns/map", typeName: "nav_msgs/msg/OccupancyGrid", reliability: .reliable,
                    durability: .transientLocal, nodeName: "graph_pub", nodeNamespace: "/graph_ns"),
                GraphPublisherEndpoint(
                    topicName: "/fibonacci/_action/feedback",
                    typeName: "example_interfaces/action/Fibonacci_FeedbackMessage", reliability: .reliable,
                    durability: .volatile, nodeName: "graph_pub", nodeNamespace: "/graph_ns"),
                GraphPublisherEndpoint(
                    topicName: "/chatter", typeName: "std_msgs/msg/String", reliability: .reliable,
                    durability: .volatile, nodeName: "talker", nodeNamespace: "/"),
                GraphPublisherEndpoint(
                    topicName: "/chatter", typeName: "std_msgs/msg/Int32", reliability: .reliable,
                    durability: .volatile, nodeName: "talker", nodeNamespace: "/"),
                GraphPublisherEndpoint(
                    topicName: "/raw", typeName: "std_msgs/msg/String", reliability: .bestEffort,
                    durability: .volatile, nodeName: "_NODE_NAME_UNKNOWN_",
                    nodeNamespace: "_NODE_NAMESPACE_UNKNOWN_"),
            ])
    }

    func testFirstCallCreatesOneGraphNodeAndLaterCallsReuseIt() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        XCTAssertTrue(client.nodesCreated.isEmpty, "open() must not create the graph node")

        _ = try await session.publisherEndpoints()
        _ = try await session.publisherEndpoints()

        XCTAssertEqual(client.nodesCreated.map(\.name), ["_swift_ros2_graph"])
        XCTAssertEqual(client.nodesCreated.map(\.namespace), ["/"])
        let graphNode = try XCTUnwrap(client.nodeHandles.first)
        XCTAssertEqual(client.graphQueryNodes.count, 2)
        XCTAssertTrue(client.graphQueryNodes.allSatisfy { $0 === graphNode })
    }

    func testEntitiesNeverBindToTheGraphNode() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        try session.registerNode(name: "imu_node", namespace: "/ios")
        _ = try await session.publisherEndpoints()

        // The unnamed path falls back to the last-registered node: the user's, not the graph node.
        let publisher = try session.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)

        let userNode = try XCTUnwrap(client.nodeHandles.first { $0.name == "imu_node" })
        XCTAssertTrue(publisher.isActive)
        XCTAssertTrue(client.publisherHandles.first?.node === userNode)
    }

    func testCloseDestroysTheGraphNodeBeforeTheContext() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        try session.registerNode(name: "imu_node", namespace: "/ios")
        _ = try await session.publisherEndpoints()

        try session.close()

        let events = client.teardownEvents
        let graphIndex = try XCTUnwrap(events.firstIndex(of: "node:_swift_ros2_graph"))
        let contextIndex = try XCTUnwrap(events.firstIndex(of: "context"))
        XCTAssertLessThan(graphIndex, contextIndex)
        XCTAssertEqual(events.filter { $0 == "node:_swift_ros2_graph" }.count, 1)
    }

    func testCloseWithoutASnapshotCreatesNoGraphNode() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)

        try session.close()

        XCTAssertFalse(client.teardownEvents.contains("node:_swift_ros2_graph"))
    }

    func testNotConnectedBeforeOpenAndAfterClose() async throws {
        let client = MockRclClient()
        let session = RclTransportSession(client: client)
        await assertNotConnected(session)

        try await session.open(config: .rcl(domainId: 0))
        _ = try await session.publisherEndpoints()
        try session.close()

        await assertNotConnected(session)
        XCTAssertEqual(client.nodesCreated.count, 1, "a closed session must not create a graph node again")
    }

    func testReopenedSessionCreatesAFreshGraphNode() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        _ = try await session.publisherEndpoints()
        try session.close()

        try await session.open(config: .rcl(domainId: 0))
        _ = try await session.publisherEndpoints()

        XCTAssertEqual(client.nodesCreated.map(\.name), ["_swift_ros2_graph", "_swift_ros2_graph"])
        XCTAssertTrue(client.graphQueryNodes.last === client.nodeHandles.last)
    }

    func testGraphNodeCreationFailureIsSessionUnhealthyAndRetried() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        client.createNodeShouldThrow = .connectionFailed("rcl_node_init failed")

        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected sessionUnhealthy")
        } catch TransportError.sessionUnhealthy(let message) {
            XCTAssertTrue(message.contains("graph node"), message)
        }

        client.createNodeShouldThrow = nil
        _ = try await session.publisherEndpoints()
        XCTAssertEqual(client.nodesCreated.map(\.name), ["_swift_ros2_graph"])
    }

    func testClientTransportErrorPassesThrough() async throws {
        let client = MockRclClient()
        client.graphPublishersShouldThrow = TransportError.sessionUnhealthy("rcl graph query failed: boom")
        let session = try await openSession(client)

        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected sessionUnhealthy")
        } catch TransportError.sessionUnhealthy(let message) {
            XCTAssertEqual(message, "rcl graph query failed: boom")
        }
    }

    func testOtherClientErrorsMapToSessionUnhealthy() async throws {
        struct Boom: Error {}
        let client = MockRclClient()
        client.graphPublishersShouldThrow = Boom()
        let session = try await openSession(client)

        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected sessionUnhealthy")
        } catch let error as TransportError {
            guard case .sessionUnhealthy = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(error.isRecoverable)
        }
    }

    func testCloseWaitsForASnapshotInFlight() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        client.onGraphPublishers = {
            entered.signal()
            release.wait()
        }
        let snapshot = Task { try await session.publisherEndpoints() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? session.close()
            closed.signal()
        }
        // close() marks the session closed at once but must not destroy the graph node or
        // the context under the running snapshot.
        XCTAssertEqual(closed.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertFalse(session.isConnected)
        XCTAssertFalse(client.teardownEvents.contains("node:_swift_ros2_graph"))
        XCTAssertFalse(client.teardownEvents.contains("context"))

        release.signal()
        XCTAssertEqual(closed.wait(timeout: .now() + 5), .success)
        _ = try await snapshot.value
        let events = client.teardownEvents
        let graphIndex = try XCTUnwrap(events.firstIndex(of: "node:_swift_ros2_graph"))
        let contextIndex = try XCTUnwrap(events.firstIndex(of: "context"))
        XCTAssertLessThan(graphIndex, contextIndex)
    }

    func testSnapshotsNeverOverlap() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        let probe = OverlapProbe()
        client.onGraphPublishers = {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.005)
            probe.exit()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { _ = try await session.publisherEndpoints() }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(probe.maxRunning, 1)
        XCTAssertEqual(client.graphQueryNodes.count, 16)
        XCTAssertEqual(client.nodesCreated.count, 1)
    }

    func testSnapshotRunsOffTheCallersThreadOnTheGraphQueue() async throws {
        let client = MockRclClient()
        let session = try await openSession(client)
        let key = DispatchSpecificKey<String>()
        session.graphQueue.setSpecific(key: key, value: "graph")
        let label = LabelBox()
        client.onGraphPublishers = {
            label.value = DispatchQueue.getSpecific(key: key)
        }

        _ = try await session.publisherEndpoints()

        XCTAssertEqual(label.value, "graph")
        XCTAssertEqual(session.graphQueue.label, "swift-ros2.graph.rcl")
    }

    private func assertNotConnected(
        _ session: RclTransportSession, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected notConnected", file: file, line: line)
        } catch TransportError.notConnected {
        } catch {
            XCTFail("got \(error)", file: file, line: line)
        }
    }
}

private final class LabelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

private final class OverlapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var _maxRunning = 0

    func enter() {
        lock.lock()
        running += 1
        _maxRunning = max(_maxRunning, running)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        running -= 1
        lock.unlock()
    }

    var maxRunning: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxRunning
    }
}
