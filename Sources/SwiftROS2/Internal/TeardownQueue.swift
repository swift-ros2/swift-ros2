// TeardownQueue.swift
// Runs blocking teardown calls off Swift's cooperative thread pool.

import Dispatch
import Foundation

/// A private serial queue for the blocking transport calls of a context's
/// teardown.
///
/// A transport close can block for as long as its link stalls: a wire Zenoh
/// publisher close waits for a put that is stuck on a frozen TCP connection,
/// and closing a publisher waits for a matched-subscriptions handler call that
/// is running. Made straight from an `async` function, such a call holds a
/// thread of the cooperative pool, which is only as wide as the CPU core
/// count, so as many concurrent teardowns as there are cores stall every task
/// on the global concurrent executor. ``run(_:)`` makes the call on this
/// queue's thread instead and suspends the caller until it has returned.
///
/// Each ``ROS2Context`` owns one queue. The teardown steps of one context run
/// one at a time, in the order they were submitted, and a context whose close
/// is stuck never delays the teardown of another context.
final class TeardownQueue: @unchecked Sendable {
    private static let serials = SerialCounter()

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()

    /// `prefix` followed by a number unique in the process, so the queue of
    /// each context can be told apart in a hang report.
    let label: String

    init(prefix: String) {
        label = "\(prefix).\(Self.serials.next())"
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Whether the caller runs on this queue.
    var isCurrent: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// Runs `work` on the queue, after every block submitted before it, and
    /// returns once `work` has returned.
    ///
    /// Cancelling the calling task does not cut the wait short: teardown always
    /// runs to completion. `work` must not wait for another block of this
    /// queue, since that block only starts once `work` has returned.
    func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }

    /// Guards the blocking teardown steps, which must never run on a
    /// cooperative-pool thread: an unoptimized (debug) build stops the process
    /// unless the caller runs on this queue.
    ///
    /// An optimized (release) build skips the check. A step that ran off the
    /// queue would bring back a liveness problem, not corrupt data, so it must
    /// never crash an app that uses the library; the debug test suite runs
    /// every teardown path and catches such a caller.
    func assertOnQueue(file: StaticString = #file, line: UInt = #line) {
        assert(isCurrent, "a blocking teardown step ran off its context's teardown queue", file: file, line: line)
    }
}

private final class SerialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
