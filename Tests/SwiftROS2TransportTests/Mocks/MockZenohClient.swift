import Foundation
import SwiftROS2Transport

/// In-memory ZenohClientProtocol used by ZenohTransportSession unit tests.
///
/// Records every call so tests can assert against `puts`, `publisherDeclarations`,
/// `subscriptions`, etc. Lock-protected so tests can also exercise the
/// session's @Sendable contract.
final class MockZenohClient: ZenohClientProtocol, @unchecked Sendable {
    private let lock = NSLock()

    // Configurable behavior
    var isOpen = false
    var sessionIdValue = "mock-session-id"
    var openShouldThrow: ZenohError?
    var closeShouldThrow: ZenohError?
    var declarePublisherShouldThrow: ZenohError?
    var putShouldThrow: ZenohError?
    /// Successful `subscribe` calls before every later one fails; nil never fails.
    var subscribeFailsAfter: Int?
    var getHistoryShouldThrow: ZenohError?
    var healthOverride: Bool?
    /// Fails every `declareLivelinessToken` call.
    var declareLivelinessTokenShouldThrow: ZenohError? {
        get { locked { _declareLivelinessTokenShouldThrow } }
        set { locked { _declareLivelinessTokenShouldThrow = newValue } }
    }
    /// Fails every `livelinessGet`, firing `onFinish` first as the C bridge does.
    var livelinessGetShouldThrow: ZenohError? {
        get { locked { _livelinessGetShouldThrow } }
        set { locked { _livelinessGetShouldThrow = newValue } }
    }
    /// Whether liveliness queries reply with the mock's own live declarations, as a
    /// router that echoes a session's tokens would. `remoteLivelinessTokens` always reply.
    var livelinessEchoesOwnTokens: Bool {
        get { locked { _livelinessEchoesOwnTokens } }
        set { locked { _livelinessEchoesOwnTokens = newValue } }
    }
    /// Holds every liveliness query instead of answering it, as a router that never
    /// sends the final would; tests answer them through `heldLivelinessQueries`.
    var livelinessGetHolds: Bool {
        get { locked { _livelinessGetHolds } }
        set { locked { _livelinessGetHolds = newValue } }
    }
    /// Runs after each successful `declareLivelinessToken`, outside the mock's lock and
    /// before the handle is returned, so a test can act between the two.
    var onDeclareLivelinessToken: ((String) -> Void)? {
        get { locked { _onDeclareLivelinessToken } }
        set { locked { _onDeclareLivelinessToken = newValue } }
    }
    private var _declareLivelinessTokenShouldThrow: ZenohError?
    private var _onDeclareLivelinessToken: ((String) -> Void)?
    private var _livelinessGetShouldThrow: ZenohError?
    private var _livelinessEchoesOwnTokens = true
    private var _livelinessGetHolds = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // Recorded invocations
    private(set) var openedLocators: [String] = []
    private(set) var closedCount = 0
    private(set) var publisherDeclarations: [String] = []
    private(set) var publisherHandles: [MockPublisherHandle] = []
    private(set) var publisherOptions: [ZenohPublisherOptions] = []
    private(set) var puts: [(key: String, payload: Data, attachment: Data?)] = []
    private(set) var subscriptions: [(key: String, handler: (ZenohSample) -> Void)] = []
    private(set) var livelinessDeclarations: [String] = []
    private(set) var subscriberHandles: [MockSubscriberHandle] = []
    private(set) var livelinessHandles: [MockLivelinessTokenHandle] = []
    private(set) var queryableDeclarations: [(key: String, handler: @Sendable (any ZenohQueryHandle) -> Void)] = []
    private(set) var gets: [(key: String, payload: Data?, attachment: Data?, timeoutMs: UInt32)] = []
    /// Recorded `getHistory` calls. Tests answer them through `historyQueries[i]`.
    private(set) var historyQueries: [MockHistoryQuery] = []
    /// Key expressions of the liveliness queries, in order.
    var livelinessGets: [String] { locked { _livelinessGets } }
    private var _livelinessGets: [String] = []
    /// The liveliness queries held while `livelinessGetHolds` is set, in order.
    var heldLivelinessQueries: [MockHistoryQuery] { locked { _heldLivelinessQueries } }
    private var _heldLivelinessQueries: [MockHistoryQuery] = []
    /// Tokens alive on the simulated network besides the mock's own declarations;
    /// liveliness queries reply with every token, declared or listed here, that
    /// matches the queried key expression.
    var remoteLivelinessTokens: [String] {
        get { locked { _remoteLivelinessTokens } }
        set { locked { _remoteLivelinessTokens = newValue } }
    }
    private var _remoteLivelinessTokens: [String] = []
    /// Every query handed to a queryable by `deliverQuery` / `deliverQueryToQueryable`.
    private(set) var deliveredQueries: [MockQueryHandle] = []

