// ZenohPublisherTokenTests.swift
// Reading rmw_zenoh MP liveliness tokens for the topic graph.

import XCTest

@testable import SwiftROS2Wire

final class ZenohPublisherTokenTests: XCTestCase {
    private typealias Info = ZenohPublisherTokenInfo

    // MARK: - Type names

    func testToROSTypeNameInvertsTheDDSForm() {
        XCTAssertEqual(
            TypeNameConverter.toROSTypeName("nav_msgs::msg::dds_::OccupancyGrid_"), "nav_msgs/msg/OccupancyGrid")
        XCTAssertEqual(
            TypeNameConverter.toROSTypeName("example_interfaces::action::dds_::Fibonacci_FeedbackMessage_"),
            "example_interfaces/action/Fibonacci_FeedbackMessage")
        XCTAssertEqual(
            TypeNameConverter.toROSTypeName(TypeNameConverter.goalStatusArrayDDSTypeName),
            "action_msgs/msg/GoalStatusArray")
        for name in ["sensor_msgs/msg/Imu", "std_msgs/msg/String", "tf2_msgs/msg/TFMessage"] {
            XCTAssertEqual(TypeNameConverter.toROSTypeName(TypeNameConverter.toDDSTypeName(name)), name)
        }
    }

    /// A name of any other shape keeps its text, with `::` turned into `/`.
    func testToROSTypeNameKeepsOddShapes() {
        XCTAssertEqual(TypeNameConverter.toROSTypeName("Custom_"), "Custom_")
        XCTAssertEqual(TypeNameConverter.toROSTypeName("pkg::Custom_"), "pkg/Custom_")
        XCTAssertEqual(TypeNameConverter.toROSTypeName("pkg::msg::Custom_"), "pkg/msg/Custom_")
        XCTAssertEqual(TypeNameConverter.toROSTypeName("pkg::msg::dds_::_"), "pkg/msg/dds_/_")
        XCTAssertEqual(TypeNameConverter.toROSTypeName("pkg::msg::dds_::Type"), "pkg/msg/dds_/Type")
        XCTAssertEqual(TypeNameConverter.toROSTypeName("a::b::c::dds_::T_"), "a/b/c/dds_/T_")
        XCTAssertEqual(TypeNameConverter.toROSTypeName(""), "")
    }

    // MARK: - Query

    func testPublisherLivelinessQueryMatchesEveryMPTokenOfTheDomain() {
        XCTAssertEqual(
            ZenohWireCodec(distro: .jazzy).makePublisherLivelinessQuery(domainId: 123), "@ros2_lv/123/*/*/*/MP/**")
        XCTAssertEqual(
            ZenohWireCodec(distro: .humble).makePublisherLivelinessQuery(domainId: 0), "@ros2_lv/0/*/*/*/MP/**")
    }

    // MARK: - Layouts

    func testHumbleTokenWithTheHashPlaceholder() {
        let token =
            "@ros2_lv/0/aa11/0/10/MP/%/%/talker/%chatter/std_msgs::msg::dds_::String_/TypeHashNotSupported/::,7:,:,:,,"
        XCTAssertEqual(
            ZenohWireCodec.parsePublisherToken(token),
            Info(
                topicName: "/chatter", typeName: "std_msgs/msg/String", reliability: .reliable,
                durability: .volatile, nodeName: "talker", nodeNamespace: "/"))
    }

    func testJazzyTokenWithAHash() {
        let token =
            "@ros2_lv/123/bb22/3/12/MP/%/%gt/pub_node/%gt%map/nav_msgs::msg::dds_::OccupancyGrid_/"
            + "RIHS01_f8a0c2e7bf8bc7f5d4b5f6a8b0e2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0/:1:,1:,:,:,,"
        XCTAssertEqual(
            ZenohWireCodec.parsePublisherToken(token),
            Info(
                topicName: "/gt/map", typeName: "nav_msgs/msg/OccupancyGrid", reliability: .reliable,
                durability: .transientLocal, nodeName: "pub_node", nodeNamespace: "/gt"))
    }

