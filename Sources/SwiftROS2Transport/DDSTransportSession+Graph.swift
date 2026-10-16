// DDSTransportSession+Graph.swift
// The topic graph of a wire DDS session: the writers CycloneDDS discovery lists,
// attributed to nodes through `ros_discovery_info`.
//
// DDS discovery knows participants and endpoints, not nodes. Each ROS participant
// publishes its nodes and their writer gids on `ros_discovery_info`; the session
// reads those records (`DDSDiscoveryInfoCache`) and attributes a writer by its
// GUID. Writers of the wire DDS sessions in this process are attributed from their
// `DDSParticipantGraph` directly (`DDSInProcessNodeRegistry`), so they are never
// reported as unknown while their own record is still in flight.

import Foundation
import SwiftROS2Wire

// MARK: - Topic graph

extension DDSTransportSession: TopicGraphSession {
    /// Every publisher of the domain, read from the builtin `DCPSPublication` topic.
    ///
    /// The read runs on the session's serial graph queue (`swift-ros2.graph.dds`), never
    /// on the cooperative pool or a CycloneDDS listener thread. Only `rt/` topics are
    /// listed. A writer whose node is not known (its participant's record has not arrived,
    /// or the participant does not publish one) is listed with the unknown node strings.
    ///
    /// - Throws: ``TransportError/notConnected`` when the session is closed;
    ///   ``TransportError/sessionUnhealthy(_:)`` when the discovery readers cannot be read.
    package func publisherEndpoints() async throws -> [GraphPublisherEndpoint] {
        try await withCheckedThrowingContinuation { continuation in
            graphQueue.async {
                continuation.resume(with: Result { try self.readPublisherEndpoints() })
            }
        }
    }

    /// One graph read. Runs on `graphQueue`.
    private func readPublisherEndpoints() throws -> [GraphPublisherEndpoint] {
        lock.lock()
        let open = isOpen
        lock.unlock()
        guard open else { throw TransportError.notConnected }

        let snapshot: DDSDiscoverySnapshot
        do {
            snapshot = try client.discoverySnapshot()
        } catch DDSError.notConnected {
            throw TransportError.notConnected
        } catch {
            throw TransportError.sessionUnhealthy("cannot read DDS discovery: \(error.localizedDescription)")
        }

        let present = Set(
            snapshot.participantGUIDs.map(DDSGUID.prefix)
                + snapshot.publications.map { DDSGUID.prefix($0.participantGUID) }
        )
        // Records of this process's writers win: they are current even while the
        // writer's own record is still on its way.
        let nodes = discoveryInfo.writerNodes(keepingParticipants: present)
            .merging(DDSInProcessNodeRegistry.shared.writerNodes()) { _, local in local }
        return Self.graphEndpoints(snapshot.publications, writerNodes: nodes)
    }

    /// The `rt/` writers of `publications` as graph endpoints, attributed through
    /// `writerNodes` (keyed by the writer's 16-byte GUID).
    static func graphEndpoints(
        _ publications: [DDSDiscoveredPublication], writerNodes: [[UInt8]: DDSNodeName]
    ) -> [GraphPublisherEndpoint] {
        publications.compactMap { publication in
            guard publication.topicName.hasPrefix("rt/"), publication.topicName.count > 3 else { return nil }
            let node = writerNodes[DDSGUID.prefix(publication.endpointGUID)]
            return GraphPublisherEndpoint(
                topicName: "/" + publication.topicName.dropFirst(3),
                typeName: TypeNameConverter.toROSTypeName(publication.typeName),
                reliability: publication.reliability == .reliable ? .reliable : .bestEffort,
                durability: publication.durability.isTransientLocalOrStronger ? .transientLocal : .volatile,
                nodeName: node?.name ?? GraphPublisherEndpoint.unknownNodeName,
                nodeNamespace: node?.namespace ?? GraphPublisherEndpoint.unknownNodeNamespace)
        }
    }
}

extension DDSDiscoveredPublication.Durability {
    /// Whether a transient-local reader matches a writer of this durability. TRANSIENT and
    /// PERSISTENT are stronger than TRANSIENT_LOCAL, so it does.
    var isTransientLocalOrStronger: Bool {
        switch self {
        case .transientLocal, .transient, .persistent: return true
        case .volatile, .unknown: return false
        }
    }
}

// MARK: - Node names

/// The node a DDS writer belongs to.
struct DDSNodeName: Equatable, Sendable {
    /// The absolute namespace, `/` for the root.
    let namespace: String
    let name: String
}

enum DDSGUID {
    /// The 16-byte DDS GUID inside a gid: Humble's 24-byte gid is the GUID zero-padded.
    static func prefix(_ gid: [UInt8]) -> [UInt8] {
        Array(gid.prefix(16))
    }
}

// MARK: - ros_discovery_info records

