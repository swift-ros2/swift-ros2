// DDSTransportSession.swift
// TransportSession implementation using DDSClientProtocol
//
// Uses protocol injection so tests can substitute the client.

import Foundation

// MARK: - DDS Transport Session

/// TransportSession implementation using DDS via DDSClientProtocol
///
/// The client protocol is injected at construction time: the production
/// client is `DDSClient`, tests inject a mock.
///
/// The session announces its nodes and their endpoints on `ros_discovery_info`
/// (see `DDSTransportSession+Discovery.swift`).
package final class DDSTransportSession: TransportSession, @unchecked Sendable {
    /// The injected client wrapped in a `DDSGraphTrackingClient`, so that every
    /// reader and writer the session creates or destroys updates `graph`.
    let client: any DDSClientProtocol
    /// The nodes of the session's participant, published on `ros_discovery_info`.
    let graph: DDSParticipantGraph
    var publishers: [String: DDSTransportPublisherImpl] = [:]
    var subscribers: [DDSTransportSubscriberImpl] = []
    var serviceServers: [DDSTransportServiceServerImpl] = []
    var serviceClients: [DDSTransportServiceClientImpl] = []
    var actionServers: [DDSTransportActionServerImpl] = []
    var actionClients: [DDSTransportActionClientImpl] = []
    let lock = NSLock()
    private var _sessionId: String = ""
    var isOpen = false

    package var transportType: TransportType { .dds }

    package var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen && client.isConnected()
    }

    package var sessionId: String {
        lock.lock()
        defer { lock.unlock() }
        return _sessionId
    }

    /// Create a DDS transport session
    /// - Parameter client: DDS client protocol implementation (wraps C bridge)
    package init(client: any DDSClientProtocol) {
        let graph = DDSParticipantGraph(client: client)
        self.graph = graph
        self.client = DDSGraphTrackingClient(base: client, graph: graph)
    }

    package func open(config: TransportConfig) async throws {
        guard config.type == .dds else {
            throw TransportError.invalidConfiguration("Expected DDS configuration, got \(config.type)")
        }

        try config.validate()

        guard client.isAvailable else {
            throw TransportError.unsupportedFeature("DDS transport not available (CycloneDDS not compiled)")
        }

        // Build discovery config
        let discoveryMode: DDSBridgeDiscoveryMode
        switch config.ddsDiscoveryMode {
        case .multicast: discoveryMode = .multicast
        case .unicast: discoveryMode = .unicast
        case .hybrid: discoveryMode = .hybrid
        }

        let discoveryConfig = DDSBridgeDiscoveryConfig(
            mode: discoveryMode,
            unicastPeers: config.ddsUnicastPeers.map { $0.discoveryAddress },
            networkInterface: config.ddsNetworkInterface
        )

        try client.createSession(domainId: Int32(config.domainId), discoveryConfig: discoveryConfig)

        lock.lock()
        self.isOpen = true
        self._sessionId = client.getSessionId() ?? generateFallbackSessionId()
        lock.unlock()

        // A context passes its distribution as the wire mode; it picks the
        // gid size and type hash of the `ros_discovery_info` record.
        graph.start(distro: config.wireMode ?? .jazzy)
    }

    package func close() throws {
        // Stop announcing first: the participant leaves the network below, and
        // hosts drop its record with it.
        graph.stop()

        let pubs = takeAllPublishers()
        for pub in pubs {
            try? pub.close()
        }

        let subs = takeAllSubscribers()
        for sub in subs {
            try? sub.close()
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
        for srv in aServers {
            try? srv.close()
        }

        let aClients = takeAllActionClients()
        for cli in aClients {
            try? cli.close()
        }

        lock.lock()
        isOpen = false
        _sessionId = ""
        lock.unlock()

        try client.destroySession()
    }

    // MARK: - Helpers

    func bridgeQoS(from qos: TransportQoS) -> DDSBridgeQoSConfig {
        TransportQoSMapper.toDDSBridgeQoSConfig(qos)
    }

    private func generateFallbackSessionId() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(32).description
    }
}
