import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2TestSupport
import SwiftROS2Transport
import XCTest

/// Wire Zenoh: cancelling a subscription from inside a `.stream` handler, through a real
/// router. Requires `ZENOH_ROUTER` (for example `tcp/127.0.0.1:7447`); skips otherwise.
///
/// A `.stream` handler runs on the session's own thread. Since zenoh-pico 1.8 an
/// undeclare waits until the entity's callbacks are over, so an undeclare made by the
/// handler waited for itself: `cancel()` never returned and the context received nothing
/// more. The swift-ros2 fork of zenoh-pico does not wait on that thread.
final class ZenohCancelInHandlerIntegrationTests: XCTestCase {
    func testCancelInsideItsOwnStreamHandlerReturnsAndTheContextKeepsReceiving() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        // Domain 75 and the /cancel_own namespace keep the key expressions apart from the other tests.
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "cancel_own_sub", namespace: "/cancel_own")
        let pubNode = try await pubCtx.createNode(name: "cancel_own_pub", namespace: "/cancel_own")

        let once = try await subNode.createSubscription(StringMsg.self, topic: "once")
        let more = try await subNode.createSubscription(StringMsg.self, topic: "more")
        let onceEvents = Events()
        let moreEvents = Events()
        once.onMessage { message in
            onceEvents.append("received \(message.data)")
            once.cancel()
            onceEvents.append("cancel returned")
        }
        more.onMessage { moreEvents.append($0.data) }

        let oncePub = try await pubNode.createPublisher(StringMsg.self, topic: "once")
        let morePub = try await pubNode.createPublisher(StringMsg.self, topic: "more")
        await waitUntil("both publishers are matched") {
            oncePub.hasMatchedSubscriptions && morePub.hasMatchedSubscriptions
        }

        try oncePub.publish(StringMsg(data: "first"))
        await waitUntil("the handler ran") { onceEvents.items.first == "received first" }
        await waitUntil("cancel() returned inside the handler") { onceEvents.items.contains("cancel returned") }
        guard onceEvents.items.contains("cancel returned") else {
            // The session's thread is stuck in cancel(): shutting the context down would wait for it.
            return
        }

        // The session's thread is free again: another subscription of the context still receives.
        try morePub.publish(StringMsg(data: "after the cancel"))
        await waitUntil("the other subscription still receives") {
            moreEvents.items.contains("after the cancel")
        }

        // The cancelled subscription gets nothing more.
        await waitUntil("the publisher lost its only subscriber") { !oncePub.hasMatchedSubscriptions }
        try? oncePub.publish(StringMsg(data: "second"))
        try morePub.publish(StringMsg(data: "marker"))
        await waitUntil("the marker arrived") { moreEvents.items.contains("marker") }
        XCTAssertEqual(onceEvents.items, ["received first", "cancel returned"])

        more.cancel()
        await subCtx.shutdown()
        await pubCtx.shutdown()
    }

    /// Two subscriptions of one context on the same topic: the handler that runs first
    /// cancels the other one. That `cancel()` must return, and the other handler must be
    /// called neither for the message that is being delivered nor for a later one.
    ///
    /// `cancel()` drops the handler before it closes the transport subscriber, so this
    /// does not show whether zenoh-pico skipped the undeclared subscriber. The fork's
    /// `z_undeclare_in_callback_test` checks that.
    func testCancelOfAnotherSubscriptionOnTheSameTopicInsideAStreamHandler() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "cancel_other_sub", namespace: "/cancel_other")
        let pubNode = try await pubCtx.createNode(name: "cancel_other_pub", namespace: "/cancel_other")

        let first = try await subNode.createSubscription(StringMsg.self, topic: "shared")
        let second = try await subNode.createSubscription(StringMsg.self, topic: "shared")
        let events = Events()
        first.onMessage { message in
            events.append("first \(message.data)")
            second.cancel()
        }
        second.onMessage { message in
            events.append("second \(message.data)")
            first.cancel()
        }

        let pub = try await pubNode.createPublisher(StringMsg.self, topic: "shared")
        await waitUntil("the publisher is matched") { pub.hasMatchedSubscriptions }

        try pub.publish(StringMsg(data: "a"))
        await waitUntil("one handler ran") { !events.items.isEmpty }
        try pub.publish(StringMsg(data: "b"))
        await waitUntil("the surviving handler got the second message") { events.items.count >= 2 }
        // Give a wrongly delivered message time to show up.
        try await Task.sleep(nanoseconds: 300_000_000)

        let items = events.items
        XCTAssertEqual(items.count, 2, "\(items)")
        if let winner = items.first?.split(separator: " ").first {
            XCTAssertEqual(items, ["\(winner) a", "\(winner) b"])
        }

        first.cancel()
        second.cancel()
        await subCtx.shutdown()
        await pubCtx.shutdown()
    }

    /// `cancel()` from another thread while the handler is running, and the handler
    /// cancels the subscription too. With zenoh-pico 1.10 the outer `cancel()` waits
    /// inside the undeclare for the handler, so the handler's `cancel()` meets a
    /// subscription that is being closed. It must find it closed: undeclaring the same
    /// subscriber a second time freed it twice.
    func testCancelFromAnotherThreadWhileTheHandlerCancelsToo() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "cancel_both_sub", namespace: "/cancel_both")
        let pubNode = try await pubCtx.createNode(name: "cancel_both_pub", namespace: "/cancel_both")

        let held = try await subNode.createSubscription(StringMsg.self, topic: "held")
        let more = try await subNode.createSubscription(StringMsg.self, topic: "more")
        let events = Events()
        let moreEvents = Events()
        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        held.onMessage { message in
            events.append("received \(message.data)")
            handlerEntered.signal()
            // Stay in the handler until the test has seen the outer cancel() wait.
            _ = releaseHandler.wait(timeout: .now() + 10)
            held.cancel()
            events.append("handler cancel returned")
        }
        more.onMessage { moreEvents.append($0.data) }

        let outer = Thread {
            guard handlerEntered.wait(timeout: .now() + 10) == .success else { return }
            events.append("outer cancel called")
            held.cancel()
            events.append("outer cancel returned")
        }
        outer.start()

        let heldPub = try await pubNode.createPublisher(StringMsg.self, topic: "held")
        let morePub = try await pubNode.createPublisher(StringMsg.self, topic: "more")
        await waitUntil("both publishers are matched") {
            heldPub.hasMatchedSubscriptions && morePub.hasMatchedSubscriptions
        }

        try heldPub.publish(StringMsg(data: "first"))
        await waitUntil("the outer cancel() was called") { events.items.contains("outer cancel called") }
        // The outer cancel() waits for the handler, which is still held.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(events.items.contains("outer cancel returned"), "\(events.items)")

        releaseHandler.signal()
        await waitUntil("both cancel() calls returned") {
            events.items.contains("handler cancel returned") && events.items.contains("outer cancel returned")
        }
        guard events.items.contains("handler cancel returned"), events.items.contains("outer cancel returned")
        else {
            // A cancel() is stuck: shutting the context down would wait for it.
            return
        }

        // The session's thread is free again, and the cancelled subscription gets nothing more.
        await waitUntil("the publisher lost its only subscriber") { !heldPub.hasMatchedSubscriptions }
        try? heldPub.publish(StringMsg(data: "second"))
        try morePub.publish(StringMsg(data: "marker"))
        await waitUntil("the other subscription still receives") { moreEvents.items.contains("marker") }
        XCTAssertEqual(events.items.filter { $0.hasPrefix("received") }, ["received first"])

        more.cancel()
        await subCtx.shutdown()
        await pubCtx.shutdown()
    }

    /// A `.stream` handler that is called with the cached sample of a TRANSIENT_LOCAL
    /// publisher cancels another subscription of its context and then its own.
    ///
    /// The cached samples are delivered from the finish callback of the history query.
    /// zenoh-pico made that call with the session's lock held, and an undeclare takes
    /// that lock: the first `cancel()` waited for its own thread.
    func testCancelInsideAStreamHandlerCalledWithACachedSample() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let pubNode = try await pubCtx.createNode(name: "cancel_cached_pub", namespace: "/cancel_cached")
        let latchedPub = try await pubNode.createPublisher(StringMsg.self, topic: "latched", qos: .latched)
        let morePub = try await pubNode.createPublisher(StringMsg.self, topic: "more")
        // Published before the subscription exists, and only once: the handler can get it
        // from the publisher's cache alone.
        try latchedPub.publish(StringMsg(data: "cached"))
        // Let the publisher's cache and liveliness token reach the router before anyone asks.
        try await Task.sleep(nanoseconds: 500_000_000)

        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "cancel_cached_sub", namespace: "/cancel_cached")
        let other = try await subNode.createSubscription(StringMsg.self, topic: "other")
        let more = try await subNode.createSubscription(StringMsg.self, topic: "more")
        let moreEvents = Events()
        more.onMessage { moreEvents.append($0.data) }

        let events = Events()
        let own = SubscriptionBox<StringMsg>()
        let latched = try await subNode.createSubscription(
            StringMsg.self, topic: "latched", qos: .latched, delivery: .stream
        ) { message in
            events.append("received \(message.data)")
            other.cancel()
            events.append("other cancel returned")
            // The cached sample can arrive before createSubscription has returned.
            guard let subscription = own.wait(seconds: 10) else {
                events.append("no subscription to cancel")
                return
            }
            subscription.cancel()
            events.append("own cancel returned")
        }
        own.set(latched)

        await waitUntil("the handler got the cached sample") { events.items.first == "received cached" }
        await waitUntil("both cancel() calls returned inside the handler") {
            events.items.contains("own cancel returned")
        }
        guard events.items.contains("own cancel returned") else {
            // The session's thread is stuck in a cancel(): shutting the context down would wait for it.
            return
        }

        // The session's thread is free again, and the cancelled subscription gets nothing more.
        await waitUntil("the publisher of the other topic is matched") { morePub.hasMatchedSubscriptions }
        try? latchedPub.publish(StringMsg(data: "live"))
        try morePub.publish(StringMsg(data: "marker"))
        await waitUntil("the other subscription still receives") { moreEvents.items.contains("marker") }
        XCTAssertEqual(events.items, ["received cached", "other cancel returned", "own cancel returned"])

        more.cancel()
        await subCtx.shutdown()
        await pubCtx.shutdown()
    }

    /// The last subscription on a topic is cancelled while messages for it are still on
    /// their way, many times over.
    ///
    /// Those messages name a key expression that the session has just undeclared.
    /// zenoh-pico took one for a protocol error and closed the session, so the context
    /// received nothing more.
    func testCancellingTheLastSubscriptionOnABusyTopicKeepsTheSession() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "cancel_busy_sub", namespace: "/cancel_busy")
        let pubNode = try await pubCtx.createNode(name: "cancel_busy_pub", namespace: "/cancel_busy")

        let busyPub = try await pubNode.createPublisher(StringMsg.self, topic: "busy")
        let canaryPub = try await pubNode.createPublisher(StringMsg.self, topic: "canary")
        let canary = try await subNode.createSubscription(StringMsg.self, topic: "canary")
        let canaryCount = Counter()
        canary.onMessage { _ in canaryCount.increment() }

        // A thread of its own keeps the topic busy, so that every cancel() has messages in flight.
        let stopFlood = Counter()
        let floodEnded = DispatchSemaphore(value: 0)
        let flood = Thread {
            let message = StringMsg(data: "busy")
            while stopFlood.value == 0 {
                try? busyPub.publish(message)
                Thread.sleep(forTimeInterval: 0.0001)
            }
            floodEnded.signal()
        }
        flood.start()

        var cancelled = 0
        for round in 1...50 {
            let seen = Counter()
            let subscription: ROS2Subscription<StringMsg>
            do {
                subscription = try await subNode.createSubscription(StringMsg.self, topic: "busy")
            } catch {
                XCTFail("round \(round): the context cannot subscribe any more: \(error)")
                break
            }
            subscription.onMessage { _ in seen.increment() }
            let receives = await eventually(timeout: 10) { seen.value >= 2 }
            subscription.cancel()
            guard receives else {
                XCTFail("round \(round): a new subscription receives nothing")
                break
            }
            cancelled += 1
        }
        stopFlood.increment()
        _ = floodEnded.wait(timeout: .now() + 10)

        // The context kept its session: another subscription of it still receives.
        let before = canaryCount.value
        await waitUntil("the canary subscription receives after \(cancelled) cancels", timeout: 10) {
            try? canaryPub.publish(StringMsg(data: "canary"))
            return canaryCount.value > before
        }

        canary.cancel()
        await subCtx.shutdown()
        await pubCtx.shutdown()
    }

    /// A publisher is closed right after it was created, on a topic that another context
    /// subscribes to, and then that subscription is cancelled, many times over.
    ///
    /// The router tells a new publisher about the subscription, and names the topic's key
    /// by the id the publisher's session declared for it. When the publisher is closed
    /// before that arrives, the session has undeclared the id: zenoh-pico took the
    /// declaration for a protocol error and closed the session. With the declaration
    /// dropped, it did the same for the undeclaration that the router sends when the
    /// subscription goes.
    func testClosingAPublisherRightAfterCreatingItKeepsTheSession() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/127.0.0.1:7447)")
        }
        let subCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let pubCtx = try await ROS2Context(
            transport: .zenoh(locator: router, domainId: 75, wireMode: .jazzy), distro: .jazzy)
        let subNode = try await subCtx.createNode(name: "flash_sub", namespace: "/flash")
        let pubNode = try await pubCtx.createNode(name: "flash_pub", namespace: "/flash")

        let canaryPub = try await pubNode.createPublisher(StringMsg.self, topic: "canary")
        let canary = try await subNode.createSubscription(StringMsg.self, topic: "canary")
        let canaryCount = Counter()
        canary.onMessage { _ in canaryCount.increment() }

        let rounds = 60
        var survived = 0
        for round in 1...rounds {
            let flash = try await subNode.createSubscription(StringMsg.self, topic: "flash")
            // Let the router see the subscription before the publisher asks for it.
            try await Task.sleep(nanoseconds: 10_000_000)

            // The publisher's context holds nothing else on the topic, so closing the publisher
            // undeclares the key. Whether that happens before the router's answer arrives is a
            // race, which is why there are many rounds.
            do {
                let node = try await pubCtx.createNode(name: "flash_pub_\(round)", namespace: "/flash")
                _ = try await node.createPublisher(StringMsg.self, topic: "flash")
                await node.destroy()
            } catch {
                flash.cancel()
                XCTFail("round \(round): the publisher's context cannot declare any more: \(error)")
                break
            }
            flash.cancel()

            let before = canaryCount.value
            let alive = await eventually(timeout: 10) {
                try? canaryPub.publish(StringMsg(data: "canary"))
                return canaryCount.value > before
            }
            guard alive else {
                XCTFail("round \(round): the publisher's context sends nothing any more")
                break
            }
            survived += 1
        }
        XCTAssertEqual(survived, rounds)

        canary.cancel()
        await subCtx.shutdown()
        await pubCtx.shutdown()
    }
}

/// Thread-safe list of what the handlers saw, in order.
private final class Events: @unchecked Sendable {
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

/// Thread-safe counter.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Hands a subscription to its own handler, which can run before `createSubscription` has returned.
private final class SubscriptionBox<M: CDRDecodable & ROS2MessageType>: @unchecked Sendable {
    private let lock = NSLock()
    private let isSet = DispatchSemaphore(value: 0)
    private var subscription: ROS2Subscription<M>?

    func set(_ value: ROS2Subscription<M>) {
        lock.lock()
        subscription = value
        lock.unlock()
        isSet.signal()
    }

    /// The subscription, or `nil` when it was not set within `seconds`.
    func wait(seconds: Int) -> ROS2Subscription<M>? {
        guard isSet.wait(timeout: .now() + .seconds(seconds)) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return subscription
    }
}
