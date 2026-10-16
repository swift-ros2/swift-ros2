// TypeNameConverter.swift
// Utilities for ROS 2 / DDS type name conversion

import Foundation

/// Shared utilities for ROS 2 type and topic name conversion
public enum TypeNameConverter {
    /// DDS type name for `action_msgs/srv/CancelGoal_Request` — fixed across
    /// every action regardless of the per-action `Goal`/`Result`/`Feedback`
    /// types. Shared by both wire codecs to avoid drift.
    public static let cancelGoalRequestDDSTypeName = "action_msgs::srv::dds_::CancelGoal_Request_"

    /// DDS type name for `action_msgs/srv/CancelGoal_Response` — fixed across
    /// every action.
    public static let cancelGoalResponseDDSTypeName = "action_msgs::srv::dds_::CancelGoal_Response_"

    /// DDS type name of the `action_msgs/srv/CancelGoal` service — the type of
    /// every action's `_action/cancel_goal` service in rmw_zenoh key expressions
    /// and liveliness tokens.
    public static let cancelGoalServiceDDSTypeName = "action_msgs::srv::dds_::CancelGoal_"

    /// DDS type name for `action_msgs/msg/GoalStatusArray` — the fixed type
    /// carried on every action's `_action/status` topic.
    public static let goalStatusArrayDDSTypeName = "action_msgs::msg::dds_::GoalStatusArray_"

    /// Strip leading "/" from a namespace
    public static func stripLeadingSlash(_ namespace: String) -> String {
        namespace.hasPrefix("/") ? String(namespace.dropFirst()) : namespace
    }

    /// Convert ROS type name to DDS format
    ///
    /// "sensor_msgs/msg/Imu" -> "sensor_msgs::msg::dds_::Imu_"
    public static func toDDSTypeName(_ typeName: String) -> String {
        ddsName(typeName, suffix: "")
    }

    /// Convert a ROS service type name to the DDS name of the service type.
    ///
    /// "std_srvs/srv/Trigger" -> "std_srvs::srv::dds_::Trigger_"
    ///
    /// rmw_zenoh_cpp names a service by this type (its response type name without
    /// `Response_`) in the service key expression and liveliness tokens.
    public static func toDDSServiceTypeName(_ serviceTypeName: String) -> String {
        toDDSTypeName(serviceTypeName)
    }

    /// Convert a ROS service type name to the DDS request type name.
    ///
    /// "example_interfaces/srv/AddTwoInts" -> "example_interfaces::srv::dds_::AddTwoInts_Request_"
    public static func toDDSServiceRequestTypeName(_ serviceTypeName: String) -> String {
        toDDSServiceSuffixedTypeName(serviceTypeName, suffix: "Request")
    }

    /// Convert a ROS service type name to the DDS response type name.
    ///
    /// "example_interfaces/srv/AddTwoInts" -> "example_interfaces::srv::dds_::AddTwoInts_Response_"
    public static func toDDSServiceResponseTypeName(_ serviceTypeName: String) -> String {
        toDDSServiceSuffixedTypeName(serviceTypeName, suffix: "Response")
    }

    private static func toDDSServiceSuffixedTypeName(_ serviceTypeName: String, suffix: String) -> String {
        ddsName(serviceTypeName, suffix: "_\(suffix)")
    }

    /// Convert a ROS action type name to the DDS type name for one of its
    /// per-action synthesized roles (`SendGoal`, `GetResult`, `FeedbackMessage`).
    ///
    /// Does **not** handle `cancel_goal` — that role uses the fixed type
    /// ``cancelGoalRequestDDSTypeName`` / ``cancelGoalResponseDDSTypeName``
    /// from `action_msgs/srv/CancelGoal` regardless of the action — nor
    /// `status`, which uses the fixed ``goalStatusArrayDDSTypeName``. Callers
    /// should branch on those role tags before reaching for this helper.
    ///
    /// Examples:
    /// - `("example_interfaces/action/Fibonacci", role: "SendGoal", suffix: "Request")`
    ///   → `example_interfaces::action::dds_::Fibonacci_SendGoal_Request_`
    /// - `("example_interfaces/action/Fibonacci", role: "FeedbackMessage", suffix: nil)`
    ///   → `example_interfaces::action::dds_::Fibonacci_FeedbackMessage_`
    ///
    /// `suffix` is `"Request"` / `"Response"` for the two per-action service
    /// roles, and `nil` for `FeedbackMessage` (which has no request/response
    /// split).
    public static func toDDSActionRoleTypeName(
        _ actionTypeName: String,
        role: String,
        suffix: String?
    ) -> String {
        ddsName(actionTypeName, suffix: "_\(role)" + (suffix.map { "_\($0)" } ?? ""))
    }

    /// Convert a DDS type name back to the ROS form: the inverse of ``toDDSTypeName(_:)``.
    ///
    /// "nav_msgs::msg::dds_::OccupancyGrid_" -> "nav_msgs/msg/OccupancyGrid"
    ///
    /// A name of the `<pkg>::<kind>::dds_::<Type>_` shape loses the `dds_` segment and
    /// one trailing `_`. A name of any other shape has every `::` replaced by `/` and is
    /// otherwise kept, so a graph entry with an unexpected type name is still listed.
    package static func toROSTypeName(_ ddsName: String) -> String {
        let parts = ddsName.components(separatedBy: "::")
        guard parts.count == 4, parts[2] == "dds_", parts[3].count > 1, parts[3].hasSuffix("_"),
            !parts[0].isEmpty, !parts[1].isEmpty
        else {
            return parts.joined(separator: "/")
        }
        return "\(parts[0])/\(parts[1])/\(parts[3].dropLast())"
    }

    /// `pkg/kind/Name` → `pkg::kind::dds_::Name<suffix>_`. A name that is not three
    /// `/`-separated segments has its `/` turned into `::` and gets `<suffix>_`.
    private static func ddsName(_ rosName: String, suffix: String) -> String {
        let parts = rosName.split(separator: "/", maxSplits: .max, omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            return rosName.replacingOccurrences(of: "/", with: "::") + suffix + "_"
        }
        return "\(parts[0])::\(parts[1])::dds_::\(parts[2])\(suffix)_"
    }
}
