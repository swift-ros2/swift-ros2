import Foundation
import XCTest

@testable import SwiftROS2DDS
@testable import SwiftROS2Transport

/// Closing a wire DDS session deletes its participant. It used to be leaked:
/// it stayed on the network and kept its memory until the process exited.
///
/// The domains stay at or below 101. A domain binds fixed UDP ports from
/// 7400 + 250 × id, and above 101 they fall in the ephemeral port range
/// (Linux 32768+, Windows 49152+). Windows reserves 100-port blocks of that
/// range at boot (`netsh int ipv4 show excludedportrange protocol=udp`), and
/// binding a reserved port fails with WSAEACCES, which CycloneDDS logs as
/// "failed to bind to ANY:<port>: Not allowed" and the session reports as a
/// failed domain creation.
final class SessionCloseTests: XCTestCase {
    private let type = "std_msgs::msg::dds_::String_"
    /// A std_msgs/String "hi": encapsulation header, length, bytes.
    private let payload = Data([0, 1, 0, 0, 3, 0, 0, 0, 0x68, 0x69, 0])

    /// Deleting the participant deletes the endpoints it still owns. A reader
    /// hangs directly off the participant, so a writer in another session
    /// loses its match on a reader whose session was closed without closing
    /// the reader first; a leaked participant would keep the reader matched.
    func testClosingASessionDeletesItsParticipant() async throws {
        let config = DDSBridgeDiscoveryConfig(mode: .multicast)
        let topic = "rt/swift_ros2_session_close_test"
        let observer = DDSClient()
        try observer.createSession(domainId: 71, discoveryConfig: config)
        defer { try? observer.destroySession() }
        let writer = try observer.createRawWriter(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil)
        defer { observer.destroyWriter(writer) }

        let closing = DDSClient()
        try closing.createSession(domainId: 71, discoveryConfig: config)
        let reader = try closing.createRawReader(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil, handler: { _, _ in })
        try await waitUntil { observer.isPublicationMatched(writer: writer) }

        try closing.destroySession()
        try await waitUntil { !observer.isPublicationMatched(writer: writer) }
        // Releases the bridge's reader record; its entity went with the participant.
        closing.destroyReader(reader)
    }

    /// Sessions can be opened and closed many times in one process: every
    /// close returns promptly and every new pair of sessions exchanges data.
    func testRepeatedOpenAndCloseKeepsWorking() throws {
        let config = DDSBridgeDiscoveryConfig(mode: .multicast)
        let topic = "rt/swift_ros2_session_reopen_test"
        let qos = DDSBridgeQoSConfig(reliability: .reliable)
        for round in 0..<20 {
            let publisher = DDSClient()
            let subscriber = DDSClient()
            try publisher.createSession(domainId: 72, discoveryConfig: config)
            try subscriber.createSession(domainId: 72, discoveryConfig: config)
            let received = DispatchSemaphore(value: 0)
            let reader = try subscriber.createRawReader(
                topicName: topic, typeName: type, qos: qos, userData: nil, handler: { _, _ in received.signal() })
            let writer = try publisher.createRawWriter(topicName: topic, typeName: type, qos: qos, userData: nil)

            var delivered = false
            let deadline = Date().addingTimeInterval(5)
            while !delivered, Date() < deadline {
                try publisher.writeRawCDR(writer: writer, data: payload, timestamp: 0)
                delivered = received.wait(timeout: .now() + .milliseconds(50)) == .success
            }
            XCTAssertTrue(delivered, "round \(round): no sample delivered")

            publisher.destroyWriter(writer)
            subscriber.destroyReader(reader)
            let start = Date()
            try publisher.destroySession()
            try subscriber.destroySession()
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "round \(round): closing took too long")
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
