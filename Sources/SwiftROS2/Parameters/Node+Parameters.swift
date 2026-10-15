// Public Parameter API on ROS2Node: declare / get / set / list / describe.
// Services, /parameter_events and callbacks live in the sibling files.

extension ROS2Node {
    @discardableResult
    public func declareParameter<T: ROS2ParameterConvertible>(
        _ name: String,
        default value: T,
        descriptor: ROS2ParameterDescriptor = ROS2ParameterDescriptor(),
        ignoreOverride: Bool = false  // reserved for a parameter-override layer; not used yet
    ) async throws -> T {
        var d = descriptor
        // Always pin the descriptor's name to the declared name. If the caller
        // supplied a non-empty name that differs, we silently override rather
        // than throwing — the parameter's storage key is the canonical name
        // and a divergent descriptor.name would later confuse describeParameter.
        d.name = name
        if d.type == .notSet { d.type = T.parameterType }
        let stored = try await parameterStore.declare(
            name: name, value: value.parameterValue, descriptor: d)
        return try T(parameterValue: stored)
    }

    public func undeclareParameter(_ name: String) async throws {
        try await parameterStore.undeclare(name: name)
    }

    public func hasParameter(_ name: String) async -> Bool {
        await parameterStore.has(name: name)
    }

    public func listParameters(
        prefixes: [String] = [], depth: UInt64 = 0
    ) async -> ROS2ListParametersResult {
        await parameterStore.list(prefixes: prefixes, depth: depth)
    }

    public func getParameter(_ name: String) async throws -> ROS2Parameter {
        try await parameterStore.get(name: name)
    }

    public func getParameterOrDefault<T: ROS2ParameterConvertible>(
        _ name: String, default value: T
    ) async -> T {
        do {
            let p = try await parameterStore.get(name: name)
            return try T(parameterValue: p.value)
        } catch {
            return value
        }
    }

    @discardableResult
    public func setParameter(
        _ p: ROS2Parameter
    ) async -> ROS2SetParametersResult {
        await parameterStore.set(p)
    }

    @discardableResult
    public func setParameters(
        _ ps: [ROS2Parameter]
    ) async -> [ROS2SetParametersResult] {
        await parameterStore.setMany(ps)
    }

    @discardableResult
    public func setParametersAtomically(
        _ ps: [ROS2Parameter]
    ) async -> ROS2SetParametersResult {
        await parameterStore.setAtomically(ps)
    }

    public func describeParameter(
        _ name: String
    ) async throws -> ROS2ParameterDescriptor {
        try await parameterStore.describe(name: name)
    }
}
