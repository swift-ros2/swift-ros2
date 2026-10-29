import Foundation
import XCTest

@testable import SwiftROS2DDS
@testable import SwiftROS2Transport

/// Destroying a reader while a writer in another session of the same process
/// keeps delivering to it. CycloneDDS delivers a local sample on the writing
/// thread, so the reader's listener runs there while another thread destroys
/// the reader (#326). The Thread Sanitizer CI jobs run this class and fail on
/// any race report; a plain run checks that it neither crashes nor hangs.
///
/// The domain stays at or below 101: see `SessionCloseTests`.
final class DDSEndpointTeardownTests: XCTestCase {
    private let type = "std_msgs::msg::dds_::String_"
    /// A std_msgs/String "hi": encapsulation header, length, bytes.
    private let payload = Data([0, 1, 0, 0, 3, 0, 0, 0, 0x68, 0x69, 0])

    func testDestroyingAReaderWhileALocalWriterDeliversToIt() throws {
        let config = DDSBridgeDiscoveryConfig(mode: .multicast)
        let topic = "rt/swift_ros2_endpoint_teardown_test"
        let publisher = DDSClient()
        try publisher.createSession(domainId: 82, discoveryConfig: config)
        defer { try? publisher.destroySession() }
        let subscriber = DDSClient()
        try subscriber.createSession(domainId: 82, discoveryConfig: config)
        defer { try? subscriber.destroySession() }

        let writer = try publisher.createRawWriter(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil)
        defer { publisher.destroyWriter(writer) }

        let stop = NSLock()
        var stopped = false
        let writing = DispatchGroup()
        DispatchQueue.global().async(group: writing) { [payload] in
            while !stop.withLock({ stopped }) {
                try? publisher.writeRawCDR(writer: writer, data: payload, timestamp: 0)
            }
        }
        defer {
            stop.withLock { stopped = true }
            writing.wait()
        }

        var matchedRounds = 0
        for _ in 0..<30 {
            let delivered = DispatchSemaphore(value: 0)
            let reader = try subscriber.createRawReader(
                topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil,
                handler: { _, _ in delivered.signal() })
            // Destroy it while samples are arriving, once the first one did.
            if delivered.wait(timeout: .now() + 2) == .success {
                matchedRounds += 1
            }
            subscriber.destroyReader(reader)
        }
        XCTAssertGreaterThan(matchedRounds, 0, "no reader got a sample, so no teardown overlapped a delivery")
    }
}
