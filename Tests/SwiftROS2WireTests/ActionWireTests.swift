// ActionWireTests.swift
// Phase 2 wire-codec golden tests for ROS 2 Actions.

import XCTest

@testable import SwiftROS2Wire

final class ActionWireTests: XCTestCase {

    // MARK: - TypeNameConverter.toDDSActionRoleTypeName

    func testActionRoleTypeNameSendGoalRequest() {
        let name = TypeNameConverter.toDDSActionRoleTypeName(
            "example_interfaces/action/Fibonacci",
            role: "SendGoal",
            suffix: "Request"
        )
        XCTAssertEqual(name, "example_interfaces::action::dds_::Fibonacci_SendGoal_Request_")
    }

    func testActionRoleTypeNameSendGoalResponse() {
        let name = TypeNameConverter.toDDSActionRoleTypeName(
            "example_interfaces/action/Fibonacci",
            role: "SendGoal",
            suffix: "Response"
        )
        XCTAssertEqual(name, "example_interfaces::action::dds_::Fibonacci_SendGoal_Response_")
    }

    func testActionRoleTypeNameGetResultRequest() {
        let name = TypeNameConverter.toDDSActionRoleTypeName(
            "example_interfaces/action/Fibonacci",
            role: "GetResult",
            suffix: "Request"
        )
        XCTAssertEqual(name, "example_interfaces::action::dds_::Fibonacci_GetResult_Request_")
    }

    func testActionRoleTypeNameGetResultResponse() {
        let name = TypeNameConverter.toDDSActionRoleTypeName(
            "example_interfaces/action/Fibonacci",
            role: "GetResult",
            suffix: "Response"
        )
        XCTAssertEqual(name, "example_interfaces::action::dds_::Fibonacci_GetResult_Response_")
    }

    func testActionRoleTypeNameFeedbackMessage() {
        let name = TypeNameConverter.toDDSActionRoleTypeName(
            "example_interfaces/action/Fibonacci",
            role: "FeedbackMessage",
            suffix: nil
        )
        XCTAssertEqual(name, "example_interfaces::action::dds_::Fibonacci_FeedbackMessage_")
    }

    func testActionRoleTypeNameMalformedFallback() {
        // No `/action/` infix → conservative fallback that still emits a valid DDS-shape string.
        let name = TypeNameConverter.toDDSActionRoleTypeName(
            "weird_pkg.Fibonacci",
            role: "SendGoal",
            suffix: "Request"
        )
        XCTAssertEqual(name, "weird_pkg.Fibonacci_SendGoal_Request_")
    }

    // MARK: - DDSWireCodec.actionTopicNames

    func testDDSActionTopicNames() {
        let codec = DDSWireCodec()
        let names = codec.actionTopicNames(
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci"
        )
        XCTAssertEqual(names.sendGoalRequestTopic, "rq/fibonacci/_action/send_goalRequest")
        XCTAssertEqual(names.sendGoalReplyTopic, "rr/fibonacci/_action/send_goalReply")
        XCTAssertEqual(names.cancelGoalRequestTopic, "rq/fibonacci/_action/cancel_goalRequest")
        XCTAssertEqual(names.cancelGoalReplyTopic, "rr/fibonacci/_action/cancel_goalReply")
        XCTAssertEqual(names.getResultRequestTopic, "rq/fibonacci/_action/get_resultRequest")
        XCTAssertEqual(names.getResultReplyTopic, "rr/fibonacci/_action/get_resultReply")
        XCTAssertEqual(names.feedbackTopic, "rt/fibonacci/_action/feedback")
        XCTAssertEqual(names.statusTopic, "rt/fibonacci/_action/status")

        XCTAssertEqual(
            names.sendGoalRequestTypeName,
            "example_interfaces::action::dds_::Fibonacci_SendGoal_Request_")
        XCTAssertEqual(
            names.sendGoalReplyTypeName,
            "example_interfaces::action::dds_::Fibonacci_SendGoal_Response_")
        XCTAssertEqual(
            names.cancelGoalRequestTypeName,
            "action_msgs::srv::dds_::CancelGoal_Request_")
        XCTAssertEqual(
            names.cancelGoalReplyTypeName,
            "action_msgs::srv::dds_::CancelGoal_Response_")
        XCTAssertEqual(
            names.getResultRequestTypeName,
            "example_interfaces::action::dds_::Fibonacci_GetResult_Request_")
        XCTAssertEqual(
            names.getResultReplyTypeName,
            "example_interfaces::action::dds_::Fibonacci_GetResult_Response_")
        XCTAssertEqual(
            names.feedbackTypeName,
            "example_interfaces::action::dds_::Fibonacci_FeedbackMessage_")
        XCTAssertEqual(
            names.statusTypeName,
            "action_msgs::msg::dds_::GoalStatusArray_")
    }

