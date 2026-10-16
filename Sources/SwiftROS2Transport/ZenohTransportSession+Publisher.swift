// ZenohTransportSession+Publisher.swift
// Publisher creation and the ZenohTransportPublisher concrete type.

import Foundation
import SwiftROS2Wire

extension ZenohTransportSession {
    package func createPublisher(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportPublisher {
        try createPublisher(
            topic: topic, typeName: typeName, typeHash: typeHash, qos: qos, nodeName: nil, nodeNamespace: nil)
    }

    /// Declare a publisher of the node `nodeName` in `nodeNamespace` and announce it
    /// with an `MP` token under that node.
    package func createPublisher(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportPublisher {
        let (config, codec) = try openState()
        let ddsTypeName = TypeNameConverter.toDDSTypeName(typeName)
        let keyExpr = codec.makeEntityKeyExpr(
            domainId: config.domainId, name: topic, ddsTypeName: ddsTypeName, typeHash: typeHash)

        // Declare a publisher: it publishes and reports matching subscribers
        let publisherOptions = zenohPublisherOptions(for: qos)
        let zenohPublisher: any ZenohPublisherHandle
        do {
            zenohPublisher = try client.declarePublisher(keyExpr, options: publisherOptions)
        } catch let error as ZenohError {
            throw TransportError.publisherCreationFailed(error.localizedDescription ?? "Publisher declaration failed")
        }

        // Announce the publisher to the ROS graph, under its node. Best effort: a
        // failed declaration leaves the publisher sending on its key.
        let livelinessToken = try? declareEntityToken(
            kind: "MP",
            codec: codec,
            domainId: config.domainId,
            name: topic,
            ddsTypeName: ddsTypeName,
            typeHash: typeHash,
            qos: qos,
            node: nodeIdentity(name: nodeName, namespace: nodeNamespace)
        )

        let gid = gidManager.getOrCreateGid()

        let publisher = ZenohTransportPublisher(
            publisher: zenohPublisher,
            livelinessToken: livelinessToken,
            codec: codec,
            gid: gid,
            topic: topic
        )

        appendPublisher(publisher, for: topic)
        return publisher
    }

    /// Maps the topic QoS to the zenoh publisher options.
    ///
    /// - Congestion control: a reliable publisher blocks on congestion, a
    ///   best-effort one drops. rmw_zenoh_cpp blocks only for reliable
    ///   keep-all publishers, but its DROP is zenoh's: the sample is queued and
    ///   only dropped when the transmit queue stays full. zenoh-pico's DROP
    ///   only try-locks the session's transmit mutex, so a put fails with -100
    ///   whenever another thread is sending on the same session (another
    ///   publisher, a liveliness token, a query reply, the lease task's
    ///   keep-alive), with no congestion on the network at all. BLOCK waits
    ///   for the send in progress instead (bounded by the C bridge's send
    ///   timeout); a best-effort topic may lose the sample.
    /// - Durability: rmw_zenoh's TRANSIENT_LOCAL mapping. Cache the history
    ///   depth (keep-all as 1000), and send 500 ms sporadic heartbeats when
    ///   reliable.
    func zenohPublisherOptions(for qos: TransportQoS) -> ZenohPublisherOptions {
        let blockOnCongestion = qos.reliability == .reliable
        guard qos.durability == .transientLocal else {
            return ZenohPublisherOptions(blockOnCongestion: blockOnCongestion)
        }
        let depth: Int
        switch qos.history {
        case .keepLast(let n): depth = max(1, n)
        case .keepAll: depth = 1000
        }
        return ZenohPublisherOptions(
            cacheDepth: depth,
            heartbeatMs: qos.reliability == .reliable ? 500 : 0,
            blockOnCongestion: blockOnCongestion
        )
    }

    private func appendPublisher(_ publisher: ZenohTransportPublisher, for topic: String) {
        publishersLock.lock()
        publishers[topic] = publisher
        publishersLock.unlock()
    }

    func takeAllPublishers() -> [ZenohTransportPublisher] {
        publishersLock.lock()
        let pubs = Array(publishers.values)
        publishers.removeAll()
        publishersLock.unlock()
        return pubs
    }
}

// MARK: - Zenoh Transport Publisher

/// TransportPublisher using Zenoh
final class ZenohTransportPublisher: TransportPublisher, @unchecked Sendable {
    private var publisher: (any ZenohPublisherHandle)?
    private var livelinessToken: (any ZenohLivelinessTokenHandle)?
    private let codec: ZenohWireCodec
    private let gid: [UInt8]
    let topic: String
    private let lock = NSLock()
    private var closed = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && publisher != nil
    }

    var matchedSubscriptions: Bool? {
        lock.lock()
        let p = closed ? nil : publisher
        lock.unlock()
        return p?.matchingStatus()
    }

    init(
        publisher: any ZenohPublisherHandle,
        livelinessToken: (any ZenohLivelinessTokenHandle)?,
        codec: ZenohWireCodec,
        gid: [UInt8],
        topic: String
    ) {
        self.publisher = publisher
        self.livelinessToken = livelinessToken
        self.codec = codec
        self.gid = gid
        self.topic = topic
    }

    func publish(data: Data, timestamp: UInt64, sequenceNumber: Int64) throws {
        lock.lock()
        guard !closed, let p = publisher else {
            lock.unlock()
            throw TransportError.publisherClosed
        }
        lock.unlock()

        let attachment = codec.buildAttachment(
            seq: sequenceNumber,
            tsNsec: Int64(bitPattern: timestamp),
            gid: gid
        )

        do {
            try p.put(payload: data, attachment: attachment)
        } catch let error as ZenohError {
            if case .sessionDisconnected = error {
                throw TransportError.sessionUnhealthy(error.localizedDescription ?? "Disconnected")
            }
            throw TransportError.publishFailed(error.localizedDescription ?? "Put failed")
        }
    }

    func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let token = livelinessToken
        let p = publisher
        livelinessToken = nil
        publisher = nil
        lock.unlock()

        try? p?.close()
        try? token?.close()
    }
}
