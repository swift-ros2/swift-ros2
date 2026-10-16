// ZenohTransportSession.swift
// TransportSession implementation using ZenohClientProtocol
//
// Uses protocol injection so tests can substitute the client.

import Foundation
import SwiftROS2Wire

// MARK: - Zenoh Transport Session

/// TransportSession implementation using Zenoh via ZenohClientProtocol
///
/// The client protocol is injected at construction time: the production
/// client is `ZenohClient`, tests inject a mock.
package final class ZenohTransportSession: TransportSession, @unchecked Sendable {
    let client: any ZenohClientProtocol
    var config: TransportConfig?
    var publishers: [String: ZenohTransportPublisher] = [:]
    var serviceServers: [ZenohTransportServiceServerImpl] = []
    var serviceClients: [ZenohTransportServiceClientImpl] = []
    var actionServers: [ZenohTransportActionServerImpl] = []
    var actionClients: [ZenohTransportActionClientImpl] = []
    /// The nodes whose entities this session announces, keyed by
    /// `<namespace>|<name>`. Guarded by `publishersLock`.
    var nodes: [String: ZenohNodeEntry] = [:]
    let publishersLock = NSLock()
    let entityManager: EntityManager
    let gidManager: GIDManager

    /// The wire mode of the open session: the configured one, Jazzy when none is
    /// configured. Set with `config` by `open(config:)`, cleared with it by `close()`.
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
            self.resolvedWireMode = config.wireMode ?? .jazzy
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

        for token in takeAllNodeTokens() {
            try? token.close()
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

    /// The configuration and wire codec of the open session.
    func openState() throws -> (config: TransportConfig, codec: ZenohWireCodec) {
        guard isConnected, let config, let distro = resolvedWireMode else {
            throw TransportError.notConnected
        }
        return (config, ZenohWireCodec(distro: distro))
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
        if let entry = nodes[key] {
            return entry.identity
        }
        let identity = ZenohNodeIdentity(
            namespace: resolvedNamespace, name: resolvedName, id: String(entityManager.getNextEntityId()))
        nodes[key] = ZenohNodeEntry(identity: identity)
        return identity
    }

    /// Announce a node with the `NN` token rmw_zenoh_cpp declares for it. rmw_zenoh_cpp
    /// removes a node from its graph only when that token goes away. Best effort, like
    /// a publisher's token: a node whose token fails still announces its entities.
    /// Two nodes with the same name and namespace share one identity and one token.
    package func registerNode(name: String, namespace: String) throws {
        guard let (config, codec) = try? openState() else { return }
        let identity = nodeIdentity(name: name, namespace: namespace)
        let key = "\(identity.namespace)|\(identity.name)"
        publishersLock.lock()
        nodes[key]?.registrations += 1
        let needsToken = nodes[key]?.registrations == 1
        publishersLock.unlock()
        guard needsToken else { return }

        let token = try? client.declareLivelinessToken(
            codec.makeNodeLivelinessToken(
                domainId: config.domainId, sessionId: sessionId, nodeId: identity.id,
                nodeNamespace: identity.namespace, nodeName: identity.name))
        publishersLock.lock()
        if nodes[key]?.identity == identity, nodes[key]?.registrations ?? 0 > 0 {
            nodes[key]?.token = token
            publishersLock.unlock()
        } else {
            publishersLock.unlock()
            try? token?.close()
        }
    }

    /// Withdraw a node registered with ``registerNode(name:namespace:)`` once its last
    /// registration goes: its `NN` token is undeclared and a node created later under
    /// the same name gets a new node id.
    package func unregisterNode(name: String, namespace: String) {
        let key = "\(ZenohNodeIdentity.normalizedNamespace(namespace))|\(name)"
        publishersLock.lock()
        guard var entry = nodes[key], entry.registrations > 0 else {
            publishersLock.unlock()
            return
        }
        entry.registrations -= 1
        let token = entry.registrations == 0 ? entry.token : nil
        nodes[key] = entry.registrations == 0 ? nil : entry
        publishersLock.unlock()
        try? token?.close()
    }

    func takeAllNodeTokens() -> [any ZenohLivelinessTokenHandle] {
        publishersLock.lock()
        let tokens = nodes.values.compactMap(\.token)
        nodes.removeAll()
        publishersLock.unlock()
        return tokens
    }
}
