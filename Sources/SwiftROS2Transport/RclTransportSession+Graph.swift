// RclTransportSession+Graph.swift
// The topic graph of an RCL session: the publishers in rmw's graph cache.

import Foundation

extension RclTransportSession: TopicGraphSession {
    /// The internal node the graph is read through. The leading underscore hides
    /// it from `ros2 node list` without `-a`.
    package static let graphNodeName = "_swift_ros2_graph"
    /// The graph node's namespace, the root.
    package static let graphNodeNamespace = "/"

    /// Every publisher in rmw's graph cache, read through rcl's graph API.
    ///
    /// The first call creates the session's graph node, ``graphNodeName`` in `/`; `close()`
    /// destroys it before the context. Each call runs on the session's graph queue
    /// under one lock, never on the cooperative pool. rmw fills the cache
    /// asynchronously after the context opens, so early results can be partial.
    ///
    /// - Throws: ``TransportError/notConnected`` when the session is not open;
    ///   ``TransportError/sessionUnhealthy(_:)`` when the graph node cannot be created or
    ///   rcl cannot read the graph; ``TransportError/unsupportedFeature(_:)`` when the
    ///   client has no graph support.
    package func publisherEndpoints() async throws -> [GraphPublisherEndpoint] {
        try await withCheckedThrowingContinuation { continuation in
            graphQueue.async {
                continuation.resume(with: Result { try self.snapshotPublishers() })
            }
        }
    }

    /// One snapshot. Runs on `graphQueue`.
    private func snapshotPublishers() throws -> [GraphPublisherEndpoint] {
        graphLock.lock()
        defer { graphLock.unlock() }
        guard isConnected else { throw TransportError.notConnected }
        let node: any RclNodeHandle
        if let existing = graphNode {
            node = existing
        } else {
            do {
                node = try client.createNode(name: Self.graphNodeName, namespace: Self.graphNodeNamespace)
            } catch TransportError.notConnected {
                throw TransportError.notConnected
            } catch {
                throw TransportError.sessionUnhealthy("cannot create the graph node: \(error)")
            }
            graphNode = node
        }
        let records: [RclGraphPublisherRecord]
        do {
            records = try client.graphPublishers(node: node)
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.sessionUnhealthy("rcl graph query failed: \(error)")
        }
        return records.map(GraphPublisherEndpoint.init(rclRecord:))
    }
}

extension GraphPublisherEndpoint {
    /// Maps rmw's QoS policy values: only RELIABLE reads as reliable and only
    /// TRANSIENT_LOCAL as transient-local; system default, unknown, best available and
    /// anything else read as best effort and volatile.
    init(rclRecord record: RclGraphPublisherRecord) {
        self.init(
            topicName: record.topicName,
            typeName: record.typeName,
            reliability: record.reliability == RclGraphPublisherRecord.rmwReliabilityReliable
                ? .reliable : .bestEffort,
            durability: record.durability == RclGraphPublisherRecord.rmwDurabilityTransientLocal
                ? .transientLocal : .volatile,
            nodeName: record.nodeName,
            nodeNamespace: record.nodeNamespace)
    }
}
