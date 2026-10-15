// ActionServerHandler.swift
// User-supplied protocol for ROS 2 Action servers.

import SwiftROS2Messages

/// User-implemented protocol for an action server.
///
/// Typically implemented as an `actor`. The umbrella `ROS2ActionServer<H>`
/// owns one Task per accepted goal and dispatches into these methods.
///
/// Lifecycle: `handleGoal` decides accept / reject; on accept the umbrella
/// spawns a Task that calls `execute`; if a cancel arrives during execution,
/// the umbrella calls `handleCancel` (the handler decides accept / reject) and
/// — on accept — cancels the executing Task. The handler's `execute`
/// implementation must check `await handle.isCancelRequested` periodically and
/// throw `CancellationError` (or any error) to abort.
public protocol ActionServerHandler: Sendable {
    associatedtype Action: ROS2Action

    /// Decide whether to accept a new goal. Called once per inbound goal,
    /// before the umbrella spawns the executing Task.
    func handleGoal(_ goal: Action.Goal) async -> GoalResponse

    /// Decide whether to honor a cancel request. Called when the client side
    /// requests cancellation of a goal that is currently executing.
    func handleCancel(_ handle: ActionGoalHandle<Action>) async -> CancelResponse

    /// Run the goal. Must produce the final `Action.Result` or throw to abort
    /// (the umbrella translates the throw into `ActionGoalStatus.aborted`).
    /// Periodically check `await handle.isCancelRequested` and throw
    /// `CancellationError` when set to honor a cooperatively-handled cancel.
    func execute(_ handle: ActionGoalHandle<Action>) async throws -> Action.Result

    /// The result sent with a goal that ends without one: canceled, aborted,
    /// or unknown to the server.
    ///
    /// A ROS 2 GetResult response always carries a complete result, so the
    /// umbrella answers such a goal with its status and this result, as
    /// rclcpp and rclpy answer with a default-constructed one. The default
    /// implementation returns a zero-valued result: every number zero, every
    /// `bool` false, every string and sequence empty, at every nesting level.
    /// That is what rosidl builds for every field without an IDL default
    /// value. Override it to report those defaults too, for example
    /// `geometry_msgs/Quaternion`'s `w = 1.0`:
    ///
    /// ```swift
    /// func defaultResult() -> Action.Result { Action.Result() }
    /// ```
    ///
    /// If it throws, the response carries the status alone, which only a
    /// swift-ros2 client can read.
    func defaultResult() async throws -> Action.Result
}

extension ActionServerHandler {
    /// Returns a zero-valued result; see ``ActionServerHandler/defaultResult()``.
    public func defaultResult() async throws -> Action.Result {
        try ZeroValuedResult.make(Action.Result.self)
    }
}
