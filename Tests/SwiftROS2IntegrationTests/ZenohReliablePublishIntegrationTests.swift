import Foundation
import SwiftROS2
import SwiftROS2TestFixtures
import XCTest

/// Reliable topic publishers on one wire Zenoh session, publishing from
/// several threads at once through a real router. Requires `ZENOH_ROUTER`
/// (for example `tcp/192.168.1.85:7447`). Skips otherwise.
///
/// zenoh-pico's default congestion control (DROP) only try-locks the session's
/// transmit mutex, so a put that overlaps another send on the same session
/// fails with -100 (`_Z_ERR_TRANSPORT_TX_FAILED`) with no congestion on the
/// network. Reliable publishers block on congestion instead and must never
/// fail that way.
final class ZenohReliablePublishIntegrationTests: XCTestCase {
    func testConcurrentReliablePublishersNeverFail() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        let ctx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
        let node = try await ctx.createNode(name: "reliable_publish_it", namespace: "/zenoh_reliable_it")

        let threads = 8
        let messagesPerThread = 500
        var publishers: [ROS2Publisher<Imu>] = []
        for t in 0..<threads {
            publishers.append(try await node.createPublisher(Imu.self, topic: "imu_\(t)", qos: .reliableSensor))
        }

        let failures = Self.publishConcurrently(publishers, messagesPerThread: messagesPerThread)

        await ctx.shutdown()
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) of \(threads * messagesPerThread) publishes failed, first: \(failures.first ?? "")")
    }

    /// Publishes `messagesPerThread` messages through each publisher, one
    /// thread per publisher, all at once. Returns the failures.
    private static func publishConcurrently(_ publishers: [ROS2Publisher<Imu>], messagesPerThread: Int) -> [String] {
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: publishers.count) { t in
            var message = Imu()
            message.header.frameId = "imu_link"
            for i in 0..<messagesPerThread {
                message.linearAcceleration.z = Double(i)
                do {
                    try publishers[t].publish(message)
                } catch {
                    lock.lock()
                    failures.append("publisher \(t) message \(i): \(error)")
                    lock.unlock()
                }
            }
        }
        return failures
    }
}
