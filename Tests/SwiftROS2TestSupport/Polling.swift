#if canImport(XCTest)
    import Foundation
    import XCTest

    /// The ceiling every polling wait in the tests uses unless a test needs a different one.
    ///
    /// Generous on purpose: CI runs many test processes at once, and a long ceiling only costs time
    /// when the wait is going to fail anyway.
    public let defaultWaitTimeout: TimeInterval = 20

    /// Polls `condition` until it holds or `timeout` elapses and returns whether it held. Does not
    /// fail the test; use ``waitUntil(timeout:interval:file:line:_:)`` for that.
    @discardableResult
    public func eventually(
        timeout: TimeInterval = defaultWaitTimeout,
        interval: Duration = .milliseconds(10),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if await condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: interval)
        }
    }

    /// Polls `condition` until it holds, failing the test with `message` when `timeout` elapses
    /// first. Returns how long the condition took to hold.
    @discardableResult
    public func waitUntil(
        _ message: @autoclosure () -> String = "condition not met",
        timeout: TimeInterval = defaultWaitTimeout,
        interval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async -> TimeInterval {
        let start = ContinuousClock.now
        let held = await eventually(timeout: timeout, interval: interval, condition)
        let elapsed = start.duration(to: ContinuousClock.now)
        if !held {
            XCTFail("\(message()) within \(timeout) s", file: file, line: line)
        }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
#endif
