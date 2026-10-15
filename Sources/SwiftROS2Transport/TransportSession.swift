// TransportSession.swift
// Transport abstraction protocols

import Foundation
import SwiftROS2CDR
import SwiftROS2Wire

// MARK: - Transport Session Protocol

/// Protocol for transport session lifecycle management
///
/// Implementations provide the actual transport mechanism:
/// - Zenoh: via zenoh-pico C-FFI
/// - DDS: via CycloneDDS C-FFI
/// - RCL: `RclTransportSession` over `RclClientProtocol` (real rcl + rmw,
///   Apple xcframework or Linux system ROS 2)
package protocol TransportSession: AnyObject, Sendable {
    var isConnected: Bool { get }
    var transportType: TransportType { get }
    var sessionId: String { get }

    func open(config: TransportConfig) async throws
    func close() throws
    func checkHealth() -> Bool

    /// Register a ROS 2 node so backends that model real nodes (the rcl
    /// backend) create one with the caller's name. The wire DDS transport has
    /// no node entity and ignores this; the wire Zenoh session uses the
    /// identity for services and actions. Default: no-op.
    func registerNode(name: String, namespace: String) throws

    /// Tear down a node previously registered via a successful `registerNode`
    /// call. Called by `ROS2Node.destroy()`. Default: no-op.
    func unregisterNode(name: String, namespace: String)

    /// Create a publisher for a topic
    func createPublisher(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportPublisher

    /// Create a subscriber for a topic
    func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber

    /// Create a Service Server.
    ///
    /// `serviceTypeName` is the ROS-format service type name (e.g.
    /// `std_srvs/srv/Trigger`). Each transport derives the wire-level naming
    /// from this: DDS uses `DDSWireCodec.serviceTopicNames` to build the
    /// `rq/<service>Request` / `rr/<service>Reply` topic pair plus
    /// `<pkg>::srv::dds_::<Type>_Request_` / `_Response_` type names; Zenoh
    /// uses `ZenohWireCodec.makeServiceKeyExpr` to build the queryable key
    /// expression. Callers do not need to pre-derive any of this.
    func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService

    /// Create a Service Client.
    ///
    /// `serviceTypeName` is the ROS-format service type name (e.g.
    /// `std_srvs/srv/Trigger`). Each transport derives the wire-level naming
    /// from this: DDS uses `DDSWireCodec.serviceTopicNames`; Zenoh uses
    /// `ZenohWireCodec.makeServiceKeyExpr`. Callers do not need to pre-derive
    /// any of it.
    func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient

    /// Create an Action Server.
    ///
    /// `actionTypeName` is the ROS-format action type (e.g.
    /// `example_interfaces/action/Fibonacci`). The transport derives all 5
    /// wire-level role names from this via `DDSWireCodec.actionTopicNames(...)`
    /// or `ZenohWireCodec.makeActionKeyExpr(...)`. `roleTypeHashes` carries the
    /// per-role hashes the umbrella API extracted from `ROS2ActionTypeInfo`.
    ///
    /// Default implementation throws `TransportError.unsupportedFeature` —
    /// only `DDSTransportSession` (Phase 4) and `ZenohTransportSession`
    /// (Phase 5) override it.
    func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer

    /// Create an Action Client.
    ///
    /// Default implementation throws `TransportError.unsupportedFeature` —
    /// only `DDSTransportSession` (Phase 4) and `ZenohTransportSession`
    /// (Phase 5) override it.
    func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS
    ) throws -> any TransportActionClient
}

extension TransportSession {
    package func registerNode(name: String, namespace: String) throws {}
    package func unregisterNode(name: String, namespace: String) {}

    /// Default — concrete sessions override in Phases 4 / 5.
    package func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer {
        throw TransportError.unsupportedFeature("createActionServer (transport: \(transportType))")
    }

    /// Default — concrete sessions override in Phases 4 / 5.
    package func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS
    ) throws -> any TransportActionClient {
        throw TransportError.unsupportedFeature("createActionClient (transport: \(transportType))")
    }
}

// MARK: - Transport Publisher Protocol

/// An active publisher handle that writes pre-serialized CDR payloads to a transport.
///
/// Conforming types are returned by ``TransportSession/createPublisher(topic:typeName:typeHash:qos:)``
/// and must remain sendable across concurrency domains.
package protocol TransportPublisher: Sendable {
    func publish(data: Data, timestamp: UInt64, sequenceNumber: Int64) throws
    func close() throws
    var topic: String { get }
    var isActive: Bool { get }

    /// Whether at least one subscription currently matches this publisher:
    /// `true` or `false` when the transport can tell, `nil` when it cannot.
    /// A wire Zenoh session that has lost its router reports `nil`: zenoh-pico
    /// would keep the last known state forever.
    ///
    /// May be called from any thread, concurrently with `publish` and `close`,
    /// and after `close`. It must not touch released native state, and must
    /// return `nil` once the publisher is closed.
    var matchedSubscriptions: Bool? { get }
}

