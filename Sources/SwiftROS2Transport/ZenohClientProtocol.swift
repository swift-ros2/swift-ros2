// ZenohClientProtocol.swift
// Protocol abstraction for Zenoh C-FFI bridge
//
// This protocol allows swift-ros2 to use Zenoh transport without
// directly depending on the C bridge. The consuming app (e.g., Conduit)
// provides a concrete implementation that calls the C functions.

import Foundation

// MARK: - Handle Protocols (type-erased C resource wrappers)

/// Handle to a declared Zenoh key expression
package protocol ZenohKeyExprHandle: AnyObject {}

/// Handle to a Zenoh subscriber
package protocol ZenohSubscriberHandle: AnyObject {
    func close() throws
}

/// Handle to a Zenoh liveliness token
package protocol ZenohLivelinessTokenHandle: AnyObject {
    func close() throws
}

/// Handle to a declared Zenoh queryable (Service Server side)
package protocol ZenohQueryableHandle: AnyObject {
    func close() throws
}

/// Handle to a declared Zenoh publisher
package protocol ZenohPublisherHandle: AnyObject {
    /// Publish through this publisher.
    func put(payload: Data, attachment: Data?) throws
    /// `true` when a subscriber matches, `false` when none does, `nil` when the
    /// build cannot tell, the publisher is closed, or its session has lost its
    /// router (the last known state would otherwise stay frozen).
    func matchingStatus() -> Bool?
    func close() throws
}

/// A live in-flight Zenoh query held by the C bridge until reply.
///
/// Consumed by the first call to `reply(payload:attachment:)` or
/// `replyError(message:)`. After consumption further reply calls throw
/// `ZenohError.invalidParameter`.
package protocol ZenohQueryHandle: AnyObject, Sendable {
    /// The key expression the query was issued against.
    var keyExpr: String { get }

    /// The query payload (empty if the query carried none).
    var payload: Data { get }

    /// The query attachment (nil if the query carried none).
    var attachment: Data? { get }

    /// Reply with a successful payload. Consumes the handle.
    func reply(payload: Data, attachment: Data?) throws

    /// Reply with an error message. Consumes the handle.
    func replyError(message: String) throws
}

// MARK: - Zenoh Sample

/// Data received by a Zenoh subscriber
package struct ZenohSample: Sendable {
    package let keyExpr: String
    package let payload: Data
    package let attachment: Data?

    package init(keyExpr: String, payload: Data, attachment: Data?) {
        self.keyExpr = keyExpr
        self.payload = payload
        self.attachment = attachment
    }
}

// MARK: - Zenoh Error

/// Errors from Zenoh operations
package enum ZenohError: Error, LocalizedError {
    case sessionCreationFailed(String)
    case sessionCloseFailed(String)
    case keyExprDeclarationFailed(String)
    case putFailed(String)
    case subscribeFailed(String)
    case unsubscribeFailed(String)
    case invalidParameter(String)
    case internalError(String)
    case sessionDisconnected(String)
    /// Reply with `is_error == true` from a `get`. Carries the remote error
    /// payload decoded as UTF-8 so the transport layer can surface it as a
    /// `serviceHandlerFailed` without parsing prefixed strings.
    case queryReplyError(String)

    package var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let msg): return "Session creation failed: \(msg)"
        case .sessionCloseFailed(let msg): return "Session close failed: \(msg)"
        case .keyExprDeclarationFailed(let msg): return "Key expression declaration failed: \(msg)"
        case .putFailed(let msg): return "Put operation failed: \(msg)"
        case .subscribeFailed(let msg): return "Subscribe operation failed: \(msg)"
        case .unsubscribeFailed(let msg): return "Unsubscribe operation failed: \(msg)"
        case .invalidParameter(let msg): return "Invalid parameter: \(msg)"
        case .internalError(let msg): return "Internal error: \(msg)"
        case .sessionDisconnected(let msg): return "Session disconnected: \(msg)"
        case .queryReplyError(let msg): return "Query reply error: \(msg)"
        }
    }
}

