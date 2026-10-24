// Client.swift
// ROS 2 Service Client (typed wrapper around TransportClient)

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2Transport

/// ROS 2 service client for a specific ``ROS2ServiceType``.
///
/// Construct one via ``ROS2Node/createClient(_:name:qos:)``. Encodes the
/// typed request into CDR, calls the underlying transport, and decodes the
/// CDR response back into `S.Response`.
///
/// ```swift
/// let cli = try await node.createClient(TriggerSrv.self, name: "/trigger")
/// try await cli.waitForService(timeout: .seconds(2))
/// let resp = try await cli.call(.init(), timeout: .seconds(5))
/// ```
public final class ROS2Client<S: ROS2ServiceType>: @unchecked Sendable, NodeEntity {
    private let transport: any TransportClient
    /// The distribution whose message schemas the request encoder and response decoder use.
    private let distro: ROS2Distro
    private let lock = NSLock()
    private var closed = false

    /// The service name supplied at construction.
    public var name: String { transport.name }

    /// Whether the client is still active.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && transport.isActive
    }

    init(transport: any TransportClient, distro: ROS2Distro) {
        self.transport = transport
        self.distro = distro
    }

    /// Wait until a matching service is reachable, or throw if `timeout` elapses.
    public func waitForService(timeout: Duration) async throws {
        do {
            try await transport.waitForService(timeout: timeout)
        } catch {
            throw ServiceError.mapping(error)
        }
    }

    /// Send `request` and await the typed response.
    public func call(_ request: S.Request, timeout: Duration) async throws -> S.Response {
        lock.lock()
        if closed {
            lock.unlock()
            throw ServiceError.clientClosed
        }
        lock.unlock()

        // Encode the typed request into CDR.
        let requestCDR: Data
        do {
            let encoder = CDREncoder(distro: distro)
            encoder.writeEncapsulationHeader()
            try request.encode(to: encoder)
            requestCDR = encoder.getData()
        } catch {
            throw ServiceError.requestEncodingFailed(error.localizedDescription)
        }

        // Send and await reply.
        let responseCDR: Data
        do {
            responseCDR = try await transport.call(requestCDR: requestCDR, timeout: timeout)
        } catch {
            throw ServiceError.mapping(error)
        }

        // Decode.
        do {
            let decoder = try CDRDecoder(data: responseCDR, distro: distro)
            return try S.Response(from: decoder)
        } catch {
            throw ServiceError.responseDecodingFailed(error.localizedDescription)
        }
    }

    /// Cancel the client, closing the underlying transport handle.
    public func cancel() {
        try? closeEntity()
    }

    var nodeEntityKind: NodeEntityKind { .client }

    func closeEntity() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        try? transport.close()
    }
}
