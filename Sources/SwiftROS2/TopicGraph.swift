// TopicGraph.swift
// The published topics of a context's ROS domain.

import Foundation
import SwiftROS2Transport

/// The QoS and the owning node of one publisher in the ROS graph.
///
/// The values are what the transport could observe. A reliability it cannot read as
/// RELIABLE is reported as `.bestEffort`, and a durability it cannot read as
/// TRANSIENT_LOCAL (or a stronger DDS durability) as `.volatile`, so a subscriber QoS
/// derived from these values never asks for more than a publisher offers.
public struct EndpointQoS: Sendable, Equatable {
    /// The publisher's reliability.
    public let reliability: QoSProfile.Reliability
    /// The publisher's durability. `.transientLocal` means late joiners can get its
    /// cached samples.
    public let durability: QoSProfile.Durability
    /// The name of the node that owns the publisher, or `_NODE_NAME_UNKNOWN_` when the
    /// transport cannot attribute it (for example a DDS writer whose participant does not
    /// publish `ros_discovery_info`).
    public let nodeName: String
    /// The absolute namespace of that node (`/` for the root namespace), or
    /// `_NODE_NAMESPACE_UNKNOWN_` when the transport cannot attribute it.
    public let nodeNamespace: String

    /// Creates an endpoint description, for tests and for callers that build a graph
    /// themselves.
    public init(
        reliability: QoSProfile.Reliability,
        durability: QoSProfile.Durability,
        nodeName: String,
        nodeNamespace: String
    ) {
        self.reliability = reliability
        self.durability = durability
        self.nodeName = nodeName
        self.nodeNamespace = nodeNamespace
    }
}

/// One published topic of the ROS graph, with the publishers of one type.
public struct TopicInfo: Sendable, Equatable {
    /// The absolute topic name, for example `/kachaka/mapping/map`.
    public let name: String
    /// The ROS type name, for example `nav_msgs/msg/OccupancyGrid`. A topic published with
    /// two types appears as two `TopicInfo` values with the same `name`.
    public let typeName: String
    /// Every known publisher of `name` with type `typeName`, never empty. Sorted by node
    /// namespace, node name, reliability (reliable first) and durability (volatile first).
    public let publishers: [EndpointQoS]

    /// Creates a topic description, for tests and for callers that build a graph
    /// themselves.
    public init(name: String, typeName: String, publishers: [EndpointQoS]) {
        self.name = name
        self.typeName = typeName
        self.publishers = publishers
    }
}

extension ROS2Context {
    /// Returns a snapshot of every published topic in this context's ROS domain.
    ///
    /// The result lists each topic that has at least one known publisher, with one entry
    /// per topic name and type, sorted by name and then type. It includes hidden topics
    /// (`/<action>/_action/feedback`, `/<action>/_action/status`), this context's own
    /// publishers and those of other contexts in the process; drop your own by node name
    /// and namespace.
    ///
    /// How fresh the snapshot is depends on the transport. Wire Zenoh asks the router on
    /// every call and waits at most 1.5 s for the answer. Wire DDS and RCL read a local
    /// discovery cache, in which a remote publisher that went away without saying so stays
    /// listed until its participant's lease expires.
    ///
    /// Discovery on wire DDS and RCL is asynchronous. For the first seconds after the
    /// context opens, the result can miss remote publishers, and a listed publisher can
    /// carry `_NODE_NAME_UNKNOWN_` until its node's `ros_discovery_info` record arrives.
    /// Poll; do not read an early empty or partial result as "nothing is published".
    ///
    /// The call does not observe task cancellation: on wire Zenoh it returns or throws
    /// within the 1.5 s wait, and on wire DDS and RCL the cache read is short. The DDS and
    /// RCL reads run on a serial dispatch queue owned by the session, never on the Swift
    /// concurrency cooperative pool.
    ///
    /// - Throws: ``TransportError/notConnected`` when the context is shut down, or when
    ///   the wire Zenoh session has lost its router; ``TransportError/sessionUnhealthy(_:)``
    ///   (recoverable) when the router does not answer in time, the query fails, or the
    ///   session's graph queries have stalled (then ``isConnected`` is also `false`);
    ///   ``TransportError/unsupportedFeature(_:)`` on a transport without graph support.
    public func topicGraph() async throws -> [TopicInfo] {
        guard let graph = session as? any TopicGraphSession else {
            throw TransportError.unsupportedFeature("topic graph")
        }
        return Self.topics(from: try await graph.publisherEndpoints())
    }

    /// Groups `endpoints` by topic name and type and sorts the groups and their
    /// publishers, the shape ``topicGraph()`` returns on every transport.
    static func topics(from endpoints: [GraphPublisherEndpoint]) -> [TopicInfo] {
        struct Key: Hashable {
            let name: String
            let typeName: String
        }
        let groups = Dictionary(grouping: endpoints) { Key(name: $0.topicName, typeName: $0.typeName) }
        return groups.map { key, members in
            TopicInfo(
                name: key.name, typeName: key.typeName,
                publishers: members.map(EndpointQoS.init(graphEndpoint:)).sorted(by: EndpointQoS.graphOrder))
        }
        .sorted { ($0.name, $0.typeName) < ($1.name, $1.typeName) }
    }
}

extension EndpointQoS {
    init(graphEndpoint endpoint: GraphPublisherEndpoint) {
        self.init(
            reliability: endpoint.reliability == .reliable ? .reliable : .bestEffort,
            durability: endpoint.durability == .transientLocal ? .transientLocal : .volatile,
            nodeName: endpoint.nodeName,
            nodeNamespace: endpoint.nodeNamespace)
    }

    /// Node namespace, node name, then reliable before best effort, then volatile before
    /// transient-local.
    static func graphOrder(_ lhs: EndpointQoS, _ rhs: EndpointQoS) -> Bool {
        func rank(_ qos: EndpointQoS) -> (Int, Int) {
            (qos.reliability == .reliable ? 0 : 1, qos.durability == .volatile ? 0 : 1)
        }
        let (lr, ld) = rank(lhs)
        let (rr, rd) = rank(rhs)
        return (lhs.nodeNamespace, lhs.nodeName, lr, ld) < (rhs.nodeNamespace, rhs.nodeName, rr, rd)
    }
}
