import Foundation
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2DDS

/// `DDSClient.discoverySnapshot()` against the real CycloneDDS: the builtin
/// `DCPSPublication` and `DCPSParticipant` readers behind the topic graph.
///
/// Domain 78 is the topic graph tests' domain; it is at or below 101, so its fixed UDP
/// ports stay out of the range Windows reserves.
final class DDSClientDiscoveryTests: XCTestCase {
    private static let domainId: Int32 = 78
    private static let type = "std_msgs::msg::dds_::String_"

    func testSnapshotWithoutSessionThrowsNotConnected() {
        XCTAssertThrowsError(try DDSClient().discoverySnapshot()) { error in
            guard case DDSError.notConnected = error else {
                return XCTFail("Expected .notConnected, got \(error)")
            }
        }
    }

    func testSnapshotListsLocalWritersWithGUIDsAndQoS() async throws {
        let client = DDSClient()
        try client.createSession(domainId: Self.domainId, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? client.destroySession() }
        let participant = try XCTUnwrap(client.participantGUID())

        let latchedTopic = "rt/swift_ros2_snapshot_test/latched"
        let bestEffortTopic = "rt/swift_ros2_snapshot_test/best_effort"
        let latched = try client.createRawWriter(
            topicName: latchedTopic, typeName: Self.type,
            qos: DDSBridgeQoSConfig(reliability: .reliable, durability: .transientLocal, historyDepth: 1),
            userData: nil)
        let bestEffort = try client.createRawWriter(
            topicName: bestEffortTopic, typeName: Self.type, qos: DDSBridgeQoSConfig(), userData: nil)
        let latchedGUID = try XCTUnwrap(client.writerGUID(latched))
        let bestEffortGUID = try XCTUnwrap(client.writerGUID(bestEffort))

        // Local endpoints are listed at once; the first call creates the builtin readers.
        let snapshot = try client.discoverySnapshot()
        let byGUID = Dictionary(snapshot.publications.map { ($0.endpointGUID, $0) }) { first, _ in first }
        XCTAssertEqual(
            byGUID[latchedGUID],
            DDSDiscoveredPublication(
                endpointGUID: latchedGUID, participantGUID: participant, topicName: latchedTopic,
                typeName: Self.type, reliability: .reliable, durability: .transientLocal))
        XCTAssertEqual(
            byGUID[bestEffortGUID],
            DDSDiscoveredPublication(
                endpointGUID: bestEffortGUID, participantGUID: participant, topicName: bestEffortTopic,
                typeName: Self.type, reliability: .bestEffort, durability: .volatile))
        XCTAssertTrue(snapshot.participantGUIDs.contains(participant))

        // A destroyed writer leaves the next snapshot.
        client.destroyWriter(bestEffort)
        let after = try client.discoverySnapshot()
        XCTAssertFalse(after.publications.contains { $0.endpointGUID == bestEffortGUID })
        XCTAssertTrue(after.publications.contains { $0.endpointGUID == latchedGUID })
        client.destroyWriter(latched)
    }

    /// More writers than the first read batch holds: the read grows its buffers and
    /// later reads and takes keep using the grown size.
    func testSnapshotListsMoreWritersThanOneBatchOnEveryCall() throws {
        let client = DDSClient()
        try client.createSession(domainId: Self.domainId, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? client.destroySession() }

        var writers: [any DDSWriterHandle] = []
        for index in 0..<300 {
            writers.append(
                try client.createRawWriter(
                    topicName: "rt/swift_ros2_snapshot_test/many_\(index)", typeName: Self.type,
                    qos: DDSBridgeQoSConfig(), userData: nil))
        }
        let guids = Set(writers.compactMap { client.writerGUID($0) })
        XCTAssertEqual(guids.count, 300)

        for call in 0..<3 {
            let listed = Set(try client.discoverySnapshot().publications.map(\.endpointGUID))
            XCTAssertTrue(guids.isSubset(of: listed), "call \(call)")
        }
        for writer in writers.prefix(150) { client.destroyWriter(writer) }
        let listed = Set(try client.discoverySnapshot().publications.map(\.endpointGUID))
        XCTAssertEqual(guids.intersection(listed).count, 150)
        for writer in writers.dropFirst(150) { client.destroyWriter(writer) }
    }

    func testSnapshotListsAnotherParticipantInTheProcess() async throws {
        let observer = DDSClient()
        try observer.createSession(domainId: Self.domainId, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? observer.destroySession() }
        let other = DDSClient()
        try other.createSession(domainId: Self.domainId, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        let otherParticipant = try XCTUnwrap(other.participantGUID())
        let writer = try other.createRawWriter(
            topicName: "rt/swift_ros2_snapshot_test/other", typeName: Self.type, qos: DDSBridgeQoSConfig(),
            userData: nil)
        let writerGUID = try XCTUnwrap(other.writerGUID(writer))

        await waitUntil("the observer lists the other participant's writer", interval: .milliseconds(50)) {
            ((try? observer.discoverySnapshot())?.publications ?? []).contains {
                $0.endpointGUID == writerGUID && $0.participantGUID == otherParticipant
            }
        }
        XCTAssertTrue(try observer.discoverySnapshot().participantGUIDs.contains(otherParticipant))

        // Deleting the participant disposes its endpoints and itself.
        other.destroyWriter(writer)
        try other.destroySession()
        await waitUntil("the other participant leaves the snapshot", interval: .milliseconds(50)) {
            guard let snapshot = try? observer.discoverySnapshot() else { return false }
            return !snapshot.participantGUIDs.contains(otherParticipant)
                && !snapshot.publications.contains { $0.endpointGUID == writerGUID }
        }
    }
}