// MARK: - Transport Subscriber Protocol

/// An active subscriber handle that receives raw CDR payloads from a transport.
///
/// Conforming types are returned by ``TransportSession/createSubscriber(topic:typeName:typeHash:qos:handler:)``
/// and must remain sendable across concurrency domains.
package protocol TransportSubscriber: Sendable {
    var topic: String { get }
    var isActive: Bool { get }
    func close() throws
}

// MARK: - Transport Service / Client (Service Server / Service Client)

/// An active Service Server handle.
///
/// The handler closure passed at creation time receives raw CDR request bytes
/// and is expected to return raw CDR response bytes. The transport layer is
/// untyped on purpose — `ROS2Service<S>` on top encodes / decodes typed values.
package protocol TransportService: Sendable {
    var name: String { get }
    var isActive: Bool { get }
    func close() throws
}

/// An active Service Client handle.
///
/// `call` operates on raw CDR. The `ROS2Client<S>` layer encodes the typed
/// request, invokes this method, and decodes the typed response.
package protocol TransportClient: Sendable {
    var name: String { get }
    var isActive: Bool { get }
    func waitForService(timeout: Duration) async throws
    /// Send pre-encoded CDR request, await pre-encoded CDR response.
    /// Throws `TransportError.requestTimeout` on deadline,
    /// `TransportError.requestCancelled` on parent-Task cancellation.
    func call(requestCDR: Data, timeout: Duration) async throws -> Data
    func close() throws
}

// MARK: - Transport QoS

/// Package-internal QoS shape derived from `QoSProfile`. End users see only `QoSProfile`.
package struct TransportQoS: Sendable, Equatable {
    package enum Reliability: String, Sendable {
        case reliable
        case bestEffort = "best_effort"
    }

    package enum Durability: String, Sendable {
        case volatile
        case transientLocal = "transient_local"
    }

    package enum History: Sendable, Equatable {
        case keepLast(Int)
        case keepAll
    }

    package let reliability: Reliability
    package let durability: Durability
    package let history: History

    package static let sensorData = TransportQoS(
        reliability: .reliable,
        durability: .volatile,
        history: .keepLast(10)
    )

    package static let bestEffort = TransportQoS(
        reliability: .bestEffort,
        durability: .volatile,
        history: .keepLast(1)
    )

    package static let `default` = sensorData

    package init(
        reliability: Reliability = .reliable,
        durability: Durability = .volatile,
        history: History = .keepLast(10)
    ) {
        self.reliability = reliability
        self.durability = durability
        self.history = history
    }
}

// MARK: - Transport Errors

/// Errors thrown by transport session operations such as connect, publish, and subscribe.
///
/// Check ``isRecoverable`` to decide whether a retry is appropriate.
public enum TransportError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionTimeout(TimeInterval)
    case alreadyConnected
    case notConnected
    case publisherCreationFailed(String)
    case subscriberCreationFailed(String)
    case publishFailed(String)
    case publisherClosed
    case sessionUnhealthy(String)
    case sessionClosed
    case invalidConfiguration(String)
    case unsupportedFeature(String)
    case requestTimeout(Duration)
    case requestCancelled
    case serviceHandlerFailed(String)
    case goalRejected
    case goalUnknown
    case actionServerUnavailable

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .connectionTimeout(let t): return "Connection timed out after \(Int(t))s"
        case .alreadyConnected: return "Already connected"
        case .notConnected: return "Not connected"
        case .publisherCreationFailed(let msg): return "Failed to create publisher: \(msg)"
        case .subscriberCreationFailed(let msg): return "Failed to create subscriber: \(msg)"
        case .publishFailed(let msg): return "Publish failed: \(msg)"
        case .publisherClosed: return "Publisher is closed"
        case .sessionUnhealthy(let msg): return "Session unhealthy: \(msg)"
        case .sessionClosed: return "Session is closed"
        case .invalidConfiguration(let msg): return "Invalid configuration: \(msg)"
        case .unsupportedFeature(let f): return "Unsupported feature: \(f)"
        case .requestTimeout(let d): return "Service request timed out after \(d)"
        case .requestCancelled: return "Service request was cancelled"
        case .serviceHandlerFailed(let msg): return "Service handler failed: \(msg)"
        case .goalRejected: return "Action goal was rejected by the server"
        case .goalUnknown: return "Action goal id is unknown to the server"
        case .actionServerUnavailable: return "Action server is not reachable"
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .connectionFailed, .connectionTimeout, .publishFailed, .sessionUnhealthy,
            .actionServerUnavailable:
            return true
        default:
            return false
        }
    }
}
