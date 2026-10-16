// DDSTransportSession+Discovery.swift
// Announces the session's nodes on `ros_discovery_info`.
//
// rmw_cyclonedds_cpp hosts learn which node a reader or writer belongs to only
// from the `ros_discovery_info` record of its participant (see
// `ParticipantEntitiesInfo`). The wire DDS session keeps that record the way
// rmw_cyclonedds_cpp does: it publishes it when the session opens, and again
// whenever a node is registered or unregistered or one of a node's readers or
// writers is created or destroyed. The writer is RELIABLE, TRANSIENT_LOCAL,
// KEEP_LAST(1), so a host that starts later still receives the latest record.

import Foundation
import SwiftROS2Wire

// MARK: - Node-scoped creation

extension DDSTransportSession: NodeScopedSession {
    // Each node-scoped create runs the plain create inside an endpoint scope:
    // the readers and writers it creates are recorded under the owning node.

    package func createPublisher(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportPublisher {
        try graph.recordingEndpoints(ofNode: nodeName, namespace: nodeNamespace) {
            try createPublisher(topic: topic, typeName: typeName, typeHash: typeHash, qos: qos)
        }
    }

    package func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        try graph.recordingEndpoints(ofNode: nodeName, namespace: nodeNamespace) {
            try createSubscriber(topic: topic, typeName: typeName, typeHash: typeHash, qos: qos, handler: handler)
        }
    }

    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        try graph.recordingEndpoints(ofNode: nodeName, namespace: nodeNamespace) {
            try createServiceServer(
                name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
                responseTypeHash: responseTypeHash, qos: qos, handler: handler)
        }
    }

    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportClient {
        try graph.recordingEndpoints(ofNode: nodeName, namespace: nodeNamespace) {
            try createServiceClient(
                name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
                responseTypeHash: responseTypeHash, qos: qos)
        }
    }

    package func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer {
        try graph.recordingEndpoints(ofNode: nodeName, namespace: nodeNamespace) {
            try createActionServer(
                name: name, actionTypeName: actionTypeName, roleTypeHashes: roleTypeHashes, qos: qos,
                handlers: handlers)
        }
    }

    package func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportActionClient {
        try graph.recordingEndpoints(ofNode: nodeName, namespace: nodeNamespace) {
            try createActionClient(
                name: name, actionTypeName: actionTypeName, roleTypeHashes: roleTypeHashes, qos: qos)
        }
    }

    // MARK: Nodes

    package func registerNode(name: String, namespace: String) throws {
        graph.addNode(name: name, namespace: namespace)
    }

    package func unregisterNode(name: String, namespace: String) {
        graph.removeNode(name: name, namespace: namespace)
    }
}

// MARK: - Participant graph

/// The nodes of one DDS participant and the gids of each node's readers and
/// writers, published as a `ParticipantEntitiesInfo` on `ros_discovery_info`
/// every time they change.
///
/// Endpoints reach the graph through `DDSGraphTrackingClient`: a reader or
/// writer created inside ``recordingEndpoints(ofNode:namespace:_:)`` joins that
/// node once the create call returns, and any destroyed one leaves its node.
final class DDSParticipantGraph: @unchecked Sendable {
    /// The readers and writers created during one node-scoped create call.
    final class EndpointScope: @unchecked Sendable {
        private let lock = NSLock()
        private var writers: [any DDSWriterHandle] = []
        private var readers: [any DDSReaderHandle] = []

        func add(writer: any DDSWriterHandle) {
            lock.lock()
            writers.append(writer)
            lock.unlock()
        }

        func add(reader: any DDSReaderHandle) {
            lock.lock()
            readers.append(reader)
            lock.unlock()
        }

        func take() -> (writers: [any DDSWriterHandle], readers: [any DDSReaderHandle]) {
            lock.lock()
            defer {
                writers.removeAll()
                readers.removeAll()
                lock.unlock()
            }
            return (writers, readers)
        }
    }

    /// The scope of the node-scoped create call running on this thread or task.
    @TaskLocal static var currentScope: EndpointScope?

    private struct Endpoint {
        let handle: AnyObject
        let gid: [UInt8]
    }

    private struct Node {
        let namespace: String
        let name: String
        var readers: [Endpoint] = []
        var writers: [Endpoint] = []
    }

    private struct Announcer {
        let writer: any DDSWriterHandle
        let participantGid: [UInt8]
        let gidSize: Int
    }