    func testDDSActionTopicNamesWithNamespace() {
        let codec = DDSWireCodec()
        let names = codec.actionTopicNames(
            namespace: "/ios",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci"
        )
        XCTAssertEqual(names.sendGoalRequestTopic, "rq/ios/fibonacci/_action/send_goalRequest")
        XCTAssertEqual(names.feedbackTopic, "rt/ios/fibonacci/_action/feedback")
        XCTAssertEqual(names.statusTopic, "rt/ios/fibonacci/_action/status")
    }

    func testDDSActionTopicNamesStripsLeadingSlashOnAction() {
        let codec = DDSWireCodec()
        let withSlash = codec.actionTopicNames(
            namespace: "",
            actionName: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci"
        )
        let withoutSlash = codec.actionTopicNames(
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci"
        )
        XCTAssertEqual(withSlash, withoutSlash)
        XCTAssertFalse(withSlash.sendGoalRequestTopic.contains("//"))
    }

    // MARK: - ZenohWireCodec.makeActionKeyExpr

    func testJazzyActionSendGoalKey() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .sendGoal,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_d1a57fb2a4afe8c21e34fb10db206f16ce6729b28531141472df92277c55b557"
        )
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/RIHS01_d1a57fb2a4afe8c21e34fb10db206f16ce6729b28531141472df92277c55b557"
        )
    }

    func testJazzyActionCancelGoalKey() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .cancelGoal,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_573d8b0a534451d7bc2ac8c5ffde8ac14b8593b7001175d0cd6516dcbeb8689a"
        )
        // cancel_goal uses the action_msgs/srv/CancelGoal_Request type, NOT the per-action type.
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/cancel_goal/action_msgs::srv::dds_::CancelGoal_/RIHS01_573d8b0a534451d7bc2ac8c5ffde8ac14b8593b7001175d0cd6516dcbeb8689a"
        )
    }

    func testJazzyActionGetResultKey() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .getResult,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_1b0de0d5d29dc955d92f546706568428632771db13ec84c15ec1c1a59f424a57"
        )
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/get_result/example_interfaces::action::dds_::Fibonacci_GetResult_/RIHS01_1b0de0d5d29dc955d92f546706568428632771db13ec84c15ec1c1a59f424a57"
        )
    }

    func testJazzyActionFeedbackKey() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .feedback,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_c1de71afd52e49a89c53d8262366884185bc0a02f78ce051c4e46b0a7fe59bb2"
        )
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/feedback/example_interfaces::action::dds_::Fibonacci_FeedbackMessage_/RIHS01_c1de71afd52e49a89c53d8262366884185bc0a02f78ce051c4e46b0a7fe59bb2"
        )
    }

    func testJazzyActionStatusKey() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .status,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_6c1684b00f177d37438febe6e709fc4e2b0d4248dca4854946f9ed8b30cda83e"
        )
        // status uses action_msgs/msg/GoalStatusArray, fixed across all actions.
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/status/action_msgs::msg::dds_::GoalStatusArray_/RIHS01_6c1684b00f177d37438febe6e709fc4e2b0d4248dca4854946f9ed8b30cda83e"
        )
    }

    func testJazzyActionKeyWithNamespace() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .sendGoal,
            domainId: 0,
            namespace: "/ios",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_aaa"
        )
        XCTAssertEqual(
            key,
            "0/ios/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/RIHS01_aaa"
        )
    }

    func testHumbleActionKeyAppendsTypeHashNotSupported() {
        let codec = ZenohWireCodec(distro: .humble)
        let key = codec.makeActionKeyExpr(
            role: .sendGoal,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: nil
        )
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/TypeHashNotSupported"
        )
    }

    func testJazzyActionKeyOmitsEmptyHashSegment() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeActionKeyExpr(
            role: .sendGoal,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: nil
        )
        XCTAssertEqual(
            key,
            "0/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_"
        )
    }

    func testActionKeyStripsLeadingSlashFromActionName() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let withSlash = codec.makeActionKeyExpr(
            role: .feedback,
            domainId: 0,
            namespace: "",
            actionName: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_aaa"
        )
        let withoutSlash = codec.makeActionKeyExpr(
            role: .feedback,
            domainId: 0,
            namespace: "",
            actionName: "fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHash: "RIHS01_aaa"
        )
        XCTAssertEqual(withSlash, withoutSlash)
        XCTAssertFalse(withSlash.contains("//"))
    }

    func testActionRoleRawValues() {
        XCTAssertEqual(ZenohWireCodec.ActionRole.sendGoal.rawValue, "send_goal")
        XCTAssertEqual(ZenohWireCodec.ActionRole.cancelGoal.rawValue, "cancel_goal")
        XCTAssertEqual(ZenohWireCodec.ActionRole.getResult.rawValue, "get_result")
        XCTAssertEqual(ZenohWireCodec.ActionRole.feedback.rawValue, "feedback")
        XCTAssertEqual(ZenohWireCodec.ActionRole.status.rawValue, "status")
    }

    // MARK: - Action entities as rmw_zenoh_cpp names them

    func testActionRoleTypeNamesAreServiceTypes() {
        let fib = "example_interfaces/action/Fibonacci"
        XCTAssertEqual(
            ZenohWireCodec.ddsTypeName(forRole: .sendGoal, actionTypeName: fib),
            "example_interfaces::action::dds_::Fibonacci_SendGoal_")
        XCTAssertEqual(
            ZenohWireCodec.ddsTypeName(forRole: .getResult, actionTypeName: fib),
            "example_interfaces::action::dds_::Fibonacci_GetResult_")
        XCTAssertEqual(
            ZenohWireCodec.ddsTypeName(forRole: .cancelGoal, actionTypeName: fib),
            "action_msgs::srv::dds_::CancelGoal_")
        XCTAssertEqual(
            ZenohWireCodec.ddsTypeName(forRole: .feedback, actionTypeName: fib),
            "example_interfaces::action::dds_::Fibonacci_FeedbackMessage_")
        XCTAssertEqual(
            ZenohWireCodec.ddsTypeName(forRole: .status, actionTypeName: fib),
            "action_msgs::msg::dds_::GoalStatusArray_")
    }

    func testLegacyRequestTypeNamesOnlyForServiceRoles() {
        let fib = "example_interfaces/action/Fibonacci"
        XCTAssertEqual(
            ZenohWireCodec.legacyRequestDDSTypeName(forRole: .sendGoal, actionTypeName: fib),
            "example_interfaces::action::dds_::Fibonacci_SendGoal_Request_")
        XCTAssertEqual(
            ZenohWireCodec.legacyRequestDDSTypeName(forRole: .getResult, actionTypeName: fib),
            "example_interfaces::action::dds_::Fibonacci_GetResult_Request_")
        XCTAssertEqual(
            ZenohWireCodec.legacyRequestDDSTypeName(forRole: .cancelGoal, actionTypeName: fib),
            "action_msgs::srv::dds_::CancelGoal_Request_")
        XCTAssertNil(ZenohWireCodec.legacyRequestDDSTypeName(forRole: .feedback, actionTypeName: fib))
        XCTAssertNil(ZenohWireCodec.legacyRequestDDSTypeName(forRole: .status, actionTypeName: fib))
        XCTAssertEqual(
            ZenohWireCodec.ActionRole.allCases.filter(\.isService), [.sendGoal, .cancelGoal, .getResult])
    }

    func testActionRoleNames() {
        XCTAssertEqual(
            ZenohWireCodec.actionRoleName(namespace: "", actionName: "/e2e/fibonacci", role: .sendGoal),
            "/e2e/fibonacci/_action/send_goal")
        XCTAssertEqual(
            ZenohWireCodec.actionRoleName(namespace: "/e2e", actionName: "fibonacci", role: .status),
            "/e2e/fibonacci/_action/status")
    }

    /// Every key of a Fibonacci action server on each distro, as rmw_zenoh_cpp
    /// declares them.
    func testFibonacciActionKeysPerDistro() {
        let fib = "example_interfaces/action/Fibonacci"
        let feedback = "RIHS01_c1de71afd52e49a89c53d8262366884185bc0a02f78ce051c4e46b0a7fe59bb2"
        let status = "RIHS01_6c1684b00f177d37438febe6e709fc4e2b0d4248dca4854946f9ed8b30cda83e"
        let sendGoal = "RIHS01_d1a57fb2a4afe8c21e34fb10db206f16ce6729b28531141472df92277c55b557"
        let getResult = "RIHS01_1b0de0d5d29dc955d92f546706568428632771db13ec84c15ec1c1a59f424a57"
        let cancelGoal = "RIHS01_573d8b0a534451d7bc2ac8c5ffde8ac14b8593b7001175d0cd6516dcbeb8689a"
        let hashes: [ZenohWireCodec.ActionRole: String] = [
            .sendGoal: sendGoal, .getResult: getResult, .cancelGoal: cancelGoal, .feedback: feedback, .status: status,
        ]
        let expectedTypes: [ZenohWireCodec.ActionRole: String] = [
            .sendGoal: "example_interfaces::action::dds_::Fibonacci_SendGoal_",
            .getResult: "example_interfaces::action::dds_::Fibonacci_GetResult_",
            .cancelGoal: "action_msgs::srv::dds_::CancelGoal_",
            .feedback: "example_interfaces::action::dds_::Fibonacci_FeedbackMessage_",
            .status: "action_msgs::msg::dds_::GoalStatusArray_",
        ]
        for distro in ROS2Distro.allCases {
            let codec = ZenohWireCodec(distro: distro)
            for role in ZenohWireCodec.ActionRole.allCases {
                let key = codec.makeActionKeyExpr(
                    role: role, domainId: 123, namespace: "/e2e_srv", actionName: "fibonacci",
                    actionTypeName: fib, roleTypeHash: hashes[role])
                let hash = distro.supportsTypeHash ? hashes[role]! : "TypeHashNotSupported"
                XCTAssertEqual(
                    key, "123/e2e_srv/fibonacci/_action/\(role.rawValue)/\(expectedTypes[role]!)/\(hash)",
                    "\(distro) \(role)")
            }
        }
    }
}