    /// Jazzy and later omit an absent hash: the QoS is index 11.
    func testHashlessTokenReadsIndex11AsTheQoS() {
        let token = "@ros2_lv/5/cc33/1/2/MP/%/%a%b/n/%a%b%scan/sensor_msgs::msg::dds_::LaserScan_/2::,5:,:,:,,"
        XCTAssertEqual(
            ZenohWireCodec.parsePublisherToken(token),
            Info(
                topicName: "/a/b/scan", typeName: "sensor_msgs/msg/LaserScan", reliability: .bestEffort,
                durability: .volatile, nodeName: "n", nodeNamespace: "/a/b"))
    }

    func testLyricalTokenWithAHash() {
        let token =
            "@ros2_lv/123/dd44/0/7/MP/%/%e2e/host_node/%e2e%chatter/std_msgs::msg::dds_::String_/"
            + "RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18/::,10:,:,:,,"
        XCTAssertEqual(
            ZenohWireCodec.parsePublisherToken(token),
            Info(
                topicName: "/e2e/chatter", typeName: "std_msgs/msg/String", reliability: .reliable,
                durability: .volatile, nodeName: "host_node", nodeNamespace: "/e2e"))
    }

    // MARK: - QoS fields

    func testQoSFieldMapping() {
        func parse(_ qos: String) -> Info? {
            ZenohWireCodec.parsePublisherToken("@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/\(qos)")
        }
        XCTAssertEqual(parse("::,10:,:,:,,")?.reliability, .reliable)
        XCTAssertEqual(parse("::,10:,:,:,,")?.durability, .volatile)
        XCTAssertEqual(parse("1:2:,10:,:,:,,")?.reliability, .reliable)
        XCTAssertEqual(parse("1:2:,10:,:,:,,")?.durability, .volatile)
        XCTAssertEqual(parse("2::,5:,:,:,,")?.reliability, .bestEffort)
        XCTAssertEqual(parse(":1:,1:,:,:,,")?.durability, .transientLocal)
        XCTAssertEqual(parse(":1:2,:,:,:,,")?.durability, .transientLocal)
        // Values this parser does not know never report more than the publisher offers.
        for value in ["0", "3", "4", "x"] {
            XCTAssertEqual(parse("\(value)::,10:,:,:,,")?.reliability, .bestEffort, value)
            XCTAssertEqual(parse(":\(value):,10:,:,:,,")?.durability, .volatile, value)
        }
    }

    // MARK: - Rejected and ignored components

    /// A hash-like index 11 that is neither form is read as the QoS, and rejected when
    /// it does not split.
    func testUnknownHashFormIsReadAsTheQoS() {
        XCTAssertNil(
            ZenohWireCodec.parsePublisherToken(
                "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/RIHS02_abcdef/::,10:,:,:,,"))
        XCTAssertNil(
            ZenohWireCodec.parsePublisherToken(
                "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/RIHS02_abcdef"))
    }

    func testComponentsAfterTheQoSAreIgnored() {
        let base = "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_"
        let expected = Info(
            topicName: "/t", typeName: "std_msgs/msg/String", reliability: .reliable, durability: .volatile,
            nodeName: "n", nodeNamespace: "/")
        XCTAssertEqual(ZenohWireCodec.parsePublisherToken("\(base)/::,10:,:,:,,/backends:cpu:"), expected)
        XCTAssertEqual(ZenohWireCodec.parsePublisherToken("\(base)/RIHS01_00/::,10:,:,:,,/future/suffix"), expected)
    }