    // Service test helpers
    private(set) var lastQueryReplyPayload: Data?
    private(set) var lastQueryReplyError: String?
    private var queryReplied = false

    /// Per-call scripts for `get`. Each `get` invocation pops the next entry.
    /// `nil` payload means "fire only onFinish" (timeout).
    private var getScripts: [(payload: Data?, isError: Bool)] = []

    /// Optional dynamic reply handler for `get`. If set, takes precedence over
    /// `getScripts` — invoked synchronously per `get` call. Returning non-nil
    /// fires a successful sample reply; returning nil triggers timeout (only
    /// `onFinish` fires). Used by the Action transport tests.
    var getReplyHandler: (@Sendable (_ keyExpr: String, _ payload: Data?) -> Data?)?

    /// Per-key capture of every `put` (string-keyed overload and declared
    /// publishers). Mirrors `puts` but indexed for fast lookup by key — used by
    /// Action transport tests.
    private(set) var putsByKey: [String: [(payload: Data, attachment: Data?)]] = [:]

    /// Captured liveliness-token key expressions. Alias of
    /// `livelinessDeclarations` used by the Action transport tests.
    var declaredLivelinessTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return livelinessDeclarations
    }

    func open(locator: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let e = openShouldThrow { throw e }
        openedLocators.append(locator)
        isOpen = true
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closedCount += 1
        if let e = closeShouldThrow { throw e }
        isOpen = false
    }

    func isSessionHealthy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return healthOverride ?? isOpen
    }

    func getSessionId() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return sessionIdValue
    }

    func declarePublisher(_ keyExpr: String, options: ZenohPublisherOptions) throws -> any ZenohPublisherHandle {
        lock.lock()
        defer { lock.unlock() }
        if let e = declarePublisherShouldThrow { throw e }
        publisherDeclarations.append(keyExpr)
        publisherOptions.append(options)
        let handle = MockPublisherHandle(keyExpr: keyExpr, client: self)
        publisherHandles.append(handle)
        return handle
    }

    /// Records a put made through a `MockPublisherHandle` in `puts` and
    /// `putsByKey`; fails with `putShouldThrow` when set.
    func recordPublisherPut(key: String, payload: Data, attachment: Data?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let e = putShouldThrow { throw e }
        puts.append((key: key, payload: payload, attachment: attachment))
        putsByKey[key, default: []].append((payload: payload, attachment: attachment))
    }

    func subscribe(keyExpr: String, handler: @escaping (ZenohSample) -> Void) throws -> any ZenohSubscriberHandle {
        lock.lock()
        defer { lock.unlock() }
        if let limit = subscribeFailsAfter, subscriptions.count >= limit {
            throw ZenohError.subscribeFailed("scripted failure")
        }
        subscriptions.append((key: keyExpr, handler: handler))
        let handle = MockSubscriberHandle()
        subscriberHandles.append(handle)
        return handle
    }

    func declareLivelinessToken(_ keyExpr: String) throws -> any ZenohLivelinessTokenHandle {
        lock.lock()
        if let e = _declareLivelinessTokenShouldThrow {
            lock.unlock()
            throw e
        }
        livelinessDeclarations.append(keyExpr)
        let handle = MockLivelinessTokenHandle()
        livelinessHandles.append(handle)
        let hook = _onDeclareLivelinessToken
        lock.unlock()
        hook?(keyExpr)
        return handle
    }

    func livelinessGet(
        keyExpr: String,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        _livelinessGets.append(keyExpr)
        if let e = _livelinessGetShouldThrow {
            lock.unlock()
            onFinish()
            throw e
        }
        if _livelinessGetHolds {
            _heldLivelinessQueries.append(
                MockHistoryQuery(
                    keyExpr: keyExpr, parameters: "", timeoutMs: timeoutMs, handler: handler, onFinish: onFinish))
            lock.unlock()
            return
        }
        let own =
            _livelinessEchoesOwnTokens
            ? zip(livelinessDeclarations, livelinessHandles).filter { $0.1.closeCount == 0 }.map(\.0) : []
        let alive = own + _remoteLivelinessTokens
        lock.unlock()
        let matches = alive.filter { MockKeyExprMatcher.matches(pattern: keyExpr, key: $0) }
        DispatchQueue.global(qos: .userInitiated).async {
            for token in matches {
                handler(.success(ZenohSample(keyExpr: token, payload: Data(), attachment: nil)))
            }
            onFinish()
        }
    }

    func declareQueryable(
        _ keyExpr: String,
        handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
    ) throws -> any ZenohQueryableHandle {
        lock.lock()
        defer { lock.unlock() }
        queryableDeclarations.append((key: keyExpr, handler: handler))
        return MockQueryableHandle()
    }

    func get(
        keyExpr: String,
        payload: Data?,
        attachment: Data?,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        gets.append((key: keyExpr, payload: payload, attachment: attachment, timeoutMs: timeoutMs))
        // Snapshot the dynamic handler / next scripted reply under the lock,
        // but call the dynamic handler outside it. Otherwise a handler that
        // touches the mock (e.g. inspects `writes`) would deadlock on the
        // same lock.
        let dyn = getReplyHandler
        let scripted: (payload: Data?, isError: Bool)? =
            (dyn == nil && !getScripts.isEmpty) ? getScripts.removeFirst() : nil
        lock.unlock()

        let script: (payload: Data?, isError: Bool)?
        if let dyn = dyn {
            if let replyPayload = dyn(keyExpr, payload) {
                script = (payload: replyPayload, isError: false)
            } else {
                script = (payload: nil, isError: false)
            }
        } else {
            script = scripted
        }

        // Fire the scripted reply / finish on a background queue to mirror
        // the C bridge's "callbacks run on a zenoh-pico-owned thread"
        // contract, then immediately fire onFinish.
        DispatchQueue.global(qos: .userInitiated).async {
            if let script = script {
                if let payload = script.payload {
                    if script.isError {
                        let msg = String(decoding: payload, as: UTF8.self)
                        handler(.failure(.queryReplyError(msg)))
                    } else {
                        handler(
                            .success(
                                ZenohSample(keyExpr: keyExpr, payload: payload, attachment: nil)
                            ))
                    }
                }
                // payload == nil: timeout — only onFinish fires.
            }
            onFinish()
        }
    }

    func getHistory(
        keyExpr: String,
        parameters: String,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if let e = getHistoryShouldThrow { throw e }
        historyQueries.append(
            MockHistoryQuery(
                keyExpr: keyExpr, parameters: parameters, timeoutMs: timeoutMs, handler: handler,
                onFinish: onFinish))
    }

    /// Test helper: deliver a synthetic query to every queryable registered on
    /// `keyExpr` and collect the resulting `reply(...)` payloads. Each invoked
    /// handler reads the query asynchronously (the action server fires a Task
    /// internally), so this helper polls briefly until **every** invoked
    /// handler has produced a reply (one reply per handler) or the 1s
    /// poll budget elapses — sufficient for the in-process mock-driven tests.
    func deliverQuery(keyExpr: String, payload: Data, attachment: Data? = nil) async throws -> [Data] {
        let handlers: [@Sendable (any ZenohQueryHandle) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            return queryableDeclarations.filter { $0.key == keyExpr }.map { $0.handler }
        }()
        guard !handlers.isEmpty else { return [] }

        let collector = QueryReplyCollector()
        for handler in handlers {
            let q = MockQueryHandle(
                keyExpr: keyExpr, payload: payload, attachment: attachment
            ) { reply in
                Task { await collector.append(reply) }
            }
            lock.lock()
            deliveredQueries.append(q)
            lock.unlock()
            handler(q)
        }
        // Poll briefly for the asynchronous Task in the queryable handler to
        // resolve. 1s upper bound matches the test expectations elsewhere.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            let snapshot = await collector.snapshot()
            if snapshot.count >= handlers.count {
                return snapshot.compactMap {
                    if case .success(let p) = $0 { return p } else { return nil }
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return await collector.snapshot().compactMap {
            if case .success(let p) = $0 { return p } else { return nil }
        }
    }

    /// Test helper: deliver a synthetic subscriber sample to every subscriber
    /// registered on `keyExpr`.
    func deliverSubscriberSample(keyExpr: String, payload: Data, attachment: Data?) {
        let handlers: [(ZenohSample) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            return subscriptions.filter { $0.key == keyExpr }.map { $0.handler }
        }()
        let sample = ZenohSample(keyExpr: keyExpr, payload: payload, attachment: attachment)
        for handler in handlers {
            handler(sample)
        }
    }

    /// Test helper: deliver a sample to all matching subscriber handlers.
    func deliver(sample: ZenohSample, toKeyExpr key: String) {
        let handlers: [(ZenohSample) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            return subscriptions.filter { $0.key == key }.map { $0.handler }
        }()
        for handler in handlers {
            handler(sample)
        }
    }

    /// Test helper: deliver a synthetic query to the most-recently-declared
    /// queryable whose key prefix matches `keyExpr`. The mock query handle
    /// records `reply` / `replyError` calls into `lastQueryReplyPayload` /
    /// `lastQueryReplyError`.
    func deliverQueryToQueryable(keyExpr: String, payload: Data, attachment: Data?) {
        let target: (key: String, handler: @Sendable (any ZenohQueryHandle) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return queryableDeclarations.last(where: { keyExpr.hasPrefix($0.key) || $0.key.hasPrefix(keyExpr) })
                ?? queryableDeclarations.last
        }()
        guard let target = target else { return }
        let query = MockQueryHandle(
            keyExpr: keyExpr,
            payload: payload,
            attachment: attachment
        ) { [weak self] reply in
            guard let self = self else { return }
            self.lock.lock()
            switch reply {
            case .success(let p):
                self.lastQueryReplyPayload = p
            case .failure(let m):
                self.lastQueryReplyError = m
            }
            self.queryReplied = true
            self.lock.unlock()
        }
        lock.lock()
        deliveredQueries.append(query)
        lock.unlock()
        target.handler(query)
    }

    /// Test helper: poll until a queryable reply has been recorded or the
    /// timeout elapses.
    func awaitQueryReply(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            lock.lock()
            let done = queryReplied
            lock.unlock()
            if done { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(
            domain: "MockZenohClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "awaitQueryReply timed out"])
    }

    /// Script the next `get` to return `payload` (success or error) before firing onFinish.
    func scriptGetReply(payload: Data, isError: Bool) {
        lock.lock()
        getScripts.append((payload: payload, isError: isError))
        lock.unlock()
    }

    /// Script the next `get` to fire only onFinish (no reply) — i.e. simulate timeout.
    func scriptGetTimeout() {
        lock.lock()
        getScripts.append((payload: nil, isError: false))
        lock.unlock()
    }
}

final class MockPublisherHandle: ZenohPublisherHandle, @unchecked Sendable {
    let keyExpr: String
    private weak var client: MockZenohClient?
    private let lock = NSLock()
    private var _matching: Bool? = false
    private(set) var closeCount = 0

    init(keyExpr: String, client: MockZenohClient) {
        self.keyExpr = keyExpr
        self.client = client
    }

    var matching: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _matching
        }
        set {
            lock.lock()
            _matching = newValue
            lock.unlock()
        }
    }

    func put(payload: Data, attachment: Data?) throws {
        guard let client else { throw ZenohError.putFailed("mock client released") }
        try client.recordPublisherPut(key: keyExpr, payload: payload, attachment: attachment)
    }

    func matchingStatus() -> Bool? { matching }

    func close() throws {
        lock.lock()
        closeCount += 1
        lock.unlock()
    }
}

final class MockSubscriberHandle: ZenohSubscriberHandle {
    private(set) var closeCount = 0
    private let lock = NSLock()
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closeCount += 1
    }
}

