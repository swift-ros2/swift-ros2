// RclClientProtocol.swift
// FFI seam for the real-rcl backend. The concrete RclClient lives in the
// gated SwiftROS2RCL target; this protocol stays C-free so RclTransportSession
// is unit-testable with a mock (no xcframework) in ordinary CI.

import Foundation

/// Opaque handle to an rcl node owned by the client.
package protocol RclNodeHandle: AnyObject, Sendable {}

/// Opaque handle to an rcl publisher owned by the client.
package protocol RclPublisherHandle: AnyObject, Sendable {
    var isActive: Bool { get }
    func close()
}

/// Opaque handle to an rcl subscription owned by the client.
package protocol RclSubscriptionHandle: AnyObject, Sendable {
    var isActive: Bool { get }
}

/// Opaque handle to an rcl service server owned by the client.
package protocol RclServiceHandle: AnyObject, Sendable {
    var isActive: Bool { get }
}

/// Opaque handle to an rcl service client owned by the client.
package protocol RclClientHandle: AnyObject, Sendable {
    var isActive: Bool { get }
}

/// Opaque handle to an rcl_action action server owned by the client.
package protocol RclActionServerHandle: AnyObject, Sendable {
    var isActive: Bool { get }
}

/// Opaque handle to an rcl_action action client owned by the client.
package protocol RclActionClientHandle: AnyObject, Sendable {
    var isActive: Bool { get }
}

/// rcl_action goal state-machine events (mirrors `rcl_action_goal_event_t`).
package enum RclGoalEvent: Int32, Sendable {
    case execute = 0
    case cancelGoal = 1
    case succeed = 2
    case abort = 3
    case canceled = 4
}

/// One `action_msgs/msg/GoalStatus` entry as taken by the rcl action client.
package struct RclGoalStatusRecord: Sendable, Equatable {
    /// 16-byte goal id.
    package let goalId: [UInt8]
    package let stampSec: Int32
    package let stampNanosec: UInt32
    /// Raw `GoalStatus.STATUS_*` value.
    package let status: Int8

    package init(goalId: [UInt8], stampSec: Int32, stampNanosec: UInt32, status: Int8) {
        self.goalId = goalId
        self.stampSec = stampSec
        self.stampNanosec = stampNanosec
        self.status = status
    }
}

/// Wait-thread callback bag for an rcl action server. Each closure receives
/// the raw request CDR (incl. the 4-byte encapsulation header) plus the
/// opaque 24-byte request-id blob to echo into the matching send call.
package struct RclActionServerCallbacks: Sendable {
    package let onGoalRequest: @Sendable (Data, [UInt8]) -> Void
    package let onCancelRequest: @Sendable (Data, [UInt8]) -> Void
    package let onResultRequest: @Sendable (Data, [UInt8]) -> Void

    package init(
        onGoalRequest: @escaping @Sendable (Data, [UInt8]) -> Void,
        onCancelRequest: @escaping @Sendable (Data, [UInt8]) -> Void,
        onResultRequest: @escaping @Sendable (Data, [UInt8]) -> Void
    ) {
        self.onGoalRequest = onGoalRequest
        self.onCancelRequest = onCancelRequest
        self.onResultRequest = onResultRequest
    }
}

/// Wait-thread callback bag for an rcl action client. The three response
/// closures receive rcl's sequence number (as returned by the matching send)
/// plus the raw response CDR; `onFeedback` receives the FeedbackMessage CDR;
/// `onStatus` receives the decoded status entries of one GoalStatusArray.
package struct RclActionClientCallbacks: Sendable {
    package let onGoalResponse: @Sendable (Int64, Data) -> Void
    package let onCancelResponse: @Sendable (Int64, Data) -> Void
    package let onResultResponse: @Sendable (Int64, Data) -> Void
    package let onFeedback: @Sendable (Data) -> Void
    package let onStatus: @Sendable ([RclGoalStatusRecord]) -> Void

    package init(
        onGoalResponse: @escaping @Sendable (Int64, Data) -> Void,
        onCancelResponse: @escaping @Sendable (Int64, Data) -> Void,
        onResultResponse: @escaping @Sendable (Int64, Data) -> Void,
        onFeedback: @escaping @Sendable (Data) -> Void,
        onStatus: @escaping @Sendable ([RclGoalStatusRecord]) -> Void
    ) {
        self.onGoalResponse = onGoalResponse
        self.onCancelResponse = onCancelResponse
        self.onResultResponse = onResultResponse
        self.onFeedback = onFeedback
        self.onStatus = onStatus
    }
}

