// TeardownQueue.swift
// Runs blocking teardown calls off Swift's cooperative thread pool.

import Dispatch

/// A private serial queue for the blocking transport calls of a context's
/// teardown.
///
/// A transport close can block for as long as its link stalls: a wire Zenoh
/// publisher close waits for a put that is stuck on a frozen TCP connection,
/// and closing a publisher waits for a matched-subscriptions handler call that
/// is running. Made straight from an `async` function, such a call holds a
/// thread of the cooperative pool, which is only as wide as the CPU core
/// count, so a few teardowns during a stall stop every task in the process.
/// ``run(_:)`` makes the call on this queue's thread instead and suspends the
/// caller until it has returned.
///
/// Each ``ROS2Context`` owns one queue. The teardown steps of one context run
/// one at a time, in the order they were submitted, and a context whose close
/// is stuck never delays the teardown of another context.
final class TeardownQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
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
}