final class MockLivelinessTokenHandle: ZenohLivelinessTokenHandle {
    private(set) var closeCount = 0
    private let lock = NSLock()
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closeCount += 1
    }
}

final class MockQueryableHandle: ZenohQueryableHandle {
    private(set) var closeCount = 0
    private let lock = NSLock()
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closeCount += 1
    }
}

/// Collects asynchronous queryable replies produced by `deliverQuery`. Used
/// to bridge the queryable handler's `Task { ... query.reply(...) }` shape
/// back into a polling `await` site.
actor QueryReplyCollector {
    private var replies: [MockQueryHandle.Reply] = []

    func append(_ reply: MockQueryHandle.Reply) {
        replies.append(reply)
    }

    func snapshot() -> [MockQueryHandle.Reply] {
        return replies
    }
}

/// Synthetic in-process `ZenohQueryHandle`. Reply / replyError are reported
/// to the mock's recorder via the closure passed at init.
final class MockQueryHandle: ZenohQueryHandle, @unchecked Sendable {
    let keyExpr: String
    let payload: Data
    let attachment: Data?

    enum Reply {
        case success(Data)
        case failure(String)
    }

    private let recorder: @Sendable (Reply) -> Void
    private let lock = NSLock()
    private var consumed = false

    init(
        keyExpr: String, payload: Data, attachment: Data?,
        recorder: @escaping @Sendable (Reply) -> Void
    ) {
        self.keyExpr = keyExpr
        self.payload = payload
        self.attachment = attachment
        self.recorder = recorder
    }