/// One publisher as rcl's graph reports it, with rmw's own QoS policy values.
///
/// The client passes the values through unmapped; ``RclTransportSession`` turns
/// them into the topic graph's reliability and durability.
package struct RclGraphPublisherRecord: Sendable, Equatable {
    /// `RMW_QOS_POLICY_RELIABILITY_RELIABLE`. Every other value (system default,
    /// best effort, unknown, best available) reads as best effort.
    package static let rmwReliabilityReliable: Int32 = 1
    /// `RMW_QOS_POLICY_DURABILITY_TRANSIENT_LOCAL`. Every other value reads as
    /// volatile.
    package static let rmwDurabilityTransientLocal: Int32 = 1

    /// The absolute ROS topic name.
    package let topicName: String
    /// The ROS type name of this publisher, for example `std_msgs/msg/String`.
    package let typeName: String
    /// The `rmw_qos_reliability_policy_e` value.
    package let reliability: Int32
    /// The `rmw_qos_durability_policy_e` value.
    package let durability: Int32
    /// The node name rmw reports, `_NODE_NAME_UNKNOWN_` when it cannot attribute
    /// the publisher.
    package let nodeName: String
    /// The node namespace rmw reports, `_NODE_NAMESPACE_UNKNOWN_` when it cannot
    /// attribute the publisher.
    package let nodeNamespace: String

    package init(
        topicName: String, typeName: String, reliability: Int32, durability: Int32,
        nodeName: String, nodeNamespace: String
    ) {
        self.topicName = topicName
        self.typeName = typeName
        self.reliability = reliability
        self.durability = durability
        self.nodeName = nodeName
        self.nodeNamespace = nodeNamespace
    }
}

