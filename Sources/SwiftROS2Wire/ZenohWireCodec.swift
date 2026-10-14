// ZenohWireCodec.swift
// Wire format codec for rmw_zenoh compatibility

import Foundation

/// Wire format codec for rmw_zenoh
///
/// Generates key expressions, liveliness tokens, and 33-byte attachments
/// compatible with rmw_zenoh_cpp. Handles both legacy (Humble) and modern
/// (Jazzy/Kilted/Lyrical/Rolling) wire formats.
public struct ZenohWireCodec: WireCodec {
    public let distro: ROS2Distro

    public init(distro: ROS2Distro) {
        self.distro = distro
    }

    // MARK: - Key Expression

    /// Generate key expression for rmw_zenoh
    ///
    /// Format: `<domain>/<namespace>/<topic>/<dds_type_name>/<type_hash>`
    public func makeKeyExpr(
        domainId: Int,
        namespace: String,
        topic: String,
        typeName: String,
        typeHash: String?
    ) -> String {
        let cleanNamespace = TypeNameConverter.stripLeadingSlash(namespace)
        let ddsTypeName = TypeNameConverter.toDDSTypeName(typeName)
        let hashComponent = distro.formatTypeHash(typeHash)
        // Global topics (e.g. /tf_static) are published with an empty namespace;
        // avoid emitting `domain//topic` which Zenoh rejects as invalid.
        let topicPath = cleanNamespace.isEmpty ? topic : "\(cleanNamespace)/\(topic)"

        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return "\(domainId)/\(topicPath)/\(ddsTypeName)"
        } else {
            return "\(domainId)/\(topicPath)/\(ddsTypeName)/\(hashComponent)"
        }
    }

    /// Generate the Zenoh service key expression
    ///
    /// Format: `<domain>/<namespace>/<service_name>/<dds_request_type_name>/<request_type_hash>`
    ///
    /// - The DDS request type name uses `<pkg>::srv::dds_::<Type>_Request_` form.
    /// - On Humble, the trailing segment is `TypeHashNotSupported`.
    /// - On Jazzy+ with no hash, the trailing segment is omitted (matching Pub/Sub).
    /// - A leading slash on `serviceName` is stripped so callers can pass either
    ///   `/trigger` or `trigger` without producing a `//` segment.
    public func makeServiceKeyExpr(
        domainId: Int,
        namespace: String,
        serviceName: String,
        serviceTypeName: String,
        requestTypeHash: String?
    ) -> String {
        let cleanNamespace = TypeNameConverter.stripLeadingSlash(namespace)
        let cleanServiceName = TypeNameConverter.stripLeadingSlash(serviceName)
        let ddsRequestTypeName = TypeNameConverter.toDDSServiceRequestTypeName(serviceTypeName)
        let hashComponent = distro.formatTypeHash(requestTypeHash)
        let svcPath = cleanNamespace.isEmpty ? cleanServiceName : "\(cleanNamespace)/\(cleanServiceName)"

        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return "\(domainId)/\(svcPath)/\(ddsRequestTypeName)"
        } else {
            return "\(domainId)/\(svcPath)/\(ddsRequestTypeName)/\(hashComponent)"
        }
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
    }

    /// Generate the Zenoh action key expression for one role.
    ///
    /// Format:
    /// `<domain>/<ns>/<action>/_action/<role>/<dds_role_type>/<role_type_hash>`
    ///
    /// `actionTypeName` is the ROS-format action type (e.g.
    /// `example_interfaces/action/Fibonacci`). `cancel_goal` and `status` use
    /// fixed types from `action_msgs` regardless of the action — this method
    /// substitutes them automatically.
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
        let cleanNS = TypeNameConverter.stripLeadingSlash(namespace)
        let cleanAction = TypeNameConverter.stripLeadingSlash(actionName)
        let actionPath = cleanNS.isEmpty ? cleanAction : "\(cleanNS)/\(cleanAction)"
        let ddsRoleTypeName = ZenohWireCodec.ddsTypeName(forRole: role, actionTypeName: actionTypeName)
        let hashComponent = distro.formatTypeHash(roleTypeHash)
        let prefix = "\(domainId)/\(actionPath)/_action/\(role.rawValue)/\(ddsRoleTypeName)"

        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return prefix
        } else {
            return "\(prefix)/\(hashComponent)"
        }
    }

    /// Resolve the DDS role type name used in the Zenoh key expression.
    ///
    /// `cancel_goal` and `status` use fixed `action_msgs` types; the other three
    /// roles use per-action synthesized types.
    static func ddsTypeName(forRole role: ActionRole, actionTypeName: String) -> String {
        switch role {
        case .sendGoal:
            return TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "SendGoal", suffix: "Request")
        case .getResult:
            return TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "GetResult", suffix: "Request")
        case .feedback:
            return TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "FeedbackMessage", suffix: nil)
        case .cancelGoal:
            return TypeNameConverter.cancelGoalRequestDDSTypeName
        case .status:
            return TypeNameConverter.goalStatusArrayDDSTypeName
        }
    }

    // MARK: - Service Liveliness Token

    /// Liveliness-token entity kind for Service entities.
    ///
    /// Parallels rmw_zenoh_cpp's per-entity-kind tags (`MP` = message publisher,
    /// `SS` = service server, `SC` = service client). Pub/Sub is hard-coded to
    /// `MP` in `makeLivelinessToken`; services pass one of these values to
    /// ``makeServiceLivelinessToken(entityKind:domainId:sessionId:nodeId:entityId:namespace:nodeName:serviceName:serviceTypeName:requestTypeHash:qos:)``.
    public enum ServiceEntityKind: String, Sendable {
        case serviceServer = "SS"
        case serviceClient = "SC"
    }

    /// Generate a Service-shaped liveliness token (`SS` / `SC`).
    ///
    /// Format: `@ros2_lv/<domain>/<session>/<node>/<entity>/<SS|SC>/%/%/<node_name>/<mangled_service_path>/<dds_request_type>/<request_hash>/<qos>`
    ///
    /// - On Humble, the hash segment is `TypeHashNotSupported`.
    /// - On Jazzy+ with no hash, the hash segment is omitted (parallel to
    ///   ``makeServiceKeyExpr(domainId:namespace:serviceName:serviceTypeName:requestTypeHash:)``)
    ///   so the token never contains a `//` segment.
    /// - `serviceName` may carry a leading slash; ``TypeNameConverter/mangleTopicPath(namespace:topic:)``
    ///   normalizes it.
    package func makeServiceLivelinessToken(
        entityKind: ServiceEntityKind,
        domainId: Int,
        sessionId: String,
        nodeId: String,
        entityId: String,
        namespace: String,
        nodeName: String,
        serviceName: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        qos: QoSPolicy
    ) -> String {
        let cleanServiceName = TypeNameConverter.stripLeadingSlash(serviceName)
        let mangled = TypeNameConverter.mangleTopicPath(namespace: namespace, topic: cleanServiceName)
        let ddsRequestTypeName = TypeNameConverter.toDDSServiceRequestTypeName(serviceTypeName)
        let hashComponent = distro.formatTypeHash(requestTypeHash)
        let qosKeyExpr = qos.toKeyExpr()
        let prefix =
            "@ros2_lv/\(domainId)/\(sessionId)/\(nodeId)/\(entityId)/\(entityKind.rawValue)/%/%/\(nodeName)/\(mangled)/\(ddsRequestTypeName)"

        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return "\(prefix)/\(qosKeyExpr)"
        } else {
            return "\(prefix)/\(hashComponent)/\(qosKeyExpr)"
        }
    }

    // MARK: - Action Liveliness Token

    /// Liveliness-token entity-kind tag for Action entities.
    ///
    /// Parallels ``ServiceEntityKind`` (`SS` / `SC`). The action server side
    /// announces `SA` (server-action) and the client side announces `CA`
    /// (client-action) so discovery can distinguish action endpoints from
    /// regular service endpoints.
    public enum ActionEntityKind: String, Sendable {
        case actionServer = "SA"
        case actionClient = "CA"
    }

    /// Generate an Action-shaped liveliness token (`SA` / `CA`).
    ///
    /// Format:
    /// `@ros2_lv/<domain>/<session>/<node>/<entity>/<SA|CA>/%/%/<node_name>/<mangled_action_path>/<dds_send_goal_request_type>/<role_type_hash>/<qos>`
    ///
    /// The discovery anchor is the `send_goal` request type (one announcement
    /// per action) so a peer that sees a single token knows the full action is
    /// available — the other four roles are guaranteed to be co-declared by
    /// the action server / client implementation in Phases 4–5.
    package func makeActionLivelinessToken(
        entityKind: ActionEntityKind,
        domainId: Int,
        sessionId: String,
        nodeId: String,
        entityId: String,
        namespace: String,
        nodeName: String,
        actionName: String,
        actionTypeName: String,
        roleTypeHash: String?,
        qos: QoSPolicy
    ) -> String {
        let cleanAction = TypeNameConverter.stripLeadingSlash(actionName)
        let mangled = TypeNameConverter.mangleTopicPath(namespace: namespace, topic: cleanAction)
        let ddsRoleTypeName = TypeNameConverter.toDDSActionRoleTypeName(
            actionTypeName, role: "SendGoal", suffix: "Request")
        let hashComponent = distro.formatTypeHash(roleTypeHash)
        let qosKeyExpr = qos.toKeyExpr()
        let prefix =
            "@ros2_lv/\(domainId)/\(sessionId)/\(nodeId)/\(entityId)/\(entityKind.rawValue)/%/%/\(nodeName)/\(mangled)/\(ddsRoleTypeName)"

        if !distro.alwaysIncludeTypeHashInKey && hashComponent.isEmpty {
            return "\(prefix)/\(qosKeyExpr)"
        } else {
            return "\(prefix)/\(hashComponent)/\(qosKeyExpr)"
        }
    }

    // MARK: - Liveliness Token

    /// Generate liveliness token for ROS 2 discovery
    ///
    /// Format: `@ros2_lv/<domain>/<session>/<node>/<entity>/MP/%/%/<node_name>/<topic>/<type>/<hash>/<qos>`
    package func makeLivelinessToken(
        domainId: Int,
        sessionId: String,
        nodeId: String,
        entityId: String,
        namespace: String,
        nodeName: String,
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: QoSPolicy
    ) -> String {
        makeTopicLivelinessToken(
            entityKind: "MP", domainId: domainId, sessionId: sessionId, nodeId: nodeId,
            entityId: entityId, namespace: namespace, nodeName: nodeName, topic: topic,
            typeName: typeName, typeHash: typeHash, qos: qos)
    }

    /// Generate a subscription liveliness token (`MS`) for ROS 2 discovery.
    ///
    /// Format: `@ros2_lv/<domain>/<session>/<node>/<entity>/MS/%/%/<node_name>/<topic>/<type>/<hash>/<qos>[/backends:cpu:]`
    ///
    /// With `cpuBufferBackend`, the token ends with the `backends:cpu:` component a
    /// CPU-only buffer-aware rmw_zenoh subscription (Lyrical and later) announces. A
    /// buffer-aware publisher only sends to subscriptions it has discovered, and sends
    /// to such a subscription on the CPU group key (see ``makeCPUBufferGroupKeyExpr(_:)``).
    package func makeSubscriptionLivelinessToken(
        domainId: Int,
        sessionId: String,
        nodeId: String,
        entityId: String,
        namespace: String,
        nodeName: String,
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: QoSPolicy,
        cpuBufferBackend: Bool
    ) -> String {
        let token = makeTopicLivelinessToken(
            entityKind: "MS", domainId: domainId, sessionId: sessionId, nodeId: nodeId,
            entityId: entityId, namespace: namespace, nodeName: nodeName, topic: topic,
            typeName: typeName, typeHash: typeHash, qos: qos)
        return cpuBufferBackend ? "\(token)/\(ZenohWireCodec.cpuBufferBackendsComponent)" : token
    }

    private func makeTopicLivelinessToken(
        entityKind: String,
        domainId: Int,
        sessionId: String,
        nodeId: String,
        entityId: String,
        namespace: String,
        nodeName: String,
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: QoSPolicy
    ) -> String {
        let mangledTopic = TypeNameConverter.mangleTopicPath(namespace: namespace, topic: topic)
        let ddsTypeName = TypeNameConverter.toDDSTypeName(typeName)
        let hashComponent = distro.formatTypeHash(typeHash)
        let qosKeyExpr = qos.toKeyExpr()

        return
            "@ros2_lv/\(domainId)/\(sessionId)/\(nodeId)/\(entityId)/\(entityKind)/%/%/\(nodeName)/\(mangledTopic)/\(ddsTypeName)/\(hashComponent)/\(qosKeyExpr)"
    }

    // MARK: - Buffer Endpoints (Lyrical and later)

    /// The liveliness-token component of a CPU-only buffer-aware subscription.
    static let cpuBufferBackendsComponent = "backends:cpu:"

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
