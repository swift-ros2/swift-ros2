import XCTest

@testable import SwiftROS2Transport

final class RclTransportSessionTests: XCTestCase {
    private func openSession(
        _ client: MockRclClient = MockRclClient(),
        domainId: Int = 0
    ) async throws -> RclTransportSession {
        let s = RclTransportSession(client: client)
        try await s.open(config: .rcl(domainId: domainId))
        return s
    }

    func testOpenCreatesContext() async throws {
        let client = MockRclClient()
        let s = try await openSession(client, domainId: 5)
        XCTAssertTrue(client.contextCreated)
        XCTAssertEqual(client.lastDomainId, 5)
        XCTAssertTrue(s.isConnected)
        XCTAssertEqual(s.transportType, .rcl)
        XCTAssertEqual(s.sessionId, "rcl-5")
    }

    func testRclOpenForwardsUnicastDiscoveryToClient() async throws {
        let client = MockRclClient()
        let session = RclTransportSession(client: client)
        let peer = DDSPeer(address: "192.168.1.85", port: DDSPeer.discoveryPort(forDomain: 0))
        try await session.open(
            config: .rclUnicast(peers: [peer], domainId: 0, interface: "en0"))
        // Port included: the RCL path feeds the same CycloneDDS discovery XML
        // as the wire DDS path, so a bare host there loses SPDP the same way
        // (issue #176).
        XCTAssertEqual(client.lastUnicastPeerAddresses, ["192.168.1.85:7400"])
        XCTAssertEqual(client.lastNetworkInterface, "en0")
    }

    // `.dds` must be accepted, not rejected: on Linux (runtime rmw
    // selection) makeDefaultSession routes `.dds` configs here and the client
    // picks rmw_cyclonedds_cpp from the forwarded transport type. Rejecting it
    // makes the whole Linux DDS-RCL path dead on arrival.
    func testOpenAcceptsDdsConfigAndForwardsTransportType() async throws {
        let client = MockRclClient()
        let s = RclTransportSession(client: client)
        try await s.open(config: .ddsMulticast(domainId: 3))
        XCTAssertEqual(client.lastTransportType, .dds)
        guard let recordedLocator = client.recordedZenohLocator else {
            return XCTFail("createContext was never called")
        }
        XCTAssertNil(recordedLocator, "a .dds config must not carry a zenoh locator")
        XCTAssertTrue(s.isConnected)
        XCTAssertEqual(s.sessionId, "rcl-3")
    }

    func testOpenFailsWhenUnavailable() async {
        let client = MockRclClient()
        client.isAvailable = false
        let s = RclTransportSession(client: client)
        do {
            try await s.open(config: .rcl(domainId: 0))
            XCTFail("expected unsupportedFeature")
        } catch let e as TransportError {
            guard case .unsupportedFeature = e else { return XCTFail("got \(e)") }
        } catch { XCTFail("got \(error)") }
    }

