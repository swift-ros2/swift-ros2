// ZenohGraphQueries.swift
// The wire Zenoh topic graph's liveliness queries: one in flight, a deadline, and a
// budget for queries the router never finishes.

import Foundation

/// The time and count limits of the wire Zenoh graph queries.
package struct ZenohGraphLimits: Sendable, Equatable {
    /// How long a graph call waits for the router's answer.
    package var deadline: Duration
    /// How old a query without a final must be before a new one may start.
    package var abandonAfter: Duration
    /// How many abandoned queries may be pending before the session is graph-stalled.
    package var stallCap: Int

    package init(deadline: Duration, abandonAfter: Duration, stallCap: Int) {
        self.deadline = deadline
        self.abandonAfter = abandonAfter
        self.stallCap = stallCap
    }

    /// 1.5 s, below a 2 s poll; 10 s; three queries.
    package static let standard = ZenohGraphLimits(
        deadline: .milliseconds(1500), abandonAfter: .seconds(10), stallCap: 3)
}

/// Runs the liveliness queries of a wire Zenoh session's topic graph.
///
/// zenoh-pico ignores a liveliness query's timeout: a query stays pending until the
/// router sends its final or the session is torn down. So:
///
/// - A call joins the newest query while it is within its deadline. At the deadline
///   the query's callers get `.sessionUnhealthy` and nothing else.
/// - A call made after that deadline, while the query is still pending and younger
///   than `abandonAfter`, fails at once and starts nothing.
/// - Once the pending query is `abandonAfter` old, the next call abandons it and starts
///   a new one. Its final, if it ever comes, only takes it off the pending list.
/// - When `stallCap` abandoned queries are pending, the session is graph-stalled until
///   ``reset()``: every call fails at once and ``isStalled`` is `true`.
///
/// Every state change happens under one lock. The callbacks (on zenoh-pico's read
/// task) only take that lock, append or resolve, and resume continuations outside it.
final class ZenohGraphQueries: @unchecked Sendable {
    /// Starts one liveliness query: `onReply` for each token, `onFinish` once at the end.
    typealias Issue =
        @Sendable (
            _ onReply: @escaping @Sendable (String) -> Void,
            _ onFinish: @escaping @Sendable () -> Void
        ) throws -> Void

    private final class Query {
        let id: UInt64
        let startedAt: ContinuousClock.Instant
        var tokens: [String] = []
        var result: Result<[String], TransportError>?
        var waiters: [CheckedContinuation<[String], Error>] = []
        var abandoned = false

        init(id: UInt64, startedAt: ContinuousClock.Instant) {
            self.id = id
            self.startedAt = startedAt
        }
    }

    private enum Admission {
        case joined
        case start(id: UInt64, deadline: Duration)
        case fail(TransportError)
    }

    private let lock = NSLock()
    private var limitsValue = ZenohGraphLimits.standard
    private var nextId: UInt64 = 0
    /// Queries without a final, live or abandoned.
    private var pending: [UInt64: Query] = [:]
    /// The query a call may join.
    private var newest: Query?
    private var stalled = false

    var limits: ZenohGraphLimits {
        get {
            lock.lock()
            defer { lock.unlock() }
            return limitsValue
        }
        set {
            lock.lock()
            limitsValue = newValue
            lock.unlock()
        }
    }

