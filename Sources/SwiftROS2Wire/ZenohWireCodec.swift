// ZenohWireCodec.swift
// Wire format codec for rmw_zenoh compatibility

import Foundation

/// Wire format codec for rmw_zenoh
///
/// Generates key expressions, liveliness tokens, and 33-byte attachments
/// compatible with rmw_zenoh_cpp. Handles both legacy (Humble) and modern
/// (Jazzy/Kilted/Lyrical/Rolling) wire formats.
public struct ZenohWireCodec: Sendable {
    public let distro: ROS2Distro

    public init(distro: ROS2Distro) {
        self.distro = distro
    }

    // MARK: - Key Expression

    /// Generate the key expression of a topic
    ///
    /// Format: `<domain>/<namespace>/<topic>/<dds_type_name>/<type_hash>`
    ///
    /// The same key ``makeServiceKeyExpr(domainId:namespace:serviceName:serviceTypeName:serviceTypeHash:)``
    /// builds for a service: on Humble the trailing segment is `TypeHashNotSupported`;
    /// on Jazzy and later it is the hash, and it is omitted when `typeHash` is `nil`.
    /// A global topic (e.g. `/tf_static`, an empty or `/` namespace) has no empty
    /// segment: Zenoh rejects `domain//topic`.
    public func makeKeyExpr(
        domainId: Int,
        namespace: String,
        topic: String,
        typeName: String,
        typeHash: String?
    ) -> String {
        makeEntityKeyExpr(
            domainId: domainId,
            name: Self.joinName(namespace: namespace, leaf: topic),
            ddsTypeName: TypeNameConverter.toDDSTypeName(typeName),
            typeHash: typeHash
        )
    }

    /// Generate the Zenoh service key expression
    ///
    /// Format: `<domain>/<namespace>/<service_name>/<dds_service_type_name>/<service_type_hash>`
    ///
    /// This is the key rmw_zenoh_cpp declares its service queryables on and sends its
    /// client queries to:
    /// - The DDS service type name uses the `<pkg>::srv::dds_::<Type>_` form (the
    ///   response type name without `Response_`), for example
    ///   `std_srvs::srv::dds_::Trigger_`.
    /// - `serviceTypeHash` is the hash of the service type itself, not of its
    ///   request or response.
    /// - On Humble, the trailing segment is `TypeHashNotSupported`.
    /// - On Jazzy+ with no hash, the trailing segment is omitted (matching Pub/Sub).
    /// - A leading slash on `serviceName` is stripped so callers can pass either
    ///   `/trigger` or `trigger` without producing a `//` segment.
    public func makeServiceKeyExpr(
        domainId: Int,
        namespace: String,
        serviceName: String,
        serviceTypeName: String,
        serviceTypeHash: String?
    ) -> String {
        makeEntityKeyExpr(
            domainId: domainId,
            name: Self.joinName(namespace: namespace, leaf: serviceName),
            ddsTypeName: TypeNameConverter.toDDSServiceTypeName(serviceTypeName),
            typeHash: serviceTypeHash
        )
    }

