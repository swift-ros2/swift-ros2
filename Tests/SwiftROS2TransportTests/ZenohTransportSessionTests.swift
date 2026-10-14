import SwiftROS2Transport
import SwiftROS2Wire
import XCTest

final class ZenohTransportSessionTests: XCTestCase {
    // MARK: - Helpers

    private func openSession(
        wireMode: ROS2Distro? = .jazzy,
        client: MockZenohClient = MockZenohClient()
    ) async throws -> (ZenohTransportSession, MockZenohClient) {
        let session = ZenohTransportSession(client: client)
        let config = TransportConfig.zenoh(
            locator: "tcp/127.0.0.1:7447",
            wireMode: wireMode,
            connectionTimeout: 1.0
        )
        try await session.open(config: config)
        return (session, client)
    }

    // MARK: - open / close

    func testOpenWithMismatchedTransportTypeThrows() async {
        let session = ZenohTransportSession(client: MockZenohClient())
        let config = TransportConfig.ddsMulticast()
        do {
            try await session.open(config: config)
            XCTFail("Expected invalidConfiguration")
        } catch TransportError.invalidConfiguration {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testOpenWithoutLocatorThrows() async {
        let session = ZenohTransportSession(client: MockZenohClient())
        let config = TransportConfig(type: .zenoh, zenohLocator: nil)
        do {
            try await session.open(config: config)
            XCTFail("Expected invalidConfiguration")
        } catch TransportError.invalidConfiguration {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testOpenSucceedsThroughMock() async throws {
        let (session, client) = try await openSession()
        XCTAssertEqual(client.openedLocators, ["tcp/127.0.0.1:7447"])
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.transportType, .zenoh)
    }

    func testOpenWiresExplicitWireMode() async throws {
        let (session, _) = try await openSession(wireMode: .humble)
        XCTAssertEqual(session.resolvedWireMode, .humble)
    }

    func testOpenDefaultsToJazzyWhenNoWireModeGiven() async throws {
        let session = ZenohTransportSession(client: MockZenohClient())
        let config = TransportConfig.zenoh(
            locator: "tcp/127.0.0.1:7447",
            wireMode: nil,
            connectionTimeout: 1.0
        )
        try await session.open(config: config)
        XCTAssertEqual(session.resolvedWireMode, .jazzy)
    }

    func testOpenPropagatesConnectionFailure() async {
        let client = MockZenohClient()
        client.openShouldThrow = .sessionCreationFailed("boom")
        let session = ZenohTransportSession(client: client)
        let config = TransportConfig.zenoh(locator: "tcp/127.0.0.1:7447", connectionTimeout: 1.0)
        do {
            try await session.open(config: config)
            XCTFail("Expected connectionFailed")
        } catch TransportError.connectionFailed {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testCloseClearsResolvedWireMode() async throws {
        let (session, client) = try await openSession()
        try session.close()
        XCTAssertEqual(client.closedCount, 1)
        XCTAssertNil(session.resolvedWireMode)
    }

    // MARK: - createPublisher

    func testCreatePublisherDeclaresPublisherAndLiveliness() async throws {
        let (session, client) = try await openSession(wireMode: .jazzy)
        let pub = try session.createPublisher(
            topic: "/ios/imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: "RIHS01_abc",
            qos: .sensorData
        )
        XCTAssertTrue(pub.isActive)
        XCTAssertEqual(client.publisherDeclarations.count, 1)
        XCTAssertEqual(client.publisherDeclarations.first, "0/ios/imu/sensor_msgs::msg::dds_::Imu_/RIHS01_abc")
        XCTAssertEqual(client.livelinessDeclarations.count, 1)
        XCTAssertTrue(client.livelinessDeclarations.first?.hasPrefix("@ros2_lv/0/") == true)
    }

    func testCreatePublisherDeclaresAZenohPublisherOnTheKeyExpr() async throws {
        let (session, client) = try await openSession()
        _ = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        XCTAssertEqual(client.publisherDeclarations.count, 1)
        XCTAssertTrue(client.publisherDeclarations[0].contains("conduit/imu"))
    }

    func testPublishGoesThroughTheDeclaredPublisher() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        try pub.publish(data: Data([0, 1, 0, 0, 42]), timestamp: 1, sequenceNumber: 0)
        XCTAssertEqual(client.puts.count, 1)
        XCTAssertEqual(client.puts[0].key, client.publisherDeclarations[0])
    }

    func testVolatilePublisherHasNoCache() async throws {
        let (session, client) = try await openSession()
        _ = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        XCTAssertEqual(client.publisherOptions.last, ZenohPublisherOptions(cacheDepth: 0, heartbeatMs: 0))
    }

    func testReliableTransientLocalPublisherCachesDepthAndSendsHeartbeats() async throws {
        let (session, client) = try await openSession()
        let latched = TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1))
        _ = try session.createPublisher(
            topic: "/tf_static", typeName: "tf2_msgs/msg/TFMessage", typeHash: "RIHS01_abc", qos: latched)
        XCTAssertEqual(client.publisherOptions.last, ZenohPublisherOptions(cacheDepth: 1, heartbeatMs: 500))
    }

    func testBestEffortTransientLocalPublisherCachesWithoutHeartbeats() async throws {
        let (session, client) = try await openSession()
        let qos = TransportQoS(reliability: .bestEffort, durability: .transientLocal, history: .keepLast(5))
        _ = try session.createPublisher(
            topic: "/camera_info", typeName: "sensor_msgs/msg/CameraInfo", typeHash: "RIHS01_abc", qos: qos)
        XCTAssertEqual(client.publisherOptions.last, ZenohPublisherOptions(cacheDepth: 5, heartbeatMs: 0))
    }

    func testKeepAllTransientLocalPublisherCachesAThousandSamples() async throws {
        let (session, client) = try await openSession()
        let qos = TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepAll)
        _ = try session.createPublisher(
            topic: "/events", typeName: "std_msgs/msg/String", typeHash: "RIHS01_abc", qos: qos)
        XCTAssertEqual(client.publisherOptions.last, ZenohPublisherOptions(cacheDepth: 1000, heartbeatMs: 500))
    }

    func testMatchedSubscriptionsFollowsTheZenohMatchingStatus() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        let handle = try XCTUnwrap(client.publisherHandles.first)
        handle.matching = false
        XCTAssertEqual(pub.matchedSubscriptions, false)
        handle.matching = true
        XCTAssertEqual(pub.matchedSubscriptions, true)
        handle.matching = nil
        XCTAssertNil(pub.matchedSubscriptions)
    }

