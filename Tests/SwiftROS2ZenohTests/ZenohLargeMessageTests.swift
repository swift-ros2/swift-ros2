import CZenohBridge
import Foundation
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2Transport
@testable import SwiftROS2Zenoh

/// Receiving messages larger than one batch over wire Zenoh.
///
/// zenoh-pico sends a message larger than the session's batch size (2 KB) in
/// fragments and drops a received one whose fragments add up to more than its
/// compile-time `Z_FRAG_MAX_SIZE`. With zenoh-pico's default of 4096, every
/// received message above about 4 KB (a camera image, a point cloud, a map)
/// was dropped without an error; publishing them worked.
final class ZenohLargeMessageTests: XCTestCase {
    /// The reassembly limit swift-ros2 builds zenoh-pico with (64 MiB).
    private static let requiredFragmentLimit = 64 * 1024 * 1024

    func testLinkedZenohPicoReassemblesMessagesUpTo64MiB() throws {
        try Self.requireFragmentLimit()
    }

    /// Two sessions through a real router (zenoh-pico does not route a
    /// session's own puts to its own subscribers). Requires `ZENOH_ROUTER`
    /// (for example `tcp/192.168.1.85:7447`). Skips otherwise.
    func testMessagesLargerThanOneBatchArriveThroughTheRouter() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        try Self.requireFragmentLimit()

        let keyExpr = "swift_ros2_test/large_message/\(UUID().uuidString)"
        // Just above the old 4096 limit, a few dozen fragments, and a 1280x720
        // rgb8 image (2.76 MB).
        let sizes = [4_200, 100_000, 1280 * 720 * 3]
        let payloads = sizes.map(Self.payload(size:))

        let subscriberSession = ZenohClient()
        try subscriberSession.open(locator: router)
        defer { try? subscriberSession.close() }
        let received = ReceivedPayloads()
        let subscriber = try subscriberSession.subscribe(keyExpr: keyExpr) { received.append($0.payload) }
        defer { try? subscriber.close() }

        let publisherSession = ZenohClient()
        try publisherSession.open(locator: router)
        defer { try? publisherSession.close() }
        let publisher = try publisherSession.declarePublisher(
            keyExpr, options: ZenohPublisherOptions(blockOnCongestion: true))
        defer { try? publisher.close() }

        await waitUntil("the publisher never matched the subscriber") { publisher.matchingStatus() == true }

        for payload in payloads {
            try publisher.put(payload: payload, attachment: nil)
        }

        await waitUntil("received \(received.sizes) of \(sizes) bytes") { received.count == payloads.count }
        XCTAssertEqual(received.sizes, sizes)
        for (got, sent) in zip(received.items, payloads) where got != sent {
            XCTFail("the \(sent.count)-byte payload arrived corrupted")
        }
    }

    /// `size` bytes of a repeating 0...250 ramp, starting at a size-dependent
    /// offset. 251 is prime, so the ramp does not line up with the fragments: a
    /// fragment lost, repeated or reordered changes the bytes.
    private static func payload(size: Int) -> Data {
        let ramp = Data((0..<251).map { UInt8($0) })
        var data = Data(capacity: size + ramp.count)
        data.append(ramp[(size % ramp.count)...])
        while data.count < size { data.append(ramp) }
        return Data(data.prefix(size))
    }

    /// Fails unless the linked zenoh-pico reassembles 64 MiB messages. The Apple
    /// platforms link the prebuilt CZenohPico xcframework, so there the check
    /// skips until `Package.swift` pins assets built with
    /// `Scripts/build-xcframework.sh` from this source (or the test runs with
    /// `SWIFT_ROS2_ZENOH_LOCAL=1` against a local build).
    private static func requireFragmentLimit() throws {
        let limit = zenoh_max_fragmented_message_size()
        #if canImport(Darwin)
            if limit < requiredFragmentLimit {
                throw XCTSkip("The linked CZenohPico xcframework reassembles messages up to \(limit) bytes only")
            }
        #endif
        XCTAssertGreaterThanOrEqual(limit, requiredFragmentLimit)
    }
}

/// Thread-safe collector for payloads received on a subscriber callback.
private final class ReceivedPayloads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    func append(_ value: Data) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var items: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var count: Int { items.count }
    var sizes: [Int] { items.map(\.count) }
}
