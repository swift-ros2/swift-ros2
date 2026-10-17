import SwiftROS2TestSupport
import SwiftROS2Transport
import XCTest

final class DDSTransportSessionTests: XCTestCase {
    private func openSession(
        client: MockDDSClient = MockDDSClient()
    ) async throws -> (DDSTransportSession, MockDDSClient) {
        let session = DDSTransportSession(client: client)
        try await session.open(config: TransportConfig.ddsMulticast(domainId: 0))
        return (session, client)
    }

    // MARK: - open / close

    func testOpenWithMismatchedTransportTypeThrows() async {
        let session = DDSTransportSession(client: MockDDSClient())
        do {
            try await session.open(config: TransportConfig.zenoh(locator: "tcp/x:7447"))
            XCTFail("Expected invalidConfiguration")
        } catch TransportError.invalidConfiguration {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testOpenFailsWhenDDSUnavailable() async {
        let client = MockDDSClient()
        client.isAvailable = false
        let session = DDSTransportSession(client: client)
        do {
            try await session.open(config: TransportConfig.ddsMulticast())
            XCTFail("Expected unsupportedFeature")
        } catch TransportError.unsupportedFeature {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testOpenCreatesSessionThroughClient() async throws {
        let (session, client) = try await openSession()
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(client.sessionCreations.count, 1)
        XCTAssertEqual(client.sessionCreations[0].domainId, 0)
        XCTAssertEqual(client.sessionCreations[0].config.mode, .multicast)
    }

    func testOpenForwardsUnicastPeers() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        let peers = [
            DDSPeer.peer(address: "10.0.0.5", domainId: 1),
            DDSPeer.peer(address: "10.0.0.6", domainId: 1),
        ]
        try await session.open(config: TransportConfig.ddsUnicast(peers: peers, domainId: 1))
        XCTAssertEqual(client.sessionCreations[0].config.mode, .unicast)
        // Each peer keeps its configured port, so a participant without an
        // index is still reached (issue #176), and is also listed as the bare
        // host, so CycloneDDS probes every participant index's own port and
        // not only the shared one, which reaches only the newest participant
        // on a Linux host (youtalk/conduit#123).
        XCTAssertEqual(
            client.sessionCreations[0].config.unicastPeers,
            ["10.0.0.5:7650", "10.0.0.5", "10.0.0.6:7650", "10.0.0.6"])
    }

    func testCloseDestroysSession() async throws {
        let (session, client) = try await openSession()
        try session.close()
        XCTAssertEqual(client.sessionDestructions, 1)
        XCTAssertFalse(session.isConnected)
    }

    // MARK: - createPublisher

    func testCreatePublisherRegistersWriter() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/ios/imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: "RIHS01_abc",
            qos: .sensorData
        )
        XCTAssertTrue(pub.isActive)
        XCTAssertEqual(client.writers.count, 1)
        XCTAssertEqual(client.writers[0].topic, "rt/ios/imu")
        XCTAssertEqual(client.writers[0].type, "sensor_msgs::msg::dds_::Imu_")
        XCTAssertEqual(client.writers[0].userData, "typehash=RIHS01_abc;")
    }

    func testCreatePublisherRejectsEmptyTopic() async throws {
        let (session, _) = try await openSession()
        XCTAssertThrowsError(
            try session.createPublisher(topic: "", typeName: "x", typeHash: nil, qos: .sensorData)
        )
    }

    func testCreatePublisherRejectsDuplicateTopic() async throws {
        let (session, _) = try await openSession()
        _ = try session.createPublisher(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        )
        XCTAssertThrowsError(
            try session.createPublisher(topic: "/x", typeName: "std_msgs/msg/String", typeHash: nil, qos: .sensorData)
        ) { error in
            guard case TransportError.publisherCreationFailed = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        }
    }

    func testPublishRequiresMinimum4ByteCDRHeader() async throws {
        let (session, _) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        )
        XCTAssertThrowsError(try pub.publish(data: Data([0x00, 0x01, 0x00]), timestamp: 0, sequenceNumber: 0))
    }

    func testPublishWritesRawCDR() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        )
        let payload = Data([0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x68, 0x69])
        try pub.publish(data: payload, timestamp: 42, sequenceNumber: 0)
        XCTAssertEqual(client.writes.count, 1)
        XCTAssertEqual(client.writes[0].data, payload)
        XCTAssertEqual(client.writes[0].timestamp, 42)
    }

    // MARK: - createSubscriber

    func testCreateSubscriberRegistersReader() async throws {
        let (session, client) = try await openSession()
        _ = try session.createSubscriber(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: "RIHS01_abc",
            qos: .sensorData
        ) { _, _ in }
        // The other reader is the session's own `ros_discovery_info` reader.
        let readers = client.readers.filter { $0.topic != "ros_discovery_info" }
        XCTAssertEqual(readers.count, 1)
        XCTAssertEqual(readers[0].topic, "rt/x")
        XCTAssertEqual(readers[0].type, "std_msgs::msg::dds_::String_")
        XCTAssertEqual(readers[0].userData, "typehash=RIHS01_abc;")
    }

    func testSubscriberHandlerReceivesDeliveredSamples() async throws {
        let (session, client) = try await openSession()
        let captured = Box<(Data, UInt64)?>(nil)
        _ = try session.createSubscriber(
            topic: "/x",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        ) { data, ts in
            captured.value = (data, ts)
        }
        client.deliver(toTopic: "rt/x", data: Data([0xAB, 0xCD]), timestamp: 99)

        XCTAssertEqual(captured.value?.0, Data([0xAB, 0xCD]))
        XCTAssertEqual(captured.value?.1, 99)
    }

    func testCloseDestroysOutstandingWritersAndReaders() async throws {
        let (session, client) = try await openSession()
        _ = try session.createPublisher(
            topic: "/p",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        )
        _ = try session.createSubscriber(
            topic: "/s",
            typeName: "std_msgs/msg/String",
            typeHash: nil,
            qos: .sensorData
        ) { _, _ in }
        try session.close()
        XCTAssertEqual(client.destroyedWriters, 1)
        XCTAssertEqual(client.destroyedReaders, 2, "the subscriber and the ros_discovery_info reader")
    }

    func testMatchedSubscriptionsFollowsTheWriterMatchedCount() async throws {
        let (session, client) = try await openSession()
        let pub = try session.createPublisher(
            topic: "/conduit/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        let ddsTopic = try XCTUnwrap(client.writers.last?.topic)
        XCTAssertNil(pub.matchedSubscriptions)
        client.setMatchedCount(topic: ddsTopic, 0)
        XCTAssertEqual(pub.matchedSubscriptions, false)
        client.setMatchedCount(topic: ddsTopic, 2)
        XCTAssertEqual(pub.matchedSubscriptions, true)
        try pub.close()
        XCTAssertNil(pub.matchedSubscriptions)
    }
}
