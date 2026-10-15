// ZenohTransportSession+Service.swift
// Service Server / Client implementation for the Zenoh transport.
//
// `rmw_zenoh_cpp` models a ROS 2 service as a Zenoh queryable on the service
// key expression `<domain>/<service>/<pkg>::srv::dds_::<Type>_/<service hash>`.
// The server declares a queryable; the client issues a `get` against the same
// key expression with the request CDR as payload. The first reply (success or
// error) resolves the call.
//
// The wire payload on each side is the raw user CDR (no `RMWRequestId`
// prefix). Correlation rides on the 33-byte attachment: a request carries the
// client's sequence number and GID, and the reply echoes them, as rmw_zenoh_cpp
// requires in both directions.
//
// Both sides declare the liveliness token rmw_zenoh_cpp's graph discovers them
// by (`SS` for a server, `SC` for a client) under the owning node, and a client
// waits for a server by querying `SS` tokens.

import Foundation
import SwiftROS2Wire

extension ZenohTransportSession: NodeScopedSession {
    // MARK: Publisher / subscriber

    // Topics keep their per-publisher node identity; only services and actions
    // are announced under the owning node.

    package func createPublisher(
        topic: String,
        typeName: String,
        typeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportPublisher {
        try createPublisher(topic: topic, typeName: typeName, typeHash: typeHash, qos: qos)
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
        try createSubscriber(topic: topic, typeName: typeName, typeHash: typeHash, qos: qos, handler: handler)
    }

    // MARK: Service

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
        try createServiceServer(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, serviceTypeHash: nil, qos: qos, nodeName: nodeName,
            nodeNamespace: nodeNamespace, handler: handler)
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
        try createServiceClient(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, serviceTypeHash: nil, qos: qos, nodeName: nodeName,
            nodeNamespace: nodeNamespace)
    }

    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        serviceTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        let endpoint = try makeServiceEndpoint(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            serviceTypeHash: serviceTypeHash)

        let server = ZenohTransportServiceServerImpl(
            name: name,
            keyExpr: endpoint.keyExpr,
            codec: endpoint.codec,
            handler: handler
        )

        let queryable: any ZenohQueryableHandle
        do {
            queryable = try client.declareQueryable(endpoint.keyExpr) { [weak server] query in
                server?.handleQuery(query)
            }
        } catch let error as ZenohError {
            throw TransportError.subscriberCreationFailed(error.localizedDescription ?? "declareQueryable failed")
        }

        let token: any ZenohLivelinessTokenHandle
        do {
            token = try declareServiceToken(
                kind: .serviceServer, endpoint: endpoint, name: name, qos: qos,
                node: nodeIdentity(name: nodeName, namespace: nodeNamespace))
        } catch {
            try? queryable.close()
            throw error
        }
        server.attach(queryable: queryable, livelinessToken: token)