    func testActionFeedbackAndStatusTokens() {
        let feedback =
            "@ros2_lv/0/z/1/9/MP/%/%gt/pub_node/%gt%fibonacci%_action%feedback/"
            + "example_interfaces::action::dds_::Fibonacci_FeedbackMessage_/RIHS01_11/::,10:,:,:,,"
        let status =
            "@ros2_lv/0/z/1/10/MP/%/%gt/pub_node/%gt%fibonacci%_action%status/"
            + "action_msgs::msg::dds_::GoalStatusArray_/RIHS01_22/:1:,1:,:,:,,"
        XCTAssertEqual(
            ZenohWireCodec.parsePublisherToken(feedback),
            Info(
                topicName: "/gt/fibonacci/_action/feedback",
                typeName: "example_interfaces/action/Fibonacci_FeedbackMessage",
                reliability: .reliable, durability: .volatile, nodeName: "pub_node", nodeNamespace: "/gt"))
        XCTAssertEqual(
            ZenohWireCodec.parsePublisherToken(status),
            Info(
                topicName: "/gt/fibonacci/_action/status", typeName: "action_msgs/msg/GoalStatusArray",
                reliability: .reliable, durability: .transientLocal, nodeName: "pub_node", nodeNamespace: "/gt"))
    }

    func testOtherEntitiesAndMalformedTokensAreIgnored() {
        let rejected = [
            // Subscription, with Lyrical's buffer component.
            "@ros2_lv/0/z/1/2/MS/%/%/n/%t/std_msgs::msg::dds_::String_/RIHS01_00/::,10:,:,:,,/backends:cpu:",
            "@ros2_lv/0/z/1/2/SS/%/%/n/%srv/std_srvs::srv::dds_::Trigger_/RIHS01_00/::,10:,:,:,,",
            "@ros2_lv/0/z/1/1/NN/%/%/n",
            // Too few components, wrong prefix, an unsplittable QoS, an empty node or topic.
            "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_",
            "@ros2_xx/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/::,10:,:,:,,",
            "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/garbage",
            "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/::10:,:,:,,",
            "@ros2_lv/0/z/1/2/MP/%/%/n/%t/std_msgs::msg::dds_::String_/::,10:,:,",
            "@ros2_lv/0/z/1/2/MP/%/%//%t/std_msgs::msg::dds_::String_/::,10:,:,:,,",
            "@ros2_lv/0/z/1/2/MP/%/%/n/%/std_msgs::msg::dds_::String_/::,10:,:,:,,",
            "@ros2_lv/0/z/1/2/MP/%/%/n/%t//::,10:,:,:,,",
            "",
        ]
        for token in rejected {
            XCTAssertNil(ZenohWireCodec.parsePublisherToken(token), token)
        }
    }

    // MARK: - Round trip

    /// Whatever ``ZenohWireCodec/makeEntityLivelinessToken`` writes for a publisher reads
    /// back, on every distribution, with and without a hash.
    func testRoundTripOnEveryDistro() {
        let cases: [(QoSPolicy, QoSPolicy.Reliability, QoSPolicy.Durability)] = [
            (.reliableSensor, .reliable, .volatile),
            (.latched, .reliable, .transientLocal),
            (.sensorData, .bestEffort, .volatile),
            (
                QoSPolicy(reliability: .reliable, durability: .volatile, historyPolicy: .keepAll, historyDepth: 0),
                .reliable, .volatile
            ),
        ]
        for distro in ROS2Distro.allCases {
            let codec = ZenohWireCodec(distro: distro)
            for hash in [nil, "RIHS01_" + String(repeating: "ab", count: 32)] as [String?] {
                for (namespace, expectedNamespace) in [("/", "/"), ("", "/"), ("/gt", "/gt"), ("/a/b", "/a/b")] {
                    for (qos, reliability, durability) in cases {
                        let token = codec.makeEntityLivelinessToken(
                            entityKind: "MP", domainId: 42, sessionId: "0123abcd", nodeId: "3", entityId: "17",
                            nodeNamespace: namespace, nodeName: "pub_node", name: "/gt/map",
                            ddsTypeName: "nav_msgs::msg::dds_::OccupancyGrid_", typeHash: hash, qos: qos)
                        XCTAssertEqual(
                            ZenohWireCodec.parsePublisherToken(token),
                            Info(
                                topicName: "/gt/map", typeName: "nav_msgs/msg/OccupancyGrid", reliability: reliability,
                                durability: durability, nodeName: "pub_node", nodeNamespace: expectedNamespace),
                            "\(distro) \(token)")
                    }
                }
            }
        }
    }
}