    /// Whether `stallCap` abandoned queries are pending. Sticky until ``reset()``.
    var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalled
    }

    /// The tokens of the newest query, joining it when it is within its deadline,
    /// or of a new one started with `issue`.
    func tokens(issue: @escaping Issue) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            lock.lock()
            let admission = admitLocked(continuation)
            lock.unlock()
            switch admission {
            case .joined:
                return
            case .fail(let error):
                continuation.resume(throwing: error)
            case .start(let id, let deadline):
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline.dispatchInterval) {
                    [self] in
                    expire(id)
                }
                // Off the caller's thread: a send that stalls must not hold the deadline up.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    start(id, issue: issue)
                }
            }
        }
    }

    /// Forget every query and the stalled mark, and fail the callers still waiting
    /// with `.notConnected`. A late reply or final of a forgotten query is ignored.
    func reset() {
        lock.lock()
        let waiters = pending.values.flatMap { query -> [CheckedContinuation<[String], Error>] in
            defer { query.waiters = [] }
            return query.result == nil ? query.waiters : []
        }
        pending.removeAll()
        newest = nil
        stalled = false
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: TransportError.notConnected)
        }
    }

    // MARK: - Private

    private func admitLocked(_ continuation: CheckedContinuation<[String], Error>) -> Admission {
        if stalled {
            return .fail(.sessionUnhealthy("the session's topic graph queries have stalled"))
        }
        let now = ContinuousClock.now
        if let query = newest, pending[query.id] != nil {
            if query.result == nil {
                query.waiters.append(continuation)
                return .joined
            }
            if now - query.startedAt < limitsValue.abandonAfter {
                return .fail(.sessionUnhealthy("the previous topic graph query is still pending"))
            }
            query.abandoned = true
            newest = nil
            if pending.values.filter(\.abandoned).count >= limitsValue.stallCap {
                stalled = true
                return .fail(.sessionUnhealthy("the session's topic graph queries have stalled"))
            }
        }
        nextId &+= 1
        let query = Query(id: nextId, startedAt: now)
        query.waiters = [continuation]
        pending[query.id] = query
        newest = query
        return .start(id: query.id, deadline: limitsValue.deadline)
    }

    /// Issues query `id`. A final that fires during `issue` (the bridge fires it on its
    /// failure paths before it returns the error) is applied only once `issue` returned.
    private func start(_ id: UInt64, issue: Issue) {
        let call = InCall()
        do {
            try issue(
                { [self] token in reply(id, token) },
                { [self] in
                    if !call.deferFinish() { finish(id) }
                })
            if call.end() { finish(id) }
        } catch {
            _ = call.end()
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            fail(id, .sessionUnhealthy("topic graph query failed: \(reason)"))
        }
    }

    private func reply(_ id: UInt64, _ token: String) {
        lock.lock()
        if let query = pending[id], query.result == nil {
            query.tokens.append(token)
        }
        lock.unlock()
    }

    private func finish(_ id: UInt64) {
        lock.lock()
        guard let query = pending.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let tokens = query.tokens
        let waiters = resolveLocked(query, .success(tokens))
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: tokens)
        }
    }

    private func expire(_ id: UInt64) {
        lock.lock()
        guard let query = pending[id] else {
            lock.unlock()
            return
        }
        let error = TransportError.sessionUnhealthy("the router did not answer the topic graph query in time")
        let waiters = resolveLocked(query, .failure(error))
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func fail(_ id: UInt64, _ error: TransportError) {
        lock.lock()
        guard let query = pending.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let waiters = resolveLocked(query, .failure(error))
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    /// Sets the result once and hands back the callers to resume. Caller holds `lock`.
    private func resolveLocked(
        _ query: Query, _ result: Result<[String], TransportError>
    ) -> [CheckedContinuation<[String], Error>] {
        guard query.result == nil else { return [] }
        query.result = result
        let waiters = query.waiters
        query.waiters = []
        return waiters
    }
}

/// Whether a query's final fired while its `issue` call was still running.
private final class InCall: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var finishedDuringCall = false

    /// `true` when the final must wait for the call to return.
    func deferFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { finishedDuringCall = true }
        return running
    }

    /// Marks the call returned; `true` when a final fired during it.
    func end() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        running = false
        return finishedDuringCall
    }
}

/// The publisher (`MP`) tokens a wire Zenoh session has declared and not yet
/// undeclared. The topic graph merges them into the router's answer, because whether
/// the router echoes a session's own tokens back is not established.
final class ZenohOwnPublisherTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<String> = []

    func insert(_ token: String) {
        lock.lock()
        tokens.insert(token)
        lock.unlock()
    }

    func remove(_ token: String) {
        lock.lock()
        tokens.remove(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        tokens.removeAll()
        lock.unlock()
    }

    var snapshot: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    /// Whether `token` announces a publisher: its entity kind (index 5) is `MP`.
    static func isPublisherToken(_ token: String) -> Bool {
        let parts = token.split(separator: "/", maxSplits: 6, omittingEmptySubsequences: false)
        return parts.count > 5 && parts[0] == "@ros2_lv" && parts[5] == "MP"
    }
}

/// A publisher token whose `close()` takes it out of the session's own-token set
/// before it undeclares it.
final class ZenohTrackedLivelinessToken: ZenohLivelinessTokenHandle, @unchecked Sendable {
    private let inner: any ZenohLivelinessTokenHandle
    private let keyExpr: String
    private let owner: ZenohOwnPublisherTokens

    init(_ inner: any ZenohLivelinessTokenHandle, keyExpr: String, owner: ZenohOwnPublisherTokens) {
        self.inner = inner
        self.keyExpr = keyExpr
        self.owner = owner
    }

    func close() throws {
        owner.remove(keyExpr)
        try inner.close()
    }
}

extension Duration {
    /// The duration as a dispatch interval, in nanoseconds, never negative.
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let comps = components
        let nanos = comps.seconds * 1_000_000_000 + comps.attoseconds / 1_000_000_000
        return .nanoseconds(Int(clamping: max(0, nanos)))
    }
}
