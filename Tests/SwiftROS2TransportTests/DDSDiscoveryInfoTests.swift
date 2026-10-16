import Foundation
import SwiftROS2Wire
import XCTest

@testable import SwiftROS2Transport

/// The `ros_discovery_info` record (`rmw_dds_common/msg/ParticipantEntitiesInfo`)
/// and when the wire DDS session publishes it.
final class DDSDiscoveryInfoTests: XCTestCase {
    // MARK: - Encoding (golden bytes)

    // Each golden sample is a `ros_discovery_info` record that an rmw_cyclonedds_cpp
    // participant published: an rclpy node `/golden/golden_node` with one
    // publisher, one subscription and the default parameter services, captured
    // with a raw CycloneDDS reader. Every gid is the participant's 12-byte GUID
    // prefix plus a 4-byte entity id.

    /// Jazzy (rmw_cyclonedds_cpp 2.2.3, CycloneDDS 0.10.5): 16-byte gids.
    func testEncodeMatchesJazzyGolden() throws {
        let info = Self.goldenInfo(
            prefix: "0110eeaabf19d1f7cb203cb1",
            readers: ["0904", "0b04", "0d04", "0f04", "1104", "1304", "1504", "1704"],
            writers: ["0603", "0703", "0803", "0a03", "0c03", "0e03", "1003", "1203", "1403", "1603"])
        let golden = Self.bytes([
            "000100000110eeaabf19d1f7cb203cb1000001c101000000080000002f676f6c64656e000c000000676f6c64656e5f6e",
            "6f646500080000000110eeaabf19d1f7cb203cb1000009040110eeaabf19d1f7cb203cb100000b040110eeaabf19d1f7",
            "cb203cb100000d040110eeaabf19d1f7cb203cb100000f040110eeaabf19d1f7cb203cb1000011040110eeaabf19d1f7",
            "cb203cb1000013040110eeaabf19d1f7cb203cb1000015040110eeaabf19d1f7cb203cb1000017040a0000000110eeaa",
            "bf19d1f7cb203cb1000006030110eeaabf19d1f7cb203cb1000007030110eeaabf19d1f7cb203cb1000008030110eeaa",
            "bf19d1f7cb203cb100000a030110eeaabf19d1f7cb203cb100000c030110eeaabf19d1f7cb203cb100000e030110eeaa",
            "bf19d1f7cb203cb1000010030110eeaabf19d1f7cb203cb1000012030110eeaabf19d1f7cb203cb1000014030110eeaa",
            "bf19d1f7cb203cb100001603",
        ])
        try assertGolden(info, golden, distro: .jazzy)
    }

    /// Lyrical (rmw_cyclonedds_cpp 4.1.5, CycloneDDS 11.0.1): same shape as Jazzy.
    func testEncodeMatchesLyricalGolden() throws {
        let info = Self.goldenInfo(
            prefix: "01100d0203c4ee6832d7e272",
            readers: ["0e04", "1204", "1604", "1a04", "1e04", "2204", "2604", "2a04"],
            writers: ["0803", "0a03", "0d03", "1103", "1503", "1903", "1d03", "2103", "2503", "2803"])
        let golden = Self.bytes([
            "0001000001100d0203c4ee6832d7e272000001c101000000080000002f676f6c64656e000c000000676f6c64656e5f6e",
            "6f6465000800000001100d0203c4ee6832d7e27200000e0401100d0203c4ee6832d7e2720000120401100d0203c4ee68",
            "32d7e2720000160401100d0203c4ee6832d7e27200001a0401100d0203c4ee6832d7e27200001e0401100d0203c4ee68",
            "32d7e2720000220401100d0203c4ee6832d7e2720000260401100d0203c4ee6832d7e27200002a040a00000001100d02",
            "03c4ee6832d7e2720000080301100d0203c4ee6832d7e27200000a0301100d0203c4ee6832d7e27200000d0301100d02",
            "03c4ee6832d7e2720000110301100d0203c4ee6832d7e2720000150301100d0203c4ee6832d7e2720000190301100d02",
            "03c4ee6832d7e27200001d0301100d0203c4ee6832d7e2720000210301100d0203c4ee6832d7e2720000250301100d02",
            "03c4ee6832d7e27200002803",
        ])
        try assertGolden(info, golden, distro: .lyrical)
    }

