// TopicGraphSession.swift
// The seam the umbrella's topic graph reads publishers through.

import Foundation

/// One publisher of the ROS graph as a transport sees it.
///
/// The values follow the topic graph's rules: names in ROS form, a reliability or
/// durability the transport cannot read as RELIABLE or TRANSIENT_LOCAL reported as
/// `.bestEffort` or `.volatile`, and a publisher whose node is unknown kept with
/// ``unknownNodeName`` and ``unknownNodeNamespace``.
package struct GraphPublisherEndpoint: Sendable, Equatable, Hashable {
    /// The node name `ros2 topic info -v` shows for a publisher it cannot attribute.
    package static let unknownNodeName = "_NODE_NAME_UNKNOWN_"
    /// The node namespace `ros2 topic info -v` shows for a publisher it cannot attribute.
    package static let unknownNodeNamespace = "_NODE_NAMESPACE_UNKNOWN_"

    /// The absolute ROS topic name, for example `/kachaka/mapping/map`.
    package let topicName: String
    /// The ROS type name, for example `nav_msgs/msg/OccupancyGrid`.
    package let typeName: String
    package let reliability: TransportQoS.Reliability
    package let durability: TransportQoS.Durability
    package let nodeName: String
    /// The absolute namespace of the node, `/` for the root namespace.
    package let nodeNamespace: String

    package init(
        topicName: String,
        typeName: String,
        reliability: TransportQoS.Reliability,
        durability: TransportQoS.Durability,
        nodeName: String,
        nodeNamespace: String
    ) {
        self.topicName = topicName
        self.typeName = typeName
        self.reliability = reliability
        self.durability = durability
        self.nodeName = nodeName
        self.nodeNamespace = nodeNamespace
    }
}

/// A session that can list the publishers of its ROS domain. A separate `package`
/// protocol, like ``NodeScopedSession``: `ROS2Context.topicGraph()` downcasts its
/// session and reports the topic graph as unsupported when the cast fails.
///
/// The wire Zenoh, wire DDS and RCL sessions conform.
package protocol TopicGraphSession: TransportSession {
    /// Every publisher of the domain the session can see, including the session's own,
    /// in any order. Grouping and sorting are the caller's.
    ///
    /// - Throws: ``TransportError/notConnected`` when the session is closed or lost,
    ///   ``TransportError/sessionUnhealthy(_:)`` when the graph cannot be read right now.
    func publisherEndpoints() async throws -> [GraphPublisherEndpoint]
}
