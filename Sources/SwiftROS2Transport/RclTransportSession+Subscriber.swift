// RclTransportSession+Subscriber.swift
// Subscriber creation and the RclTransportSubscriber concrete type.

import Foundation

extension RclTransportSession {
    // TransportSession conformance (no node identity → single-node fallback).
    package func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        try createSubscriber(
            topic: topic, typeName: typeName, typeHash: typeHash, qos: qos,
            nodeName: nil, nodeNamespace: nil, handler: handler)
    }

    // NodeScopedSession conformance (node-aware creation).
    package func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        guard !topic.isEmpty else {
            throw TransportError.invalidConfiguration("Topic name cannot be empty")
        }
        guard !typeName.isEmpty else {
            throw TransportError.invalidConfiguration("Type name cannot be empty")
        }
        // typeHash is forwarded so the route-(b) raw-CDR reader (non-bundled
        // types, registry miss) can emit the USER_DATA typehash; the bundled
        // route-a path ignores it (rcl derives the hash from the typesupport).
        let node = try preflightSubscriber(nodeName: nodeName, nodeNamespace: nodeNamespace)
        let handle = try client.createSubscription(
            node: node, typeName: typeName, typeHash: typeHash, topic: topic, qos: qos,
            handler: handler)
        let sub = RclTransportSubscriber(client: client, handle: handle, topic: topic)
        try appendSubscriber(sub)
        return sub
    }
}

final class RclTransportSubscriber: TransportSubscriber, @unchecked Sendable {
    private let client: any RclClientProtocol
    private var handle: (any RclSubscriptionHandle)?
    package let topic: String
    private let lock = NSLock()
    private var closed = false

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        return handle?.isActive ?? false
    }

    init(client: any RclClientProtocol, handle: any RclSubscriptionHandle, topic: String) {
        self.client = client
        self.handle = handle
        self.topic = topic
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
        if let h {
            // Blocks until any in-flight handler invocation has returned.
            client.destroySubscription(h)
        }
    }
}
