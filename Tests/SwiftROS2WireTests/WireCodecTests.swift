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

    func testTopicPathMangling() {
        XCTAssertEqual(
            TypeNameConverter.mangleTopicPath(namespace: "/ios", topic: "imu"),
            "%ios%imu"
        )
        XCTAssertEqual(
            TypeNameConverter.mangleTopicPath(namespace: "ios", topic: "imu"),
            "%ios%imu"
        )
        XCTAssertEqual(
            TypeNameConverter.mangleTopicPath(namespace: "", topic: "tf_static"),
            "%tf_static"
        )
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

    func testLivelinessToken() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let qos = QoSPolicy(reliability: .bestEffort, durability: .volatile, historyPolicy: .keepLast, historyDepth: 10)
        let token = codec.makeLivelinessToken(
            domainId: 0,
            sessionId: "abc123",
            nodeId: "1",
            entityId: "2",
            namespace: "/ios",
            nodeName: "imu_node",
            topic: "imu",
            typeName: "sensor_msgs/msg/Imu",
            typeHash: "RIHS01_hash",
            qos: qos
        )
        XCTAssertTrue(token.hasPrefix("@ros2_lv/0/abc123/1/2/MP/%/%/imu_node/"))
        XCTAssertTrue(token.contains("%ios%imu"))
        XCTAssertTrue(token.contains("sensor_msgs::msg::dds_::Imu_"))
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

    func testDistroTypeHashSupport() {
        XCTAssertFalse(ROS2Distro.humble.supportsTypeHash)
        XCTAssertTrue(ROS2Distro.jazzy.supportsTypeHash)
        XCTAssertTrue(ROS2Distro.kilted.supportsTypeHash)
        XCTAssertTrue(ROS2Distro.rolling.supportsTypeHash)
    }

    func testDistroFormatTypeHash() {
        XCTAssertEqual(ROS2Distro.humble.formatTypeHash(nil), "TypeHashNotSupported")
        XCTAssertEqual(ROS2Distro.humble.formatTypeHash("RIHS01_abc"), "TypeHashNotSupported")
        XCTAssertEqual(ROS2Distro.jazzy.formatTypeHash("RIHS01_abc"), "RIHS01_abc")
        XCTAssertEqual(ROS2Distro.jazzy.formatTypeHash(nil), "")
    }

    func testDistroDisplayNames() {
        XCTAssertEqual(ROS2Distro.humble.displayName, "Humble")
        XCTAssertEqual(ROS2Distro.jazzy.displayName, "Jazzy")
        XCTAssertEqual(ROS2Distro.kilted.displayName, "Kilted")
        XCTAssertEqual(ROS2Distro.lyrical.displayName, "Lyrical")
        XCTAssertEqual(ROS2Distro.rolling.displayName, "Rolling")
    }

    func testDistroIsLegacySchema() {
        XCTAssertTrue(ROS2Distro.humble.isLegacySchema)
        XCTAssertFalse(ROS2Distro.jazzy.isLegacySchema)
        XCTAssertFalse(ROS2Distro.kilted.isLegacySchema)
        XCTAssertFalse(ROS2Distro.rolling.isLegacySchema)
    }

    func testDistroWireGroup() {
        XCTAssertEqual(ROS2Distro.humble.wireGroup, .legacy)
        XCTAssertEqual(ROS2Distro.jazzy.wireGroup, .modern)
        XCTAssertEqual(ROS2Distro.kilted.wireGroup, .modern)
        XCTAssertEqual(ROS2Distro.rolling.wireGroup, .modern)
    }

    func testDistroTypeHashPlaceholder() {
        XCTAssertEqual(ROS2Distro.humble.typeHashPlaceholder, "TypeHashNotSupported")
        XCTAssertEqual(ROS2Distro.jazzy.typeHashPlaceholder, "TypeHashNotSupported")
    }

    func testDistroAlwaysIncludeTypeHashInKey() {
        XCTAssertTrue(ROS2Distro.humble.alwaysIncludeTypeHashInKey)
        XCTAssertFalse(ROS2Distro.jazzy.alwaysIncludeTypeHashInKey)
        XCTAssertFalse(ROS2Distro.kilted.alwaysIncludeTypeHashInKey)
        XCTAssertFalse(ROS2Distro.rolling.alwaysIncludeTypeHashInKey)
    }

    func testWireGroupDistros() {
        XCTAssertEqual(ROS2Distro.WireGroup.legacy.distros, [.humble])
        XCTAssertEqual(ROS2Distro.WireGroup.modern.distros, [.jazzy, .kilted, .lyrical, .rolling])
    }

    func testWireGroupRawValues() {
        XCTAssertEqual(ROS2Distro.WireGroup.legacy.rawValue, "Humble and earlier")
        XCTAssertEqual(ROS2Distro.WireGroup.modern.rawValue, "Iron and later")
    }

    func testDistroAllCases() {
        XCTAssertEqual(ROS2Distro.allCases, [.humble, .jazzy, .kilted, .lyrical, .rolling])
    }

    func testLyricalIsModern() {
        XCTAssertEqual(ROS2Distro(rawValue: "lyrical"), .lyrical)
        XCTAssertTrue(ROS2Distro.lyrical.supportsTypeHash)
        XCTAssertFalse(ROS2Distro.lyrical.isLegacySchema)
        XCTAssertFalse(ROS2Distro.lyrical.alwaysIncludeTypeHashInKey)
        XCTAssertEqual(ROS2Distro.lyrical.wireGroup, .modern)
        XCTAssertEqual(ROS2Distro.lyrical.formatTypeHash("RIHS01_abc"), "RIHS01_abc")
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
                    serviceTypeName: "std_srvs/srv/Trigger", requestTypeHash: hash),
                jazzy.makeServiceKeyExpr(
                    domainId: 123, namespace: "conduit", serviceName: "trigger",
                    serviceTypeName: "std_srvs/srv/Trigger", requestTypeHash: hash))
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
            XCTAssertEqual(
                lyrical.makeLivelinessToken(
                    domainId: 123, sessionId: "abc123", nodeId: "1", entityId: "2", namespace: "/conduit",
                    nodeName: "imu_node", topic: "imu", typeName: "sensor_msgs/msg/Imu", typeHash: hash, qos: qos),
                jazzy.makeLivelinessToken(
                    domainId: 123, sessionId: "abc123", nodeId: "1", entityId: "2", namespace: "/conduit",
                    nodeName: "imu_node", topic: "imu", typeName: "sensor_msgs/msg/Imu", typeHash: hash, qos: qos))
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

    func testCPUOnlySubscriptionLivelinessToken() {
        let codec = ZenohWireCodec(distro: .lyrical)
        let token = codec.makeSubscriptionLivelinessToken(
            domainId: 123, sessionId: "abc123", nodeId: "3", entityId: "4", namespace: "/e2e",
            nodeName: "ios_points_node", topic: "points", typeName: "sensor_msgs/msg/PointCloud2",
            typeHash: pointCloudHash, qos: .reliableSensor, cpuBufferBackend: true)
        XCTAssertEqual(
            token,
            "@ros2_lv/123/abc123/3/4/MS/%/%/ios_points_node/%e2e%points/sensor_msgs::msg::dds_::PointCloud2_/"
                + "\(pointCloudHash)/1::,10:,:,:,,/backends:cpu:")
    }

    func testSubscriptionLivelinessTokenWithoutBackends() {
        let codec = ZenohWireCodec(distro: .lyrical)
        let token = codec.makeSubscriptionLivelinessToken(
            domainId: 123, sessionId: "abc123", nodeId: "3", entityId: "4", namespace: "/",
            nodeName: "ios_tf_static_node", topic: "tf_static", typeName: "tf2_msgs/msg/TFMessage",
            typeHash: "RIHS01_abc", qos: .latched, cpuBufferBackend: false)
        XCTAssertEqual(
            token,
            "@ros2_lv/123/abc123/3/4/MS/%/%/ios_tf_static_node/%tf_static/tf2_msgs::msg::dds_::TFMessage_/"
                + "RIHS01_abc/1:1:,1:,:,:,,")
    }

    func testPublisherTokenIsUnchangedBySubscriptionTokenSupport() {
        let codec = ZenohWireCodec(distro: .lyrical)
        let token = codec.makeLivelinessToken(
            domainId: 123, sessionId: "abc123", nodeId: "1", entityId: "2", namespace: "/e2e",
            nodeName: "ios_points_node", topic: "points", typeName: "sensor_msgs/msg/PointCloud2",
            typeHash: pointCloudHash, qos: .reliableSensor)
        XCTAssertEqual(
            token,
            "@ros2_lv/123/abc123/1/2/MP/%/%/ios_points_node/%e2e%points/sensor_msgs::msg::dds_::PointCloud2_/"
                + "\(pointCloudHash)/1::,10:,:,:,,")
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
            fields.gid, [0x4a, 0xf9, 0x03, 0x55, 0xa4, 0xc9, 0x5f, 0xfe, 0xaa, 0x80, 0x50, 0x9f, 0xcf, 0x0e, 0x46, 0x14])
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
