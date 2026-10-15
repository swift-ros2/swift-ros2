// A Swift-public client that talks to a remote node's six rcl_interfaces
// parameter services. Each public method
// is a thin wrapper: WireBridge encode → ROS2Client.call → WireBridge
// decode. No transport-level work — every byte goes through the existing
// ROS2Client / TransportClient stack.

import Foundation
import SwiftROS2Messages

/// High-level client for a remote node's six parameter services.
///
/// Construct one via `ROS2Node.createParameterClient(remoteNode:)`.
///
/// ```swift
/// let pc = try await node.createParameterClient(remoteNode: "/talker")
/// try await pc.waitForService(timeout: .seconds(2))
/// _ = try await pc.setParameters([
///     ROS2Parameter(name: "rate", value: .integer(60))
/// ])
/// ```
public final class ROS2ParameterClient: @unchecked Sendable {
    public let remoteNodeName: String
    public let defaultTimeout: Duration

    private let getParametersClient: ROS2Client<GetParametersSrv>
    private let setParametersClient: ROS2Client<SetParametersSrv>
    private let setParametersAtomicallyClient: ROS2Client<SetParametersAtomicallySrv>
    private let listParametersClient: ROS2Client<ListParametersSrv>
    private let describeParametersClient: ROS2Client<DescribeParametersSrv>
    private let getParameterTypesClient: ROS2Client<GetParameterTypesSrv>

    private let lock = NSLock()
    private var closed = false
    private let teardownQueue: TeardownQueue

    public init(
        node: ROS2Node,
        remoteNodeName: String,
        defaultTimeout: Duration = .seconds(5)
    ) async throws {
        self.remoteNodeName = remoteNodeName
        self.defaultTimeout = defaultTimeout
        self.teardownQueue = node.context.teardownQueue
        self.getParametersClient = try await node.createClient(
            GetParametersSrv.self, name: "\(remoteNodeName)/get_parameters")
        self.setParametersClient = try await node.createClient(
            SetParametersSrv.self, name: "\(remoteNodeName)/set_parameters")
        self.setParametersAtomicallyClient = try await node.createClient(
            SetParametersAtomicallySrv.self,
            name: "\(remoteNodeName)/set_parameters_atomically")
        self.listParametersClient = try await node.createClient(
            ListParametersSrv.self, name: "\(remoteNodeName)/list_parameters")
        self.describeParametersClient = try await node.createClient(
            DescribeParametersSrv.self,
            name: "\(remoteNodeName)/describe_parameters")
        self.getParameterTypesClient = try await node.createClient(
            GetParameterTypesSrv.self,
            name: "\(remoteNodeName)/get_parameter_types")
    }

    /// Closes the six service clients and returns once they are closed.
    ///
    /// The closes run on the serial teardown queue of the node's context (see
    /// ``ROS2Context/shutdown()``), so a close that blocks on a stalled
    /// transport never holds a thread of the cooperative pool. A later call
    /// returns at once without closing anything. As with the other teardowns,
    /// do not block a swift-ros2 callback until this close finishes.
    public func close() async {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        await teardownQueue.run { [self] in
            cancelClients()
        }
    }

    private func cancelClients() {
        teardownQueue.assertOnQueue()
        getParametersClient.cancel()
        setParametersClient.cancel()
        setParametersAtomicallyClient.cancel()
        listParametersClient.cancel()
        describeParametersClient.cancel()
        getParameterTypesClient.cancel()
    }
}

extension ROS2ParameterClient {
    public func getParameters(
        _ names: [String], timeout: Duration? = nil
    ) async throws -> [ROS2ParameterValue] {
        let req = GetParametersRequest(names: names)
        let resp = try await getParametersClient.call(
            req, timeout: timeout ?? defaultTimeout)
        return resp.values.map { ROS2ParameterValue(wire: $0) }
    }
}

extension ROS2ParameterClient {
    public func setParameters(
        _ ps: [ROS2Parameter], timeout: Duration? = nil
    ) async throws -> [ROS2SetParametersResult] {
        let req = SetParametersRequest(parameters: ps.map { $0.toWire() })
        let resp = try await setParametersClient.call(
            req, timeout: timeout ?? defaultTimeout)
        return resp.results.map {
            ROS2SetParametersResult(successful: $0.successful, reason: $0.reason)
        }
    }

    public func setParametersAtomically(
        _ ps: [ROS2Parameter], timeout: Duration? = nil
    ) async throws -> ROS2SetParametersResult {
        let req = SetParametersAtomicallyRequest(parameters: ps.map { $0.toWire() })
        let resp = try await setParametersAtomicallyClient.call(
            req, timeout: timeout ?? defaultTimeout)
        return ROS2SetParametersResult(
            successful: resp.result.successful, reason: resp.result.reason)
    }
}

extension ROS2ParameterClient {
    public func listParameters(
        prefixes: [String] = [], depth: UInt64 = 0, timeout: Duration? = nil
    ) async throws -> ROS2ListParametersResult {
        let req = ListParametersRequest(prefixes: prefixes, depth: depth)
        let resp = try await listParametersClient.call(
            req, timeout: timeout ?? defaultTimeout)
        return ROS2ListParametersResult(
            names: resp.result.names, prefixes: resp.result.prefixes)
    }

    public func describeParameters(
        _ names: [String], timeout: Duration? = nil
    ) async throws -> [ROS2ParameterDescriptor] {
        let req = DescribeParametersRequest(names: names)
        let resp = try await describeParametersClient.call(
            req, timeout: timeout ?? defaultTimeout)
        return resp.descriptors.map { ROS2ParameterDescriptor(wire: $0) }
    }

    public func getParameterTypes(
        _ names: [String], timeout: Duration? = nil
    ) async throws -> [ROS2ParameterType] {
        let req = GetParameterTypesRequest(names: names)
        let resp = try await getParameterTypesClient.call(
            req, timeout: timeout ?? defaultTimeout)
        return resp.types.map { ROS2ParameterType(rawValue: $0) ?? .notSet }
    }
}

extension ROS2ParameterClient {
    /// Wait until every one of the six underlying clients reports that a
    /// matching service is reachable, or until `timeout` elapses. Each
    /// child wait sees the same `timeout` budget; whichever child throws
    /// first cancels the rest via the task group.
    public func waitForService(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for cli in allClients(timeout: timeout) {
                group.addTask { try await cli() }
            }
            try await group.waitForAll()
        }
    }

    /// Type-erases the six client `waitForService` calls into a list of
    /// throwing closures so the task group iterates uniformly.
    private func allClients(
        timeout: Duration
    ) -> [@Sendable () async throws -> Void] {
        [
            { [getParametersClient] in
                try await getParametersClient.waitForService(timeout: timeout)
            },
            { [setParametersClient] in
                try await setParametersClient.waitForService(timeout: timeout)
            },
            { [setParametersAtomicallyClient] in
                try await setParametersAtomicallyClient.waitForService(timeout: timeout)
            },
            { [listParametersClient] in
                try await listParametersClient.waitForService(timeout: timeout)
            },
            { [describeParametersClient] in
                try await describeParametersClient.waitForService(timeout: timeout)
            },
            { [getParameterTypesClient] in
                try await getParameterTypesClient.waitForService(timeout: timeout)
            },
        ]
    }
}