    /// Humble (CycloneDDS 0.9): 24-byte gids, the 16-byte GUID zero-padded.
    func testEncodeMatchesHumbleGolden() throws {
        let info = Self.goldenInfo(
            prefix: "0110a00a450b8a2a9318281b",
            readers: ["0904", "0b04", "0d04", "0f04", "1104", "1304", "1504"],
            writers: ["0603", "0703", "0803", "0a03", "0c03", "0e03", "1003", "1203", "1403"])
        let golden = Self.bytes([
            "000100000110a00a450b8a2a9318281b000001c1000000000000000001000000080000002f676f6c64656e000c000000",
            "676f6c64656e5f6e6f646500070000000110a00a450b8a2a9318281b0000090400000000000000000110a00a450b8a2a",
            "9318281b00000b0400000000000000000110a00a450b8a2a9318281b00000d0400000000000000000110a00a450b8a2a",
            "9318281b00000f0400000000000000000110a00a450b8a2a9318281b0000110400000000000000000110a00a450b8a2a",
            "9318281b0000130400000000000000000110a00a450b8a2a9318281b000015040000000000000000090000000110a00a",
            "450b8a2a9318281b0000060300000000000000000110a00a450b8a2a9318281b0000070300000000000000000110a00a",
            "450b8a2a9318281b0000080300000000000000000110a00a450b8a2a9318281b00000a0300000000000000000110a00a",
            "450b8a2a9318281b00000c0300000000000000000110a00a450b8a2a9318281b00000e0300000000000000000110a00a",
            "450b8a2a9318281b0000100300000000000000000110a00a450b8a2a9318281b0000120300000000000000000110a00a",
            "450b8a2a9318281b000014030000000000000000",
        ])
        try assertGolden(info, golden, distro: .humble)
    }

    /// The record an rmw_cyclonedds_cpp participant publishes before it has a node.
    func testEncodeEmptyRecord() {
        let gid = [UInt8](Self.bytes(["0110eeaabf19d1f7cb203cb1000001c1"]))
        let info = ParticipantEntitiesInfo(participantGid: gid)
        XCTAssertEqual(
            info.encode(gidSize: 16), Self.bytes(["00010000", "0110eeaabf19d1f7cb203cb1000001c1", "00000000"]))
        XCTAssertEqual(
            info.encode(gidSize: 24),
            Self.bytes(["00010000", "0110eeaabf19d1f7cb203cb1000001c1", "0000000000000000", "00000000"]))
    }

    func testGidSizeAndUserDataFollowTheDistribution() {
        XCTAssertEqual(ParticipantEntitiesInfo.gidSize(for: .humble), 24)
        XCTAssertNil(ParticipantEntitiesInfo.userData(for: .humble))
        for distro in [ROS2Distro.jazzy, .kilted, .lyrical] {
            XCTAssertEqual(ParticipantEntitiesInfo.gidSize(for: distro), 16, "\(distro)")
            XCTAssertEqual(
                ParticipantEntitiesInfo.userData(for: distro),
                "typehash=RIHS01_91a0593bacdcc50ea9bdcf849a938b128412cc1ea821245c663bcd26f83c295e;", "\(distro)")
        }
    }

    // MARK: - Session announcements

