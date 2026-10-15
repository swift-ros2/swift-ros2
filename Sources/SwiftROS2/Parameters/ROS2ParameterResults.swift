/// Outcome of a single attempted parameter set.
///
/// Mirrors `rcl_interfaces/msg/SetParametersResult` — failures are reported
/// via `successful = false` plus a human-readable `reason`, never via thrown
/// errors. This matches what crosses the wire from the parameter services.
public struct ROS2SetParametersResult: Sendable, Equatable {
    public var successful: Bool
    public var reason: String

    public init(successful: Bool, reason: String = "") {
        self.successful = successful
        self.reason = reason
    }

    public static func success() -> ROS2SetParametersResult {
        ROS2SetParametersResult(successful: true)
    }

    public static func failure(reason: String) -> ROS2SetParametersResult {
        ROS2SetParametersResult(successful: false, reason: reason)
    }
}

/// Result of a `listParameters` query.
///
/// `names` is the matched flat parameter names; `prefixes` is every distinct
/// dotted ancestor seen across those names (sorted, deduplicated). Mirrors
/// `rcl_interfaces/msg/ListParametersResult`.
public struct ROS2ListParametersResult: Sendable, Equatable {
    public var names: [String]
    public var prefixes: [String]

    public init(names: [String] = [], prefixes: [String] = []) {
        self.names = names
        self.prefixes = prefixes
    }
}
