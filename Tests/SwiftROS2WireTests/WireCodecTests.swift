// WireCodecTests.swift
// Tests for wire format codecs

import XCTest

@testable import SwiftROS2Wire

final class WireCodecTests: XCTestCase {

    // MARK: - Type Name Conversion

    func testDDSTypeNameConversion() {
        XCTAssertEqual(
            TypeNameConverter.toDDSTypeName("sensor_msgs/msg/Imu"),
            "sensor_msgs::msg::dds_::Imu_"
        )
        XCTAssertEqual(
            TypeNameConverter.toDDSTypeName("geometry_msgs/msg/Twist"),
            "geometry_msgs::msg::dds_::Twist_"
        )
        XCTAssertEqual(
            TypeNameConverter.toDDSTypeName("std_msgs/msg/String"),
            "std_msgs::msg::dds_::String_"
        )
    }

    /// A name without the `<pkg>/<kind>/<Type>` shape keeps its segments, `::`-joined,
    /// without the `dds_` segment.
    func testTypeNameWithoutThreeSegmentsIsJoinedAsIs() {
        XCTAssertEqual(TypeNameConverter.toDDSTypeName("Custom"), "Custom_")
        XCTAssertEqual(TypeNameConverter.toDDSTypeName("pkg/Custom"), "pkg::Custom_")
        XCTAssertEqual(TypeNameConverter.toDDSServiceRequestTypeName("pkg/Custom"), "pkg::Custom_Request_")
        XCTAssertEqual(TypeNameConverter.toDDSServiceResponseTypeName("Custom"), "Custom_Response_")
    }

    func testStripLeadingSlash() {
        XCTAssertEqual(TypeNameConverter.stripLeadingSlash("/ios"), "ios")
        XCTAssertEqual(TypeNameConverter.stripLeadingSlash("ios"), "ios")
        XCTAssertEqual(TypeNameConverter.stripLeadingSlash(""), "")
    }

    // MARK: - Zenoh Wire Codec

