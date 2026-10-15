// Bind the six rcl_interfaces parameter service handlers on a node's
// fully-qualified name. Handlers route through the node's ParameterStore.

import RclInterfaces
import SwiftROS2Messages

extension ROS2Node {
    /// Register the six standard parameter services on
    /// `<fullyQualifiedName>/<service>`.
    ///
    /// `ROS2Context.createNode(...)` calls this automatically when
    /// `ROS2NodeOptions.startParameterServices` is `true` (the default).
    /// Calling it manually after opting out is supported. A repeated call
    /// after a successful registration is a no-op; a call that retries
    /// after a previous failed attempt re-runs the registration.
    public func startParameterServices() async throws {
        guard await parameterStore.markServicesStarted() else { return }

        let store = parameterStore  // captured by handler closures (actor → Sendable)
        let fqn = fullyQualifiedName

        do {
            _ = try await createService(
                GetParametersSrv.self,
                name: "\(fqn)/get_parameters",
                qos: .servicesDefault
            ) { req in
                await Self.handleGetParameters(req, store: store)
            }

            _ = try await createService(
                SetParametersSrv.self,
                name: "\(fqn)/set_parameters",
                qos: .servicesDefault
            ) { req in
                await Self.handleSetParameters(req, store: store)
            }

            _ = try await createService(
                SetParametersAtomicallySrv.self,
                name: "\(fqn)/set_parameters_atomically",
                qos: .servicesDefault
            ) { req in
                await Self.handleSetParametersAtomically(req, store: store)
            }

            _ = try await createService(
                ListParametersSrv.self,
                name: "\(fqn)/list_parameters",
                qos: .servicesDefault
            ) { req in
                await Self.handleListParameters(req, store: store)
            }

            _ = try await createService(
                DescribeParametersSrv.self,
                name: "\(fqn)/describe_parameters",
                qos: .servicesDefault
            ) { req in
                await Self.handleDescribeParameters(req, store: store)
            }

            _ = try await createService(
                GetParameterTypesSrv.self,
                name: "\(fqn)/get_parameter_types",
                qos: .servicesDefault
            ) { req in
                await Self.handleGetParameterTypes(req, store: store)
            }
        } catch {
            // Mid-registration failure: release the latch so a future
            // call can retry. The partially-registered services live on
            // the node's services array; the node owner (Context.createNode
            // or the caller of this method directly) is responsible for
            // closing them via node.destroy() if a clean retry is wanted.
            await parameterStore.resetServicesStarted()
            throw error
        }

        // Wire the /parameter_events emitter here (rather than in
        // Context.createNode) so a manual `startParameterServices()` after
        // an opt-out construction also gets event publishing — keeping
        // the two start paths consistent.
        await installParameterEventEmitter()
    }

    // MARK: - Service handlers
    //
    // Each handler is a `static` async function so it doesn't capture `self`
    // implicitly — only the Sendable `ParameterStore` actor crosses the
    // closure boundary, which keeps the @Sendable handler closure surface
    // minimal.

    static func handleGetParameters(
        _ request: GetParametersRequest, store: ParameterStore
    ) async -> GetParametersResponse {
        var values: [RclInterfaces.ParameterValue] = []
        values.reserveCapacity(request.names.count)
        for name in request.names {
            let entry = await store.entry(name: name)
            let swiftValue = entry?.value ?? .notSet
            values.append(swiftValue.toWire())
        }
        return GetParametersResponse(values: values)
    }

    static func handleSetParameters(
        _ request: SetParametersRequest, store: ParameterStore
    ) async -> SetParametersResponse {
        var results: [RclInterfaces.SetParametersResult] = []
        results.reserveCapacity(request.parameters.count)
        for wireParam in request.parameters {
            let swiftParam = ROS2Parameter(wire: wireParam)
            let r = await store.set(swiftParam)
            results.append(
                RclInterfaces.SetParametersResult(
                    successful: r.successful, reason: r.reason))
        }
        return SetParametersResponse(results: results)
    }

    static func handleSetParametersAtomically(
        _ request: SetParametersAtomicallyRequest, store: ParameterStore
    ) async -> SetParametersAtomicallyResponse {
        let swiftParams = request.parameters.map { ROS2Parameter(wire: $0) }
        let r = await store.setAtomically(swiftParams)
        return SetParametersAtomicallyResponse(
            result: RclInterfaces.SetParametersResult(
                successful: r.successful, reason: r.reason))
    }

    static func handleListParameters(
        _ request: ListParametersRequest, store: ParameterStore
    ) async -> ListParametersResponse {
        let r = await store.list(prefixes: request.prefixes, depth: request.depth)
        return ListParametersResponse(
            result: RclInterfaces.ListParametersResult(
                names: r.names, prefixes: r.prefixes))
    }

    static func handleDescribeParameters(
        _ request: DescribeParametersRequest, store: ParameterStore
    ) async -> DescribeParametersResponse {
        var out: [RclInterfaces.ParameterDescriptor] = []
        out.reserveCapacity(request.names.count)
        for name in request.names {
            if let entry = await store.entry(name: name) {
                out.append(entry.descriptor.toWire())
            } else {
                // rclcpp returns a descriptor whose name echoes the request and
                // whose type slot is PARAMETER_NOT_SET. Mirror that.
                var stub = RclInterfaces.ParameterDescriptor()
                stub.name = name
                stub.type = 0
                out.append(stub)
            }
        }
        return DescribeParametersResponse(descriptors: out)
    }

    static func handleGetParameterTypes(
        _ request: GetParameterTypesRequest, store: ParameterStore
    ) async -> GetParameterTypesResponse {
        var types: [UInt8] = []
        types.reserveCapacity(request.names.count)
        for name in request.names {
            let entry = await store.entry(name: name)
            types.append(entry?.descriptor.type.rawValue ?? 0)
        }
        return GetParameterTypesResponse(types: types)
    }
}
