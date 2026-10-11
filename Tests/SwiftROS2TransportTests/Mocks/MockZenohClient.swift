import Foundation
import SwiftROS2Transport

/// In-memory ZenohClientProtocol used by ZenohTransportSession unit tests.
///
/// Records every call so tests can assert against `puts`, `keyExprDeclarations`,
/// `subscriptions`, etc. Lock-protected so tests can also exercise the
/// session's @Sendable contract.
final class MockZenohClient: ZenohClientProtocol, @unchecked Sendable {
    private let lock = NSLock()

    // Configurable behavior
    var isOpen = false
    var sessionIdValue = "mock-session-id"
    var openShouldThrow: ZenohError?
    var declareKeyExprShouldThrow: ZenohError?
    var declarePublisherShouldThrow: ZenohError?
    var putShouldThrow: ZenohError?
    var subscribeShouldThrow: ZenohError?
    var livelinessShouldThrow: ZenohError?
    var declareQueryableShouldThrow: ZenohError?
    var getShouldThrow: ZenohError?
    var healthOverride: Bool?

    // Recorded invocations
    private(set) var openedLocators: [String] = []
    private(set) var closedCount = 0
    private(set) var keyExprDeclarations: [String] = []
    private(set) var publisherDeclarations: [String] = []
    private(set) var publisherHandles: [MockPublisherHandle] = []
    private(set) var publisherOptions: [ZenohPublisherOptions] = []
    private(set) var puts: [(key: String, payload: Data, attachment: Data?)] = []
    private(set) var subscriptions: [(key: String, handler: (ZenohSample) -> Void)] = []
    private(set) var livelinessDeclarations: [String] = []
    private(set) var queryableDeclarations: [(key: String, handler: @Sendable (any ZenohQueryHandle) -> Void)] = []
    private(set) var gets: [(key: String, payload: Data?, attachment: Data?, timeoutMs: UInt32)] = []

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

    /// Per-key capture of every `put` (string-keyed overload). Mirrors `puts`
    /// but indexed for fast lookup by key — used by Action transport tests.
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

    func declareKeyExpr(_ keyExpr: String) throws -> any ZenohKeyExprHandle {
        lock.lock()
        defer { lock.unlock() }
        if let e = declareKeyExprShouldThrow { throw e }
        keyExprDeclarations.append(keyExpr)
        return MockKeyExprHandle(keyExpr: keyExpr)
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

    /// Records a put made through a `MockPublisherHandle`; shares `putShouldThrow`
    /// and `puts` with `put(keyExpr:payload:attachment:)`.
    func recordPublisherPut(key: String, payload: Data, attachment: Data?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let e = putShouldThrow { throw e }
        puts.append((key: key, payload: payload, attachment: attachment))
    }

    func put(keyExpr: any ZenohKeyExprHandle, payload: Data, attachment: Data?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let e = putShouldThrow { throw e }
        let key = (keyExpr as? MockKeyExprHandle)?.keyExpr ?? "<unknown>"
        puts.append((key: key, payload: payload, attachment: attachment))
    }

    func put(keyExpr: String, payload: Data, attachment: Data?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let e = putShouldThrow { throw e }
        puts.append((key: keyExpr, payload: payload, attachment: attachment))
        var bucket = putsByKey[keyExpr] ?? []
        bucket.append((payload: payload, attachment: attachment))
        putsByKey[keyExpr] = bucket
    }

    func subscribe(keyExpr: String, handler: @escaping (ZenohSample) -> Void) throws -> any ZenohSubscriberHandle {
        lock.lock()
        defer { lock.unlock() }
        if let e = subscribeShouldThrow { throw e }
        subscriptions.append((key: keyExpr, handler: handler))
        return MockSubscriberHandle()
    }

    func declareLivelinessToken(_ keyExpr: String) throws -> any ZenohLivelinessTokenHandle {
        lock.lock()
        defer { lock.unlock() }
        if let e = livelinessShouldThrow { throw e }
        livelinessDeclarations.append(keyExpr)
        return MockLivelinessTokenHandle()
    }

    func declareQueryable(
        _ keyExpr: String,
        handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
    ) throws -> any ZenohQueryableHandle {
        lock.lock()
        defer { lock.unlock() }
        if let e = declareQueryableShouldThrow { throw e }
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
        if let e = getShouldThrow {
            lock.unlock()
            throw e
        }
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

    /// Test helper: deliver a synthetic query to every queryable registered on
    /// `keyExpr` and collect the resulting `reply(...)` payloads. Each invoked
    /// handler reads the query asynchronously (the action server fires a Task
    /// internally), so this helper polls briefly until **every** invoked
    /// handler has produced a reply (one reply per handler) or the 1s
    /// poll budget elapses — sufficient for the in-process mock-driven tests.
    func deliverQuery(keyExpr: String, payload: Data) async throws -> [Data] {
        let handlers: [@Sendable (any ZenohQueryHandle) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            return queryableDeclarations.filter { $0.key == keyExpr }.map { $0.handler }
        }()
        guard !handlers.isEmpty else { return [] }

        let collector = QueryReplyCollector()
        for handler in handlers {
            let q = MockQueryHandle(
                keyExpr: keyExpr, payload: payload, attachment: nil
            ) { reply in
                Task { await collector.append(reply) }
            }
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

final class MockKeyExprHandle: ZenohKeyExprHandle {
    let keyExpr: String
    init(keyExpr: String) { self.keyExpr = keyExpr }
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

    func reply(payload: Data, attachment: Data?) throws {
        try claim()
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