    func testOpenPublishesAnEmptyRecordOnALatchedWriter() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }

        let writer = try XCTUnwrap(client.writers.first { $0.topic == "ros_discovery_info" })
        XCTAssertEqual(writer.type, "rmw_dds_common::msg::dds_::ParticipantEntitiesInfo_")
        XCTAssertEqual(writer.qos.reliability, .reliable)
        XCTAssertEqual(writer.qos.durability, .transientLocal)
        XCTAssertEqual(writer.qos.historyKind, .keepLast)
        XCTAssertEqual(writer.qos.historyDepth, 1)
        XCTAssertEqual(writer.userData, ParticipantEntitiesInfo.userData(for: .jazzy))

        let record = try latestRecord(client)
        XCTAssertEqual(record, ParticipantEntitiesInfo(participantGid: Self.participantGid))
    }

    func testHumbleSessionUses24ByteGidsAndNoTypeHash() async throws {
        let (session, client) = try await openSession(distro: .humble)
        defer { try? session.close() }
        try session.registerNode(name: "talker", namespace: "/e2e")
        _ = try session.createPublisher(
            topic: "/e2e/chatter", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "talker", nodeNamespace: "/e2e")

        let writer = try XCTUnwrap(client.writers.first { $0.topic == "ros_discovery_info" })
        XCTAssertNil(writer.userData)
        let data = try XCTUnwrap(client.lastWritten(topic: "ros_discovery_info"))
        // header 4, gid 24, node count 4, "/e2e" 12, "talker" 12, reader count 4, writer count 4, gid 24
        XCTAssertEqual(data.count, 88)
        let record = try ParticipantEntitiesInfo(decoding: data, gidSize: 24)
        XCTAssertEqual(record.participantGid, Self.participantGid + [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(record.nodes.map(\.writerGids), [[client.writerGUIDs(topic: "rt/e2e/chatter")[0] + Self.pad8]])
    }

    func testWithoutAParticipantGUIDNothingIsAnnounced() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast())
        try session.registerNode(name: "talker", namespace: "/")
        _ = try session.createPublisher(
            topic: "/chatter", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "talker", nodeNamespace: "/")
        try session.close()

        XCTAssertFalse(client.writers.contains { $0.topic == "ros_discovery_info" })
        XCTAssertEqual(client.allWrites(topic: "ros_discovery_info"), [])
    }

    func testNodesAndTheirTopicEndpointsAreAnnounced() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }

        try session.registerNode(name: "talker", namespace: "/e2e_200")
        XCTAssertEqual(try latestRecord(client).nodes, [.init(namespace: "/e2e_200", name: "talker")])

        let pub = try session.createPublisher(
            topic: "/e2e_200/chatter", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "talker", nodeNamespace: "/e2e_200")
        let sub = try session.createSubscriber(
            topic: "/e2e_200/heard", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "talker", nodeNamespace: "/e2e_200", handler: { _, _ in })
        let writerGid = client.writerGUIDs(topic: "rt/e2e_200/chatter")
        let readerGid = client.readerGUIDs(topic: "rt/e2e_200/heard")
        XCTAssertEqual(
            try latestRecord(client).nodes,
            [.init(namespace: "/e2e_200", name: "talker", readerGids: readerGid, writerGids: writerGid)])

        try pub.close()
        XCTAssertEqual(
            try latestRecord(client).nodes,
            [.init(namespace: "/e2e_200", name: "talker", readerGids: readerGid)])
        try sub.close()
        XCTAssertEqual(try latestRecord(client).nodes, [.init(namespace: "/e2e_200", name: "talker")])

        session.unregisterNode(name: "talker", namespace: "/e2e_200")
        XCTAssertEqual(try latestRecord(client).nodes, [])
    }

    func testServiceAndActionEndpointsAreAnnouncedInOneRecordEach() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        try session.registerNode(name: "server", namespace: "/")

        var writes = client.allWrites(topic: "ros_discovery_info").count
        _ = try session.createServiceServer(
            name: "/trigger", serviceTypeName: "std_srvs/srv/Trigger", requestTypeHash: nil,
            responseTypeHash: nil, qos: .default, nodeName: "server", nodeNamespace: "/",
            handler: { $0 })
        XCTAssertEqual(client.allWrites(topic: "ros_discovery_info").count, writes + 1)
        var node = try XCTUnwrap(latestRecord(client).nodes.first)
        XCTAssertEqual(node.readerGids, client.readerGUIDs(topic: "rq/triggerRequest"))
        XCTAssertEqual(node.writerGids, client.writerGUIDs(topic: "rr/triggerReply"))

        writes = client.allWrites(topic: "ros_discovery_info").count
        _ = try session.createActionServer(
            name: "/fibonacci", actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: Self.noHashes, qos: .default, nodeName: "server", nodeNamespace: "/",
            handlers: Self.noopActionHandlers)
        XCTAssertEqual(client.allWrites(topic: "ros_discovery_info").count, writes + 1)
        node = try XCTUnwrap(latestRecord(client).nodes.first)
        XCTAssertEqual(node.readerGids.count, 1 + 3)
        XCTAssertEqual(node.writerGids.count, 1 + 5)

        _ = try session.createActionClient(
            name: "/fibonacci", actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: Self.noHashes, qos: .default, nodeName: "server", nodeNamespace: "/")
        _ = try session.createServiceClient(
            name: "/trigger", serviceTypeName: "std_srvs/srv/Trigger", requestTypeHash: nil,
            responseTypeHash: nil, qos: .default, nodeName: "server", nodeNamespace: "/")
        node = try XCTUnwrap(latestRecord(client).nodes.first)
        XCTAssertEqual(node.readerGids.count, 1 + 3 + 5 + 1)
        XCTAssertEqual(node.writerGids.count, 1 + 5 + 3 + 1)
        XCTAssertEqual(Set(node.readerGids + node.writerGids).count, 20, "every gid is a distinct endpoint")
    }

    func testEndpointsWithoutARegisteredNodeAreNotListed() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        let writes = client.allWrites(topic: "ros_discovery_info").count

        _ = try session.createPublisher(
            topic: "/plain", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default)
        _ = try session.createPublisher(
            topic: "/orphan", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "unregistered", nodeNamespace: "/")

        XCTAssertEqual(client.allWrites(topic: "ros_discovery_info").count, writes)
        XCTAssertEqual(try latestRecord(client).nodes, [])
    }

    func testFailedCreateRecordsNothing() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        try session.registerNode(name: "server", namespace: "/")
        let writes = client.allWrites(topic: "ros_discovery_info").count

        client.failReaderAfter = 0
        XCTAssertThrowsError(
            try session.createServiceServer(
                name: "/trigger", serviceTypeName: "std_srvs/srv/Trigger", requestTypeHash: nil,
                responseTypeHash: nil, qos: .default, nodeName: "server", nodeNamespace: "/",
                handler: { $0 }))

        XCTAssertEqual(client.destroyedWriters, 1, "the reply writer is rolled back")
        XCTAssertEqual(client.allWrites(topic: "ros_discovery_info").count, writes)
        XCTAssertEqual(try latestRecord(client).nodes, [.init(namespace: "/", name: "server")])
    }

    func testNamespacesAreNormalized() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        try session.registerNode(name: "a", namespace: "")
        try session.registerNode(name: "b", namespace: "ns/")
        XCTAssertEqual(try latestRecord(client).nodes.map(\.namespace), ["/", "/ns"])

        session.unregisterNode(name: "b", namespace: "/ns")
        XCTAssertEqual(try latestRecord(client).nodes.map(\.name), ["a"])
    }

    func testCloseDestroysTheDiscoveryWriterBeforeTheEntities() async throws {
        let (session, client) = try await openSession()
        try session.registerNode(name: "talker", namespace: "/")
        _ = try session.createPublisher(
            topic: "/chatter", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "talker", nodeNamespace: "/")
        let writes = client.allWrites(topic: "ros_discovery_info").count

        try session.close()

        XCTAssertEqual(client.openWriterCount(topic: "ros_discovery_info"), 0)
        XCTAssertEqual(
            client.allWrites(topic: "ros_discovery_info").count, writes,
            "closing the publisher does not announce a record any more")
    }

    // MARK: - Helpers

    private static let participantGid: [UInt8] = Array(repeating: 0xCD, count: 12) + [0x00, 0x00, 0x01, 0xC1]
    private static let pad8 = [UInt8](repeating: 0, count: 8)

    private static let noopActionHandlers = TransportActionServerHandlers(
        onSendGoal: { _, _ in (false, 0, 0) },
        onCancelGoal: { _ in Data() },
        onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) })

    private static let noHashes = ActionRoleTypeHashes(
        sendGoalRequest: nil, sendGoalResponse: nil, cancelGoalRequest: nil, cancelGoalResponse: nil,
        getResultRequest: nil, getResultResponse: nil, feedbackMessage: nil, statusArray: nil)

    private func openSession(distro: ROS2Distro = .jazzy) async throws -> (DDSTransportSession, MockDDSClient) {
        let client = MockDDSClient()
        client.participantGuidValue = Self.participantGid
        let session = DDSTransportSession(client: client)
        try await session.open(config: TransportConfig(type: .dds, wireMode: distro))
        return (session, client)
    }

    private func latestRecord(_ client: MockDDSClient) throws -> ParticipantEntitiesInfo {
        let data = try XCTUnwrap(client.lastWritten(topic: "ros_discovery_info"))
        return try ParticipantEntitiesInfo(decoding: data, gidSize: 16)
    }

    private func assertGolden(
        _ info: ParticipantEntitiesInfo, _ golden: Data, distro: ROS2Distro,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let gidSize = ParticipantEntitiesInfo.gidSize(for: distro)
        XCTAssertEqual(info.encode(gidSize: gidSize).hex, golden.hex, file: file, line: line)

        let decoded = try ParticipantEntitiesInfo(decoding: golden, gidSize: gidSize)
        let padding = [UInt8](repeating: 0, count: gidSize - 16)
        let padded = ParticipantEntitiesInfo(
            participantGid: info.participantGid + padding,
            nodes: info.nodes.map {
                .init(
                    namespace: $0.namespace, name: $0.name, readerGids: $0.readerGids.map { $0 + padding },
                    writerGids: $0.writerGids.map { $0 + padding })
            })
        XCTAssertEqual(decoded, padded, file: file, line: line)
    }

    /// The captured node: `/golden/golden_node`, its gids given by entity id.
    private static func goldenInfo(prefix: String, readers: [String], writers: [String]) -> ParticipantEntitiesInfo {
        func gid(_ entityId: String) -> [UInt8] { [UInt8](bytes([prefix, entityId])) }
        return ParticipantEntitiesInfo(
            participantGid: gid("000001c1"),
            nodes: [
                .init(
                    namespace: "/golden", name: "golden_node", readerGids: readers.map { gid("0000" + $0) },
                    writerGids: writers.map { gid("0000" + $0) })
            ])
    }

    private static func bytes(_ hexChunks: [String]) -> Data {
        let hex = Array(hexChunks.joined().utf8)
        var data = Data(capacity: hex.count / 2)
        for i in stride(from: 0, to: hex.count, by: 2) {
            data.append(UInt8(String(decoding: hex[i..<i + 2], as: UTF8.self), radix: 16)!)
        }
        return data
    }
}

extension MockDDSClient {
    /// The GUIDs of the writers created on `topic`, oldest first.
    fileprivate func writerGUIDs(topic: String) -> [[UInt8]] {
        createdWriterHandles.filter { $0.topic == topic }.map(\.guid)
    }

    /// The GUIDs of the readers created on `topic`, oldest first.
    fileprivate func readerGUIDs(topic: String) -> [[UInt8]] {
        createdReaderHandles.filter { $0.topic == topic }.map(\.guid)
    }
}

extension Data {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
