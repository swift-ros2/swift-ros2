// ZenohTransportSession+Subscriber.swift
// Subscriber creation and the ZenohTransportSubscriberWrapper concrete type.

import Foundation
import SwiftROS2Wire

extension ZenohTransportSession {
    package func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        try createSubscriber(
            topic: topic, typeName: typeName, typeHash: typeHash, qos: qos, nodeName: nil, nodeNamespace: nil,
            handler: handler)
    }

    /// Subscribe for the node `nodeName` in `nodeNamespace` and announce the
    /// subscription with an `MS` token under that node.
    package func createSubscriber(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        guard isConnected else {
            throw TransportError.notConnected
        }

        guard let config = config else {
            throw TransportError.notConnected
        }

        let wireMode = resolvedWireMode ?? .jazzy
        let codec = ZenohWireCodec(distro: wireMode)

        let effectiveTypeHash: String?
        if wireMode.supportsTypeHash {
            effectiveTypeHash = typeHash
        } else {
            effectiveTypeHash = nil
        }

        let keyExpr = codec.makeKeyExpr(
            domainId: config.domainId,
            namespace: extractNamespace(from: topic),
            topic: extractTopicName(from: topic),
            typeName: typeName,
            typeHash: effectiveTypeHash ?? wireMode.typeHashPlaceholder
        )

        let onSample: (ZenohSample) -> Void = { sample in
            let timestampNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            handler(sample.payload, timestampNs)
        }

        // A transient-local subscription also fetches what the publishers' caches
        // hold, and delivers it before the live samples that arrive meanwhile.
        let historyGate = qos.durability == .transientLocal ? ZenohHistoryGate(deliver: onSample) : nil
        let onLiveSample = historyGate.map { gate in { (sample: ZenohSample) in gate.receiveLive(sample) } } ?? onSample

        var handles: [any ZenohSubscriberHandle] = []
        // From Lyrical, an rmw_zenoh publisher of a message with a `uint8[]` field
        // sends only to the subscriptions it discovers through liveliness, and to
        // CPU-only ones on `<key>/_buf_cpu`; it falls back to the topic key when an
        // undiscovered subscription matches. This subscription announces itself as
        // CPU-only and listens on both keys. The transport cannot tell whether the type
        // has such a field, so it does this for every type; publishers of other types
        // ignore both. Transient-local endpoints never use buffer endpoints.
        let usesCPUGroup = wireMode.usesZenohBufferEndpoints && qos.durability != .transientLocal
        do {
            handles.append(try client.subscribe(keyExpr: keyExpr, handler: onLiveSample))
            if usesCPUGroup {
                handles.append(
                    try client.subscribe(keyExpr: codec.makeCPUBufferGroupKeyExpr(keyExpr), handler: onSample))
            }
        } catch {
            for handle in handles {
                try? handle.close()
            }
            throw error
        }

        // Announce the subscription to the ROS graph, under its node. Best effort, like
        // the publisher's token: a failed declaration leaves the subscription receiving
        // on its keys.
        let livelinessToken = declareSubscriptionLivelinessToken(
            codec: codec,
            domainId: config.domainId,
            topic: topic,
            typeName: typeName,
            typeHash: effectiveTypeHash ?? wireMode.typeHashPlaceholder,
            qos: qos,
            cpuBufferBackend: usesCPUGroup,
            node: nodeIdentity(name: nodeName, namespace: nodeNamespace)
        )

        if let historyGate {
            fetchHistory(
                codec: codec, keyExpr: keyExpr, maxSamples: qos.historyMaxSamples, into: historyGate)
        }

        return ZenohTransportSubscriberWrapper(
            handles: handles, livelinessToken: livelinessToken, historyGate: historyGate, topic: topic)
    }

    /// How long a late joiner waits for the publishers' caches before it lets live
    /// samples through. The router answers as soon as every cache has replied.
    package static let historyQueryTimeoutMs: UInt32 = 5000

    /// Query the caches of the topic's transient-local publishers (rmw_zenoh advanced
    /// publishers) and hand the replies to `gate`. Best effort: without an answer the
    /// subscription still receives live samples.
    private func fetchHistory(
        codec: ZenohWireCodec, keyExpr: String, maxSamples: Int?, into gate: ZenohHistoryGate
    ) {
        do {
            try client.getHistory(
                keyExpr: codec.makeHistoryQueryKeyExpr(keyExpr),
                parameters: codec.makeHistoryQueryParameters(maxSamples: maxSamples),
                timeoutMs: Self.historyQueryTimeoutMs,
                handler: { reply in
                    if case .success(let sample) = reply { gate.receiveHistory(sample) }
                },
                onFinish: { gate.finish() }
            )
        } catch {
            gate.finish()
        }
    }

    /// Declare the `MS` token of a subscription, with the `backends:cpu:` component
    /// of a CPU-only buffer-aware subscription when `cpuBufferBackend` is set.
    private func declareSubscriptionLivelinessToken(
        codec: ZenohWireCodec,
        domainId: Int,
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        cpuBufferBackend: Bool,
        node: ZenohNodeIdentity
    ) -> (any ZenohLivelinessTokenHandle)? {
        let token = codec.makeEntityLivelinessToken(
            entityKind: "MS",
            domainId: domainId,
            sessionId: sessionId,
            nodeId: node.id,
            entityId: String(entityManager.getNextEntityId()),
            nodeNamespace: node.namespace,
            nodeName: node.name,
            name: topic,
            ddsTypeName: TypeNameConverter.toDDSTypeName(typeName),
            typeHash: typeHash,
            qos: qos.toQoSPolicy()
        )
        return try? client.declareLivelinessToken(
            cpuBufferBackend ? "\(token)/\(ZenohWireCodec.cpuBufferBackendsComponent)" : token)
    }
}

extension TransportQoS {
    /// The history depth as a sample count; `nil` for keep-all.
    fileprivate var historyMaxSamples: Int? {
        switch history {
        case .keepLast(let depth): return depth
        case .keepAll: return nil
        }
    }
}

// MARK: - Zenoh Transport Subscriber Wrapper

private final class ZenohTransportSubscriberWrapper: TransportSubscriber, @unchecked Sendable {
    private let handles: [any ZenohSubscriberHandle]
    private let livelinessToken: (any ZenohLivelinessTokenHandle)?
    private let historyGate: ZenohHistoryGate?
    package let topic: String
    private var _isActive = true
    private let lock = NSLock()

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    init(
        handles: [any ZenohSubscriberHandle],
        livelinessToken: (any ZenohLivelinessTokenHandle)?,
        historyGate: ZenohHistoryGate?,
        topic: String
    ) {
        self.handles = handles
        self.livelinessToken = livelinessToken
        self.historyGate = historyGate
        self.topic = topic
    }

    package func close() throws {
        lock.lock()
        _isActive = false
        lock.unlock()
        historyGate?.close()
        try? livelinessToken?.close()
        var firstError: Error?
        for handle in handles {
            do {
                try handle.close()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
