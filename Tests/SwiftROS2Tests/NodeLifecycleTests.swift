import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

final class NodeLifecycleTests: XCTestCase {
    private func makeContext(
        session: MockTransportSession = MockTransportSession()
    ) async throws -> (ROS2Context, MockTransportSession) {
        let config = TransportConfig.zenoh(locator: "tcp/mock:7447")
        // Phase-3 Task 10 auto-registers parameter services on createNode;
        // give the mock an echo dispatcher so that registration succeeds.
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(transport: config, session: session)
        return (ctx, session)
    }

    // MARK: - Node creation

    func testContextWithInjectedSessionSkipsFactory() async throws {
        let (ctx, session) = try await makeContext()
        XCTAssertTrue(ctx.isConnected)
        // The mock starts as already-connected, so open() should not be called.
        XCTAssertEqual(session.openedConfigs.count, 0)
    }

    func testContextOpensSessionWhenNotConnected() async throws {
        let session = MockTransportSession()
        session.isConnected = false
        _ = try await ROS2Context(transport: .zenoh(locator: "tcp/m:7447"), session: session)
        XCTAssertEqual(session.openedConfigs.count, 1)
    }

    func testContextPassesItsDistroAsTheZenohWireMode() async throws {
        let session = MockTransportSession()
        session.isConnected = false
        _ = try await ROS2Context(transport: .zenoh(locator: "tcp/m:7447"), distro: .lyrical, session: session)
        XCTAssertEqual(session.openedConfigs.first?.wireMode, .lyrical)
    }

    func testExplicitZenohWireModeWinsOverTheContextDistro() async throws {
        let session = MockTransportSession()
        session.isConnected = false
        _ = try await ROS2Context(
            transport: .zenoh(locator: "tcp/m:7447", wireMode: .humble), distro: .lyrical, session: session)
        XCTAssertEqual(session.openedConfigs.first?.wireMode, .humble)
    }

    func testCreateNodeReturnsNodeWithFullyQualifiedName() async throws {
        let (ctx, _) = try await makeContext()
        let node = try await ctx.createNode(name: "imu_node", namespace: "/ios")
        XCTAssertEqual(node.name, "imu_node")
        XCTAssertEqual(node.namespace, "/ios")
        XCTAssertEqual(node.fullyQualifiedName, "/ios/imu_node")
    }

    func testCreateNodeWithRootNamespaceUsesSlashJoin() async throws {
        let (ctx, _) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/")
        XCTAssertEqual(node.fullyQualifiedName, "/n")
    }

    // MARK: - Publisher

    func testCreatePublisherForwardsToSession() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        _ = try await node.createPublisher(StringMsg.self, topic: "chatter")

