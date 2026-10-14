import Foundation
import XCTest

@testable import SwiftROS2Transport
@testable import SwiftROS2Zenoh

/// Concurrent puts on one session through a real router. Requires
/// `ZENOH_ROUTER` (for example `tcp/192.168.1.85:7447`). Skips otherwise.
///
/// Under zenoh-pico's default congestion control (DROP) a put only try-locks
/// the session's transmit mutex, so a put that overlaps another send on the
/// same session fails with -100 (_Z_ERR_TRANSPORT_TX_FAILED). A publisher
/// declared with `blockOnCongestion` waits for that send instead.
final class ZenohConcurrentPutTests: XCTestCase {
    func testBlockingPublishersNeverFailUnderConcurrentPuts() throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        let z = ZenohClient()
        try z.open(locator: router)
        defer { try? z.close() }

        let threads = 8
        let putsPerThread = 200
        let publishers = try (0..<threads).map { t in
            try z.declarePublisher(
                "swift_ros2_test/concurrent_put/\(t)", options: ZenohPublisherOptions(blockOnCongestion: true))
        }
        let payload = Data(repeating: 0xAB, count: 64)
        let attachment = Data(repeating: 0x01, count: 33)
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<putsPerThread {
                do {
                    try publishers[t].put(payload: payload, attachment: attachment)
                } catch {
                    lock.lock()
                    failures.append("thread \(t) put \(i): \(error)")
                    lock.unlock()
                }
            }
        }
        for p in publishers { try p.close() }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) puts failed, first: \(failures.first ?? "")")
    }
}