/// The `ros_discovery_info` records of the domain's participants, read by a reader the
/// session opens next to its own `ros_discovery_info` writer.
///
/// The reader is RELIABLE, TRANSIENT_LOCAL, KEEP_ALL: the topic is keyless, so every
/// participant's record is one instance, and each writer replays its latest record to
/// a late reader. The reader goes through the session's own client, not the tracking
/// wrapper, so it is not recorded as an endpoint of any node.
///
/// The handler runs on a CycloneDDS listener thread, and on the thread that writes a
/// local record (the session's own writer publishes while holding
/// `DDSParticipantGraph`'s lock) or creates the reader (with the client's lock held).
/// It therefore takes only this cache's own lock and never calls into the client.
final class DDSDiscoveryInfoCache: @unchecked Sendable {
    private let client: any DDSClientProtocol
    private let lock = NSLock()
    /// The latest record of each participant, keyed by its 16-byte GUID.
    private var records: [[UInt8]: [ParticipantEntitiesInfo.NodeEntities]] = [:]
    private var reader: (any DDSReaderHandle)?
    private var preferredGidSize = 16

    init(client: any DDSClientProtocol) {
        self.client = client
    }

    /// Opens the `ros_discovery_info` reader. A reader that cannot be created leaves
    /// every remote writer unattributed rather than failing the open.
    func start(distro: ROS2Distro) {
        lock.lock()
        preferredGidSize = ParticipantEntitiesInfo.gidSize(for: distro)
        lock.unlock()
        let qos = DDSBridgeQoSConfig(
            reliability: .reliable, durability: .transientLocal, historyKind: .keepAll, historyDepth: 0)
        // Not under `lock`: historical records can be delivered while the reader is
        // being created, and the handler takes `lock`.
        guard
            let reader = try? client.createRawReader(
                topicName: ParticipantEntitiesInfo.topicName,
                typeName: ParticipantEntitiesInfo.ddsTypeName,
                qos: qos,
                userData: ParticipantEntitiesInfo.userData(for: distro),
                handler: { [weak self] data, _ in self?.receive(data) })
        else { return }
        lock.lock()
        self.reader = reader
        lock.unlock()
    }

    /// Destroys the reader and forgets every record.
    func stop() {
        lock.lock()
        let reader = self.reader
        self.reader = nil
        records.removeAll()
        lock.unlock()
        // Outside `lock`: destroying the reader waits for a handler in progress.
        if let reader {
            client.destroyReader(reader)
        }
    }

    /// Stores a received record, replacing the participant's previous one. A sample
    /// that does not decode with either gid size is dropped.
    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let info = ParticipantEntitiesInfo.decodeReceived(data, preferredGidSize: preferredGidSize) else {
            return
        }
        records[DDSGUID.prefix(info.participantGid)] = info.nodes
    }

    /// Drops the records of participants not in `participants` (16-byte GUIDs), then
    /// returns the node of every writer the remaining records list.
    func writerNodes(keepingParticipants participants: Set<[UInt8]>) -> [[UInt8]: DDSNodeName] {
        lock.lock()
        defer { lock.unlock() }
        records = records.filter { participants.contains($0.key) }
        var result: [[UInt8]: DDSNodeName] = [:]
        for nodes in records.values {
            for node in nodes {
                let name = DDSNodeName(namespace: node.namespace, name: node.name)
                for gid in node.writerGids {
                    result[DDSGUID.prefix(gid)] = name
                }
            }
        }
        return result
    }

    /// The participants a record is kept for, for tests.
    var participantsWithRecords: Set<[UInt8]> {
        lock.lock()
        defer { lock.unlock() }
        return Set(records.keys)
    }
}

// MARK: - In-process registry

/// The participant graphs of every open wire DDS session in the process.
///
/// The CycloneDDS domain is process-global, so `DCPSPublication` lists the writers of
/// every session in the process; this registry attributes them at once, while their
/// `ros_discovery_info` record may still be in flight.
final class DDSInProcessNodeRegistry: @unchecked Sendable {
    static let shared = DDSInProcessNodeRegistry()

    private final class WeakGraph {
        weak var graph: DDSParticipantGraph?
        init(_ graph: DDSParticipantGraph) { self.graph = graph }
    }

    private let lock = NSLock()
    private var graphs: [ObjectIdentifier: WeakGraph] = [:]

    func register(_ graph: DDSParticipantGraph) {
        lock.lock()
        defer { lock.unlock() }
        graphs[ObjectIdentifier(graph)] = WeakGraph(graph)
    }

    func unregister(_ graph: DDSParticipantGraph) {
        lock.lock()
        defer { lock.unlock() }
        graphs[ObjectIdentifier(graph)] = nil
    }

    /// The node of every writer of the registered sessions, keyed by 16-byte GUID.
    func writerNodes() -> [[UInt8]: DDSNodeName] {
        lock.lock()
        graphs = graphs.filter { $0.value.graph != nil }
        let live = graphs.values.compactMap(\.graph)
        lock.unlock()
        // Each graph's lock is taken without holding the registry's.
        var result: [[UInt8]: DDSNodeName] = [:]
        for graph in live {
            result.merge(graph.writerNodes()) { first, _ in first }
        }
        return result
    }

    /// Whether `graph` is registered, for tests.
    func contains(_ graph: DDSParticipantGraph) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return graphs[ObjectIdentifier(graph)]?.graph === graph
    }
}
