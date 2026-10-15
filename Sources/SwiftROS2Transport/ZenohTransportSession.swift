// ZenohTransportSession.swift
// TransportSession implementation using ZenohClientProtocol
//
// Ported from Conduit's production-proven implementation.
// Uses protocol injection for C bridge independence.

import Foundation
import SwiftROS2Wire

// MARK: - Zenoh Transport Session

/// TransportSession implementation using Zenoh via ZenohClientProtocol
///
/// The client protocol is injected at construction time, allowing the
/// consuming app (e.g., Conduit) to provide its own C bridge wrapper.
package final class ZenohTransportSession: TransportSession, @unchecked Sendable {
    let client: any ZenohClientProtocol
    var config: TransportConfig?
    var publishers: [String: ZenohTransportPublisher] = [:]
    var serviceServers: [ZenohTransportServiceServerImpl] = []
    var serviceClients: [ZenohTransportServiceClientImpl] = []
    var actionServers: [ZenohTransportActionServerImpl] = []
    var actionClients: [ZenohTransportActionClientImpl] = []
    /// Node ids of the nodes whose services and actions this session announces,
    /// keyed by `<namespace>|<name>`. Guarded by `publishersLock`.
    var nodeIds: [String: String] = [:]
    let publishersLock = NSLock()
    let entityManager: EntityManager
    let gidManager: GIDManager

    /// Detected or configured wire mode (set after open)
    package private(set) var resolvedWireMode: ROS2Distro?

    package var transportType: TransportType { .zenoh }

    package var isConnected: Bool {
        client.isSessionHealthy()
    }

    package var sessionId: String {
        (try? client.getSessionId()) ?? "unknown"
    }

    /// Create a Zenoh transport session
    /// - Parameters:
    ///   - client: Zenoh client protocol implementation (wraps C bridge)
    ///   - entityManager: Entity ID generator (optional, creates new if nil)
    ///   - gidManager: GID manager (optional, creates new if nil)
    package init(
        client: any ZenohClientProtocol,
        entityManager: EntityManager? = nil,
        gidManager: GIDManager? = nil
    ) {
        self.client = client
        self.entityManager = entityManager ?? EntityManager()
        self.gidManager = gidManager ?? GIDManager()
    }

    package func open(config: TransportConfig) async throws {
        guard config.type == .zenoh else {
            throw TransportError.invalidConfiguration("Expected Zenoh configuration, got \(config.type)")
        }

        guard let locator = config.zenohLocator, !locator.isEmpty else {
            throw TransportError.invalidConfiguration("Zenoh locator is required")
        }

        do {
            try config.validate()

            let timeout = config.connectionTimeout > 0 ? config.connectionTimeout : 10.0
            try await connectWithTimeout(locator: locator, timeout: timeout)

            self.config = config

            // Resolve wire mode: use explicit config or default to jazzy
            if let wireMode = config.wireMode {
                self.resolvedWireMode = wireMode
            } else {
                // Auto-detection requires VersionDetector (provided by SwiftROS2 module)
                // Default to jazzy if not configured
                self.resolvedWireMode = config.wireMode ?? .jazzy
            }
        } catch let error as ZenohError {
            throw TransportError.connectionFailed(error.localizedDescription ?? "Zenoh connection failed")
        } catch let error as TransportError {
            throw error
        }
    }

    package func close() throws {
        let pubs = takeAllPublishers()
        for pub in pubs {
            try? pub.close()
        }

        let servers = takeAllServiceServers()
        for server in servers {
            try? server.close()
        }

        let clients = takeAllServiceClients()
        for serviceClient in clients {
            try? serviceClient.close()
        }

        let aServers = takeAllActionServers()
        for s in aServers {
            try? s.close()
        }
        let aClients = takeAllActionClients()
        for c in aClients {
            try? c.close()
        }

        // A session that never opened, or whose open failed, has nothing to
        // close: that is a no-op, not an error.
        guard config != nil else { return }

        do {
            try client.close()
        } catch {
            throw TransportError.sessionClosed
        }

        resolvedWireMode = nil
        config = nil
    }

    package func checkHealth() -> Bool {
        client.isSessionHealthy()
    }

    // MARK: - Node Identity

    /// The node an entity is announced under. Every entity of one node shares its node
    /// id, which is how rmw_zenoh_cpp's graph groups them (`ros2 node info`). Without
    /// a node name, the entity belongs to a `swift_ros2_node` in the root namespace.
    func nodeIdentity(name: String?, namespace: String?) -> ZenohNodeIdentity {
        let resolvedName = (name?.isEmpty == false ? name : nil) ?? "swift_ros2_node"
        let resolvedNamespace = ZenohNodeIdentity.normalizedNamespace(namespace)
        let key = "\(resolvedNamespace)|\(resolvedName)"
        publishersLock.lock()
        defer { publishersLock.unlock() }
        if let id = nodeIds[key] {
            return ZenohNodeIdentity(namespace: resolvedNamespace, name: resolvedName, id: id)
        }
        let id = String(entityManager.getNextEntityId())
        nodeIds[key] = id
        return ZenohNodeIdentity(namespace: resolvedNamespace, name: resolvedName, id: id)
    }

    // MARK: - Topic Path Helpers

    func extractNamespace(from topic: String) -> String {
        let components = topic.split(separator: "/").map(String.init)
        if components.count > 1 {
            return "/" + components.dropLast().joined(separator: "/")
        }
        return "/"
    }

    func extractTopicName(from topic: String) -> String {
        let components = topic.split(separator: "/").map(String.init)
        return components.last ?? topic
    }
}