/// Lifecycle + publish + subscribe + service operations the rcl C bridge exposes.
package protocol RclClientProtocol: Sendable {
    /// Whether the native rcl stack is linked and usable.
    var isAvailable: Bool { get }

    /// `transportType` selects the backend rmw where that is a runtime choice
    /// (Linux: `.zenoh` ⇒ rmw_zenoh_cpp, `.dds`/`.rcl` ⇒ rmw_cyclonedds_cpp).
    /// It is authoritative for that decision — do NOT re-infer the transport
    /// from `zenohRouterLocator`, which is nil for a locator-less (multicast /
    /// peer-to-peer) zenoh session and would then mis-select the rmw.
    func createContext(
        domainId: Int32, transportType: TransportType, unicastPeerAddresses: [String],
        networkInterface: String?, zenohRouterLocator: String?) throws
    func destroyContext()

    func createNode(name: String, namespace: String) throws -> any RclNodeHandle
    func destroyNode(_ node: any RclNodeHandle)

    func createPublisher(
        node: any RclNodeHandle,
        typeName: String,
        typeHash: String?,
        topic: String,
        qos: TransportQoS
    ) throws -> any RclPublisherHandle

    /// Publish pre-serialized CDR bytes (XCDR1 incl. the 4-byte encapsulation header).
    func publishSerialized(_ publisher: any RclPublisherHandle, data: Data) throws

    /// Number of subscriptions matched to `publisher`, or `nil` when unknown.
    func publisherMatchedCount(_ publisher: any RclPublisherHandle) -> Int?

    /// Create a subscription whose receive thread invokes `handler` once per
    /// taken message with the raw CDR bytes (XCDR1 incl. the 4-byte
    /// encapsulation header) and the rmw source timestamp in nanoseconds
    /// (0 when the middleware reports none).
    func createSubscription(
        node: any RclNodeHandle,
        typeName: String,
        typeHash: String?,
        topic: String,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any RclSubscriptionHandle

    /// Destroy a subscription. Blocks until any in-flight handler invocation completes.
    func destroySubscription(_ subscription: any RclSubscriptionHandle)

    /// Create a service server whose wait thread invokes `onRequest` once per
    /// taken request with the raw request CDR bytes (XCDR1 incl. the 4-byte
    /// encapsulation header) and the opaque 24-byte request-id blob to echo
    /// back via `sendResponse(_:requestId:data:)`. `srvTypeName` is the
    /// canonical ROS service type name (e.g. `example_interfaces/srv/AddTwoInts`).
    func createServiceServer(
        node: any RclNodeHandle,
        srvTypeName: String,
        serviceName: String,
        qos: TransportQoS,
        onRequest: @escaping @Sendable (Data, [UInt8]) -> Void
    ) throws -> any RclServiceHandle

    /// Send the response CDR bytes for a previously delivered 24-byte request
    /// id. Callable from any thread (the async handler's completion).
    func sendResponse(_ service: any RclServiceHandle, requestId: [UInt8], data: Data) throws

    /// Destroy a service server. Blocks until any in-flight onRequest invocation completes.
    func destroyServiceServer(_ service: any RclServiceHandle)

    /// Create a service client whose wait thread invokes `onResponse` once per
    /// taken response with rcl's sequence number (as returned by
    /// `sendRequest(_:data:)` for the matching request) and the raw response
    /// CDR bytes.
    func createServiceClient(
        node: any RclNodeHandle,
        srvTypeName: String,
        serviceName: String,
        qos: TransportQoS,
        onResponse: @escaping @Sendable (Int64, Data) -> Void
    ) throws -> any RclClientHandle

    /// Send pre-serialized request CDR bytes; returns rcl's sequence number —
    /// the correlation key `onResponse` echoes back.
    func sendRequest(_ client: any RclClientHandle, data: Data) throws -> Int64

    /// Whether a matching service server is currently available.
    func serverAvailable(_ client: any RclClientHandle) -> Bool

    /// Destroy a service client. Blocks until any in-flight onResponse invocation completes.
    func destroyServiceClient(_ client: any RclClientHandle)

    // MARK: Actions

    /// Create an action server whose wait thread invokes the callback bag
    /// once per taken goal / cancel / result request. `actionTypeName` is the
    /// canonical ROS action type name (e.g. `example_interfaces/action/Fibonacci`).
    func createActionServer(
        node: any RclNodeHandle,
        actionTypeName: String,
        actionName: String,
        qos: TransportQoS,
        callbacks: RclActionServerCallbacks
    ) throws -> any RclActionServerHandle

    /// Send the SendGoal response CDR for a previously delivered 24-byte
    /// request id. Callable from any thread.
    func sendGoalResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws

    /// Send the CancelGoal response CDR. Callable from any thread.
    func sendCancelResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws

    /// Send the GetResult response CDR. Callable from any thread.
    func sendResultResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws

    /// Publish one FeedbackMessage frame (goal_id + feedback, CDR-encapsulated).
    func publishActionFeedback(_ server: any RclActionServerHandle, data: Data) throws

    /// Publish the goal status array snapshot from rcl_action's server-side
    /// goal tracking (kept in sync via `acceptGoal` / `updateGoalState`).
    func publishActionStatus(_ server: any RclActionServerHandle) throws

    /// Register an accepted goal with rcl_action's server-side goal tracking.
    /// Must precede an accepted SendGoal response. Idempotent per goal id.
    func acceptGoal(
        _ server: any RclActionServerHandle, goalId: [UInt8], stampSec: Int32,
        stampNanosec: UInt32
    ) throws

    /// Drive the rcl_action goal state machine for a tracked goal.
    func updateGoalState(_ server: any RclActionServerHandle, goalId: [UInt8], event: RclGoalEvent)
        throws

    /// Notify rcl_action that tracked goals reached a terminal state (starts
    /// the result-timeout expiry clock).
    func notifyGoalDone(_ server: any RclActionServerHandle) throws

    /// Destroy an action server. Blocks until any in-flight callback completes.
    func destroyActionServer(_ server: any RclActionServerHandle)

    /// Create an action client whose wait thread invokes the callback bag
    /// once per taken response / feedback / status message.
    func createActionClient(
        node: any RclNodeHandle,
        actionTypeName: String,
        actionName: String,
        qos: TransportQoS,
        callbacks: RclActionClientCallbacks
    ) throws -> any RclActionClientHandle

    /// Send pre-serialized SendGoal request CDR; returns rcl's sequence
    /// number — the correlation key `onGoalResponse` echoes back.
    func sendGoalRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64

    /// Send pre-serialized CancelGoal request CDR; correlates with `onCancelResponse`.
    func sendCancelRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64

    /// Send pre-serialized GetResult request CDR; correlates with `onResultResponse`.
    func sendResultRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64

    /// Whether a matching action server is currently available.
    func actionServerAvailable(_ client: any RclActionClientHandle) -> Bool

    /// Destroy an action client. Blocks until any in-flight callback completes.
    func destroyActionClient(_ client: any RclActionClientHandle)

    // MARK: Graph

    /// Every publisher in `node`'s view of the ROS graph, read from rmw's local
    /// graph cache (`rcl_get_topic_names_and_types`, then
    /// `rcl_get_publishers_info_by_topic` per name). Not thread-safe for one
    /// node: the caller serializes calls and keeps `node` alive during one.
    func graphPublishers(node: any RclNodeHandle) throws -> [RclGraphPublisherRecord]
}

extension RclClientProtocol {
    /// Default: unknown.
    package func publisherMatchedCount(_ publisher: any RclPublisherHandle) -> Int? { nil }

    /// Default: the client has no graph support.
    package func graphPublishers(node: any RclNodeHandle) throws -> [RclGraphPublisherRecord] {
        throw TransportError.unsupportedFeature("topic graph")
    }
}
