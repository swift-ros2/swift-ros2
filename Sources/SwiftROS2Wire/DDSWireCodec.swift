// DDSWireCodec.swift
// Wire format codec for DDS (rmw_cyclonedds) compatibility

import Foundation

/// Wire format codec for DDS transport
///
/// Handles DDS-specific topic naming and type name mangling for
/// rmw_cyclonedds_cpp compatibility.
public struct DDSWireCodec: Sendable {
    public init() {}

    /// Convert ROS topic to DDS topic name
    ///
    /// Adds "rt/" prefix: "/robot/imu" -> "rt/robot/imu"
    public func ddsTopic(from rosTopic: String) -> String {
        let clean = TypeNameConverter.stripLeadingSlash(rosTopic)
        return "rt/\(clean)"
    }

    /// Convert ROS type name to DDS type name
    ///
    /// "sensor_msgs/msg/Imu" -> "sensor_msgs::msg::dds_::Imu_"
    public func ddsTypeName(from rosTypeName: String) -> String {
        TypeNameConverter.toDDSTypeName(rosTypeName)
    }

    /// Build USER_DATA QoS string for DDS discovery
    ///
    /// Format: "typehash=RIHS01_...;"
    public func userDataString(typeHash: String?) -> String? {
        guard let hash = typeHash, !hash.isEmpty else { return nil }
        return "typehash=\(hash);"
    }

    /// Names emitted for a DDS service: paired request / reply topics + DDS type names.
    public struct ServiceTopicNames: Sendable, Equatable {
        public let requestTopic: String
        public let replyTopic: String
        public let requestTypeName: String
        public let replyTypeName: String

        public init(
            requestTopic: String,
            replyTopic: String,
            requestTypeName: String,
            replyTypeName: String
        ) {
            self.requestTopic = requestTopic
            self.replyTopic = replyTopic
            self.requestTypeName = requestTypeName
            self.replyTypeName = replyTypeName
        }
    }

    /// Build the DDS topic / type name quadruple for a service.
    ///
    /// rmw_cyclonedds_cpp pairs each service with two topics:
    /// - `rq/<service>Request` (client → server)
    /// - `rr/<service>Reply`   (server → client)
    public func serviceTopicNames(
        serviceName: String,
        serviceTypeName: String
    ) -> ServiceTopicNames {
        let cleanService = TypeNameConverter.stripLeadingSlash(serviceName)
        return ServiceTopicNames(
            requestTopic: "rq/\(cleanService)Request",
            replyTopic: "rr/\(cleanService)Reply",
            requestTypeName: TypeNameConverter.toDDSServiceRequestTypeName(serviceTypeName),
            replyTypeName: TypeNameConverter.toDDSServiceResponseTypeName(serviceTypeName)
        )
    }

    /// Names emitted for a DDS action: 6 rq/rr topics + 2 rt topics + their DDS type names.
    public struct ActionTopicNames: Sendable, Equatable {
        public let sendGoalRequestTopic: String
        public let sendGoalReplyTopic: String
        public let cancelGoalRequestTopic: String
        public let cancelGoalReplyTopic: String
        public let getResultRequestTopic: String
        public let getResultReplyTopic: String
        public let feedbackTopic: String
        public let statusTopic: String

        public let sendGoalRequestTypeName: String
        public let sendGoalReplyTypeName: String
        public let cancelGoalRequestTypeName: String
        public let cancelGoalReplyTypeName: String
        public let getResultRequestTypeName: String
        public let getResultReplyTypeName: String
        public let feedbackTypeName: String
        public let statusTypeName: String

        public init(
            sendGoalRequestTopic: String,
            sendGoalReplyTopic: String,
            cancelGoalRequestTopic: String,
            cancelGoalReplyTopic: String,
            getResultRequestTopic: String,
            getResultReplyTopic: String,
            feedbackTopic: String,
            statusTopic: String,
            sendGoalRequestTypeName: String,
            sendGoalReplyTypeName: String,
            cancelGoalRequestTypeName: String,
            cancelGoalReplyTypeName: String,
            getResultRequestTypeName: String,
            getResultReplyTypeName: String,
            feedbackTypeName: String,
            statusTypeName: String
        ) {
            self.sendGoalRequestTopic = sendGoalRequestTopic
            self.sendGoalReplyTopic = sendGoalReplyTopic
            self.cancelGoalRequestTopic = cancelGoalRequestTopic
            self.cancelGoalReplyTopic = cancelGoalReplyTopic
            self.getResultRequestTopic = getResultRequestTopic
            self.getResultReplyTopic = getResultReplyTopic
            self.feedbackTopic = feedbackTopic
            self.statusTopic = statusTopic
            self.sendGoalRequestTypeName = sendGoalRequestTypeName
            self.sendGoalReplyTypeName = sendGoalReplyTypeName
            self.cancelGoalRequestTypeName = cancelGoalRequestTypeName
            self.cancelGoalReplyTypeName = cancelGoalReplyTypeName
            self.getResultRequestTypeName = getResultRequestTypeName
            self.getResultReplyTypeName = getResultReplyTypeName
            self.feedbackTypeName = feedbackTypeName
            self.statusTypeName = statusTypeName
        }
    }

    /// Build the DDS topic / type name octuple for an action.
    ///
    /// `rmw_cyclonedds_cpp` materializes a single ROS 2 action under
    /// `<ns>/<name>/_action/` as 3 service pairs (`send_goal`, `cancel_goal`,
    /// `get_result`) plus 2 topics (`feedback`, `status`).
    public func actionTopicNames(
        namespace: String,
        actionName: String,
        actionTypeName: String
    ) -> ActionTopicNames {
        let cleanNS = TypeNameConverter.stripLeadingSlash(namespace)
        let cleanAction = TypeNameConverter.stripLeadingSlash(actionName)
        let actionPath = cleanNS.isEmpty ? cleanAction : "\(cleanNS)/\(cleanAction)"
        let basePath = "\(actionPath)/_action"

        return ActionTopicNames(
            sendGoalRequestTopic: "rq/\(basePath)/send_goalRequest",
            sendGoalReplyTopic: "rr/\(basePath)/send_goalReply",
            cancelGoalRequestTopic: "rq/\(basePath)/cancel_goalRequest",
            cancelGoalReplyTopic: "rr/\(basePath)/cancel_goalReply",
            getResultRequestTopic: "rq/\(basePath)/get_resultRequest",
            getResultReplyTopic: "rr/\(basePath)/get_resultReply",
            feedbackTopic: "rt/\(basePath)/feedback",
            statusTopic: "rt/\(basePath)/status",

            sendGoalRequestTypeName: TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "SendGoal", suffix: "Request"),
            sendGoalReplyTypeName: TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "SendGoal", suffix: "Response"),
            cancelGoalRequestTypeName: TypeNameConverter.cancelGoalRequestDDSTypeName,
            cancelGoalReplyTypeName: TypeNameConverter.cancelGoalResponseDDSTypeName,
            getResultRequestTypeName: TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "GetResult", suffix: "Request"),
            getResultReplyTypeName: TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "GetResult", suffix: "Response"),
            feedbackTypeName: TypeNameConverter.toDDSActionRoleTypeName(
                actionTypeName, role: "FeedbackMessage", suffix: nil),
            statusTypeName: TypeNameConverter.goalStatusArrayDDSTypeName
        )
    }
}
