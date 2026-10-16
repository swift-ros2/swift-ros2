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

    /// A build-configuration guard only: it reads `Z_FRAG_MAX_SIZE` from the
    /// zenoh-pico headers the C bridge was compiled against. It does not prove
    /// that the linked library was built with the same value, and it does not
    /// receive anything; the router test below does.
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

    /// Many large messages in a row from a reliable `Block` publisher all
    /// arrive, intact and in order. zenoh-pico used to send every fragment with
    /// the reliability flag inverted, so the router took a reliable message as
    /// best effort and dropped it whenever its queue toward the subscriber was
    /// full (a slow link), and afterwards dropped every fragmented message to
    /// that subscriber. Requires `ZENOH_ROUTER`. Skips otherwise.
    func testRepeatedLargeMessagesAllArriveThroughTheRouter() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        try Self.requireFragmentLimit()

        let keyExpr = "swift_ros2_test/large_message_burst/\(UUID().uuidString)"
        let sizes = Array(repeating: 300_000, count: 20) + Array(repeating: 1280 * 720 * 3, count: 3)
        let payloads = sizes.enumerated().map { Self.payload(size: $0.element + $0.offset % 7) }

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

        await waitUntil("received \(received.count) of \(payloads.count) messages", timeout: 60) {
            received.count == payloads.count
        }
        XCTAssertEqual(received.sizes, payloads.map(\.count))
        for (got, sent) in zip(received.items, payloads) where got != sent {
            XCTFail("the \(sent.count)-byte payload arrived corrupted")
        }
        XCTAssertTrue(subscriberSession.isSessionHealthy())
    }

    #if canImport(Darwin) || canImport(Glibc)
        /// After the router drops a large message for a slow subscriber, the
        /// subscriber still receives the messages that follow. The subscriber
        /// reaches the router through a 1 MB/s proxy and the publisher uses
        /// `CongestionControl::Drop`, so the router drops 2.76 MB messages for it.
        /// zenohd keeps one transmission queue for a session without QoS, and
        /// after one drop it marked that queue congested for good: every later
        /// droppable message to the subscriber was discarded. zenoh-pico now
        /// negotiates QoS, so the router keeps a queue per priority and recovers.
        /// Requires `ZENOH_ROUTER`. Skips otherwise.
        func testSubscriberRecoversAfterTheRouterDropsALargeMessage() async throws {
            guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
                throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
            }
            try Self.requireFragmentLimit()

            let proxy = try ThrottlingTCPProxy(upstream: router, bytesPerSecond: 1_000_000)
            defer { proxy.close() }

            let keyExpr = "swift_ros2_test/large_message_recovery/\(UUID().uuidString)"
            let largeSize = 1280 * 720 * 3
            let smallSize = 100_000

            let subscriberSession = ZenohClient()
            try subscriberSession.open(locator: proxy.locator)
            defer { try? subscriberSession.close() }
            let received = ReceivedPayloads()
            let subscriber = try subscriberSession.subscribe(keyExpr: keyExpr) { received.append($0.payload) }
            defer { try? subscriber.close() }

            let publisherSession = ZenohClient()
            try publisherSession.open(locator: router)
            defer { try? publisherSession.close() }
            let publisher = try publisherSession.declarePublisher(
                keyExpr, options: ZenohPublisherOptions(blockOnCongestion: false))
            defer { try? publisher.close() }

            await waitUntil("the publisher never matched the subscriber") { publisher.matchingStatus() == true }

            // Three 2.76 MB messages at once overrun the router's queue toward the
            // throttled subscriber. Wait until they are through or dropped.
            let large = Self.payload(size: largeSize)
            for _ in 0..<3 {
                try publisher.put(payload: large, attachment: nil)
            }
            try await Task.sleep(nanoseconds: 12_000_000_000)
            let largeReceived = received.sizes.filter { $0 == largeSize }.count
            if largeReceived == 3 {
                throw XCTSkip("The router dropped none of the large messages, so there is nothing to recover from")
            }

            // Each of these fits the throttled link (250 KB/s against 1 MB/s).
            let small = Self.payload(size: smallSize)
            for _ in 0..<5 {
                try publisher.put(payload: small, attachment: nil)
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            let smallReceived = { received.sizes.filter { $0 == smallSize }.count }
            await waitUntil("received \(smallReceived()) of 5 messages after the drop") { smallReceived() == 5 }
            for got in received.items where got.count == smallSize && got != small {
                XCTFail("a \(smallSize)-byte payload arrived corrupted")
            }
            XCTAssertTrue(subscriberSession.isSessionHealthy())
        }
    #endif

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
    /// `Scripts/build-xcframework.sh` from this source. With
    /// `SWIFT_ROS2_ZENOH_LOCAL=1` (a CZenohPico built from this source) it never
    /// skips, so a local build without the limit fails.
    private static func requireFragmentLimit() throws {
        let limit = zenoh_max_fragmented_message_size()
        #if canImport(Darwin)
            let localBuild = ProcessInfo.processInfo.environment["SWIFT_ROS2_ZENOH_LOCAL"] == "1"
            if !localBuild && limit < requiredFragmentLimit {
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