    /// Generate the key expression of a topic or service from its fully qualified
    /// name and its DDS type name.
    ///
    /// Format: `<domain>/<name>/<dds_type_name>/<type_hash>`, the layout of
    /// rmw_zenoh_cpp's `TopicInfo::topic_keyexpr_`. Hash handling follows
    /// ``makeKeyExpr(domainId:namespace:topic:typeName:typeHash:)``. Empty name
    /// segments are dropped, so the key never contains `//`.
    package func makeEntityKeyExpr(
        domainId: Int,
        name: String,
        ddsTypeName: String,
        typeHash: String?
    ) -> String {
        let path = name.split(separator: "/").joined(separator: "/")
        let hashComponent = distro.formatTypeHash(typeHash)
        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return "\(domainId)/\(path)/\(ddsTypeName)"
        }
        return "\(domainId)/\(path)/\(ddsTypeName)/\(hashComponent)"
    }

    /// `namespace` + `/` + `leaf` with a leading slash, without duplicate slashes.
    static func joinName(namespace: String, leaf: String) -> String {
        let cleanNamespace = TypeNameConverter.stripLeadingSlash(namespace)
        let cleanLeaf = TypeNameConverter.stripLeadingSlash(leaf)
        return cleanNamespace.isEmpty ? "/\(cleanLeaf)" : "/\(cleanNamespace)/\(cleanLeaf)"
    }

    // MARK: - Action Role / Key Expression

    /// The five wire-level roles a ROS 2 action exposes: three services and two topics.
    ///
    /// Raw values map directly to the rmw_zenoh path segment after `_action/`.
    public enum ActionRole: String, Sendable, CaseIterable {
        case sendGoal = "send_goal"
        case cancelGoal = "cancel_goal"
        case getResult = "get_result"
        case feedback
        case status

        /// Whether the role is one of the three action services.
        public var isService: Bool {
            switch self {
            case .sendGoal, .cancelGoal, .getResult: return true
            case .feedback, .status: return false
            }
        }
    }

    /// Generate the Zenoh action key expression for one role.
    ///
    /// Format:
    /// `<domain>/<ns>/<action>/_action/<role>/<dds_role_type>/<role_type_hash>`
    ///
    /// `actionTypeName` is the ROS-format action type (e.g.
    /// `example_interfaces/action/Fibonacci`). The DDS role type is the one
    /// rmw_zenoh_cpp uses:
    /// - `send_goal` / `get_result`: the service types `<Action>_SendGoal_` /
    ///   `<Action>_GetResult_`, with the service type hash
    ///   (`ROS2ActionTypeInfo.sendGoalServiceTypeHash` / `getResultServiceTypeHash`).
    /// - `cancel_goal`: `action_msgs::srv::dds_::CancelGoal_` with its service type hash.
    /// - `feedback`: `<Action>_FeedbackMessage_` with the feedback message hash.
    /// - `status`: `action_msgs::msg::dds_::GoalStatusArray_` with its hash.
    ///
    /// Hash handling parallels ``makeKeyExpr`` / ``makeServiceKeyExpr`` —
    /// Humble emits `TypeHashNotSupported`; Jazzy+ omits the hash segment when
    /// `roleTypeHash` is `nil`.
    public func makeActionKeyExpr(
        role: ActionRole,
        domainId: Int,
        namespace: String,
        actionName: String,
        actionTypeName: String,
        roleTypeHash: String?
    ) -> String {
        makeEntityKeyExpr(
            domainId: domainId,
            name: Self.actionRoleName(namespace: namespace, actionName: actionName, role: role),
            ddsTypeName: ZenohWireCodec.ddsTypeName(forRole: role, actionTypeName: actionTypeName),
            typeHash: roleTypeHash
        )
    }

    /// The fully qualified name of one action role, for example
    /// `/ns/fibonacci/_action/send_goal`.
    package static func actionRoleName(namespace: String, actionName: String, role: ActionRole) -> String {
        "\(joinName(namespace: namespace, leaf: actionName))/_action/\(role.rawValue)"
    }

    /// Resolve the DDS role type name rmw_zenoh_cpp uses in key expressions and
    /// liveliness tokens.
    ///
    /// `cancel_goal` and `status` use fixed `action_msgs` types; the other three
    /// roles use per-action synthesized types. The three services are named by
    /// their service type, not by their request type.
    package static func ddsTypeName(forRole role: ActionRole, actionTypeName: String) -> String {
        switch role {
        case .sendGoal:
            return TypeNameConverter.toDDSActionRoleTypeName(actionTypeName, role: "SendGoal", suffix: nil)
        case .getResult:
            return TypeNameConverter.toDDSActionRoleTypeName(actionTypeName, role: "GetResult", suffix: nil)
        case .feedback:
            return TypeNameConverter.toDDSActionRoleTypeName(actionTypeName, role: "FeedbackMessage", suffix: nil)
        case .cancelGoal:
            return TypeNameConverter.cancelGoalServiceDDSTypeName
        case .status:
            return TypeNameConverter.goalStatusArrayDDSTypeName
        }
    }

    /// The request type name swift-ros2 keyed an action service role on before it
    /// carried service type hashes; `nil` for the two topic roles.
    package static func legacyRequestDDSTypeName(forRole role: ActionRole, actionTypeName: String) -> String? {
        switch role {
        case .sendGoal:
            return TypeNameConverter.toDDSActionRoleTypeName(actionTypeName, role: "SendGoal", suffix: "Request")
        case .getResult:
            return TypeNameConverter.toDDSActionRoleTypeName(actionTypeName, role: "GetResult", suffix: "Request")
        case .cancelGoal:
            return TypeNameConverter.cancelGoalRequestDDSTypeName
        case .feedback, .status:
            return nil
        }
    }

    // MARK: - Entity Liveliness Token

    /// Liveliness-token entity kind for Service entities.
    ///
    /// Parallels rmw_zenoh_cpp's per-entity-kind tags (`MP` = message publisher,
    /// `MS` = message subscription, `SS` = service server, `SC` = service client).
    public enum ServiceEntityKind: String, Sendable {
        case serviceServer = "SS"
        case serviceClient = "SC"
    }

    /// Generate the liveliness token rmw_zenoh_cpp declares for an entity of a node.
    ///
    /// Format:
    /// `@ros2_lv/<domain>/<session>/<node_id>/<entity_id>/<kind>/%/<node_ns>/<node_name>/<name>/<dds_type>/<hash>/<qos>`
    ///
    /// - `entityKind` is `MP`, `MS`, `SS` or `SC`.
    /// - The enclave is empty (`%`); `nodeNamespace` and the fully qualified
    ///   topic or service `name` are mangled (`/` becomes `%`).
    /// - `ddsTypeName` is the DDS type name: the message type for a topic, the
    ///   service type (`<pkg>::srv::dds_::<Type>_`) for a service.
    /// - On Humble the hash segment is `TypeHashNotSupported`; on Jazzy+ it is
    ///   omitted when `typeHash` is `nil`, so the token never contains `//`.
    ///
    /// rmw_zenoh_cpp groups every entity token with the same session and node id
    /// into one node of the ROS graph.
    package func makeEntityLivelinessToken(
        entityKind: String,
        domainId: Int,
        sessionId: String,
        nodeId: String,
        entityId: String,
        nodeNamespace: String,
        nodeName: String,
        name: String,
        ddsTypeName: String,
        typeHash: String?,
        qos: QoSPolicy
    ) -> String {
        let mangledNamespace = Self.mangle(nodeNamespace.isEmpty ? "/" : nodeNamespace)
        let mangledName = Self.mangle(name.hasPrefix("/") ? name : "/\(name)")
        let hashComponent = distro.formatTypeHash(typeHash)
        let prefix =
            "@ros2_lv/\(domainId)/\(sessionId)/\(nodeId)/\(entityId)/\(entityKind)/%/\(mangledNamespace)/\(nodeName)/\(mangledName)/\(ddsTypeName)"
        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return "\(prefix)/\(qos.toKeyExpr())"
        }
        return "\(prefix)/\(hashComponent)/\(qos.toKeyExpr())"
    }

    /// Generate the liveliness token rmw_zenoh_cpp declares for a node (`NN`).
    ///
    /// Format: `@ros2_lv/<domain>/<session>/<node_id>/<node_id>/NN/%/<node_ns>/<node_name>`
    ///
    /// The node's own entity id is its node id. rmw_zenoh_cpp adds a node to its graph
    /// when it sees any token of the node, but removes it only when this token goes
    /// away, so a node without one stays in `ros2 node list` after it is destroyed.
    package func makeNodeLivelinessToken(
        domainId: Int,
        sessionId: String,
        nodeId: String,
        nodeNamespace: String,
        nodeName: String
    ) -> String {
        let mangledNamespace = Self.mangle(nodeNamespace.isEmpty ? "/" : nodeNamespace)
        return "@ros2_lv/\(domainId)/\(sessionId)/\(nodeId)/\(nodeId)/NN/%/\(mangledNamespace)/\(nodeName)"
    }

    /// The key expression a liveliness query uses to find the service servers
    /// (`SS` tokens) of a service on any node, whatever their hash and QoS.
    package func makeServiceServerLivelinessQuery(
        domainId: Int,
        name: String,
        ddsTypeName: String
    ) -> String {
        let mangledName = Self.mangle(name.hasPrefix("/") ? name : "/\(name)")
        return
            "@ros2_lv/\(domainId)/*/*/*/\(ServiceEntityKind.serviceServer.rawValue)/*/*/*/\(mangledName)/\(ddsTypeName)/**"
    }

    /// rmw_zenoh_cpp's `mangle_name`: every `/` becomes `%`.
    static func mangle(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "%")
    }

    // MARK: - Transient-Local History

    /// The key expression a late-joining transient-local subscription queries for the
    /// samples cached by the publishers of a topic.
    ///
    /// rmw_zenoh (Humble 0.1.x through Lyrical and Rolling) declares a TRANSIENT_LOCAL
    /// publisher as a zenoh-ext advanced publisher whose cache answers queries on
    /// `<key>/@adv/pub/<zid>/<eid>/...`; its advanced subscribers fetch the history
    /// with a query on `<key>/@adv/**`. The replies carry the topic key, the payload
    /// and the attachment of the cached samples.
    package func makeHistoryQueryKeyExpr(_ topicKeyExpr: String) -> String {
        "\(topicKeyExpr)/@adv/**"
    }

    /// The selector parameters of a history query: accept replies on any key (the
    /// replies carry the topic key, outside the queried key expression) and, when
    /// `maxSamples` is set, at most that many samples per publisher.
    package func makeHistoryQueryParameters(maxSamples: Int?) -> String {
        guard let maxSamples, maxSamples > 0 else { return "_anyke" }
        return "_anyke;_max=\(maxSamples)"
    }

    // MARK: - Buffer Endpoints (Lyrical and later)

    /// The liveliness-token component of a CPU-only buffer-aware subscription: a
    /// buffer-aware publisher only sends to subscriptions it has discovered, and sends
    /// to one whose `MS` token ends with this component on the CPU group key (see
    /// ``makeCPUBufferGroupKeyExpr(_:)``).
    package static let cpuBufferBackendsComponent = "backends:cpu:"

    /// The key expression of the CPU group channel for a topic key expression.
    ///
    /// From Lyrical, rmw_zenoh publishers of messages with an unbounded `uint8[]` field
    /// (directly or in a nested message; for example `sensor_msgs/msg/Image`,
    /// `CompressedImage`, `PointCloud2` and `std_msgs/msg/UInt8MultiArray`) send to
    /// CPU-only subscriptions on `<key>/_buf_cpu` instead of `<key>`. The payload and the
    /// attachment are the same as on the topic key: XCDR v1 and the 33-byte attachment.
    public func makeCPUBufferGroupKeyExpr(_ topicKeyExpr: String) -> String {
        "\(topicKeyExpr)/_buf_cpu"
    }

    // MARK: - Entity GID

    /// The GID rmw_zenoh_cpp gives the entity a liveliness token announces: the XXH3
    /// 128-bit hash of the token, its low 64 bits then its high 64 bits, each
    /// little-endian (`liveliness::Entity`). An rmw_zenoh_cpp publisher sends it in the
    /// attachment of every sample, and graph tools such as `ros2 topic info -v` show
    /// it, so an attachment carrying it matches the publisher's graph entry.
    package static func entityGid(livelinessToken: String) -> [UInt8] {
        let hash = XXH3.hash128(Array(livelinessToken.utf8))
        return withUnsafeBytes(of: hash.low64.littleEndian, Array.init)
            + withUnsafeBytes(of: hash.high64.littleEndian, Array.init)
    }

    // MARK: - Attachment

    /// Build 33-byte attachment for rmw_zenoh messages
    ///
    /// Layout (Zenoh ext::Serializer format):
    /// - Bytes 0-7: seq (Int64 LE)
    /// - Bytes 8-15: timestamp_ns (Int64 LE)
    /// - Byte 16: GID array length (LEB128, 0x10 for 16 bytes)
    /// - Bytes 17-32: publisher GID (16 raw bytes)
    public func buildAttachment(
        seq: Int64,
        tsNsec: Int64,
        gid: [UInt8]
    ) -> Data {
        AttachmentBuilder.build(seq: seq, tsNsec: tsNsec, gid: gid)
    }
}
