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
/// A `.stream` handler runs on the session's own thread. Since zenoh-pico 1.10 an
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

    // The Apple build links the released CZenohPico xcframework (zenoh-pico 1.7.1), whose
    // dispatch still calls a subscriber that was undeclared earlier in the same dispatch and
    // whose undeclare does not wait for a handler. Run these cases there once the
    // xcframework is built from the 1.10 fork.
    #if !canImport(Darwin)
        /// Two subscriptions of one context on the same topic: the handler that runs first
        /// cancels the other one. `cancel()` returned, so the other handler must not be
        /// called for the message that is being delivered, nor for a later one.
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
    #endif
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