        appendServiceServer(server)
        return server
    }

    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        serviceTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportClient {
        let endpoint = try makeServiceEndpoint(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            serviceTypeHash: serviceTypeHash)

        let token = try declareServiceToken(
            kind: .serviceClient, endpoint: endpoint, name: name, qos: qos,
            node: nodeIdentity(name: nodeName, namespace: nodeNamespace))

        let serviceClient = ZenohTransportServiceClientImpl(
            client: client,
            codec: endpoint.codec,
            gid: ZenohServiceAttachment.makeClientGid(),
            keyExpr: endpoint.keyExpr,
            serverQueryKeyExpr: endpoint.codec.makeServiceServerLivelinessQuery(
                domainId: endpoint.domainId, name: name, ddsTypeName: endpoint.naming.ddsTypeName),
            name: name,
            livelinessToken: token
        )
        appendServiceClient(serviceClient)
        return serviceClient
    }

    // MARK: - Plain TransportSession entry points

    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        try createServiceServer(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, serviceTypeHash: nil, qos: qos, nodeName: nil,
            nodeNamespace: nil, handler: handler)
    }

    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient {
        try createServiceClient(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, serviceTypeHash: nil, qos: qos, nodeName: nil,
            nodeNamespace: nil)
    }

    // MARK: - Naming helpers

    struct ServiceEndpoint {
        let codec: ZenohWireCodec
        let domainId: Int
        let naming: ZenohServiceNaming
        let keyExpr: String
    }

    func makeServiceEndpoint(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        serviceTypeHash: String?
    ) throws -> ServiceEndpoint {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Service name cannot be empty")
        }
        guard !serviceTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Service type name cannot be empty")
        }
        guard isConnected else {
            throw TransportError.notConnected
        }
        guard let cfg = config else {
            throw TransportError.notConnected
        }

        let codec = ZenohWireCodec(distro: resolvedWireMode ?? .jazzy)
        let naming = ZenohServiceNaming.resolve(
            distro: codec.distro,
            serviceDDSTypeName: TypeNameConverter.toDDSServiceTypeName(serviceTypeName),
            serviceTypeHash: serviceTypeHash,
            requestDDSTypeName: TypeNameConverter.toDDSServiceRequestTypeName(serviceTypeName),
            requestTypeHash: requestTypeHash
        )
        if naming.isLegacy {
            ZenohServiceHashFallbackLog.shared.reportOnce(typeName: serviceTypeName)
        }
        let keyExpr = codec.makeEntityKeyExpr(
            domainId: cfg.domainId, name: name, ddsTypeName: naming.ddsTypeName, typeHash: naming.typeHash)
        return ServiceEndpoint(codec: codec, domainId: cfg.domainId, naming: naming, keyExpr: keyExpr)
    }

    /// Declare the `SS` / `SC` liveliness token of a service endpoint of `node`.
    func declareServiceToken(
        kind: ZenohWireCodec.ServiceEntityKind,
        endpoint: ServiceEndpoint,
        name: String,
        qos: TransportQoS,
        node: ZenohNodeIdentity
    ) throws -> any ZenohLivelinessTokenHandle {
        try declareEntityToken(
            kind: kind.rawValue, codec: endpoint.codec, domainId: endpoint.domainId, name: name,
            ddsTypeName: endpoint.naming.ddsTypeName, typeHash: endpoint.naming.typeHash,
            qos: qos, node: node)
    }

    /// Declare the liveliness token of one entity (`SS`, `SC`, `MP` or `MS`) of `node`.
    func declareEntityToken(
        kind: String,
        codec: ZenohWireCodec,
        domainId: Int,
        name: String,
        ddsTypeName: String,
        typeHash: String?,
        qos: TransportQoS,
        node: ZenohNodeIdentity
    ) throws -> any ZenohLivelinessTokenHandle {
        let tokenKeyExpr = codec.makeEntityLivelinessToken(
            entityKind: kind,
            domainId: domainId,
            sessionId: sessionId,
            nodeId: node.id,
            entityId: String(entityManager.getNextEntityId()),
            nodeNamespace: node.namespace,
            nodeName: node.name,
            name: name,
            ddsTypeName: ddsTypeName,
            typeHash: typeHash,
            qos: qos.toQoSPolicy()
        )
        do {
            return try client.declareLivelinessToken(tokenKeyExpr)
        } catch let error as ZenohError {
            throw TransportError.subscriberCreationFailed(
                error.localizedDescription ?? "declareLivelinessToken failed")
        }
    }

    // MARK: - Internal lock helpers

    func appendServiceServer(_ server: ZenohTransportServiceServerImpl) {
        publishersLock.lock()
        serviceServers.append(server)
        publishersLock.unlock()
    }

    func appendServiceClient(_ serviceClient: ZenohTransportServiceClientImpl) {
        publishersLock.lock()
        serviceClients.append(serviceClient)
        publishersLock.unlock()
    }

    func takeAllServiceServers() -> [ZenohTransportServiceServerImpl] {
        publishersLock.lock()
        let out = serviceServers
        serviceServers.removeAll()
        publishersLock.unlock()
        return out
    }

    func takeAllServiceClients() -> [ZenohTransportServiceClientImpl] {
        publishersLock.lock()
        let out = serviceClients
        serviceClients.removeAll()
        publishersLock.unlock()
        return out
    }
}

// MARK: - Zenoh Transport Service Server

final class ZenohTransportServiceServerImpl: TransportService, @unchecked Sendable {
    package let name: String
    private let keyExpr: String
    private let codec: ZenohWireCodec
    private let handler: @Sendable (Data) async throws -> Data
    private var queryable: (any ZenohQueryableHandle)?
    private var livelinessToken: (any ZenohLivelinessTokenHandle)?
    private let lock = NSLock()
    private var closed = false

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && queryable != nil
    }

    init(
        name: String,
        keyExpr: String,
        codec: ZenohWireCodec,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.name = name
        self.keyExpr = keyExpr
        self.codec = codec
        self.handler = handler
    }

    func attach(queryable q: any ZenohQueryableHandle, livelinessToken token: any ZenohLivelinessTokenHandle) {
        lock.lock()
        queryable = q
        livelinessToken = token
        lock.unlock()
    }

    /// Called from a zenoh-pico-owned thread. Spawn a Task so the user
    /// handler runs in Swift concurrency, then `reply` / `replyError`.
    func handleQuery(_ query: any ZenohQueryHandle) {
        let userRequestCDR = query.payload
        let replyAttachment = ZenohServiceAttachment.reply(to: query.attachment, codec: codec)
        let captured = handler
        Task {
            do {
                let userReplyCDR = try await captured(userRequestCDR)
                try? query.reply(payload: userReplyCDR, attachment: replyAttachment)
            } catch {
                try? query.replyError(message: error.localizedDescription)
            }
        }
    }

    package func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let q = queryable
        let token = livelinessToken
        queryable = nil
        livelinessToken = nil
        lock.unlock()

        try? token?.close()
        try? q?.close()
    }
}

// MARK: - Zenoh Transport Service Client

final class ZenohTransportServiceClientImpl: TransportClient, @unchecked Sendable {
    private let client: any ZenohClientProtocol
    private let codec: ZenohWireCodec
    private let gid: [UInt8]
    private let keyExpr: String
    /// Liveliness query matching the `SS` tokens of this service's servers.
    private let serverQueryKeyExpr: String
    package let name: String

