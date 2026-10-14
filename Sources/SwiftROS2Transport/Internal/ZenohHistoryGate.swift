// ZenohHistoryGate.swift
// Orders a transient-local subscription's history before its live samples.

import Foundation
import SwiftROS2Wire

/// Delivers the samples a transient-local subscription fetches from the publishers'
/// caches before the live samples it receives meanwhile, without duplicates.
///
/// The subscription is declared before the history query, so a sample published
/// while the query runs can arrive twice: live, and in a cache reply. Until
/// ``finish()`` the gate holds live samples back and collects history; then it
/// delivers the history (oldest first by the attachment's source timestamp), then the
/// held live samples that the history did not already contain, and from then on passes
/// live samples straight through. A sample is identified by the publisher GID and
/// sequence number in its rmw_zenoh attachment; samples without one are never
/// treated as duplicates.
package final class ZenohHistoryGate: @unchecked Sendable {
    private enum Phase {
        /// The history query runs: live samples are held back.
        case fetching
        /// The history and the held samples are being delivered.
        case flushing
        /// Live samples pass straight through.
        case live
        /// The subscription is closed: nothing is delivered any more.
        case closed
    }

    private struct SampleID: Hashable {
        let gid: [UInt8]
        let seq: Int64
    }

    /// Live samples held while the query runs; older ones are dropped beyond this.
    package static let maxHeldLiveSamples = 1000

    private let deliver: (ZenohSample) -> Void
    private let lock = NSLock()
    private var phase = Phase.fetching
    private var history: [ZenohSample] = []
    private var held: [ZenohSample] = []

    package init(deliver: @escaping (ZenohSample) -> Void) {
        self.deliver = deliver
    }

    /// A sample from the live subscription.
    package func receiveLive(_ sample: ZenohSample) {
        lock.lock()
        if phase == .closed {
            lock.unlock()
            return
        }
        if phase != .live {
            held.append(sample)
            if held.count > Self.maxHeldLiveSamples {
                held.removeFirst(held.count - Self.maxHeldLiveSamples)
            }
            lock.unlock()
            return
        }
        lock.unlock()
        deliver(sample)
    }

    /// A reply to the history query. Replies after ``finish()`` are dropped.
    package func receiveHistory(_ sample: ZenohSample) {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .fetching else { return }
        history.append(sample)
    }

    /// The history query is over (all replies delivered, timed out, or failed).
    package func finish() {
        lock.lock()
        guard phase == .fetching else {
            lock.unlock()
            return
        }
        phase = .flushing
        let fetched = Self.ordered(history)
        history = []
        lock.unlock()

        var seen = Set<SampleID>()
        for sample in fetched {
            if let id = Self.id(of: sample), !seen.insert(id).inserted { continue }
            deliver(sample)
        }

        // Live samples keep arriving while the held ones are delivered: drain until
        // none is left, then let them through.
        while true {
            lock.lock()
            if phase == .closed {
                lock.unlock()
                return
            }
            if held.isEmpty {
                phase = .live
                lock.unlock()
                return
            }
            let batch = held
            held = []
            lock.unlock()
            for sample in batch {
                if let id = Self.id(of: sample), seen.contains(id) { continue }
                deliver(sample)
            }
        }
    }

    /// Stop delivering: the subscription is closed. History still in flight is dropped.
    package func close() {
        lock.lock()
        phase = .closed
        history = []
        held = []
        lock.unlock()
    }

    private static func id(of sample: ZenohSample) -> SampleID? {
        guard let attachment = sample.attachment, let fields = ZenohAttachmentFields(attachment) else {
            return nil
        }
        return SampleID(gid: fields.gid, seq: fields.seq)
    }

    /// Oldest first by source timestamp, then sequence number; arrival order when a
    /// sample has no rmw_zenoh attachment to order by.
    private static func ordered(_ samples: [ZenohSample]) -> [ZenohSample] {
        let keyed = samples.map { sample in
            (sample, sample.attachment.flatMap { ZenohAttachmentFields($0) })
        }
        guard keyed.allSatisfy({ $0.1 != nil }) else { return samples }
        return keyed.enumerated().sorted { lhs, rhs in
            let l = lhs.element.1!
            let r = rhs.element.1!
            if l.tsNsec != r.tsNsec { return l.tsNsec < r.tsNsec }
            if l.seq != r.seq { return l.seq < r.seq }
            return lhs.offset < rhs.offset
        }.map { $0.element.0 }
    }
}
