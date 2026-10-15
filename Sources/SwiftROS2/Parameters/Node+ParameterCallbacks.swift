// Parameter callback registration entry points on
// `ROS2Node`. Three flavours mirroring rclcpp — pre-set (proposes
// mutations to the incoming list), on-set (vetoes), post-set (observes).
// Each returns an opaque `ROS2ParameterCallbackHandle`. The store retains
// the closure; callbacks stay active until `removeParameterCallback(_:)`
// is called — dropping the returned handle does **not** detach.

extension ROS2Node {
    /// Register a pre-set callback. Runs first, on the store's actor,
    /// before validation. May rewrite the proposed parameter list (e.g.
    /// inject co-dependent parameters).
    @discardableResult
    public func setPreSetParametersCallback(
        _ cb: @escaping @Sendable (inout [ROS2Parameter]) -> Void
    ) async -> ROS2ParameterCallbackHandle {
        await parameterStore.registerPreSet(cb)
    }

    /// Register an on-set callback. Runs after descriptor validation, on
    /// the store's actor. Returning `successful: false` vetoes the entire
    /// batch (or the single item, when called via `setParameter` /
    /// `setParameters`). Vetoed batches emit no `ParameterEvent`.
    @discardableResult
    public func setOnSetParametersCallback(
        _ cb: @escaping @Sendable ([ROS2Parameter]) -> ROS2SetParametersResult
    ) async -> ROS2ParameterCallbackHandle {
        await parameterStore.registerOnSet(cb)
    }

    /// Register a post-set callback. Runs after a successful write, on the
    /// store's actor. Receives only the parameters that were actually
    /// applied. Observation only — return value is `Void`.
    @discardableResult
    public func setPostSetParametersCallback(
        _ cb: @escaping @Sendable ([ROS2Parameter]) -> Void
    ) async -> ROS2ParameterCallbackHandle {
        await parameterStore.registerPostSet(cb)
    }

    /// Detach a previously registered callback. Returns `true` if the
    /// handle was found and removed, `false` if no such registration
    /// exists (or it had already been removed). Idempotent.
    @discardableResult
    public func removeParameterCallback(
        _ handle: ROS2ParameterCallbackHandle
    ) async -> Bool {
        await parameterStore.unregisterCallback(handle)
    }
}
