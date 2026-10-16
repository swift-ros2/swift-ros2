// NodeScopedSession.swift
// Node-aware entity creation seam.

import Foundation

/// Entity creation bound to a specific ROS 2 node. A separate `package`
/// protocol: it does not alter the `TransportSession` surface.
/// `RclTransportSession`, `ZenohTransportSession` and `DDSTransportSession`
/// conform.
///
/// `ROS2Node` downcasts its `TransportSession` to `NodeScopedSession`. When the
/// cast succeeds it passes the owning node's `name` / `namespace` so the entity
/// is bound to the right node; when it fails it falls back to the plain
/// `TransportSession` create methods. The rcl backend creates the entity on
/// that rcl node; the wire Zenoh session announces every entity under the node;
/// the wire DDS session lists the entity's readers and writers under the node on
/// `ros_discovery_info`.
package protocol NodeScopedSession: AnyObject, Sendable {
    /// Create a publisher bound to a specific ROS 2 node.
    ///
    /// `nodeName` / `nodeNamespace` identify the owning ROS 2 node. Backends
    /// that model real nodes (the rcl backend) bind the entity to that node;
    /// passing `nil` falls back to the session's single-node behaviour.
    func createPublisher(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportPublisher

    /// Create a subscriber bound to a specific ROS 2 node.
    ///
    /// `nodeName` / `nodeNamespace` carry the owning-node identity — see
    /// ``createPublisher(topic:typeName:typeHash:qos:nodeName:nodeNamespace:)``.
    func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber

    /// Create a Service Server bound to a specific ROS 2 node.
    ///
    /// `serviceTypeName` is the ROS-format service type name (e.g.
    /// `std_srvs/srv/Trigger`). `nodeName` / `nodeNamespace` carry the
    /// owning-node identity.
    func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService

    /// Create a Service Client bound to a specific ROS 2 node.
    ///
    /// `serviceTypeName` is the ROS-format service type name (e.g.
    /// `std_srvs/srv/Trigger`). `nodeName` / `nodeNamespace` carry the
    /// owning-node identity.
    func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportClient

    /// Create a Service Server bound to a specific ROS 2 node, keyed by the
    /// service-level type hash.
    ///
    /// `serviceTypeHash` is the hash of the service type itself
    /// (`ROS2ServiceTypeInfo.serviceTypeHash`), which rmw_zenoh_cpp keys services
    /// with. Backends that do not need it ignore it; the default implementation
    /// forwards to ``createServiceServer(name:serviceTypeName:requestTypeHash:responseTypeHash:qos:nodeName:nodeNamespace:handler:)``.
    func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        serviceTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService

    /// Create a Service Client bound to a specific ROS 2 node, keyed by the
    /// service-level type hash. See
    /// ``createServiceServer(name:serviceTypeName:requestTypeHash:responseTypeHash:serviceTypeHash:qos:nodeName:nodeNamespace:handler:)``.
    func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        serviceTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportClient

    /// Create an Action Server bound to a specific ROS 2 node.
    ///
    /// `actionTypeName` is the ROS-format action type (e.g.
    /// `example_interfaces/action/Fibonacci`). `nodeName` / `nodeNamespace`
    /// carry the owning-node identity.
    func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer

    /// Create an Action Client bound to a specific ROS 2 node.
    ///
    /// `nodeName` / `nodeNamespace` carry the owning-node identity.
    func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportActionClient
}

extension NodeScopedSession {
    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        serviceTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        try createServiceServer(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, qos: qos, nodeName: nodeName, nodeNamespace: nodeNamespace,
            handler: handler)
    }

    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        serviceTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportClient {
        try createServiceClient(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, qos: qos, nodeName: nodeName, nodeNamespace: nodeNamespace)
    }
}