    /// The session's own client, not the tracking wrapper: the
    /// `ros_discovery_info` writer is not an endpoint of any node.
    private let client: any DDSClientProtocol
    /// Guards the state below. Held across each publish so that the record
    /// written last always matches the latest state.
    private let lock = NSLock()
    private var nodes: [Node] = []
    private var announcer: Announcer?

    init(client: any DDSClientProtocol) {
        self.client = client
    }

    /// Creates the `ros_discovery_info` writer of the session's participant
    /// and publishes the current record. Does nothing when the client cannot
    /// report the participant GUID; a writer that cannot be created leaves the
    /// session without announcements rather than failing the open.
    func start(distro: ROS2Distro) {
        guard let participantGid = client.participantGUID() else { return }
        let qos = DDSBridgeQoSConfig(
            reliability: .reliable, durability: .transientLocal, historyKind: .keepLast, historyDepth: 1)
        guard
            let writer = try? client.createRawWriter(
                topicName: ParticipantEntitiesInfo.topicName,
                typeName: ParticipantEntitiesInfo.ddsTypeName,
                qos: qos,
                userData: ParticipantEntitiesInfo.userData(for: distro))
        else { return }

        lock.lock()
        defer { lock.unlock() }
        announcer = Announcer(
            writer: writer, participantGid: participantGid,
            gidSize: ParticipantEntitiesInfo.gidSize(for: distro))
        publishLocked()
    }

    /// Destroys the `ros_discovery_info` writer and forgets every node.
    func stop() {
        lock.lock()
        let writer = announcer?.writer
        announcer = nil
        nodes.removeAll()
        lock.unlock()
        if let writer {
            client.destroyWriter(writer)
        }
    }

    func addNode(name: String, namespace: String) {
        lock.lock()
        defer { lock.unlock() }
        nodes.append(Node(namespace: Self.normalizedNamespace(namespace), name: name))
        publishLocked()
    }

    /// Removes the first node with this name and namespace, with its endpoints.
    func removeNode(name: String, namespace: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = nodeIndex(name: name, namespace: namespace) else { return }
        nodes.remove(at: index)
        publishLocked()
    }

    /// Runs `body`, then records every reader and writer it created under the
    /// named node and publishes the record once. Endpoints of a failed `body`
    /// were rolled back by it and are not recorded. With no `name`, or a node
    /// that is not registered, `body` just runs.
    func recordingEndpoints<T>(
        ofNode name: String?, namespace: String?, _ body: () throws -> T
    ) rethrows -> T {
        guard let name else { return try body() }
        let scope = EndpointScope()
        let result = try Self.$currentScope.withValue(scope) { try body() }
        let created = scope.take()
        let writers = created.writers.compactMap { w in client.writerGUID(w).map { Endpoint(handle: w, gid: $0) } }
        let readers = created.readers.compactMap { r in client.readerGUID(r).map { Endpoint(handle: r, gid: $0) } }

        lock.lock()
        defer { lock.unlock() }
        guard let index = nodeIndex(name: name, namespace: namespace ?? "/") else { return result }
        nodes[index].writers += writers
        nodes[index].readers += readers
        if !writers.isEmpty || !readers.isEmpty {
            publishLocked()
        }
        return result
    }

    /// Drops a reader or writer that is being destroyed from its node.
    func removeEndpoint(_ handle: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        for index in nodes.indices {
            let readerCount = nodes[index].readers.count
            let writerCount = nodes[index].writers.count
            nodes[index].readers.removeAll { $0.handle === handle }
            nodes[index].writers.removeAll { $0.handle === handle }
            if nodes[index].readers.count != readerCount || nodes[index].writers.count != writerCount {
                publishLocked()
                return
            }
        }
    }

    /// The node of every writer recorded under a node, keyed by the writer's 16-byte
    /// GUID. The topic graph attributes this process's writers through it
    /// (``DDSInProcessNodeRegistry``) without waiting for their record to come back.
    func writerNodes() -> [[UInt8]: DDSNodeName] {
        lock.lock()
        defer { lock.unlock() }
        var result: [[UInt8]: DDSNodeName] = [:]
        for node in nodes {
            for writer in node.writers {
                result[Array(writer.gid.prefix(16))] = DDSNodeName(namespace: node.namespace, name: node.name)
            }
        }
        return result
    }

    // MARK: Private

