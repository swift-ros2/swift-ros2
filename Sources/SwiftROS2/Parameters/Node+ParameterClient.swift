// Factory on ROS2Node that constructs a
// `ROS2ParameterClient` for a remote node by name. The extension is the
// idiomatic entry point; constructing `ROS2ParameterClient` directly is
// supported but discouraged.

extension ROS2Node {
    /// Construct a `ROS2ParameterClient` against a remote node's six
    /// parameter services. The remote name must be the fully-qualified
    /// node name (e.g. `/talker`, `/ns/talker`).
    public func createParameterClient(
        remoteNode: String,
        defaultTimeout: Duration = .seconds(5)
    ) async throws -> ROS2ParameterClient {
        try await ROS2ParameterClient(
            node: self, remoteNodeName: remoteNode, defaultTimeout: defaultTimeout)
    }
}