        XCTAssertEqual(session.publishers.count, 1)
        let recorded = session.publishers[0]
        XCTAssertEqual(recorded.topic, "/ns/chatter", "Topic must be namespace-prefixed")
        XCTAssertEqual(recorded.typeName, StringMsg.typeInfo.typeName)
    }

    func testPublishMessageEncodesAndDelegates() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")
        try pub.publish(StringMsg(data: "hello"))

        let recorded = session.publishers[0]
        XCTAssertEqual(recorded.publishedPayloads.count, 1)
        let payload = recorded.publishedPayloads[0]
        XCTAssertGreaterThanOrEqual(payload.data.count, 4, "CDR encapsulation header must be present")
        XCTAssertEqual(payload.sequenceNumber, 0)
    }

    func testPublishIncrementsSequenceNumber() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")
        try pub.publish(StringMsg(data: "a"))
        try pub.publish(StringMsg(data: "b"))
        try pub.publish(StringMsg(data: "c"))

        let seqs = session.publishers[0].publishedPayloads.map { $0.sequenceNumber }
        XCTAssertEqual(seqs, [0, 1, 2])
    }

    func testPublishWithSourceTimestampForwardsTimestampAndSequence() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")

        let sourceTimestamp: UInt64 = 1_700_000_000_123_456_789
        try pub.publish(StringMsg(data: "hello"), timestamp: sourceTimestamp, sequenceNumber: 42)

        let recorded = session.publishers[0]
        XCTAssertEqual(recorded.publishedPayloads.count, 1)
        let payload = recorded.publishedPayloads[0]
        XCTAssertEqual(payload.timestamp, sourceTimestamp, "Caller timestamp must reach the attachment verbatim")
        XCTAssertEqual(payload.sequenceNumber, 42, "Caller sequence number must be used as-is")
        XCTAssertGreaterThanOrEqual(payload.data.count, 4, "CDR encapsulation header must be present")
    }

    func testPublishWithSourceTimestampNilSequenceUsesMonotonicCounter() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")

        // Mixing the timestamp overload (nil sequence) with the plain overload
        // must share the one monotonic counter: 0, 1, 2.
        try pub.publish(StringMsg(data: "a"), timestamp: 100)
        try pub.publish(StringMsg(data: "b"))
        try pub.publish(StringMsg(data: "c"), timestamp: 300)

        let payloads = session.publishers[0].publishedPayloads
        XCTAssertEqual(payloads.map { $0.sequenceNumber }, [0, 1, 2])
        XCTAssertEqual(payloads.map { $0.timestamp }[0], 100)
        XCTAssertEqual(payloads.map { $0.timestamp }[2], 300)
    }

    func testPublisherUsesAbsoluteTopicWhenLeadingSlash() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        _ = try await node.createPublisher(StringMsg.self, topic: "/abs/topic")
        XCTAssertEqual(session.publishers[0].topic, "/abs/topic")
    }

    // MARK: - Subscription

    func testSubscriptionForwardsToSession() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        _ = try await node.createSubscription(StringMsg.self, topic: "chatter")
        XCTAssertEqual(session.subscribers.count, 1)
        XCTAssertEqual(session.subscribers[0].topic, "/ns/chatter")
    }

    func testPublishedMessageIsDeliveredToMatchingSubscription() async throws {
        let (ctx, _) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        let sub = try await node.createSubscription(StringMsg.self, topic: "chatter")
        let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")

        // Start the consumer before publish, then await its first delivery
        // deterministically. Avoids the timing-dependent Task.sleep dance.
        let received = expectation(description: "Receive first subscription message")

        let task = Task { () -> StringMsg? in
            for await msg in sub.messages {
                received.fulfill()
                return msg
            }
            return nil
        }

        try pub.publish(StringMsg(data: "hello world"))

        await fulfillment(of: [received], timeout: 1.0)
        sub.cancel()
        let message = await task.value
        XCTAssertEqual(message?.data, "hello world")
    }

    // MARK: - QoS propagation

    func testQoSProfileFlowsThroughToTransport() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        _ = try await node.createPublisher(
            StringMsg.self,
            topic: "chatter",
            qos: QoSProfile(reliability: .reliable, durability: .transientLocal, history: .keepLast(7))
        )

        let qos = session.publishers[0].qos
        XCTAssertEqual(qos.reliability, .reliable)
        XCTAssertEqual(qos.durability, .transientLocal)
        if case .keepLast(let n) = qos.history {
            XCTAssertEqual(n, 7)
        } else {
            XCTFail("Expected keepLast(7)")
        }
    }

    // MARK: - Shutdown

    func testShutdownClosesSession() async throws {
        let (ctx, session) = try await makeContext()
        await ctx.shutdown()
        XCTAssertEqual(session.closedCount, 1)
    }

    func testShutdownClosesAllPublishers() async throws {
        let (ctx, session) = try await makeContext()
        let node = try await ctx.createNode(name: "n", namespace: "/ns")
        _ = try await node.createPublisher(StringMsg.self, topic: "a")
        _ = try await node.createPublisher(StringMsg.self, topic: "b")

        await ctx.shutdown()
        for pub in session.publishers {
            XCTAssertFalse(pub.isActive)
        }
    }

    func testShutdownClosesAllServicesAndClients() async throws {
        let session = MockTransportSession()
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/m:7447"), session: session)
        let node = try await ctx.createNode(name: "n", namespace: "/ns")

        let service = try await node.createService(TriggerSrv.self, name: "trig") { _ in
            TriggerSrv.Response(success: true, message: "ok")
        }
        let cli = try await node.createClient(TriggerSrv.self, name: "trig")
        XCTAssertTrue(service.isActive)

        await node.destroy()

        XCTAssertFalse(service.isActive, "service should be closed after node.destroy()")
        XCTAssertFalse(cli.isActive, "client should be closed after node.destroy()")
    }

    func testContextShutdownClosesServicesViaNodeDestroy() async throws {
        let session = MockTransportSession()
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/m:7447"), session: session)
        let node = try await ctx.createNode(name: "n", namespace: "/ns")

        let service = try await node.createService(TriggerSrv.self, name: "trig") { _ in
            TriggerSrv.Response(success: true, message: "ok")
        }
        let cli = try await node.createClient(TriggerSrv.self, name: "trig")

        await ctx.shutdown()

        XCTAssertFalse(service.isActive, "service should be closed after ctx.shutdown()")
        XCTAssertFalse(cli.isActive, "client should be closed after ctx.shutdown()")
    }
}
