import SwiftROS2ExampleInterfaces
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Transport

final class MatchedSubscriptionsTests: XCTestCase {
    private func makePublisher() async throws -> (ROS2Node, ROS2Publisher<StringMsg>, MockTransportPublisher) {
        let session = MockTransportSession()
        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/m:7447"), session: session)
        let node = try await ctx.createNode(
            name: "matched", namespace: "/t", options: ROS2NodeOptions(startParameterServices: false))
        let pub = try await node.createPublisher(StringMsg.self, topic: "probe")
        let transport = try XCTUnwrap(session.publishers.last)
        return (node, pub, transport)
    }

    func testUnknownTransportStateIsReportedAsMatched() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = nil
        XCTAssertTrue(pub.hasMatchedSubscriptions)
    }

    func testReflectsTheTransportState() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = false
        XCTAssertFalse(pub.hasMatchedSubscriptions)
        transport.matched = true
        XCTAssertTrue(pub.hasMatchedSubscriptions)
    }

    func testHandlerGetsTheCurrentStateBeforeRegistrationReturns() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = Box<[Bool]>([])
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        XCTAssertEqual(box.value, [false])
    }

    func testHandlerFiresOnEveryChange() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = Box<[Bool]>([])
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        transport.matched = true
        await waitUntil { box.value == [false, true] }
        transport.matched = false
        await waitUntil { box.value == [false, true, false] }
    }

    /// A wire Zenoh session that lost its router turns a confident `false` into
    /// unknown (`nil`): the handler must then report `true` so that a caller that
    /// only publishes with subscribers publishes again and notices the loss.
    func testHandlerReportsTrueWhenTheStateBecomesUnknown() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = Box<[Bool]>([])
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        transport.matched = nil
        await waitUntil { box.value == [false, true] }
        XCTAssertTrue(pub.hasMatchedSubscriptions)
    }

    func testHandlerIsNotCalledAfterTheNodeIsDestroyed() async throws {
        let (node, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = Box<[Bool]>([])
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        await node.destroy()
        transport.matched = true
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.value, [false])
    }

    func testMonitorPollReportsOnlyChanges() {
        let state = Box<[Bool]>([])
        state.append(false)
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { state.value.last ?? true }
        let seen = Box<[Bool]>([])
        monitor.start { seen.append($0) }
        monitor.poll()
        state.append(true)
        monitor.poll()
        monitor.poll()
        monitor.stop()
        state.append(false)
        monitor.poll()
        XCTAssertEqual(seen.value, [false, true])
    }

    func testStopDrainsAnInFlightPollAndNoHandlerCallFollows() {
        let reader = GatedReader()
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { reader.read() }
        let seen = Box<[Bool]>([])
        monitor.start { seen.append($0) }
        XCTAssertEqual(seen.value, [false])

        // A poll blocks inside `read`, holding the monitor's queue, and would report a change.
        DispatchQueue.global().async { monitor.poll() }
        XCTAssertEqual(reader.entered.wait(timeout: .now() + 5), .success, "the poll never reached read()")

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            monitor.stop()
            stopReturned.signal()
        }
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 0.1), .timedOut,
            "stop() must wait for the poll that is in flight")

        reader.release.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 5), .success, "stop() never returned")
        XCTAssertEqual(seen.value, [false], "a poll that was in flight when stop() ran must not report")
    }

    func testStopWaitsForAHandlerCallThatIsAlreadyRunning() {
        let state = Box<[Bool]>([])
        state.append(false)
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { state.value.last ?? true }
        let inHandler = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let finished = Box<[Bool]>([])
        monitor.start { value in
            guard value else { return }
            inHandler.signal()
            releaseHandler.wait()
            finished.append(value)
        }

        state.append(true)
        DispatchQueue.global().async { monitor.poll() }
        XCTAssertEqual(inHandler.wait(timeout: .now() + 5), .success, "the handler was never called")

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            monitor.stop()
            stopReturned.signal()
        }
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 0.1), .timedOut,
            "stop() must wait for the handler call that is running")

        releaseHandler.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 5), .success, "stop() never returned")
        XCTAssertEqual(finished.value, [true], "the running handler call must finish before stop() returns")
    }

    func testStartAfterStopNeverCallsTheHandler() {
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { true }
        monitor.stop()
        let seen = Box<[Bool]>([])
        monitor.start { seen.append($0) }
        monitor.poll()
        XCTAssertEqual(seen.value, [])
    }

    func testHandlerMayReRegisterFromItsOwnCallback() {
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { true }
        let second = Box<[Bool]>([])
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            monitor.start { _ in monitor.start { second.append($0) } }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "re-registering from the handler deadlocked")
        XCTAssertEqual(second.value, [true])
        monitor.stop()
    }

    func testHandlerMayStopTheMonitorFromItsOwnCallback() {
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { true }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            monitor.start { _ in monitor.stop() }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "stopping from the handler deadlocked")
        let seen = Box<[Bool]>([])
        monitor.start { seen.append($0) }
        XCTAssertEqual(seen.value, [])
    }
}

/// A `read` source whose first call returns `false` at once and whose later calls
/// block until released, then return `true`.
private final class GatedReader: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    func read() -> Bool {
        lock.lock()
        calls += 1
        let isFirst = calls == 1
        lock.unlock()
        if isFirst { return false }
        entered.signal()
        release.wait()
        return true
    }
}
