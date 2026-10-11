import SwiftROS2
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

/// Wire Zenoh matched-subscription check through a real router. Requires
/// `ZENOH_ROUTER` (for example `tcp/192.168.1.85:7447`) pointing at an
/// `rmw_zenohd` or `zenohd`. Skips otherwise. Run it against each distro's
/// router: an old router that never reports interest leaves
/// `hasMatchedSubscriptions` false forever, which would silence lazy topics.
final class ZenohMatchingIntegrationTests: XCTestCase {
    func testMatchedSubscriptionsFollowsASubscriberThroughTheRouter() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        // Two contexts: zenoh-pico does not route a session's own puts to its own subscribers.
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 0, wireMode: .jazzy), distro: .jazzy)
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 0, wireMode: .jazzy), distro: .jazzy)
        let pubNode = try await pubCtx.createNode(name: "matched_pub", namespace: "/matched")
        let subNode = try await subCtx.createNode(name: "matched_sub", namespace: "/matched")
        let pub = try await pubNode.createPublisher(StringMsg.self, topic: "probe")

        try await waitUntil { !pub.hasMatchedSubscriptions }
        let sub = try await subNode.createSubscription(StringMsg.self, topic: "probe")
        try await waitUntil { pub.hasMatchedSubscriptions }
        sub.cancel()
        try await waitUntil { !pub.hasMatchedSubscriptions }

        await subCtx.shutdown()
        await pubCtx.shutdown()
    }

    /// A plain publisher must deliver like the bare `z_put` of 2.2.0: a publish
    /// right after creation reaches a subscriber that already exists, without
    /// waiting for the router's interest reply to open the publisher's write
    /// filter. A message dropped here would be silent (`publish` still succeeds).
    func testFirstPublishAfterCreationReachesAnExistingSubscriber() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 0, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "first_sub", namespace: "/first")
        let sub = try await subNode.createSubscription(StringMsg.self, topic: "first")
        let received = ReceivedStrings()
        sub.onMessage { received.append($0.data) }
        // Let the subscriber declaration propagate through the router.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 0, wireMode: .jazzy), distro: .jazzy)
        let pubNode = try await pubCtx.createNode(name: "first_pub", namespace: "/first")
        let pub = try await pubNode.createPublisher(StringMsg.self, topic: "first")
        try pub.publish(StringMsg(data: "first message"))

        try await waitUntil { received.items.contains("first message") }

        await pubCtx.shutdown()
        await subCtx.shutdown()
    }

    /// A TRANSIENT_LOCAL publisher is an advanced publisher on wire Zenoh (it
    /// caches samples for late joiners). It must still report matching and
    /// deliver live samples to an existing subscriber: unlike a plain publisher,
    /// it puts through its own write filter, so a publisher that never sees the
    /// subscriber also never sends to it.
    ///
    /// Replaying the cache to a late joiner is not covered here: swift-ros2's
    /// Zenoh subscriber is a plain subscriber that does not query the cache. That
    /// check needs a real rmw_zenoh late joiner (a transient_local `ros2 topic
    /// echo` or a transient_local subscription started after the publish).
    func testTransientLocalPublisherReportsMatchingAndDeliversLiveSamples() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 0, wireMode: .jazzy), distro: .jazzy)
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 0, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "latched_sub", namespace: "/latched")
        let pubNode = try await pubCtx.createNode(name: "latched_pub", namespace: "/latched")
        let pub = try await pubNode.createPublisher(StringMsg.self, topic: "state", qos: .latched)

        try await waitUntil { !pub.hasMatchedSubscriptions }
        let sub = try await subNode.createSubscription(StringMsg.self, topic: "state", qos: .latched)
        let received = ReceivedStrings()
        sub.onMessage { received.append($0.data) }
        try await waitUntil { pub.hasMatchedSubscriptions }

        try pub.publish(StringMsg(data: "latched message"))
        try await waitUntil(timeout: 5) { received.items.contains("latched message") }

        sub.cancel()
        try await waitUntil { !pub.hasMatchedSubscriptions }

        await pubCtx.shutdown()
        await subCtx.shutdown()
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout) s", line: line)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Thread-safe collector for strings received on a subscription callback.
private final class ReceivedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var items: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