    func testRegisterNodeCreatesRclNode() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        XCTAssertEqual(client.nodesCreated.count, 1)
        XCTAssertEqual(client.nodesCreated.first?.name, "imu_node")
        XCTAssertEqual(client.nodesCreated.first?.namespace, "/ios")
    }

    func testUnregisterNodeDestroysRclNode() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        s.unregisterNode(name: "imu_node", namespace: "/ios")
        XCTAssertEqual(client.nodesDestroyed.count, 1)
        XCTAssertEqual(client.nodesDestroyed.first?.name, "imu_node")
    }

    // MARK: - Subscriber

    func testCreateSubscriberRequiresNode() async throws {
        let s = try await openSession()
        XCTAssertThrowsError(
            try s.createSubscriber(
                topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
                qos: .sensorData, handler: { _, _ in })
        ) { error in
            guard case TransportError.subscriberCreationFailed = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreateSubscriberAttachesToCurrentNodeAndPassesQoS() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let qos = TransportQoS(
            reliability: .bestEffort, durability: .transientLocal, history: .keepLast(5))
        let sub = try s.createSubscriber(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
            qos: qos, handler: { _, _ in })
        XCTAssertEqual(client.subscriptionsCreated.count, 1)
        XCTAssertEqual(client.subscriptionsCreated.first?.topic, "/imu")
        XCTAssertEqual(client.subscriptionsCreated.first?.typeName, "sensor_msgs/msg/Imu")
        XCTAssertEqual(client.subscriptionsCreated.first?.qos, qos)
        // Node attachment by identity: the subscription must be created on the
        // exact node handle registerNode produced, not a stale or wrong one.
        XCTAssertTrue(client.subscriptionsCreated.first?.node === client.nodeHandles.first)
        XCTAssertEqual(sub.topic, "/imu")
        XCTAssertTrue(sub.isActive)
    }

    func testCreateSubscriberForwardsTypeHashToClient() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        _ = try s.createSubscriber(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_deadbeef",
            qos: .sensorData, handler: { _, _ in })
        XCTAssertEqual(client.subscriptionsCreated.first?.typeHash, "RIHS01_deadbeef")
    }

    func testSubscriberHandlerReceivesDataAndTimestamp() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let received = Box<[(Data, UInt64)]>([])
        _ = try s.createSubscriber(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
            qos: .sensorData, handler: { data, ts in received.value.append((data, ts)) })
        let cdr = Data([0x00, 0x01, 0x00, 0x00, 0xBE, 0xEF])
        client.subscriptionsCreated[0].fire(cdr, timestamp: 42)
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(received.value.first?.0, cdr)
        XCTAssertEqual(received.value.first?.1, 42)
    }

    func testSubscriberCloseDestroysExactlyOnce() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let sub = try s.createSubscriber(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
            qos: .sensorData, handler: { _, _ in })
        try sub.close()
        try sub.close()  // idempotent
        XCTAssertFalse(sub.isActive)
        XCTAssertEqual(client.subscriptionsDestroyed.count, 1)
        XCTAssertEqual(client.subscriptionsDestroyed.first?.topic, "/imu")
    }

    func testCloseDestroysSubscribersBeforeNodesAndContext() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        _ = try s.createSubscriber(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
            qos: .sensorData, handler: { _, _ in })
        try s.close()
        XCTAssertEqual(
            client.teardownEvents, ["subscription:/imu", "node:imu_node", "context"])
    }

    func testCreateSubscriberDuringCloseDestroysSubscriptionAndThrows() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        // Interleave close() into the preflight-create-append window: the
        // just-created subscription must not escape teardown (wait thread
        // joined via destroy) and the caller must see notConnected.
        client.onCreateSubscription = { try? s.close() }
        XCTAssertThrowsError(
            try s.createSubscriber(
                topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
                qos: .sensorData, handler: { _, _ in })
        ) { error in
            guard case TransportError.notConnected = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(client.subscriptionsDestroyed.count, 1)
        XCTAssertEqual(client.subscriptionsDestroyed.first?.topic, "/imu")
    }

    func testCreateSubscriberSurfacesUnsupportedTypeError() async throws {
        let client = MockRclClient()
        client.createSubscriptionShouldThrow =
            .subscriberCreationFailed("unsupported type: foo_msgs/msg/Bar")
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        XCTAssertThrowsError(
            try s.createSubscriber(
                topic: "/bar", typeName: "foo_msgs/msg/Bar", typeHash: nil,
                qos: .sensorData, handler: { _, _ in })
        ) { error in
            guard case TransportError.subscriberCreationFailed(let msg) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(msg.contains("unsupported type"))
        }
    }

    func testCloseDestroysNodesAndContext() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        try s.close()
        XCTAssertTrue(client.contextDestroyed)
        XCTAssertEqual(client.nodesDestroyed.count, 1)
        XCTAssertFalse(s.isConnected)
    }

    func testRegisterNodeBeforeOpenThrows() {
        let s = RclTransportSession(client: MockRclClient())
        XCTAssertThrowsError(try s.registerNode(name: "n", namespace: "/")) { error in
            guard case TransportError.notConnected = error else { return XCTFail("got \(error)") }
        }
    }

    func testCloseWithoutOpenSkipsDestroyContext() throws {
        let client = MockRclClient()
        let s = RclTransportSession(client: client)
        try s.close()
        XCTAssertFalse(client.contextDestroyed)
    }

    func testCreatePublisherRequiresNode() async throws {
        let s = try await openSession()
        XCTAssertThrowsError(
            try s.createPublisher(
                topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        ) { error in
            guard case TransportError.publisherCreationFailed = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreatePublisherAttachesToCurrentNode() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let pub = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        XCTAssertEqual(client.publishersCreated.count, 1)
        XCTAssertEqual(client.publishersCreated.first?.topic, "/imu")
        XCTAssertEqual(client.publishersCreated.first?.typeName, "sensor_msgs/msg/Imu")
        XCTAssertTrue(pub.isActive)
    }

    func testPublishForwardsSerializedBytes() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let pub = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        let cdr = Data([0x00, 0x01, 0x00, 0x00, 0xDE, 0xAD])
        try pub.publish(data: cdr, timestamp: 123, sequenceNumber: 1)
        XCTAssertEqual(client.publishedPayloads, [cdr])
    }

    func testPublishRejectsShortData() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let pub = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        XCTAssertThrowsError(try pub.publish(data: Data([0x00]), timestamp: 0, sequenceNumber: 0)) {
            guard case TransportError.publishFailed = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testPublishAfterCloseThrows() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let pub = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        try pub.close()
        XCTAssertFalse(pub.isActive)
        XCTAssertThrowsError(
            try pub.publish(data: Data([0x00, 0x01, 0x00, 0x00]), timestamp: 0, sequenceNumber: 0)
        ) { error in
            guard case TransportError.publisherClosed = error else { return XCTFail("got \(error)") }
        }
    }

    // rcl (like rclcpp) allows multiple publishers on one topic — the session
    // must not impose a one-publisher-per-topic restriction the underlying
    // stack does not have.
    func testTwoLivePublishersOnSameTopicAllowed() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let first = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        let second = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        XCTAssertTrue(first.isActive)
        XCTAssertTrue(second.isActive)
        XCTAssertEqual(client.publishersCreated.count, 2)
    }

    // A closed publisher must release its topic: stop/recreate cycles within
    // one context were impossible while the closed entry stayed registered.
    func testCreatePublisherAfterCloseReusesTopic() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let first = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        try first.close()
        let second = try s.createPublisher(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        XCTAssertTrue(second.isActive)
    }

    // Two nodes in one session each publish the same topic — the lazily
    // created per-node /parameter_events publisher is the production case;
    // the second node's events were silently lost while the guard existed.
    func testTwoNodesCanCreatePublishersOnSameTopic() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "node_a", namespace: "/")
        try s.registerNode(name: "node_b", namespace: "/")
        _ = try s.createPublisher(
            topic: "/parameter_events", typeName: "rcl_interfaces/msg/ParameterEvent",
            typeHash: nil, qos: .sensorData, nodeName: "node_a", nodeNamespace: "/")
        _ = try s.createPublisher(
            topic: "/parameter_events", typeName: "rcl_interfaces/msg/ParameterEvent",
            typeHash: nil, qos: .sensorData, nodeName: "node_b", nodeNamespace: "/")
        XCTAssertEqual(client.publishersCreated.count, 2)
        XCTAssertTrue(client.publisherHandles[0].node === client.nodeHandles[0])
        XCTAssertTrue(client.publisherHandles[1].node === client.nodeHandles[1])
    }

    // MARK: - Multi-node entity binding (node.multi)

    func testCreatePublisherBindsToNamedNodeNotLastRegistered() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "node_a", namespace: "/")
        try s.registerNode(name: "node_b", namespace: "/")  // currentNode is now node_b

        _ = try s.createPublisher(
            topic: "/t", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData,
            nodeName: "node_a", nodeNamespace: "/")

        XCTAssertTrue(
            client.publisherHandles.first?.node === client.nodeHandles[0],
            "publisher bound to the wrong node — node.multi misroute")
        XCTAssertFalse(client.publisherHandles.first?.node === client.nodeHandles[1])
    }

    func testCreatePublisherWithNilNodeFallsBackToCurrentNode() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "only", namespace: "/")
        _ = try s.createPublisher(
            topic: "/t", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        XCTAssertTrue(client.publisherHandles.first?.node === client.nodeHandles[0])
    }

    func testCreateSubscriberBindsToNamedNode() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "node_a", namespace: "/")
        try s.registerNode(name: "node_b", namespace: "/")
        _ = try s.createSubscriber(
            topic: "/t", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData,
            nodeName: "node_a", nodeNamespace: "/", handler: { _, _ in })
        XCTAssertTrue(client.subscriptionsCreated.first?.node === client.nodeHandles[0])
    }

    /// An unknown (name, namespace) must error, not silently bind to the
    /// last-registered node — otherwise a caller bug (or an entity created for a
    /// node already unregistered) misroutes onto an unrelated node.
    func testCreatePublisherWithUnknownNodeThrowsInsteadOfMisrouting() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "node_a", namespace: "/")  // currentNode = node_a

        XCTAssertThrowsError(
            try s.createPublisher(
                topic: "/t", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData,
                nodeName: "ghost", nodeNamespace: "/")
        )
        XCTAssertTrue(
            client.publisherHandles.isEmpty,
            "no publisher should be created for an unknown node — silent misroute regression")
    }

    func testMatchedSubscriptionsFollowsTheRclCount() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        try s.registerNode(name: "imu_node", namespace: "/ios")
        let pub = try s.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .sensorData)
        let topic = try XCTUnwrap(client.publishersCreated.last?.topic)
        XCTAssertNil(pub.matchedSubscriptions)
        client.setPublisherMatchedCount(topic: topic, 0)
        XCTAssertEqual(pub.matchedSubscriptions, false)
        client.setPublisherMatchedCount(topic: topic, 1)
        XCTAssertEqual(pub.matchedSubscriptions, true)
        try pub.close()
        XCTAssertNil(pub.matchedSubscriptions)
    }
}
