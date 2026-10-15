// DDSTransportSession.swift
// TransportSession implementation using DDSClientProtocol
//
// Uses protocol injection so tests can substitute the client.

import Foundation
import SwiftROS2Wire

// MARK: - DDS Transport Session

/// TransportSession implementation using DDS via DDSClientProtocol
///
/// The client protocol is injected at construction time: the production
/// client is `DDSClient`, tests inject a mock.
package final class DDSTransportSession: TransportSession, @unchecked Sendable {
    let client: any DDSClientProtocol
    private var config: TransportConfig?
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
        self.client = client
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
        self.config = config
        self.isOpen = true
        self._sessionId = client.getSessionId() ?? generateFallbackSessionId()
        lock.unlock()
    }

    package func close() throws {
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
        config = nil
        lock.unlock()

        try client.destroySession()
    }

    package func checkHealth() -> Bool {
        client.isConnected()
    }

    // MARK: - Helpers

    func bridgeQoS(from qos: TransportQoS) -> DDSBridgeQoSConfig {
        TransportQoSMapper.toDDSBridgeQoSConfig(qos)
    }

    private func generateFallbackSessionId() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(32).description
    }
}