// MARK: - Zenoh Publisher Options

/// How a Zenoh publisher is declared
package struct ZenohPublisherOptions: Sendable, Equatable {
    /// Samples kept for late-joining subscribers; 0 declares a plain publisher.
    package var cacheDepth: Int
    /// Sporadic sample-miss heartbeat period; 0 disables heartbeats.
    package var heartbeatMs: UInt64

    package init(cacheDepth: Int = 0, heartbeatMs: UInt64 = 0) {
        self.cacheDepth = cacheDepth
        self.heartbeatMs = heartbeatMs
    }
}

// MARK: - Zenoh Client Protocol

/// Protocol for Zenoh session management
///
/// Consuming apps implement this by wrapping the zenoh-pico C bridge.
/// swift-ros2's `ZenohTransportSession` uses this protocol to publish,
/// subscribe, and manage ROS 2 discovery without any C dependency.
///
/// Example implementation in Conduit:
/// ```swift
/// class ZenohClientAdapter: ZenohClientProtocol {
///     private let cClient = ZenohClient()  // wraps C bridge
///     func open(locator: String) throws { try cClient.open(locator: locator) }
///     // ...
/// }
/// ```
package protocol ZenohClientProtocol: AnyObject {
    /// Open a Zenoh session
    func open(locator: String) throws

    /// Close the session and release all resources
    func close() throws

    /// Check if the session is healthy: open, not stale after sleep/wake, and
    /// still connected to its router
    func isSessionHealthy() -> Bool

    /// Get the session ID as a hex string
    func getSessionId() throws -> String

    /// Declare a key expression for efficient reuse
    func declareKeyExpr(_ keyExpr: String) throws -> any ZenohKeyExprHandle

    /// Declare a publisher on a key expression; `options.cacheDepth > 0` declares
    /// an advanced publisher whose cache serves late joiners (TRANSIENT_LOCAL)
    func declarePublisher(_ keyExpr: String, options: ZenohPublisherOptions) throws -> any ZenohPublisherHandle

    /// Publish data to a declared key expression
    func put(keyExpr: any ZenohKeyExprHandle, payload: Data, attachment: Data?) throws

    /// Publish data to a key expression string (without prior declaration)
    func put(keyExpr: String, payload: Data, attachment: Data?) throws

    /// Subscribe to a key expression
    func subscribe(keyExpr: String, handler: @escaping (ZenohSample) -> Void) throws -> any ZenohSubscriberHandle

    /// Declare a liveliness token for ROS 2 discovery
    func declareLivelinessToken(_ keyExpr: String) throws -> any ZenohLivelinessTokenHandle

    /// Declare a queryable on the given key expression. The handler runs on a
    /// zenoh-pico-owned thread; do not block. Each query handle is consumed by
    /// the first `reply(...)` or `replyError(...)` call. If neither is invoked
    /// before the queryable is closed, the bridge drops the query.
    func declareQueryable(
        _ keyExpr: String,
        handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
    ) throws -> any ZenohQueryableHandle

    /// Issue a query against the given key expression, awaiting replies via
    /// `handler`. `onFinish` fires once after the final reply is delivered (or
    /// the timeout elapses). All callbacks run on a zenoh-pico-owned thread.
    func get(
        keyExpr: String,
        payload: Data?,
        attachment: Data?,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws
}

extension ZenohClientProtocol {
    /// Default stub — implementations that don't yet support queryables can
    /// fall back to this until they wire in the C bridge.
    package func declareQueryable(
        _ keyExpr: String,
        handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
    ) throws -> any ZenohQueryableHandle {
        throw ZenohError.invalidParameter("declareQueryable not implemented")
    }

    /// Default stub — implementations that don't yet support get queries can
    /// fall back to this until they wire in the C bridge.
    package func get(
        keyExpr: String,
        payload: Data?,
        attachment: Data?,
        timeoutMs: UInt32,
        handler: @escaping @Sendable (Result<ZenohSample, ZenohError>) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        throw ZenohError.invalidParameter("get not implemented")
    }
}
