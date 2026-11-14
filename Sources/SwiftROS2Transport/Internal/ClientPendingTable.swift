// ClientPendingTable.swift
// Per-client correlation table for DDS request / reply matching, and the
// request / reply helpers the DDS service and action clients share.

import Foundation

/// Per-Service-Client correlation table.
///
/// Each in-flight `call(...)` registers a continuation keyed by sequence
/// number. The transport's reply handler looks up by sequence number and
/// resolves. Used by DDS — Zenoh's queryable primitive owns correlation
/// natively, so the Zenoh transport does not need this.
actor ClientPendingTable {
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]

    /// Register a continuation under `seq` and run `register` to wire up the
    /// caller (e.g. issue the request). `register` runs while the actor holds
    /// the table; do not perform long work inside it.
    func insert(
        seq: Int64,
        register: (CheckedContinuation<Data, Error>) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[seq] = cont
            register(cont)
        }
    }

    @discardableResult
    func resolve(seq: Int64, with result: Result<Data, Error>) -> Bool {
        guard let cont = pending.removeValue(forKey: seq) else { return false }
        cont.resume(with: result)
        return true
    }

    @discardableResult
    func cancel(seq: Int64) -> Bool {
        guard let cont = pending.removeValue(forKey: seq) else { return false }
        cont.resume(throwing: TransportError.requestCancelled)
        return true
    }

    func failAll(_ error: Error) {
        let snapshot = pending
        pending.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }
}

extension ClientPendingTable {
    /// Registers `seq`, runs `send` to issue the request, and returns the reply
    /// that `resolve(seq:with:)` delivers. Throws `TransportError.requestTimeout`
    /// after `timeout`, the error `send` throws, or `requestCancelled` when the
    /// calling task is cancelled.
    ///
    /// A `timeout` too large for `Task.sleep`'s nanosecond conversion (e.g.
    /// `.seconds(Int.max)`, used as "no timeout") starts no timeout task: the
    /// call waits until the reply comes or the task is cancelled.
    nonisolated func awaitReply(
        seq: Int64,
        timeout: Duration,
        send: @escaping () throws -> Void
    ) async throws -> Data {
        let timeoutTask = TimeoutTaskSlot()
        return try await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }
            return try await insert(seq: seq) { _ in
                // This runs on the actor after `pending[seq]` holds the
                // continuation, so the timeout, the cancel path and a send
                // failure all find it when they resolve. Starting the timeout
                // earlier let a short timeout fire against an empty table and
                // the call then waited forever.
                if Task.isCancelled {
                    // `onCancel` ran before the continuation was registered and
                    // found nothing to cancel; cancel it now instead of sending.
                    Task { [self] in
                        await cancel(seq: seq)
                    }
                    return
                }
                if isSafeSleepDuration(timeout) {
                    // A cancelled sleep (the reply came first, or the caller
                    // was cancelled) exits without resolving, so it cannot
                    // race the reply or the cancel path into a timeout.
                    timeoutTask.set(
                        Task { [self] in
                            do {
                                try await Task.sleep(for: timeout)
                            } catch {
                                return
                            }
                            await resolve(
                                seq: seq, with: .failure(TransportError.requestTimeout(timeout)))
                        })
                }
                do {
                    try send()
                } catch {
                    // The actor still holds the continuation; resolve it once
                    // the registration returns.
                    Task { [self] in
                        await resolve(seq: seq, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            timeoutTask.cancel()
            Task { [self] in
                await cancel(seq: seq)
            }
        }
    }
}

/// Holds the timeout task of one `awaitReply` call. `cancel()` may run before
/// the task is set (from `onCancel`), so a task set afterwards is cancelled at
/// once.
private final class TimeoutTaskSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ newTask: Task<Void, Never>) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { task = newTask }
        lock.unlock()
        if alreadyCancelled { newTask.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }
}

extension DDSClientProtocol {
    /// Polls every 100 ms until each of `endpoints()`' writers has matched a
    /// reader and each of its readers has matched a writer. Returns `false` when
    /// `timeout` passes first; `endpoints()` returns `nil` while they are not
    /// available (not created yet, or closed). Throws `CancellationError` when
    /// the calling task is cancelled.
    func waitUntilMatched(
        timeout: Duration,
        endpoints: () -> (writers: [any DDSWriterHandle], readers: [any DDSReaderHandle])?
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let (writers, readers) = endpoints(),
                writers.allSatisfy({ isPublicationMatched(writer: $0) }),
                readers.allSatisfy({ isSubscriptionMatched(reader: $0) })
            {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
        }
        return false
    }
}
