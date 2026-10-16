// ZenohWireCodec+Graph.swift
// Reading the publishers of the ROS graph from rmw_zenoh liveliness tokens.

import Foundation

/// One publisher announced by an `MP` liveliness token, as ``ZenohWireCodec/parsePublisherToken(_:)``
/// reads it.
package struct ZenohPublisherTokenInfo: Sendable, Equatable {
    /// The absolute topic name, for example `/kachaka/mapping/map`.
    package let topicName: String
    /// The ROS type name, for example `nav_msgs/msg/OccupancyGrid`.
    package let typeName: String
    /// `.reliable` only for an empty or `1` reliability field.
    package let reliability: QoSPolicy.Reliability
    /// `.transientLocal` only for a `1` durability field.
    package let durability: QoSPolicy.Durability
    /// The name of the node that owns the publisher.
    package let nodeName: String
    /// The absolute namespace of that node, `/` for the root namespace.
    package let nodeNamespace: String

    package init(
        topicName: String,
        typeName: String,
        reliability: QoSPolicy.Reliability,
        durability: QoSPolicy.Durability,
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

extension ZenohWireCodec {
    /// The key expression a liveliness query uses to find every publisher (`MP` token)
    /// of the domain, on any session, node, topic, type, hash and QoS.
    package func makePublisherLivelinessQuery(domainId: Int) -> String {
        "@ros2_lv/\(domainId)/*/*/*/MP/**"
    }

    /// Read a publisher's liveliness token, the layout ``makeEntityLivelinessToken(entityKind:domainId:sessionId:nodeId:entityId:nodeNamespace:nodeName:name:ddsTypeName:typeHash:qos:)``
    /// writes and rmw_zenoh_cpp declares:
    ///
    /// `@ros2_lv/<domain>/<zid>/<nid>/<eid>/MP/<enclave>/<ns>/<node>/<topic>/<dds_type>[/<hash>]/<qos>`
    ///
    /// Parsing is positional. The namespace (index 7) and the topic (index 9) are
    /// demangled (`%` becomes `/`), the node name is index 8, and the type (index 10)
    /// goes through ``TypeNameConverter/toROSTypeName(_:)``. Index 11 is the type hash
    /// when it starts with `RIHS01_` or is `TypeHashNotSupported` (Humble), and the QoS
    /// is index 12; otherwise index 11 is the QoS (the hashless form of Jazzy and
    /// later). Components after the QoS are ignored.
    ///
    /// The QoS is `reliability:durability:history,depth:deadline:lifespan:liveliness`,
    /// where a field equal to rmw_zenoh's default is empty. An empty or `1`
    /// reliability is reliable and anything else best effort; a `1` durability is
    /// transient-local and anything else volatile, so a value this parser does not
    /// know never reports more than the publisher offers.
    ///
    /// Returns `nil` for a token that is not `MP`, has fewer than 12 components, or
    /// whose QoS component does not split into those six `:` fields.
    package static func parsePublisherToken(_ token: String) -> ZenohPublisherTokenInfo? {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 12, parts[0] == "@ros2_lv", parts[5] == "MP" else { return nil }
        let qosIndex = isTypeHashComponent(parts[11]) ? 12 : 11
        guard qosIndex < parts.count, let qos = parseTokenQoS(parts[qosIndex]) else { return nil }
        let nodeName = parts[8]
        let topic = demangle(parts[9])
        guard !nodeName.isEmpty, topic != "/", !parts[10].isEmpty else { return nil }
        return ZenohPublisherTokenInfo(
            topicName: topic,
            typeName: TypeNameConverter.toROSTypeName(parts[10]),
            reliability: qos.reliability,
            durability: qos.durability,
            nodeName: nodeName,
            nodeNamespace: demangle(parts[7])
        )
    }

    /// Whether a token component is a type hash: `RIHS01_…`, or Humble's placeholder.
    private static func isTypeHashComponent(_ component: String) -> Bool {
        component.hasPrefix("RIHS01_") || component == ROS2Distro.humble.typeHashPlaceholder
    }

    /// The reliability and durability of a token's QoS component, or `nil` when it is
    /// not `reliability:durability:history,depth:deadline:lifespan:liveliness`.
    private static func parseTokenQoS(
        _ component: String
    ) -> (reliability: QoSPolicy.Reliability, durability: QoSPolicy.Durability)? {
        let fields = component.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 6, fields[2].contains(",") else { return nil }
        let reliability: QoSPolicy.Reliability =
            fields[0].isEmpty || fields[0] == "1" ? .reliable : .bestEffort
        let durability: QoSPolicy.Durability = fields[1] == "1" ? .transientLocal : .volatile
        return (reliability, durability)
    }

    /// rmw_zenoh_cpp's `demangle_name`, normalized to an absolute name without empty
    /// segments: `%` becomes `/`, `%` alone is the root `/`.
    private static func demangle(_ mangled: String) -> String {
        "/" + mangled.split(separator: "%").joined(separator: "/")
    }
}
