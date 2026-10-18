import Foundation
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2Zenoh

#if canImport(Darwin) || canImport(Glibc)

    /// A batch from the router that holds more than one FRAME.
    ///
    /// zenohd packs the messages for a session into one batch and starts a new
    /// FRAME in it whenever the reliability changes, so a best-effort sample and
    /// a reliable one sent close together arrive as two frames in one batch.
    /// zenoh-pico read every byte after a FRAME header as that frame's network
    /// messages, failed on the next FRAME header ("unknown message type") and
    /// dropped the session. A ROS 2 host with both reliable and best-effort
    /// publishers (odometry, TF, scans, images) cut a wire Zenoh session every
    /// few seconds. The batches here come from `FakeZenohRouter`, so the test
    /// needs no router and does not depend on when zenohd batches.
    final class ZenohBatchFramesTests: XCTestCase {
        func testSamplesInEveryFrameOfABatchArriveAndTheSessionStays() async throws {
            let router = try FakeZenohRouter()
            defer { router.close() }

            let client = ZenohClient()
            try client.open(locator: router.locator)
            defer { try? client.close() }
            try router.waitForSession()

            let key = "swift_ros2_test/batch_frames"
            let received = ReceivedTags()
            let subscriber = try client.subscribe(keyExpr: key) { sample in
                received.append(Array(sample.payload))
            }
            defer { try? subscriber.close() }

            // One batch: best effort (2 samples), reliable (1), best effort again (1).
            var batch = FakeZenohRouter.frame(reliable: false, sn: 0)
            batch += FakeZenohRouter.push(key: key, payload: [1])
            batch += FakeZenohRouter.push(key: key, payload: [2])
            batch += FakeZenohRouter.frame(reliable: true, sn: 0)
            batch += FakeZenohRouter.push(key: key, payload: [3])
            batch += FakeZenohRouter.frame(reliable: false, sn: 1)
            batch += FakeZenohRouter.push(key: key, payload: [4])
            try router.send(batch: batch)

            // A later batch still arrives: the session kept reading.
            try router.send(
                batch: FakeZenohRouter.frame(reliable: true, sn: 1) + FakeZenohRouter.push(key: key, payload: [5]))

            await waitUntil("received samples \(received.tags) of [1, 2, 3, 4, 5]") { received.tags.count == 5 }
            XCTAssertEqual(received.tags, [1, 2, 3, 4, 5])
            XCTAssertTrue(client.isSessionHealthy())
        }
    }

    /// Thread-safe collector for the one-byte payloads the subscriber receives.
    private final class ReceivedTags: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt8] = []

        func append(_ payload: [UInt8]) {
            lock.lock()
            values += payload
            lock.unlock()
        }

        var tags: [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

#endif
