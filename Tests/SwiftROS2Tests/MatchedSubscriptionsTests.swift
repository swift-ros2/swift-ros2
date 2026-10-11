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
        let box = ValuesBox()
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        XCTAssertEqual(box.values, [false])
    }

    func testHandlerFiresOnEveryChangeAndNotOtherwise() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = ValuesBox()
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        transport.matched = true
        try await waitUntil { box.values == [false, true] }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.values, [false, true], "an unchanged state must not fire again")
        transport.matched = false
        try await waitUntil { box.values == [false, true, false] }
    }

    /// A wire Zenoh session that lost its router turns a confident `false` into
    /// unknown (`nil`): the handler must then report `true` so that a caller that
    /// only publishes with subscribers publishes again and notices the loss.
    func testHandlerReportsTrueWhenTheStateBecomesUnknown() async throws {
        let (_, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = ValuesBox()
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        transport.matched = nil
        try await waitUntil { box.values == [false, true] }
        XCTAssertTrue(pub.hasMatchedSubscriptions)
    }

    func testHandlerIsNotCalledAfterTheNodeIsDestroyed() async throws {
        let (node, pub, transport) = try await makePublisher()
        transport.matched = false
        let box = ValuesBox()
        pub.onMatchedSubscriptionsChanged { box.append($0) }
        await node.destroy()
        transport.matched = true
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.values, [false])
    }

    func testMonitorPollReportsOnlyChanges() {
        let state = ValuesBox()
        state.append(false)
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { state.values.last ?? true }
        let seen = ValuesBox()
        monitor.start { seen.append($0) }
        monitor.poll()
        state.append(true)
        monitor.poll()
        monitor.poll()
        monitor.stop()
        state.append(false)
        monitor.poll()
        XCTAssertEqual(seen.values, [false, true])
    }

    func testStopDrainsAnInFlightPollAndNoHandlerCallFollows() {
        let reader = GatedReader()
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { reader.read() }
        let seen = ValuesBox()
        monitor.start { seen.append($0) }
        XCTAssertEqual(seen.values, [false])

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
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(seen.values, [false], "a poll that was in flight when stop() ran must not report")
    }

    func testStopWaitsForAHandlerCallThatIsAlreadyRunning() {
        let state = ValuesBox()
        state.append(false)
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { state.values.last ?? true }
        let inHandler = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let finished = ValuesBox()
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
        XCTAssertEqual(finished.values, [true], "the running handler call must finish before stop() returns")
    }

    func testStartAfterStopNeverCallsTheHandler() {
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { true }
        monitor.stop()
        let seen = ValuesBox()
        monitor.start { seen.append($0) }
        monitor.poll()
        XCTAssertEqual(seen.values, [])
    }

    func testHandlerMayReRegisterFromItsOwnCallback() {
        let monitor = MatchedSubscriptionsMonitor(interval: .seconds(3600)) { true }
        let second = ValuesBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            monitor.start { _ in monitor.start { second.append($0) } }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "re-registering from the handler deadlocked")
        XCTAssertEqual(second.values, [true])
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
        let seen = ValuesBox()
        monitor.start { seen.append($0) }
        XCTAssertEqual(seen.values, [])
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout) s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class ValuesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ v: Bool) {
        lock.lock()
        _values.append(v)
        lock.unlock()
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