    /// The attachment of the successful reply, once one was sent.
    var replyAttachment: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _replyAttachment
    }
    private var _replyAttachment: Data?

    func reply(payload: Data, attachment: Data?) throws {
        try claim()
        lock.lock()
        _replyAttachment = attachment
        lock.unlock()
        recorder(.success(payload))
    }

    func replyError(message: String) throws {
        try claim()
        recorder(.failure(message))
    }

    private func claim() throws {
        lock.lock()
        if consumed {
            lock.unlock()
            throw ZenohError.invalidParameter("query handle already consumed")
        }
        consumed = true
        lock.unlock()
    }
}

/// A recorded `getHistory` call; the test drives its replies and its end.
final class MockHistoryQuery: @unchecked Sendable {
    let keyExpr: String
    let parameters: String
    let timeoutMs: UInt32
    private let handler: @Sendable (Result<ZenohSample, ZenohError>) -> Void
    private let onFinish: @Sendable () -> Void

    init(
        keyExpr: String, parameters: String, timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.keyExpr = keyExpr
        self.parameters = parameters
        self.timeoutMs = timeoutMs
        self.handler = handler
        self.onFinish = onFinish
    }

    func reply(_ sample: ZenohSample) { handler(.success(sample)) }
    func replyError(_ message: String) { handler(.failure(.queryReplyError(message))) }
    func finish() { onFinish() }
}

/// Zenoh key-expression matching for the mock: `*` matches one chunk, `**` any
/// number of chunks (including none); other chunks match verbatim.
enum MockKeyExprMatcher {
    static func matches(pattern: String, key: String) -> Bool {
        match(pattern.split(separator: "/").map(String.init)[...], key.split(separator: "/").map(String.init)[...])
    }

    private static func match(_ p: ArraySlice<String>, _ k: ArraySlice<String>) -> Bool {
        guard let head = p.first else { return k.isEmpty }
        if head == "**" {
            let rest = p.dropFirst()
            var tail = k
            while true {
                if match(rest, tail) { return true }
                guard !tail.isEmpty else { return false }
                tail = tail.dropFirst()
            }
        }
        guard let first = k.first, head == "*" || head == first else { return false }
        return match(p.dropFirst(), k.dropFirst())
    }
}