    private let seqLock = NSLock()
    private var nextSeq: Int64 = 0

    private let lock = NSLock()
    private var closed = false
    private var livelinessToken: (any ZenohLivelinessTokenHandle)?

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    init(
        client: any ZenohClientProtocol,
        codec: ZenohWireCodec,
        gid: [UInt8],
        keyExpr: String,
        serverQueryKeyExpr: String,
        name: String,
        livelinessToken: (any ZenohLivelinessTokenHandle)?
    ) {
        self.client = client
        self.codec = codec
        self.gid = gid
        self.keyExpr = keyExpr
        self.serverQueryKeyExpr = serverQueryKeyExpr
        self.name = name
        self.livelinessToken = livelinessToken
    }

    /// Wait until a server of this service is announced: a liveliness query finds
    /// its `SS` token, which rmw_zenoh_cpp and swift-ros2 servers declare after
    /// their queryable. Probing the queryable with a `get` instead would hand
    /// rmw_zenoh_cpp servers a request without an attachment, which they reject.
    /// Throws `connectionTimeout` if no server appears before `timeout` elapses.
    package func waitForService(timeout: Duration) async throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed {
            throw TransportError.sessionClosed
        }

        if await ZenohServiceDiscovery.waitForServers(
            client: client, queryKeyExprs: [serverQueryKeyExpr], timeout: timeout)
        {
            return
        }
        throw TransportError.connectionTimeout(
            TimeInterval(
                Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1.0e18))
    }

    package func call(requestCDR: Data, timeout: Duration) async throws -> Data {
        lock.lock()
        if closed {
            lock.unlock()
            throw TransportError.sessionClosed
        }
        lock.unlock()

        let seq: Int64 = {
            seqLock.lock()
            defer { seqLock.unlock() }
            nextSeq += 1
            return nextSeq
        }()

        let attachment = codec.buildAttachment(
            seq: seq,
            tsNsec: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
            gid: gid
        )

        let timeoutMs = Self.durationToMillis(timeout)
        let state = CallState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                state.set(continuation: continuation, timeout: timeout)

                do {
                    try client.get(
                        keyExpr: keyExpr,
                        payload: requestCDR,
                        attachment: attachment,
                        timeoutMs: timeoutMs,
                        handler: { result in
                            switch result {
                            case .success(let sample):
                                state.deliverReply(payload: sample.payload, isError: false)
                            case .failure(let err):
                                let msg: String
                                if case .queryReplyError(let m) = err {
                                    msg = m
                                } else {
                                    msg = err.localizedDescription ?? "Zenoh get error"
                                }
                                state.deliverReply(payload: Data(msg.utf8), isError: true)
                            }
                        },
                        onFinish: {
                            state.finish()
                        }
                    )
                } catch {
                    state.fail(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    package func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let token = livelinessToken
        livelinessToken = nil
        lock.unlock()
        try? token?.close()
    }

    private static func durationToMillis(_ duration: Duration) -> UInt32 {
        let comps = duration.components
        let seconds = max(0, Int64(comps.seconds))
        let attoseconds = Int64(comps.attoseconds)
        // 1 ms == 10^15 attoseconds
        let ms = seconds.multipliedReportingOverflow(by: 1_000)
        if ms.overflow {
            return UInt32.max
        }
        let total = ms.partialValue + attoseconds / 1_000_000_000_000_000
        if total < 0 { return 0 }
        if total > Int64(UInt32.max) { return UInt32.max }
        return UInt32(total)
    }
}

/// Internal state holder for a single in-flight `call`. Coordinates the
/// reply / finish / cancel paths under a single lock so the continuation
/// is only resumed once.
private final class CallState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: Duration = .seconds(0)
    private var resolved = false
    private var receivedReply: (payload: Data, isError: Bool)?

    func set(continuation: CheckedContinuation<Data, Error>, timeout: Duration) {
        lock.lock()
        self.continuation = continuation
        self.timeout = timeout
        lock.unlock()
    }

    /// Called from the get handler. We store the first reply but defer the
    /// actual continuation resume until `onFinish` fires — this matches the
    /// shape `rmw_zenoh_cpp` uses (one reply per service get) and keeps the
    /// resume-once invariant straightforward.
    func deliverReply(payload: Data, isError: Bool) {
        lock.lock()
        if receivedReply == nil {
            receivedReply = (payload, isError)
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let cont = continuation
        continuation = nil
        let reply = receivedReply
        let dur = timeout
        lock.unlock()

        guard let cont = cont else { return }
        if let reply = reply {
            if reply.isError {
                let msg = String(decoding: reply.payload, as: UTF8.self)
                cont.resume(throwing: TransportError.serviceHandlerFailed(msg))
            } else {
                cont.resume(returning: reply.payload)
            }
        } else {
            cont.resume(throwing: TransportError.requestTimeout(dur))
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    func cancel() {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: TransportError.requestCancelled)
    }
}
