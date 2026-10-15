import Foundation
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2DDS
@testable import SwiftROS2Transport

/// A wire DDS session announces its nodes on `ros_discovery_info` through the
/// real CycloneDDS bridge, with the participant and endpoint GUIDs that DDS
/// discovery reports for them.
final class DiscoveryInfoAnnouncementTests: XCTestCase {
    func testSessionAnnouncesItsNodeAndEndpointGUIDs() async throws {
        // At or below 101, so the domain's fixed UDP ports (7400 + 250 × id) stay
        // out of the ephemeral port range (see SessionCloseTests).
        let domainId: Int32 = 74
        let observer = DDSClient()
        try observer.createSession(domainId: domainId, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? observer.destroySession() }
        let samples = Box<[Data]>([])
        let reader = try observer.createRawReader(
            topicName: ParticipantEntitiesInfo.topicName,
            typeName: ParticipantEntitiesInfo.ddsTypeName,
            qos: DDSBridgeQoSConfig(reliability: .reliable, durability: .transientLocal, historyDepth: 1),
            userData: nil,
            handler: { data, _ in samples.append(data) })
        defer { observer.destroyReader(reader) }

        let session = DDSTransportSession(client: DDSClient())
        try await session.open(config: TransportConfig(type: .dds, domainId: Int(domainId), wireMode: .jazzy))
        defer { try? session.close() }
        // The session id is the participant GUID in hex.
        let participantGid = Self.bytes(hex: session.sessionId)
        XCTAssertEqual(participantGid.count, 16)

        /// The latest record of the session's participant.
        func latest() -> ParticipantEntitiesInfo? {
            samples.value.compactMap { try? ParticipantEntitiesInfo(decoding: $0, gidSize: 16) }
                .last { $0.participantGid == participantGid }
        }

        try session.registerNode(name: "announcer", namespace: "/discovery_test")
        let publisher = try session.createPublisher(
            topic: "/discovery_test/chatter", typeName: "std_msgs/msg/String", typeHash: nil, qos: .default,
            nodeName: "announcer", nodeNamespace: "/discovery_test")
        await waitUntil("the publisher is announced") { latest()?.nodes.first?.writerGids.count == 1 }

        let node = try XCTUnwrap(latest()?.nodes.first)
        XCTAssertEqual(node.namespace, "/discovery_test")
        XCTAssertEqual(node.name, "announcer")
        XCTAssertEqual(node.readerGids, [])
        let writerGid = try XCTUnwrap(node.writerGids.first)
        XCTAssertEqual(
            writerGid.prefix(12), participantGid.prefix(12), "an endpoint GUID shares its participant's prefix")
        XCTAssertNotEqual(writerGid, participantGid)

        try publisher.close()
        await waitUntil("the closed publisher is withdrawn") { latest()?.nodes.first?.writerGids == [] }

        session.unregisterNode(name: "announcer", namespace: "/discovery_test")
        await waitUntil("the node is withdrawn") { latest()?.nodes == [] }
    }

    private static func bytes(hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        return stride(from: 0, to: chars.count - 1, by: 2).compactMap {
            UInt8(String(decoding: chars[$0..<$0 + 2], as: UTF8.self), radix: 16)
        }
    }
}
