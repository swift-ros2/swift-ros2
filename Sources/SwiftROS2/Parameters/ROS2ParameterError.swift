/// Typed errors thrown by the throwing parameter APIs (`declareParameter`,
/// `undeclareParameter`, `getParameter`, `describeParameter`).
///
/// Non-throwing APIs such as `setParameter` surface failures (a read-only
/// parameter, a value out of the descriptor's range, a type change) via
/// `ROS2SetParametersResult.reason` instead.
public enum ROS2ParameterError: Error, Sendable, Equatable {
    case alreadyDeclared(name: String)
    case notDeclared(name: String)
    case invalidType(
        name: String, expected: ROS2ParameterType, got: ROS2ParameterType)
    case invalidValue(name: String, reason: String)
}
