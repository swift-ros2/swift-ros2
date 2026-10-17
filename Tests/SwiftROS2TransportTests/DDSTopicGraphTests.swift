import Foundation
import SwiftROS2Wire
import XCTest

@testable import SwiftROS2Transport

/// The wire DDS topic graph: `DCPSPublication` writers, attributed to nodes through
/// `ros_discovery_info` records and the in-process registry.
final class DDSTopicGraphTests: XCTestCase {
    // MARK: - Topics, types and QoS

    func testOnlyRTTopicsAreListedWithROSNamesAndTypes() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(
                    participant, 1, topic: "rt/kachaka/mapping/map", type: "nav_msgs::msg::dds_::OccupancyGrid_"),
                Self.publication(
                    participant, 2, topic: "rq/add_two_intsRequest",
                    type: "example_interfaces::srv::dds_::AddTwoInts_Request_"),
                Self.publication(
                    participant, 3, topic: "rr/add_two_intsReply",
                    type: "example_interfaces::srv::dds_::AddTwoInts_Response_"),
                Self.publication(
                    participant, 4, topic: "ros_discovery_info", type: ParticipantEntitiesInfo.ddsTypeName),
                Self.publication(participant, 5, topic: "chatter", type: "std_msgs::msg::dds_::String_"),
                Self.publication(participant, 6, topic: "rt/", type: "std_msgs::msg::dds_::String_"),
                Self.publication(
                    participant, 7, topic: "rt/fibonacci/_action/feedback",
                    type: "example_interfaces::action::dds_::Fibonacci_FeedbackMessage_"),
                Self.publication(
                    participant, 8, topic: "rt/fibonacci/_action/status",
                    type: "action_msgs::msg::dds_::GoalStatusArray_"),
                Self.publication(participant, 9, topic: "rt/odd", type: "NotADDSName"),
            ],
            participantGUIDs: [participant])

        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(
            Set(endpoints.map { "\($0.topicName) \($0.typeName)" }),
            [
                "/kachaka/mapping/map nav_msgs/msg/OccupancyGrid",
                "/fibonacci/_action/feedback example_interfaces/action/Fibonacci_FeedbackMessage",
                "/fibonacci/_action/status action_msgs/msg/GoalStatusArray",
                "/odd NotADDSName",
            ])
    }

    func testQoSMapsToWhatAReaderCanRequest() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        let cases: [(DDSDiscoveredPublication.Reliability, DDSDiscoveredPublication.Durability)] = [
            (.reliable, .volatile), (.reliable, .transientLocal), (.reliable, .transient), (.reliable, .persistent),
            (.bestEffort, .volatile), (.unknown, .unknown),
        ]
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: cases.enumerated().map { index, qos in
                Self.publication(
                    participant, UInt32(index + 1), topic: "rt/qos\(index)", type: "std_msgs::msg::dds_::String_",
                    reliability: qos.0, durability: qos.1)
            },
            participantGUIDs: [participant])

        let endpoints = try await session.publisherEndpoints()
        let byTopic = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.topicName, $0) })
        let expected: [(TransportQoS.Reliability, TransportQoS.Durability)] = [
            (.reliable, .volatile), (.reliable, .transientLocal), (.reliable, .transientLocal),
            (.reliable, .transientLocal), (.bestEffort, .volatile), (.bestEffort, .volatile),
        ]
        for (index, qos) in expected.enumerated() {
            let endpoint = try XCTUnwrap(byTopic["/qos\(index)"])
            XCTAssertEqual(endpoint.reliability, qos.0, "case \(index)")
            XCTAssertEqual(endpoint.durability, qos.1, "case \(index)")
        }
    }

    // MARK: - Node attribution

    func testUnattributedWriterKeepsTheUnknownStrings() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [Self.publication(participant, 1, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")],
            participantGUIDs: [participant])

        let endpoints = try await session.publisherEndpoints()
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.nodeName, "_NODE_NAME_UNKNOWN_")
        XCTAssertEqual(endpoint.nodeNamespace, "_NODE_NAMESPACE_UNKNOWN_")
    }

    func testRemoteWriterIsAttributedFromItsRecord() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        let writer = Self.guid(participant, 0x103)
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(participant, 0x103, topic: "rt/ns/chatter", type: "std_msgs::msg::dds_::String_"),
                Self.publication(participant, 0x203, topic: "rt/ns/other", type: "std_msgs::msg::dds_::String_"),
            ],
            participantGUIDs: [participant])
        deliverRecord(
            client,
            ParticipantEntitiesInfo(
                participantGid: participant,
                nodes: [
                    .init(
                        namespace: "/ns", name: "talker", readerGids: [Self.guid(participant, 0x104)],
                        writerGids: [writer])
                ]),
            gidSize: 16)

        let endpoints = try await session.publisherEndpoints()
        let byTopic = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.topicName, $0) })
        XCTAssertEqual(byTopic["/ns/chatter"]?.nodeName, "talker")
        XCTAssertEqual(byTopic["/ns/chatter"]?.nodeNamespace, "/ns")
        XCTAssertEqual(byTopic["/ns/other"]?.nodeName, "_NODE_NAME_UNKNOWN_", "a writer the record does not list")
    }

    func testHumbleRecordWith24ByteGidsAttributesOnAJazzySession() async throws {
        try await assertRecordAttributes(sessionDistro: .jazzy, gidSize: 24)
    }

    func testJazzyRecordWith16ByteGidsAttributesOnAHumbleSession() async throws {
        try await assertRecordAttributes(sessionDistro: .humble, gidSize: 16)
    }

    func testHumbleRecordAttributesOnAHumbleSession() async throws {
        try await assertRecordAttributes(sessionDistro: .humble, gidSize: 24)
    }

    func testANewerRecordReplacesTheParticipantsPreviousOne() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        let writer = Self.guid(participant, 0x103)
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(participant, 0x103, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")
            ],
            participantGUIDs: [participant])
        deliverRecord(
            client,
            ParticipantEntitiesInfo(
                participantGid: participant, nodes: [.init(namespace: "/", name: "a", writerGids: [writer])]),
            gidSize: 16)
        deliverRecord(
            client,
            ParticipantEntitiesInfo(
                participantGid: participant, nodes: [.init(namespace: "/", name: "b", writerGids: [writer])]),
            gidSize: 16)

        let node = try await session.publisherEndpoints().first?.nodeName
        XCTAssertEqual(node, "b")
    }

    func testMalformedRecordsAreIgnored() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        let writer = Self.guid(participant, 0x103)
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(participant, 0x103, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")
            ],
            participantGUIDs: [participant])
        let record = ParticipantEntitiesInfo(
            participantGid: participant, nodes: [.init(namespace: "/", name: "talker", writerGids: [writer])])
        // Trailing bytes, a truncated record and garbage.
        client.deliver(
            toTopic: ParticipantEntitiesInfo.topicName, data: record.encode(gidSize: 16) + Data([1, 2, 3, 4]),
            timestamp: 0)
        client.deliver(
            toTopic: ParticipantEntitiesInfo.topicName, data: record.encode(gidSize: 16).dropLast(5), timestamp: 0)
        client.deliver(toTopic: ParticipantEntitiesInfo.topicName, data: Data([0xFF, 0x00]), timestamp: 0)

        let node = try await session.publisherEndpoints().first?.nodeName
        XCTAssertEqual(node, "_NODE_NAME_UNKNOWN_")
    }

    func testRecordsOfParticipantsThatLeftArePruned() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let staying = Self.remoteParticipant()
        let leaving = Self.remoteParticipant()
        let readerOnly = Self.remoteParticipant()
        for participant in [staying, leaving, readerOnly] {
            deliverRecord(
                client,
                ParticipantEntitiesInfo(
                    participantGid: participant,
                    nodes: [.init(namespace: "/", name: "n", writerGids: [Self.guid(participant, 0x103)])]),
                gidSize: 16)
        }
        XCTAssertEqual(session.discoveryInfo.participantsWithRecords, [staying, leaving, readerOnly])

        // `readerOnly` has no writer listed but is still a participant of the domain.
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [Self.publication(staying, 0x103, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")],
            participantGUIDs: [staying, readerOnly])
        _ = try await session.publisherEndpoints()
        XCTAssertEqual(session.discoveryInfo.participantsWithRecords, [staying, readerOnly])
    }

    /// A participant discovered after the snapshot was read, whose record arrives before
    /// the read prunes, keeps its record: the snapshot could not have listed it.
    func testARecordReceivedDuringTheSnapshotReadIsNotPruned() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let newcomer = Self.remoteParticipant()
        let writer = Self.guid(newcomer, 0x103)
        let record = ParticipantEntitiesInfo(
            participantGid: newcomer, nodes: [.init(namespace: "/", name: "late", writerGids: [writer])])
        client.discoverySnapshotValue = DDSDiscoverySnapshot(publications: [], participantGUIDs: [])
        client.onDiscoverySnapshot = { [client] in
            client.onDiscoverySnapshot = nil
            client.deliver(toTopic: ParticipantEntitiesInfo.topicName, data: record.encode(gidSize: 16), timestamp: 0)
        }

        _ = try await session.publisherEndpoints()
        XCTAssertEqual(session.discoveryInfo.participantsWithRecords, [newcomer])

        // The next read lists the newcomer's writer under its node.
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(newcomer, 0x103, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")
            ],
            participantGUIDs: [newcomer])
        let node = try await session.publisherEndpoints().first?.nodeName
        XCTAssertEqual(node, "late")

        // Once a later snapshot no longer lists it, its record goes.
        client.discoverySnapshotValue = DDSDiscoverySnapshot(publications: [], participantGUIDs: [])
        _ = try await session.publisherEndpoints()
        XCTAssertEqual(session.discoveryInfo.participantsWithRecords, [])
    }

    func testAWritersParticipantCountsAsPresentEvenWhenNotListed() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        deliverRecord(
            client,
            ParticipantEntitiesInfo(
                participantGid: participant,
                nodes: [.init(namespace: "/", name: "talker", writerGids: [Self.guid(participant, 0x103)])]),
            gidSize: 16)
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(participant, 0x103, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")
            ],
            participantGUIDs: [])

        let node = try await session.publisherEndpoints().first?.nodeName
        XCTAssertEqual(node, "talker")
    }

    func testOwnWritersAreAttributedThroughTheRegistryWithoutARecord() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        try session.registerNode(name: "talker", namespace: "/ns")
        _ = try session.createPublisher(
            topic: "/ns/chatter", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "talker", nodeNamespace: "/ns")
        let writer = try XCTUnwrap(client.createdWriterHandles.first { $0.topic == "rt/ns/chatter" }?.guid)
        let participant = try XCTUnwrap(client.participantGuidValue)
        // The mock does not loop the session's own record back to its reader.
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [Self.publication(guid: writer, participant: participant, topic: "rt/ns/chatter")],
            participantGUIDs: [participant])

        let endpoints = try await session.publisherEndpoints()
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.topicName, "/ns/chatter")
        XCTAssertEqual(endpoint.nodeName, "talker")
        XCTAssertEqual(endpoint.nodeNamespace, "/ns")
    }

    func testWritersOfAnotherSessionInTheProcessAreAttributed() async throws {
        let (observer, observerClient) = try await openSession()
        defer { try? observer.close() }
        let (other, otherClient) = try await openSession()
        try other.registerNode(name: "sensor", namespace: "/robot")
        _ = try other.createPublisher(
            topic: "/robot/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil, qos: .default,
            nodeName: "sensor", nodeNamespace: "/robot")
        let writer = try XCTUnwrap(otherClient.createdWriterHandles.first { $0.topic == "rt/robot/imu" }?.guid)
        let otherParticipant = try XCTUnwrap(otherClient.participantGuidValue)
        observerClient.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(
                    guid: writer, participant: otherParticipant, topic: "rt/robot/imu",
                    type: "sensor_msgs::msg::dds_::Imu_")
            ],
            participantGUIDs: [otherParticipant])

        let node = try await observer.publisherEndpoints().first?.nodeName
        XCTAssertEqual(node, "sensor")

        // Once the other session closes, its writers are no longer attributed from it.
        try other.close()
        XCTAssertFalse(DDSInProcessNodeRegistry.shared.contains(other.graph))
        let nodeAfterClose = try await observer.publisherEndpoints().first?.nodeName
        XCTAssertEqual(nodeAfterClose, "_NODE_NAME_UNKNOWN_")
    }

    // MARK: - The ros_discovery_info reader

    func testReaderIsOpenedAtOpenAndClosedAtClose() async throws {
        let (session, client) = try await openSession()
        let reader = try XCTUnwrap(client.readers.first { $0.topic == "ros_discovery_info" })
        XCTAssertEqual(reader.type, ParticipantEntitiesInfo.ddsTypeName)
        XCTAssertEqual(reader.qos.reliability, .reliable)
        XCTAssertEqual(reader.qos.durability, .transientLocal)
        XCTAssertEqual(reader.qos.historyKind, .keepAll)
        XCTAssertEqual(reader.userData, ParticipantEntitiesInfo.userData(for: .jazzy))
        let handle = try XCTUnwrap(client.createdReaderHandles.first { $0.topic == "ros_discovery_info" })
        XCTAssertTrue(handle.isActive)
        XCTAssertTrue(DDSInProcessNodeRegistry.shared.contains(session.graph))

        try session.close()
        XCTAssertFalse(handle.isActive)
        XCTAssertFalse(DDSInProcessNodeRegistry.shared.contains(session.graph))
    }

    func testReaderIsNotRecordedAsANodeEndpoint() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        try session.registerNode(name: "talker", namespace: "/")
        let data = try XCTUnwrap(client.lastWritten(topic: "ros_discovery_info"))
        let record = try ParticipantEntitiesInfo(decoding: data, gidSize: 16)
        XCTAssertEqual(record.nodes, [.init(namespace: "/", name: "talker")])
    }

    // MARK: - Threading and errors

    func testReadsRunOnTheSessionsGraphQueue() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let key = DispatchSpecificKey<String>()
        session.graphQueue.setSpecific(key: key, value: "graph")
        let seen = LockedBox<String?>(nil)
        client.onDiscoverySnapshot = { seen.set(DispatchQueue.getSpecific(key: key)) }

        _ = try await session.publisherEndpoints()
        XCTAssertEqual(seen.value, "graph")
        XCTAssertEqual(session.graphQueue.label, "swift-ros2.graph.dds")
    }

    func testNotConnectedBeforeOpenAndAfterClose() async throws {
        let unopened = DDSTransportSession(client: MockDDSClient())
        await assertThrowsNotConnected { try await unopened.publisherEndpoints() }

        let (session, _) = try await openSession()
        try session.close()
        await assertThrowsNotConnected { try await session.publisherEndpoints() }
    }

    func testClientErrorsMap() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }

        client.discoverySnapshotError = DDSError.notConnected
        await assertThrowsNotConnected { try await session.publisherEndpoints() }

        client.discoverySnapshotError = DDSError.discoveryFailed("builtin reader")
        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected sessionUnhealthy")
        } catch TransportError.sessionUnhealthy(let message) {
            XCTAssertTrue(message.contains("builtin reader"), message)
        }
    }

    func testDefaultClientReportsNoPublishers() async throws {
        // A conformer without discovery access (the protocol default) lists nothing.
        final class Plain: DDSClientProtocol {
            var isAvailable: Bool { true }
            func createSession(domainId: Int32, discoveryConfig: DDSBridgeDiscoveryConfig) throws {}
            func destroySession() throws {}
            func isConnected() -> Bool { true }
            func getSessionId() -> String? { "plain" }
            func createRawWriter(topicName: String, typeName: String, qos: DDSBridgeQoSConfig, userData: String?) throws
                -> any DDSWriterHandle
            { MockDDSWriterHandle(topic: topicName) }
            func writeRawCDR(writer: any DDSWriterHandle, data: Data, timestamp: UInt64) throws {}
            func destroyWriter(_ writer: any DDSWriterHandle) {}
            func createRawReader(
                topicName: String, typeName: String, qos: DDSBridgeQoSConfig, userData: String?,
                handler: @escaping @Sendable (Data, UInt64) -> Void
            ) throws -> any DDSReaderHandle { MockDDSReaderHandle(topic: topicName) }
            func destroyReader(_ reader: any DDSReaderHandle) {}
        }
        let session = DDSTransportSession(client: Plain())
        try await session.open(config: .ddsMulticast())
        defer { try? session.close() }
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [])
    }

    // MARK: - Record decoding

    func testDecodeReceivedAcceptsEitherGidSizeAndAnnouncedPadding() throws {
        let participant = Self.remoteParticipant()
        let info = ParticipantEntitiesInfo(
            participantGid: participant,
            nodes: [
                .init(
                    namespace: "/ns", name: "n", readerGids: [Self.guid(participant, 4)],
                    writerGids: [Self.guid(participant, 3)])
            ])
        let padded24 = ParticipantEntitiesInfo(
            participantGid: participant + Self.pad8,
            nodes: [
                .init(
                    namespace: "/ns", name: "n", readerGids: [Self.guid(participant, 4) + Self.pad8],
                    writerGids: [Self.guid(participant, 3) + Self.pad8])
            ])

        XCTAssertEqual(ParticipantEntitiesInfo.decodeReceived(info.encode(gidSize: 16), preferredGidSize: 16), info)
        XCTAssertEqual(ParticipantEntitiesInfo.decodeReceived(info.encode(gidSize: 16), preferredGidSize: 24), info)
        XCTAssertEqual(ParticipantEntitiesInfo.decodeReceived(info.encode(gidSize: 24), preferredGidSize: 16), padded24)
        XCTAssertEqual(ParticipantEntitiesInfo.decodeReceived(info.encode(gidSize: 24), preferredGidSize: 24), padded24)

        // Padding announced in the encapsulation options is allowed, other trailing bytes are not.
        var withPadding = info.encode(gidSize: 16) + Data([0, 0])
        withPadding[3] = 2
        XCTAssertEqual(ParticipantEntitiesInfo.decodeReceived(withPadding, preferredGidSize: 16), info)
        XCTAssertNil(
            ParticipantEntitiesInfo.decodeReceived(info.encode(gidSize: 16) + Data([0, 0]), preferredGidSize: 16))
        XCTAssertNil(ParticipantEntitiesInfo.decodeReceived(Data([0, 1, 0, 0, 1]), preferredGidSize: 16))
    }

    // MARK: - Helpers

    private static let pad8 = [UInt8](repeating: 0, count: 8)

    private func openSession(distro: ROS2Distro = .jazzy) async throws -> (DDSTransportSession, MockDDSClient) {
        let client = MockDDSClient()
        let prefix = Self.randomPrefix()
        client.entityGuidPrefix = prefix
        client.participantGuidValue = prefix + [0x00, 0x00, 0x01, 0xC1]
        let session = DDSTransportSession(client: client)
        try await session.open(config: TransportConfig(type: .dds, wireMode: distro))
        return (session, client)
    }

    private func assertRecordAttributes(sessionDistro: ROS2Distro, gidSize: Int) async throws {
        let (session, client) = try await openSession(distro: sessionDistro)
        defer { try? session.close() }
        let participant = Self.remoteParticipant()
        let writer = Self.guid(participant, 0x103)
        client.discoverySnapshotValue = DDSDiscoverySnapshot(
            publications: [
                Self.publication(participant, 0x103, topic: "rt/chatter", type: "std_msgs::msg::dds_::String_")
            ],
            participantGUIDs: [participant])
        deliverRecord(
            client,
            ParticipantEntitiesInfo(
                participantGid: participant, nodes: [.init(namespace: "/h", name: "talker", writerGids: [writer])]),
            gidSize: gidSize)

        let endpoints = try await session.publisherEndpoints()
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.nodeName, "talker")
        XCTAssertEqual(endpoint.nodeNamespace, "/h")
    }

    private func deliverRecord(_ client: MockDDSClient, _ info: ParticipantEntitiesInfo, gidSize: Int) {
        client.deliver(toTopic: ParticipantEntitiesInfo.topicName, data: info.encode(gidSize: gidSize), timestamp: 0)
    }

    private func assertThrowsNotConnected(
        _ body: () async throws -> [GraphPublisherEndpoint], file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected notConnected", file: file, line: line)
        } catch TransportError.notConnected {
        } catch {
            XCTFail("expected notConnected, got \(error)", file: file, line: line)
        }
    }

    private static func randomPrefix() -> [UInt8] {
        (0..<12).map { _ in UInt8.random(in: 0...255) }
    }

    /// A remote participant's GUID: a random 12-byte prefix and the participant entity id.
    private static func remoteParticipant() -> [UInt8] {
        randomPrefix() + [0x00, 0x00, 0x01, 0xC1]
    }

    /// The GUID of entity `entityId` of `participant`.
    private static func guid(_ participant: [UInt8], _ entityId: UInt32) -> [UInt8] {
        Array(participant.prefix(12)) + withUnsafeBytes(of: entityId.bigEndian, Array.init)
    }

    private static func publication(
        _ participant: [UInt8], _ entityId: UInt32, topic: String, type: String,
        reliability: DDSDiscoveredPublication.Reliability = .reliable,
        durability: DDSDiscoveredPublication.Durability = .volatile
    ) -> DDSDiscoveredPublication {
        DDSDiscoveredPublication(
            endpointGUID: guid(participant, entityId), participantGUID: participant, topicName: topic,
            typeName: type, reliability: reliability, durability: durability)
    }

    private static func publication(
        guid: [UInt8], participant: [UInt8], topic: String, type: String = "std_msgs::msg::dds_::String_"
    ) -> DDSDiscoveredPublication {
        DDSDiscoveredPublication(
            endpointGUID: guid, participantGUID: participant, topicName: topic, typeName: type,
            reliability: .reliable, durability: .volatile)
    }
}

/// A value shared with a `@Sendable` hook.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
