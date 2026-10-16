// RclTransportSession+Publisher.swift
// Publisher creation and the RclTransportPublisher concrete type.

import Foundation

extension RclTransportSession {
    // TransportSession conformance (no node identity → single-node fallback).
    package func createPublisher(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS
    ) throws -> any TransportPublisher {
        try createPublisher(
            topic: topic, typeName: typeName, typeHash: typeHash, qos: qos,
            nodeName: nil, nodeNamespace: nil)
    }

    // NodeScopedSession conformance (node-aware creation).
    package func createPublisher(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS,
        nodeName: String?, nodeNamespace: String?
    ) throws -> any TransportPublisher {
        guard !topic.isEmpty else {
            throw TransportError.invalidConfiguration("Topic name cannot be empty")
        }
        guard !typeName.isEmpty else {
            throw TransportError.invalidConfiguration("Type name cannot be empty")
        }
        let node = try preflightPublisher(
            topic: topic, nodeName: nodeName, nodeNamespace: nodeNamespace)
        let handle = try client.createPublisher(
            node: node, typeName: typeName, typeHash: typeHash, topic: topic, qos: qos)
        let pub = RclTransportPublisher(client: client, handle: handle, topic: topic)
        appendPublisher(pub)
        return pub
    }
}

final class RclTransportPublisher: TransportPublisher, @unchecked Sendable {
    private let client: any RclClientProtocol
    private var handle: (any RclPublisherHandle)?
    package let topic: String
    private let lock = NSLock()
    private var closed = false

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        return handle?.isActive ?? false
    }

    init(client: any RclClientProtocol, handle: any RclPublisherHandle, topic: String) {
        self.client = client
        self.handle = handle
        self.topic = topic
    }

    package func publish(data: Data, timestamp: UInt64, sequenceNumber: Int64) throws {
        // P1: timestamp/sequenceNumber are unused — rmw assigns the source
        // timestamp and the sensor time rides in the CDR header.stamp.
        guard !data.isEmpty else {
            throw TransportError.publishFailed("Data is empty")
        }
        guard data.count >= 4 else {
            throw TransportError.publishFailed("Data too short: missing CDR encapsulation header")
        }
        lock.lock()
        guard !closed, let h = handle else {
            lock.unlock()
            throw TransportError.publisherClosed
        }
        lock.unlock()
        try client.publishSerialized(h, data: data)
    }

    /// Whether the RCL publisher has at least one matched subscription; `nil`
    /// once closed or when the backend cannot tell (fail-open).
    package var matchedSubscriptions: Bool? {
        lock.lock()
        let h = closed ? nil : handle
        lock.unlock()
        guard let h else { return nil }
        return client.publisherMatchedCount(h).map { $0 > 0 }
    }

    package func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let h = handle
        handle = nil
        lock.unlock()
        h?.close()
    }
}