    /// The client reports a session whose router is gone the way the C bridge
    /// does: unknown matching, unhealthy, and `sessionDisconnected` on put. The
    /// transport layer must surface that as unknown matching, a disconnected
    /// session, a recoverable publish error, and refuse new entities.
    func testSessionThatLostItsRouterReportsUnknownMatchingAndUnhealthy() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        let handle = try XCTUnwrap(client.publisherHandles.first)
        handle.matching = false
        XCTAssertEqual(pub.matchedSubscriptions, false)
        XCTAssertTrue(session.checkHealth())

        handle.matching = nil
        client.healthOverride = false
        client.putShouldThrow = .sessionDisconnected("Router connection lost")

        XCTAssertNil(pub.matchedSubscriptions)
        XCTAssertFalse(session.checkHealth())
        XCTAssertFalse(session.isConnected)
        XCTAssertThrowsError(try pub.publish(data: Data([1]), timestamp: 0, sequenceNumber: 0)) { error in
            guard case TransportError.sessionUnhealthy = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
            XCTAssertTrue((error as? TransportError)?.isRecoverable ?? false)
        }
        XCTAssertThrowsError(
            try session.createPublisher(topic: "/x", typeName: "y", typeHash: nil, qos: .sensorData)
        ) { error in
            guard case TransportError.notConnected = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        }
    }

    func testClosedPublisherReportsUnknownAndClosesTheHandle() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        let handle = try XCTUnwrap(client.publisherHandles.first)
        try pub.close()
        XCTAssertNil(pub.matchedSubscriptions)
        XCTAssertEqual(handle.closeCount, 1)
    }

    func testCreatePublisherWithoutOpenThrowsNotConnected() {
        let session = ZenohTransportSession(client: MockZenohClient())
        XCTAssertThrowsError(
            try session.createPublisher(topic: "/x", typeName: "y", typeHash: nil, qos: .sensorData)
        ) { error in
            guard case TransportError.notConnected = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        }
    }

    func testPublishSendsAttachmentAndPayload() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/ios/imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: "RIHS01_abc",
            qos: .sensorData
        )
        let payload = Data([0x00, 0x01, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        try pub.publish(data: payload, timestamp: 1_000_000_000, sequenceNumber: 7)

        XCTAssertEqual(client.puts.count, 1)
        let put = client.puts[0]
        XCTAssertEqual(put.payload, payload)
        XCTAssertEqual(put.attachment?.count, 33, "Attachment must be 33 bytes")
    }

    func testPublishAfterCloseThrowsPublisherClosed() async throws {
        let (session, _) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        )
        try pub.close()
        XCTAssertThrowsError(try pub.publish(data: Data(), timestamp: 0, sequenceNumber: 0)) { error in
            guard case TransportError.publisherClosed = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        }
    }

    func testCloseSessionAlsoClosesPublishers() async throws {
        let (session, _) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        )
        try session.close()
        XCTAssertFalse(pub.isActive)
    }

    // MARK: - createSubscriber

    func testCreateSubscriberRegistersKeyExpr() async throws {
        let (session, client) = try await openSession(wireMode: .jazzy)
        let bytes = Box<Data?>(nil)
        let sub = try session.createSubscriber(
            topic: "/ios/imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: "RIHS01_abc",
            qos: .sensorData
        ) { data, _ in
            bytes.value = data
        }
        XCTAssertTrue(sub.isActive)
        XCTAssertEqual(client.subscriptions.count, 1)

        let sample = ZenohSample(keyExpr: "ignored", payload: Data([0x01, 0x02]), attachment: nil)
        client.deliver(sample: sample, toKeyExpr: client.subscriptions[0].key)
        XCTAssertEqual(bytes.value, Data([0x01, 0x02]))
    }

    // MARK: - createSubscriber: Lyrical buffer endpoints

    private let lyricalCloudKey =
        "0/e2e/points/sensor_msgs::msg::dds_::PointCloud2_/RIHS01_cloud"

    private func subscribeCloud(
        wireMode: ROS2Distro, qos: TransportQoS = .sensorData
    ) async throws -> (any TransportSubscriber, MockZenohClient, Box<[Data]>) {
        let (session, client) = try await openSession(wireMode: wireMode)
        let received = Box<[Data]>([])
        let sub = try session.createSubscriber(
            topic: "/e2e/points",
            typeName: "sensor_msgs/msg/PointCloud2",
            typeHash: "RIHS01_cloud",
            qos: qos
        ) { data, _ in
            received.value.append(data)
        }
        return (sub, client, received)
    }

    func testLyricalSubscriberAlsoListensOnTheCPUBufferGroupKey() async throws {
        let (_, client, received) = try await subscribeCloud(wireMode: .lyrical)
        XCTAssertEqual(client.subscriptions.map(\.key), [lyricalCloudKey, lyricalCloudKey + "/_buf_cpu"])

        client.deliver(
            sample: ZenohSample(keyExpr: lyricalCloudKey + "/_buf_cpu", payload: Data([0x01]), attachment: nil),
            toKeyExpr: lyricalCloudKey + "/_buf_cpu")
        client.deliver(
            sample: ZenohSample(keyExpr: lyricalCloudKey, payload: Data([0x02]), attachment: nil),
            toKeyExpr: lyricalCloudKey)
        XCTAssertEqual(received.value, [Data([0x01]), Data([0x02])])
    }

    func testLyricalSubscriberAnnouncesItselfAsACPUOnlySubscription() async throws {
        let (_, client, _) = try await subscribeCloud(wireMode: .lyrical)
        XCTAssertEqual(client.livelinessDeclarations.count, 1)
        let token = try XCTUnwrap(client.livelinessDeclarations.first)
        XCTAssertTrue(token.hasPrefix("@ros2_lv/0/mock-session-id/"), token)
        XCTAssertTrue(
            token.hasSuffix(
                "/MS/%/%/ios_points_node/%e2e%points/sensor_msgs::msg::dds_::PointCloud2_/RIHS01_cloud/"
                    + "::,10:,:,:,,/backends:cpu:"),
            token)
    }

    func testRollingSubscriberUsesTheCPUBufferGroupKeyToo() async throws {
        let (_, client, _) = try await subscribeCloud(wireMode: .rolling)
        XCTAssertEqual(client.subscriptions.map(\.key), [lyricalCloudKey, lyricalCloudKey + "/_buf_cpu"])
        XCTAssertEqual(client.livelinessDeclarations.count, 1)
    }

    func testLyricalTransientLocalSubscriberStaysOnTheTopicKey() async throws {
        let (_, client, _) = try await subscribeCloud(
            wireMode: .lyrical,
            qos: TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1)))
        XCTAssertEqual(client.subscriptions.map(\.key), [lyricalCloudKey])
        let token = try XCTUnwrap(client.livelinessDeclarations.first)
        XCTAssertTrue(token.contains("/MS/"), token)
        XCTAssertFalse(token.contains("backends"), token)
    }

    func testPreLyricalSubscriberUsesOnlyTheTopicKey() async throws {
        for distro: ROS2Distro in [.jazzy, .kilted] {
            let (_, client, _) = try await subscribeCloud(wireMode: distro)
            XCTAssertEqual(client.subscriptions.map(\.key), [lyricalCloudKey], "\(distro)")
            XCTAssertTrue(client.livelinessDeclarations.isEmpty, "\(distro)")
        }
    }

    func testClosingALyricalSubscriberClosesBothSubscriptionsAndItsToken() async throws {
        let client = MockZenohClient()
        let (session, _) = try await openSession(wireMode: .lyrical, client: client)
        let sub = try session.createSubscriber(
            topic: "/e2e/points", typeName: "sensor_msgs/msg/PointCloud2", typeHash: "RIHS01_cloud",
            qos: .sensorData
        ) { _, _ in }
        try sub.close()
        XCTAssertFalse(sub.isActive)
        XCTAssertEqual(client.subscriberHandles.map(\.closeCount), [1, 1])
        XCTAssertEqual(client.livelinessHandles.map(\.closeCount), [1])
    }

    func testFailedCPUBufferGroupSubscriptionClosesTheTopicSubscription() async throws {
        let client = MockZenohClient()
        client.subscribeFailsAfter = 1
        let (session, _) = try await openSession(wireMode: .lyrical, client: client)
        XCTAssertThrowsError(
            try session.createSubscriber(
                topic: "/e2e/points", typeName: "sensor_msgs/msg/PointCloud2", typeHash: "RIHS01_cloud",
                qos: .sensorData
            ) { _, _ in })
        XCTAssertEqual(client.subscriberHandles.map(\.closeCount), [1])
        XCTAssertTrue(client.livelinessDeclarations.isEmpty)
    }

    // MARK: - createSubscriber: transient-local late joiner

    private let tfStaticKey = "0/tf_static/tf2_msgs::msg::dds_::TFMessage_/RIHS01_tf"

    private func subscribeTFStatic(
        wireMode: ROS2Distro = .jazzy,
        qos: TransportQoS = TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1)),
        client: MockZenohClient = MockZenohClient()
    ) async throws -> (any TransportSubscriber, MockZenohClient, Box<[Data]>) {
        let (session, _) = try await openSession(wireMode: wireMode, client: client)
        let received = Box<[Data]>([])
        let sub = try session.createSubscriber(
            topic: "/tf_static", typeName: "tf2_msgs/msg/TFMessage", typeHash: "RIHS01_tf", qos: qos
        ) { data, _ in
            received.value.append(data)
        }
        return (sub, client, received)
    }

    private func tfSample(_ tag: UInt8, seq: Int64) -> ZenohSample {
        ZenohSample(
            keyExpr: tfStaticKey, payload: Data([tag]),
            attachment: ZenohWireCodec(distro: .jazzy).buildAttachment(
                seq: seq, tsNsec: seq * 1000, gid: [UInt8](repeating: 7, count: 16)))
    }

    func testTransientLocalSubscriberQueriesThePublisherCaches() async throws {
        for distro: ROS2Distro in [.humble, .jazzy, .kilted, .lyrical] {
            let (_, client, _) = try await subscribeTFStatic(wireMode: distro)
            let query = try XCTUnwrap(client.historyQueries.first, "\(distro)")
            let humbleKey = "0/tf_static/tf2_msgs::msg::dds_::TFMessage_/TypeHashNotSupported"
            let key = distro == .humble ? humbleKey : tfStaticKey
            XCTAssertEqual(client.subscriptions.map(\.key), [key], "\(distro)")
            XCTAssertEqual(query.keyExpr, key + "/@adv/**", "\(distro)")
            XCTAssertEqual(query.parameters, "_anyke;_max=1", "\(distro)")
            XCTAssertEqual(query.timeoutMs, ZenohTransportSession.historyQueryTimeoutMs)
        }
    }

    func testKeepAllTransientLocalSubscriberAsksForTheWholeCache() async throws {
        let (_, client, _) = try await subscribeTFStatic(
            qos: TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepAll))
        XCTAssertEqual(client.historyQueries.first?.parameters, "_anyke")
    }

    func testVolatileSubscriberDoesNotQueryHistory() async throws {
        let (_, client, _) = try await subscribeTFStatic(qos: .sensorData)
        XCTAssertTrue(client.historyQueries.isEmpty)
    }

    func testCachedSamplesArriveBeforeLiveOnesWithoutDuplicates() async throws {
        let (_, client, received) = try await subscribeTFStatic()
        let query = try XCTUnwrap(client.historyQueries.first)

        client.deliver(sample: tfSample(2, seq: 2), toKeyExpr: tfStaticKey)
        query.reply(tfSample(1, seq: 1))
        query.reply(tfSample(2, seq: 2))
        query.replyError("ignored")
        XCTAssertEqual(received.value, [])

        query.finish()
        XCTAssertEqual(received.value, [Data([1]), Data([2])])

        client.deliver(sample: tfSample(3, seq: 3), toKeyExpr: tfStaticKey)
        XCTAssertEqual(received.value, [Data([1]), Data([2]), Data([3])])
    }

    func testAFailedHistoryQueryLeavesTheLiveSubscription() async throws {
        let client = MockZenohClient()
        client.getHistoryShouldThrow = .sessionDisconnected("lost")
        let (sub, _, received) = try await subscribeTFStatic(client: client)
        XCTAssertTrue(sub.isActive)
        client.deliver(sample: tfSample(1, seq: 1), toKeyExpr: tfStaticKey)
        XCTAssertEqual(received.value, [Data([1])])
    }

    func testClosedTransientLocalSubscriberIgnoresALateHistory() async throws {
        let (sub, client, received) = try await subscribeTFStatic()
        let query = try XCTUnwrap(client.historyQueries.first)
        try sub.close()
        query.reply(tfSample(1, seq: 1))
        query.finish()
        XCTAssertEqual(received.value, [])
    }
}
