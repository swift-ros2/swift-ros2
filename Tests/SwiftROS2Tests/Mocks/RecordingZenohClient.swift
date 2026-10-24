// RecordingZenohClient.swift
// A Zenoh client that records the key expressions, liveliness tokens and payloads a real
// ZenohTransportSession hands it, so umbrella tests can check what goes on the wire.

import Foundation

@testable import SwiftROS2Transport

/// Records every declaration, put and get of a `ZenohTransportSession`. Gets are answered by
/// ``getReply`` (no reply when it returns nil); queries reach a queryable through
/// ``deliverQuery(toKeyExprWithPrefix:payload:)``.
final class RecordingZenohClient: ZenohClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var _publisherKeyExprs: [String] = []
    private var _puts: [(keyExpr: String, payload: Data)] = []
    private var _subscriptions: [(keyExpr: String, handler: (ZenohSample) -> Void)] = []
    private var _livelinessTokens: [String] = []
    private var _queryables: [(keyExpr: String, handler: @Sendable (any ZenohQueryHandle) -> Void)] = []
    private var _gets: [(keyExpr: String, payload: Data?)] = []
    private var _getReply: (@Sendable (_ keyExpr: String, _ payload: Data?) -> Data?)?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var publisherKeyExprs: [String] { locked { _publisherKeyExprs } }
    var puts: [(keyExpr: String, payload: Data)] { locked { _puts } }
    var subscriptionKeyExprs: [String] { locked { _subscriptions.map(\.keyExpr) } }
    var livelinessTokens: [String] { locked { _livelinessTokens } }
    var queryableKeyExprs: [String] { locked { _queryables.map(\.keyExpr) } }
    var gets: [(keyExpr: String, payload: Data?)] { locked { _gets } }

    /// Answers each `get`: the reply payload, or nil to finish without a reply.
    var getReply: (@Sendable (_ keyExpr: String, _ payload: Data?) -> Data?)? {
        get { locked { _getReply } }
        set { locked { _getReply = newValue } }
    }

    /// Delivers a sample to every subscription whose key expression is `keyExpr`.
    func deliverSample(toKeyExpr keyExpr: String, payload: Data) {
        let handlers = locked { _subscriptions.filter { $0.keyExpr == keyExpr }.map(\.handler) }
        for handler in handlers {
            handler(ZenohSample(keyExpr: keyExpr, payload: payload, attachment: nil))
        }
    }

    /// Sends a query to the first queryable whose key expression starts with `prefix` and
    /// returns its reply payload, or nil when it replies with an error or not at all within
    /// `timeout`.
    func deliverQuery(
        toKeyExprWithPrefix prefix: String, payload: Data, timeout: Duration = .seconds(5)
    ) async throws -> Data? {
        let target = locked { _queryables.first { $0.keyExpr.hasPrefix(prefix) } }
        guard let target else { throw TransportError.unsupportedFeature("no queryable under \(prefix)") }
        let query = RecordingQueryHandle(keyExpr: target.keyExpr, payload: payload)
        target.handler(query)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let reply = query.receivedReply { return reply }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    // MARK: - ZenohClientProtocol

    func open(locator: String) throws { locked { open = true } }

    func close() throws { locked { open = false } }

    func isSessionHealthy() -> Bool { locked { open } }

    func getSessionId() throws -> String { "0123456789abcdef0123456789abcdef" }

    func declarePublisher(_ keyExpr: String, options: ZenohPublisherOptions) throws -> any ZenohPublisherHandle {
        locked { _publisherKeyExprs.append(keyExpr) }
        return RecordingPublisherHandle(keyExpr: keyExpr, client: self)
    }

    fileprivate func recordPut(keyExpr: String, payload: Data) {
        locked { _puts.append((keyExpr, payload)) }
    }

    func subscribe(keyExpr: String, handler: @escaping (ZenohSample) -> Void) throws -> any ZenohSubscriberHandle {
        locked { _subscriptions.append((keyExpr, handler)) }
        return RecordingHandle()
    }

    func declareLivelinessToken(_ keyExpr: String) throws -> any ZenohLivelinessTokenHandle {
        locked { _livelinessTokens.append(keyExpr) }
        return RecordingHandle()
    }

    func livelinessGet(
        keyExpr: String,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        onFinish()
    }

    func declareQueryable(
        _ keyExpr: String,
        handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
    ) throws -> any ZenohQueryableHandle {
        locked { _queryables.append((keyExpr, handler)) }
        return RecordingHandle()
    }

    func get(
        keyExpr: String,
        payload: Data?,
        attachment: Data?,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        let reply = locked {
            _gets.append((keyExpr, payload))
            return _getReply
        }
        DispatchQueue.global().async {
            if let data = reply?(keyExpr, payload) {
                handler(.success(ZenohSample(keyExpr: keyExpr, payload: data, attachment: nil)))
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
        onFinish()
    }
}

private final class RecordingPublisherHandle: ZenohPublisherHandle {
    let keyExpr: String
    private weak var client: RecordingZenohClient?

    init(keyExpr: String, client: RecordingZenohClient) {
        self.keyExpr = keyExpr
        self.client = client
    }

    func put(payload: Data, attachment: Data?) throws {
        client?.recordPut(keyExpr: keyExpr, payload: payload)
    }

    func matchingStatus() -> Bool? { true }

    func close() throws {}
}

private final class RecordingHandle: ZenohSubscriberHandle, ZenohLivelinessTokenHandle, ZenohQueryableHandle {
    func close() throws {}
}

private final class RecordingQueryHandle: ZenohQueryHandle, @unchecked Sendable {
    let keyExpr: String
    let payload: Data
    let attachment: Data? = nil
    private let lock = NSLock()
    private var _reply: Data?

    init(keyExpr: String, payload: Data) {
        self.keyExpr = keyExpr
        self.payload = payload
    }

    var receivedReply: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _reply
    }

    func reply(payload: Data, attachment: Data?) throws {
        lock.lock()
        _reply = payload
        lock.unlock()
    }

    func replyError(message: String) throws {}
}