    private func nodeIndex(name: String, namespace: String) -> Int? {
        let namespace = Self.normalizedNamespace(namespace)
        return nodes.firstIndex { $0.name == name && $0.namespace == namespace }
    }

    /// `/`-prefixed, without empty or trailing segments: the form rcl gives
    /// rmw_cyclonedds_cpp (`/`, `/ns`, `/a/b`).
    static func normalizedNamespace(_ namespace: String) -> String {
        "/" + namespace.split(separator: "/").joined(separator: "/")
    }

    /// The current record. Caller holds `lock`.
    private func infoLocked(participantGid: [UInt8]) -> ParticipantEntitiesInfo {
        ParticipantEntitiesInfo(
            participantGid: participantGid,
            nodes: nodes.map { node in
                ParticipantEntitiesInfo.NodeEntities(
                    namespace: node.namespace, name: node.name,
                    readerGids: node.readers.map(\.gid), writerGids: node.writers.map(\.gid))
            })
    }

    /// Writes the current record. Caller holds `lock`. A failed write is not
    /// retried: the next change writes the full record again.
    private func publishLocked() {
        guard let announcer else { return }
        let data = infoLocked(participantGid: announcer.participantGid).encode(gidSize: announcer.gidSize)
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000))
        try? client.writeRawCDR(writer: announcer.writer, data: data, timestamp: now)
    }
}

// MARK: - Tracking client

/// The client a `DDSTransportSession` and its entities use: it forwards every
/// call to the session's own client and keeps `DDSParticipantGraph` in step.
/// A reader or writer created inside a node-scoped create call joins the
/// call's endpoint scope; a destroyed one leaves its node.
final class DDSGraphTrackingClient: DDSClientProtocol {
    private let base: any DDSClientProtocol
    private let graph: DDSParticipantGraph

    init(base: any DDSClientProtocol, graph: DDSParticipantGraph) {
        self.base = base
        self.graph = graph
    }

    var isAvailable: Bool { base.isAvailable }

    func createSession(domainId: Int32, discoveryConfig: DDSBridgeDiscoveryConfig) throws {
        try base.createSession(domainId: domainId, discoveryConfig: discoveryConfig)
    }

    func destroySession() throws { try base.destroySession() }

    func isConnected() -> Bool { base.isConnected() }

    func getSessionId() -> String? { base.getSessionId() }

    func createRawWriter(
        topicName: String, typeName: String, qos: DDSBridgeQoSConfig, userData: String?
    ) throws -> any DDSWriterHandle {
        let writer = try base.createRawWriter(topicName: topicName, typeName: typeName, qos: qos, userData: userData)
        DDSParticipantGraph.currentScope?.add(writer: writer)
        return writer
    }

    func writeRawCDR(writer: any DDSWriterHandle, data: Data, timestamp: UInt64) throws {
        try base.writeRawCDR(writer: writer, data: data, timestamp: timestamp)
    }

    func destroyWriter(_ writer: any DDSWriterHandle) {
        graph.removeEndpoint(writer)
        base.destroyWriter(writer)
    }

    func publicationMatchedCount(writer: any DDSWriterHandle) -> Int? {
        base.publicationMatchedCount(writer: writer)
    }

    func createRawReader(
        topicName: String, typeName: String, qos: DDSBridgeQoSConfig, userData: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any DDSReaderHandle {
        let reader = try base.createRawReader(
            topicName: topicName, typeName: typeName, qos: qos, userData: userData, handler: handler)
        DDSParticipantGraph.currentScope?.add(reader: reader)
        return reader
    }

    func destroyReader(_ reader: any DDSReaderHandle) {
        graph.removeEndpoint(reader)
        base.destroyReader(reader)
    }

    func isPublicationMatched(writer: any DDSWriterHandle) -> Bool {
        base.isPublicationMatched(writer: writer)
    }

    func isSubscriptionMatched(reader: any DDSReaderHandle) -> Bool {
        base.isSubscriptionMatched(reader: reader)
    }

    func participantGUID() -> [UInt8]? { base.participantGUID() }

    func writerGUID(_ writer: any DDSWriterHandle) -> [UInt8]? { base.writerGUID(writer) }

    func readerGUID(_ reader: any DDSReaderHandle) -> [UInt8]? { base.readerGUID(reader) }

    func discoverySnapshot() throws -> DDSDiscoverySnapshot { try base.discoverySnapshot() }
}
