// Service.swift
// ROS 2 Service Server (typed wrapper around TransportService)

import Foundation
import SwiftROS2Messages
import SwiftROS2Transport

/// ROS 2 service server for a specific ``ROS2ServiceType``.
///
/// Construct one via ``ROS2Node/createService(_:name:qos:handler:)``. The
/// node retains the server and walks `cancel()` / close on `node.destroy()`.
///
/// ```swift
/// let svc = try await node.createService(TriggerSrv.self, name: "/trigger") { _ in
///     TriggerSrv.Response(success: true, message: "ok")
/// }
/// ```
public final class ROS2Service<S: ROS2ServiceType>: @unchecked Sendable, NodeEntity {
    private let transport: any TransportService
    private let lock = NSLock()
    private var closed = false

    /// The service name supplied at construction (e.g. `/trigger`).
    public var name: String { transport.name }

    /// Whether the service is still active.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && transport.isActive
    }

    init(transport: any TransportService) {
        self.transport = transport
    }

    /// Cancel the service, closing the underlying transport handle.
    public func cancel() {
        try? closeEntity()
    }

    var nodeEntityKind: NodeEntityKind { .service }

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
