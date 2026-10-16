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
        // A cancelled sleep (the reply came first, or the caller was
        // cancelled) exits without resolving, so it cannot race the reply or
        // the cancel path into reporting a timeout.
        let timeoutTask: Task<Void, Never>? =
            isSafeSleepDuration(timeout)
            ? Task { [self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await resolve(seq: seq, with: .failure(TransportError.requestTimeout(timeout)))
            } : nil
        return try await withTaskCancellationHandler {
            do {
                let body = try await insert(seq: seq) { _ in
                    do {
                        try send()
                    } catch {
                        // The actor still holds the continuation; resolve it
                        // once the registration returns.
                        Task { [self] in
                            await resolve(seq: seq, with: .failure(error))
                        }
                    }
                }
                timeoutTask?.cancel()
                return body
            } catch {
                timeoutTask?.cancel()
                throw error
            }
        } onCancel: {
            timeoutTask?.cancel()
            Task { [self] in
                await cancel(seq: seq)
            }
        }
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