    func testJazzyKeyExpression() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeKeyExpr(
            domainId: 0,
            namespace: "ios",
            topic: "imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: "RIHS01_abc123"
        )
        XCTAssertEqual(key, "0/ios/imu/sensor_msgs::msg::dds_::Imu_/RIHS01_abc123")
    }

    func testHumbleKeyExpression() {
        let codec = ZenohWireCodec(distro: .humble)
        let key = codec.makeKeyExpr(
            domainId: 0,
            namespace: "ios",
            topic: "imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: nil
        )
        XCTAssertEqual(key, "0/ios/imu/sensor_msgs::msg::dds_::Imu_/TypeHashNotSupported")
    }

    func testJazzyKeyExpressionEmptyNamespace() {
        // Global topics like /tf_static are published with an empty namespace.
        // The key must NOT contain a double slash between the domain id and topic.
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeKeyExpr(
            domainId: 0,
            namespace: "",
            topic: "tf_static",
            typeName: "tf2_msgs/msg/TFMessage",
            typeHash: "RIHS01_abc123"
        )
        XCTAssertEqual(key, "0/tf_static/tf2_msgs::msg::dds_::TFMessage_/RIHS01_abc123")
    }

    func testJazzyKeyExpressionWithoutTypeHash() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeKeyExpr(
            domainId: 0,
            namespace: "ios",
            topic: "imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: nil
        )
        // Jazzy omits trailing segment when hash is empty
        XCTAssertEqual(key, "0/ios/imu/sensor_msgs::msg::dds_::Imu_")
    }

    /// A topic key follows the service key rule, empty segments included.
    func testKeyExpressionNeverContainsAnEmptySegment() {
        let codec = ZenohWireCodec(distro: .jazzy)
        for (namespace, topic) in [("/e2e_s3/", "/imu"), ("e2e_s3", "imu"), ("/e2e_s3", "imu/")] {
            XCTAssertEqual(
                codec.makeKeyExpr(
                    domainId: 0, namespace: namespace, topic: topic, typeName: "sensor_msgs/msg/Imu",
                    typeHash: "RIHS01_a"),
                "0/e2e_s3/imu/sensor_msgs::msg::dds_::Imu_/RIHS01_a", "\(namespace) + \(topic)")
        }
        XCTAssertEqual(
            codec.makeKeyExpr(
                domainId: 0, namespace: "/", topic: "/tf_static", typeName: "tf2_msgs/msg/TFMessage", typeHash: nil),
            "0/tf_static/tf2_msgs::msg::dds_::TFMessage_")
    }

    // MARK: - Liveliness token QoS

    /// The QoS field of a token as rmw_zenoh_cpp's `keyexpr_to_qos` reads it: an empty
    /// reliability, durability or history field means the rmw_zenoh default (reliable,
    /// volatile, keep-last); anything else is an `rmw_qos_*_policy_e` number.
    private struct RmwZenohQoS: Equatable {
        var reliability: String
        var durability: String
        var history: String
        var depth: String

        init(keyExpr: String) {
            let parts = keyExpr.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.count, 6, "QoS field needs six ':'-separated parts: \(keyExpr)")
            reliability = parts[0].isEmpty ? "reliable" : (parts[0] == "1" ? "reliable" : "best_effort")
            durability = parts[1].isEmpty ? "volatile" : (parts[1] == "1" ? "transient_local" : "volatile")
            let historyParts = parts[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            history = historyParts[0].isEmpty ? "keep_last" : (historyParts[0] == "2" ? "keep_all" : "keep_last")
            depth = historyParts[1]
        }
    }

    func testQoSKeyExprMatchesRmwZenohEncoding() {
        // Golden fields as `qos_to_keyexpr` writes them in rmw_zenoh_cpp (the same
        // function on Humble, Jazzy, Kilted and Lyrical). The first one is the reliable,
        // volatile, keep-last 10 field of a default `ros2 topic pub` publisher.
        let reliable = QoSPolicy(
            reliability: .reliable, durability: .volatile, historyPolicy: .keepLast, historyDepth: 10)
        XCTAssertEqual(reliable.toKeyExpr(), "::,10:,:,:,,")

        let bestEffort = QoSPolicy(
            reliability: .bestEffort, durability: .volatile, historyPolicy: .keepLast, historyDepth: 5)
        XCTAssertEqual(bestEffort.toKeyExpr(), "2::,5:,:,:,,")

        let latched = QoSPolicy(
            reliability: .reliable, durability: .transientLocal, historyPolicy: .keepLast, historyDepth: 1)
        XCTAssertEqual(latched.toKeyExpr(), ":1:,1:,:,:,,")

        let keepAll = QoSPolicy(
            reliability: .reliable, durability: .volatile, historyPolicy: .keepAll, historyDepth: 1000)
        XCTAssertEqual(keepAll.toKeyExpr(), "::2,1000:,:,:,,")
    }

    func testQoSKeyExprReadsBackAsTheSameQoSInRmwZenoh() {
        let bestEffort = RmwZenohQoS(keyExpr: QoSPolicy.sensorData.toKeyExpr())
        XCTAssertEqual(bestEffort.reliability, "best_effort")
        XCTAssertEqual(bestEffort.durability, "volatile")

        let reliable = RmwZenohQoS(keyExpr: QoSPolicy.reliableSensor.toKeyExpr())
        XCTAssertEqual(reliable.reliability, "reliable")

        let latched = RmwZenohQoS(keyExpr: QoSPolicy.latched.toKeyExpr())
        XCTAssertEqual(latched.reliability, "reliable")
        XCTAssertEqual(latched.durability, "transient_local")

        let keepAll = RmwZenohQoS(
            keyExpr: QoSPolicy(reliability: .reliable, historyPolicy: .keepAll, historyDepth: 7).toKeyExpr())
        XCTAssertEqual(keepAll.history, "keep_all")
        XCTAssertEqual(keepAll.depth, "7")
    }

    func testLivelinessTokenEncodesBestEffortOnEveryDistro() {
        for distro in [ROS2Distro.humble, .jazzy, .kilted, .lyrical] {
            let codec = ZenohWireCodec(distro: distro)
            func token(_ qos: QoSPolicy) -> String {
                codec.makeEntityLivelinessToken(
                    entityKind: "MP", domainId: 123, sessionId: "abc123", nodeId: "1", entityId: "2",
                    nodeNamespace: "/", nodeName: "talker", name: "/chatter",
                    ddsTypeName: "std_msgs::msg::dds_::String_", typeHash: "RIHS01_hash", qos: qos)
            }
            let bestEffort = token(QoSPolicy(reliability: .bestEffort, historyDepth: 10))
            XCTAssertTrue(
                bestEffort.hasPrefix("@ros2_lv/123/abc123/1/2/MP/%/%/talker/%chatter/std_msgs::msg::dds_::String_/"),
                "token prefix on \(distro)")
            XCTAssertTrue(bestEffort.hasSuffix("/2::,10:,:,:,,"), "best-effort token on \(distro): \(bestEffort)")

            let reliable = token(QoSPolicy(reliability: .reliable, historyDepth: 10))
            XCTAssertTrue(reliable.hasSuffix("/::,10:,:,:,,"), "reliable token on \(distro): \(reliable)")
        }
    }

    // MARK: - Attachment

    func testAttachmentSize() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let gid = [UInt8](repeating: 0x42, count: 16)
        let attachment = codec.buildAttachment(seq: 0, tsNsec: 1234567890, gid: gid)
        XCTAssertEqual(attachment.count, 33, "Attachment must be exactly 33 bytes")
    }

    func testAttachmentFormat() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let gid: [UInt8] = Array(0..<16)
        let attachment = codec.buildAttachment(seq: 42, tsNsec: 1_000_000_000, gid: gid)

        // Verify seq (bytes 0-7)
        let seq = attachment.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        XCTAssertEqual(Int64(littleEndian: seq), 42)

        // Verify timestamp (bytes 8-15)
        let ts = attachment.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
        XCTAssertEqual(Int64(littleEndian: ts), 1_000_000_000)

        // Verify LEB128 GID length (byte 16)
        XCTAssertEqual(attachment[16], 0x10)

        // Verify GID (bytes 17-32)
        for i in 0..<16 {
            XCTAssertEqual(attachment[17 + i], UInt8(i))
        }
    }

    func testAttachmentBoundaryValues() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let gid = [UInt8](repeating: 0xFF, count: 16)
        let attachment = codec.buildAttachment(seq: Int64.min, tsNsec: Int64.max, gid: gid)

        XCTAssertEqual(attachment.count, 33)

        let seq = attachment.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        XCTAssertEqual(Int64(littleEndian: seq), Int64.min)

        let ts = attachment.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
        XCTAssertEqual(Int64(littleEndian: ts), Int64.max)

        XCTAssertEqual(attachment[16], 0x10)
        for i in 0..<16 {
            XCTAssertEqual(attachment[17 + i], 0xFF)
        }
    }

    // MARK: - DDS Wire Codec

    func testDDSTopic() {
        let codec = DDSWireCodec()
        XCTAssertEqual(codec.ddsTopic(from: "/conduit/imu"), "rt/conduit/imu")
        XCTAssertEqual(codec.ddsTopic(from: "conduit/imu"), "rt/conduit/imu")
    }

    func testDDSUserData() {
        let codec = DDSWireCodec()
        XCTAssertEqual(codec.userDataString(typeHash: "RIHS01_abc"), "typehash=RIHS01_abc;")
        XCTAssertNil(codec.userDataString(typeHash: nil))
        XCTAssertNil(codec.userDataString(typeHash: ""))
    }

    // MARK: - ROS2Distro

    /// The wire facts SwiftROS2Wire adds to `ROS2Distro` (the enum's own schema facts are tested in
    /// swift-ros2-rosidl).
    func testDistroWireFacts() {
        for distro in ROS2Distro.allCases {
            let legacy = distro == .humble
            XCTAssertEqual(distro.wireGroup, legacy ? .legacy : .modern, "\(distro)")
            XCTAssertEqual(distro.alwaysIncludeTypeHashInKey, legacy, "\(distro)")
            XCTAssertEqual(distro.typeHashPlaceholder, "TypeHashNotSupported", "\(distro)")
            XCTAssertEqual(distro.formatTypeHash("RIHS01_abc"), legacy ? "TypeHashNotSupported" : "RIHS01_abc")
            XCTAssertEqual(distro.formatTypeHash(nil), legacy ? "TypeHashNotSupported" : "")
        }
        XCTAssertEqual(ROS2Distro.WireGroup.legacy.distros, [.humble])
        XCTAssertEqual(ROS2Distro.WireGroup.modern.distros, [.jazzy, .kilted, .lyrical, .rolling])
        XCTAssertEqual(ROS2Distro.WireGroup.legacy.rawValue, "Humble and earlier")
        XCTAssertEqual(ROS2Distro.WireGroup.modern.rawValue, "Iron and later")
    }

    /// Lyrical speaks the Jazzy wire: every key expression and liveliness token must match byte for byte.
    func testLyricalWireMatchesJazzy() {
        let jazzy = ZenohWireCodec(distro: .jazzy)
        let lyrical = ZenohWireCodec(distro: .lyrical)
        let qos = QoSPolicy(reliability: .bestEffort, durability: .volatile, historyPolicy: .keepLast, historyDepth: 10)
        for hash in ["RIHS01_abc123", nil] as [String?] {
            XCTAssertEqual(
                lyrical.makeKeyExpr(
                    domainId: 123, namespace: "conduit", topic: "imu", typeName: "sensor_msgs/msg/Imu",
                    typeHash: hash),
                jazzy.makeKeyExpr(
                    domainId: 123, namespace: "conduit", topic: "imu", typeName: "sensor_msgs/msg/Imu",
                    typeHash: hash))
            XCTAssertEqual(
                lyrical.makeServiceKeyExpr(
                    domainId: 123, namespace: "conduit", serviceName: "trigger",
                    serviceTypeName: "std_srvs/srv/Trigger", serviceTypeHash: hash),
                jazzy.makeServiceKeyExpr(
                    domainId: 123, namespace: "conduit", serviceName: "trigger",
                    serviceTypeName: "std_srvs/srv/Trigger", serviceTypeHash: hash))
            for role in ZenohWireCodec.ActionRole.allCases {
                XCTAssertEqual(
                    lyrical.makeActionKeyExpr(
                        role: role, domainId: 123, namespace: "conduit", actionName: "fibonacci",
                        actionTypeName: "example_interfaces/action/Fibonacci", roleTypeHash: hash),
                    jazzy.makeActionKeyExpr(
                        role: role, domainId: 123, namespace: "conduit", actionName: "fibonacci",
                        actionTypeName: "example_interfaces/action/Fibonacci", roleTypeHash: hash),
                    "action role \(role)")
            }
            for kind in ["MP", "MS", "SS", "SC"] {
                XCTAssertEqual(
                    lyrical.makeEntityLivelinessToken(
                        entityKind: kind, domainId: 123, sessionId: "abc123", nodeId: "1", entityId: "2",
                        nodeNamespace: "/conduit", nodeName: "imu_node", name: "/conduit/imu",
                        ddsTypeName: "sensor_msgs::msg::dds_::Imu_", typeHash: hash, qos: qos),
                    jazzy.makeEntityLivelinessToken(
                        entityKind: kind, domainId: 123, sessionId: "abc123", nodeId: "1", entityId: "2",
                        nodeNamespace: "/conduit", nodeName: "imu_node", name: "/conduit/imu",
                        ddsTypeName: "sensor_msgs::msg::dds_::Imu_", typeHash: hash, qos: qos),
                    "\(kind) token")
            }
            XCTAssertEqual(
                lyrical.makeNodeLivelinessToken(
                    domainId: 123, sessionId: "abc123", nodeId: "1", nodeNamespace: "/conduit", nodeName: "imu_node"),
                jazzy.makeNodeLivelinessToken(
                    domainId: 123, sessionId: "abc123", nodeId: "1", nodeNamespace: "/conduit", nodeName: "imu_node"))
        }
    }

    // MARK: - Buffer endpoints (Lyrical and later)

    private let pointCloudHash = "RIHS01_9198cabf7da3796ae6fe19c4cb3bdd3525492988c70522628af5daa124bae2b5"

    func testUsesZenohBufferEndpointsFromLyrical() {
        XCTAssertFalse(ROS2Distro.humble.usesZenohBufferEndpoints)
        XCTAssertFalse(ROS2Distro.jazzy.usesZenohBufferEndpoints)
        XCTAssertFalse(ROS2Distro.kilted.usesZenohBufferEndpoints)
        XCTAssertTrue(ROS2Distro.lyrical.usesZenohBufferEndpoints)
        XCTAssertTrue(ROS2Distro.rolling.usesZenohBufferEndpoints)
    }

    /// Golden value from a Lyrical rmw_zenoh_cpp 0.10.6 publisher of
    /// sensor_msgs/msg/PointCloud2 on /e2e/points (domain 123).
    func testCPUBufferGroupKeyExpr() {
        let codec = ZenohWireCodec(distro: .lyrical)
        let key = codec.makeKeyExpr(
            domainId: 123, namespace: "/e2e", topic: "points",
            typeName: "sensor_msgs/msg/PointCloud2", typeHash: pointCloudHash)
        XCTAssertEqual(
            codec.makeCPUBufferGroupKeyExpr(key),
            "123/e2e/points/sensor_msgs::msg::dds_::PointCloud2_/\(pointCloudHash)/_buf_cpu")
    }

    func testCPUBufferGroupKeyExprOnAGlobalTopic() {
        let codec = ZenohWireCodec(distro: .rolling)
        let key = codec.makeKeyExpr(
            domainId: 0, namespace: "/", topic: "image",
            typeName: "sensor_msgs/msg/Image", typeHash: "RIHS01_abc")
        XCTAssertEqual(
            codec.makeCPUBufferGroupKeyExpr(key), "0/image/sensor_msgs::msg::dds_::Image_/RIHS01_abc/_buf_cpu")
    }

    // MARK: - Liveliness tokens captured from rmw_zenoh_cpp

    // Tokens of an rclpy node `/e2e_s3/ref_node` (domain 123), read verbatim with a
    // `@ros2_lv/123/**` liveliness query. Lyrical (rmw_zenoh_cpp 0.10.6), Kilted (0.6.8)
    // and Jazzy (0.2.9) declared the same tokens apart from the session id; Humble
    // (0.1.9) writes `TypeHashNotSupported` in place of each hash.

    private struct CapturedEntity {
        let token: String
        let kind: String
        let entityId: String
        let name: String
        let ddsTypeName: String
        let typeHash: String
        let qos: QoSPolicy
    }

    private static let capturedNamespace = "/e2e_s3"
    private static let capturedNodeName = "ref_node"

    private static let stringHash = "RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18"
    private static let imuHash = "RIHS01_7d9a00ff131080897a5ec7e26e315954b8eae3353c3f995c55faf71574000b5b"
    private static let triggerHash = "RIHS01_eeff2cd6fa5ad9d27cdf4dec64818317839b62f212a91e6b5304b634b2062c5f"
    private static let lookupSendGoalHash = "RIHS01_4646ff5706c86b04d0a1098d329951a9731a7517e16702905de6073cc72c8530"
    private static let cancelGoalHash = "RIHS01_573d8b0a534451d7bc2ac8c5ffde8ac14b8593b7001175d0cd6516dcbeb8689a"
    private static let lookupGetResultHash = "RIHS01_3cd1715751899e3167b5aec3e4ac194f7da9e8493a77285f9f6a4c914f5e8b24"
    private static let lookupFeedbackHash = "RIHS01_10cb89922dcb103e95c185d43e8a5efa3d38db996f733151a2f3e2ac133f4839"
    private static let statusArrayHash = "RIHS01_6c1684b00f177d37438febe6e709fc4e2b0d4248dca4854946f9ed8b30cda83e"

    private static let reliable10 = QoSPolicy(reliability: .reliable, historyDepth: 10)
    private static let latched1 = QoSPolicy(reliability: .reliable, durability: .transientLocal, historyDepth: 1)
    private static let sensorData5 = QoSPolicy(reliability: .bestEffort, historyDepth: 5)

    /// Lyrical, session `c0b37272f3cc5247f81e092daf4dd6c`, node id 0.
    private static let lyricalSession = "c0b37272f3cc5247f81e092daf4dd6c"
    private static let lyricalNodeToken = "@ros2_lv/123/c0b37272f3cc5247f81e092daf4dd6c/0/0/NN/%/%e2e_s3/ref_node"
    private static let lyricalEntities: [CapturedEntity] = {
        let prefix = "@ros2_lv/123/c0b37272f3cc5247f81e092daf4dd6c/0"
        let node = "%/%e2e_s3/ref_node"
        let lookup = "tf2_msgs::action::dds_::LookupTransform"
        return [
            CapturedEntity(
                token: "\(prefix)/10/MP/\(node)/%e2e_s3%chatter/std_msgs::msg::dds_::String_/"
                    + "\(stringHash)/::,10:,:,:,,",
                kind: "MP", entityId: "10", name: "/e2e_s3/chatter", ddsTypeName: "std_msgs::msg::dds_::String_",
                typeHash: stringHash, qos: reliable10),
            CapturedEntity(
                token: "\(prefix)/11/MP/\(node)/%e2e_s3%latched/std_msgs::msg::dds_::String_/"
                    + "\(stringHash)/:1:,1:,:,:,,",
                kind: "MP", entityId: "11", name: "/e2e_s3/latched", ddsTypeName: "std_msgs::msg::dds_::String_",
                typeHash: stringHash, qos: latched1),
            CapturedEntity(
                token: "\(prefix)/12/MS/\(node)/%e2e_s3%imu_in/sensor_msgs::msg::dds_::Imu_/"
                    + "\(imuHash)/2::,5:,:,:,,",
                kind: "MS", entityId: "12", name: "/e2e_s3/imu_in", ddsTypeName: "sensor_msgs::msg::dds_::Imu_",
                typeHash: imuHash, qos: sensorData5),
            CapturedEntity(
                token: "\(prefix)/13/SS/\(node)/%e2e_s3%trigger/std_srvs::srv::dds_::Trigger_/"
                    + "\(triggerHash)/::,10:,:,:,,",
                kind: "SS", entityId: "13", name: "/e2e_s3/trigger", ddsTypeName: "std_srvs::srv::dds_::Trigger_",
                typeHash: triggerHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/14/SC/\(node)/%e2e_s3%remote_trigger/std_srvs::srv::dds_::Trigger_/"
                    + "\(triggerHash)/::,10:,:,:,,",
                kind: "SC", entityId: "14", name: "/e2e_s3/remote_trigger",
                ddsTypeName: "std_srvs::srv::dds_::Trigger_",
                typeHash: triggerHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/15/SS/\(node)/%e2e_s3%lookup%_action%send_goal/\(lookup)_SendGoal_/\(lookupSendGoalHash)/::,10:,:,:,,",
                kind: "SS", entityId: "15", name: "/e2e_s3/lookup/_action/send_goal",
                ddsTypeName: "\(lookup)_SendGoal_", typeHash: lookupSendGoalHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/16/SS/\(node)/%e2e_s3%lookup%_action%cancel_goal/action_msgs::srv::dds_::CancelGoal_/"
                    + "\(cancelGoalHash)/::,10:,:,:,,",
                kind: "SS", entityId: "16", name: "/e2e_s3/lookup/_action/cancel_goal",
                ddsTypeName: "action_msgs::srv::dds_::CancelGoal_", typeHash: cancelGoalHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/17/SS/\(node)/%e2e_s3%lookup%_action%get_result/\(lookup)_GetResult_/\(lookupGetResultHash)/::,10:,:,:,,",
                kind: "SS", entityId: "17", name: "/e2e_s3/lookup/_action/get_result",
                ddsTypeName: "\(lookup)_GetResult_", typeHash: lookupGetResultHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/18/MP/\(node)/%e2e_s3%lookup%_action%feedback/\(lookup)_FeedbackMessage_/"
                    + "\(lookupFeedbackHash)/::,10:,:,:,,",
                kind: "MP", entityId: "18", name: "/e2e_s3/lookup/_action/feedback",
                ddsTypeName: "\(lookup)_FeedbackMessage_", typeHash: lookupFeedbackHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/19/MP/\(node)/%e2e_s3%lookup%_action%status/action_msgs::msg::dds_::GoalStatusArray_/"
                    + "\(statusArrayHash)/:1:,1:,:,:,,",
                kind: "MP", entityId: "19", name: "/e2e_s3/lookup/_action/status",
                ddsTypeName: "action_msgs::msg::dds_::GoalStatusArray_", typeHash: statusArrayHash, qos: latched1),
            CapturedEntity(
                token:
                    "\(prefix)/23/MS/\(node)/%e2e_s3%remote_lookup%_action%feedback/\(lookup)_FeedbackMessage_/"
                    + "\(lookupFeedbackHash)/::,10:,:,:,,",
                kind: "MS", entityId: "23", name: "/e2e_s3/remote_lookup/_action/feedback",
                ddsTypeName: "\(lookup)_FeedbackMessage_", typeHash: lookupFeedbackHash, qos: reliable10),
            CapturedEntity(
                token:
                    "\(prefix)/24/MS/\(node)/%e2e_s3%remote_lookup%_action%status/action_msgs::msg::dds_::GoalStatusArray_/"
                    + "\(statusArrayHash)/:1:,1:,:,:,,",
                kind: "MS", entityId: "24", name: "/e2e_s3/remote_lookup/_action/status",
                ddsTypeName: "action_msgs::msg::dds_::GoalStatusArray_", typeHash: statusArrayHash, qos: latched1),
        ]
    }()

    func testEntityTokensMatchCapturedLyricalTokens() {
        let codec = ZenohWireCodec(distro: .lyrical)
        for entity in Self.lyricalEntities {
            XCTAssertEqual(
                codec.makeEntityLivelinessToken(
                    entityKind: entity.kind, domainId: 123, sessionId: Self.lyricalSession, nodeId: "0",
                    entityId: entity.entityId, nodeNamespace: Self.capturedNamespace,
                    nodeName: Self.capturedNodeName, name: entity.name, ddsTypeName: entity.ddsTypeName,
                    typeHash: entity.typeHash, qos: entity.qos),
                entity.token)
        }
    }

    func testNodeTokenMatchesCapturedTokens() {
        XCTAssertEqual(
            ZenohWireCodec(distro: .lyrical).makeNodeLivelinessToken(
                domainId: 123, sessionId: Self.lyricalSession, nodeId: "0",
                nodeNamespace: Self.capturedNamespace, nodeName: Self.capturedNodeName),
            Self.lyricalNodeToken)
        // Humble (rmw_zenoh_cpp 0.1.9) writes the same node token.
        XCTAssertEqual(
            ZenohWireCodec(distro: .humble).makeNodeLivelinessToken(
                domainId: 123, sessionId: "c8d03e3c90880c4e2458a1a64a8c8338", nodeId: "0",
                nodeNamespace: Self.capturedNamespace, nodeName: Self.capturedNodeName),
            "@ros2_lv/123/c8d03e3c90880c4e2458a1a64a8c8338/0/0/NN/%/%e2e_s3/ref_node")
        // A node in the root namespace (Lyrical): the namespace is mangled to `%`.
        XCTAssertEqual(
            ZenohWireCodec(distro: .lyrical).makeNodeLivelinessToken(
                domainId: 123, sessionId: "f7c156db7e4b70727b9fc14a3220e2f5", nodeId: "0", nodeNamespace: "/",
                nodeName: "e2e_s3_root_ref"),
            "@ros2_lv/123/f7c156db7e4b70727b9fc14a3220e2f5/0/0/NN/%/%/e2e_s3_root_ref")
    }

    /// Humble, session `c8d03e3c90880c4e2458a1a64a8c8338`: the hash segment is
    /// `TypeHashNotSupported`.
    func testEntityTokensMatchCapturedHumbleTokens() {
        let codec = ZenohWireCodec(distro: .humble)
        let prefix = "@ros2_lv/123/c8d03e3c90880c4e2458a1a64a8c8338/0"
        let captured: [(token: String, kind: String, entityId: String, name: String, type: String, qos: QoSPolicy)] = [
            (
                "\(prefix)/9/MP/%/%e2e_s3/ref_node/%e2e_s3%chatter/std_msgs::msg::dds_::String_/TypeHashNotSupported/"
                    + "::,10:,:,:,,",
                "MP", "9", "/e2e_s3/chatter", "std_msgs::msg::dds_::String_", Self.reliable10
            ),
            (
                "\(prefix)/11/MS/%/%e2e_s3/ref_node/%e2e_s3%imu_in/sensor_msgs::msg::dds_::Imu_/TypeHashNotSupported/"
                    + "2::,5:,:,:,,",
                "MS", "11", "/e2e_s3/imu_in", "sensor_msgs::msg::dds_::Imu_", Self.sensorData5
            ),
            (
                "\(prefix)/12/SS/%/%e2e_s3/ref_node/%e2e_s3%trigger/std_srvs::srv::dds_::Trigger_/TypeHashNotSupported/"
                    + "::,10:,:,:,,",
                "SS", "12", "/e2e_s3/trigger", "std_srvs::srv::dds_::Trigger_", Self.reliable10
            ),
            (
                "\(prefix)/18/MP/%/%e2e_s3/ref_node/%e2e_s3%lookup%_action%status/"
                    + "action_msgs::msg::dds_::GoalStatusArray_/TypeHashNotSupported/:1:,1:,:,:,,",
                "MP", "18", "/e2e_s3/lookup/_action/status", "action_msgs::msg::dds_::GoalStatusArray_",
                Self.latched1
            ),
        ]
        for entity in captured {
            XCTAssertEqual(
                codec.makeEntityLivelinessToken(
                    entityKind: entity.kind, domainId: 123, sessionId: "c8d03e3c90880c4e2458a1a64a8c8338",
                    nodeId: "0", entityId: entity.entityId, nodeNamespace: Self.capturedNamespace,
                    nodeName: Self.capturedNodeName, name: entity.name, ddsTypeName: entity.type,
                    typeHash: Self.stringHash, qos: entity.qos),
                entity.token)
        }
    }

    /// A Lyrical subscription of a message with a `uint8[]` field announces itself as
    /// CPU-only: rclpy node `e2e_s3_root_ref` (root namespace) subscribing to
    /// `sensor_msgs/msg/Image` on `/e2e_s3/image_in` with sensor-data QoS.
    func testCPUOnlySubscriptionTokenMatchesCapturedLyricalToken() {
        let imageHash = "RIHS01_d31d41a9a4c4bc8eae9be757b0beed306564f7526c88ea6a4588fb9582527d47"
        let token = ZenohWireCodec(distro: .lyrical).makeEntityLivelinessToken(
            entityKind: "MS", domainId: 123, sessionId: "f7c156db7e4b70727b9fc14a3220e2f5", nodeId: "0",
            entityId: "11", nodeNamespace: "/", nodeName: "e2e_s3_root_ref", name: "/e2e_s3/image_in",
            ddsTypeName: "sensor_msgs::msg::dds_::Image_", typeHash: imageHash, qos: Self.sensorData5)
        XCTAssertEqual(
            "\(token)/\(ZenohWireCodec.cpuBufferBackendsComponent)",
            "@ros2_lv/123/f7c156db7e4b70727b9fc14a3220e2f5/0/11/MS/%/%/e2e_s3_root_ref/%e2e_s3%image_in/"
                + "sensor_msgs::msg::dds_::Image_/\(imageHash)/2::,5:,:,:,,/backends:cpu:")
    }

    // MARK: - Transient-local history

    func testHistoryQueryKeyExprAndParameters() {
        let codec = ZenohWireCodec(distro: .humble)
        let key = codec.makeKeyExpr(
            domainId: 123, namespace: "/", topic: "tf_static", typeName: "tf2_msgs/msg/TFMessage",
            typeHash: nil)
        XCTAssertEqual(
            codec.makeHistoryQueryKeyExpr(key),
            "123/tf_static/tf2_msgs::msg::dds_::TFMessage_/TypeHashNotSupported/@adv/**")
        XCTAssertEqual(codec.makeHistoryQueryParameters(maxSamples: 1), "_anyke;_max=1")
        XCTAssertEqual(codec.makeHistoryQueryParameters(maxSamples: 25), "_anyke;_max=25")
        XCTAssertEqual(codec.makeHistoryQueryParameters(maxSamples: nil), "_anyke")
        XCTAssertEqual(codec.makeHistoryQueryParameters(maxSamples: 0), "_anyke")
    }

    /// Golden attachment from a Lyrical rmw_zenoh_cpp 0.10.6 publisher (first sample).
    func testParsesAnRmwZenohAttachment() throws {
        let hex = "01000000000000002868d05f137ede18104af90355a4c95ffeaa80509fcf0e4614"
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        let fields = try XCTUnwrap(ZenohAttachmentFields(Data(bytes)))
        XCTAssertEqual(fields.seq, 1)
        XCTAssertEqual(fields.tsNsec, 0x18de_7e13_5fd0_6828)
        XCTAssertEqual(
            fields.gid,
            [0x4a, 0xf9, 0x03, 0x55, 0xa4, 0xc9, 0x5f, 0xfe, 0xaa, 0x80, 0x50, 0x9f, 0xcf, 0x0e, 0x46, 0x14]
        )
    }

    func testAttachmentParsingRoundTripsAndRejectsOtherShapes() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let gid: [UInt8] = Array(0..<16)
        let built = codec.buildAttachment(seq: -5, tsNsec: Int64.max, gid: gid)
        XCTAssertEqual(ZenohAttachmentFields(built), ZenohAttachmentFields(built))
        XCTAssertEqual(ZenohAttachmentFields(built)?.seq, -5)
        XCTAssertEqual(ZenohAttachmentFields(built)?.tsNsec, Int64.max)
        XCTAssertEqual(ZenohAttachmentFields(built)?.gid, gid)
        XCTAssertNil(ZenohAttachmentFields(built.prefix(32)))
        var wrongPrefix = built
        wrongPrefix[16] = 0x0F
        XCTAssertNil(ZenohAttachmentFields(wrongPrefix))
    }
}
