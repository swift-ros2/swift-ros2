import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2DDS

final class DDSClientSmokeTests: XCTestCase {
    func testWriteWithForeignHandleThrows() throws {
        let client = DDSClient()
        let foreign = ForeignWriterHandle()
        XCTAssertThrowsError(
            try client.writeRawCDR(
                writer: foreign, data: Data([0x00, 0x01, 0x00, 0x00]), timestamp: 0)
        ) { error in
            guard let e = error as? DDSError else {
                XCTFail("Expected DDSError, got \(type(of: error))")
                return
            }
            if case .writeFailed = e {
                // ok
            } else {
                XCTFail("Expected .writeFailed, got \(e)")
            }
        }
    }

    func testDestroyReaderWithForeignHandleIsNoOp() {
        let client = DDSClient()
        let foreign = ForeignReaderHandle()
        // destroyReader is non-throwing; the client must silently no-op on a
        // handle it didn't create rather than force-cast into its private box.
        client.destroyReader(foreign)
    }

    func testCreateReaderWithoutSessionThrows() throws {
        let client = DDSClient()
        XCTAssertThrowsError(
            try client.createRawReader(
                topicName: "rt/test",
                typeName: "std_msgs::msg::dds_::String_",
                qos: DDSBridgeQoSConfig(),
                userData: nil,
                handler: { _, _ in }
            )
        ) { error in
            guard let e = error as? DDSError else {
                XCTFail("Expected DDSError, got \(type(of: error))")
                return
            }
            if case .notConnected = e {
                // ok
            } else {
                XCTFail("Expected .notConnected, got \(e)")
            }
        }
    }

    /// `isPublicationMatched` / `isSubscriptionMatched` follow CycloneDDS's
    /// matched status: a service client's `waitForService` relies on them.
    func testMatchedStatusFollowsLocalEndpoints() async throws {
        let client = DDSClient()
        // A domain at or below 101 keeps its fixed UDP ports (7400 + 250 × id)
        // out of the ephemeral range, where Windows reserves blocks no socket can bind.
        try client.createSession(domainId: 77, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? client.destroySession() }

        let topic = "rt/swift_ros2_matched_status_test"
        let type = "std_msgs::msg::dds_::String_"
        let writer = try client.createRawWriter(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil)
        XCTAssertFalse(client.isPublicationMatched(writer: writer))

        let reader = try client.createRawReader(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil, handler: { _, _ in })
        await waitUntil {
            client.isPublicationMatched(writer: writer) && client.isSubscriptionMatched(reader: reader)
        }

        client.destroyWriter(writer)
        XCTAssertFalse(client.isPublicationMatched(writer: writer), "a closed writer reports unmatched")
        await waitUntil { !client.isSubscriptionMatched(reader: reader) }

        client.destroyReader(reader)
        XCTAssertFalse(client.isSubscriptionMatched(reader: reader), "a closed reader reports unmatched")
        XCTAssertFalse(client.isSubscriptionMatched(reader: ForeignReaderHandle()))
    }
}

private final class ForeignWriterHandle: DDSWriterHandle {
    var isActive: Bool { false }
    func close() {}
}

private final class ForeignReaderHandle: DDSReaderHandle {
    var isActive: Bool { false }
    func close() {}
}
