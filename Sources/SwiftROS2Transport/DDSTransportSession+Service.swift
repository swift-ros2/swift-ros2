// DDSTransportSession+Service.swift
// Service Server / Client implementation for the DDS transport.
//
// rmw_cyclonedds_cpp pairs each service with two topics:
// - rq/<service>Request (client → server)
// - rr/<service>Reply   (server → client)
//
// The wire payload on each topic is `[CDR header (4) | RMWRequestId (16) | user CDR body]`.
// The 16-byte request header (`guid`, `seq`) is rmw_cyclonedds_cpp's
// `cdds_request_header_t`; the server echoes it verbatim, which is what
// correlates a reply to the original request.

import Foundation
import SwiftROS2Wire

extension DDSTransportSession {
    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Service name cannot be empty")
        }
        guard !serviceTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Service type name cannot be empty")
        }

        lock.lock()
        guard isOpen else {
            lock.unlock()
            throw TransportError.notConnected
        }
        lock.unlock()

        let codec = DDSWireCodec()
        let names = codec.serviceTopicNames(serviceName: name, serviceTypeName: serviceTypeName)
        let cfg = bridgeQoS(from: qos)

        // Reply writer (server → client).
        let replyUserData = codec.userDataString(typeHash: responseTypeHash)
        let replyWriter = try client.createRawWriter(
            topicName: names.replyTopic,
            typeName: names.replyTypeName,
            qos: cfg,
            userData: replyUserData
        )

        let server = DDSTransportServiceServerImpl(
            client: client,
            replyWriter: replyWriter,
            replyTopic: names.replyTopic,
            name: name,
            handler: handler
        )

        // Request reader (client → server). Hand each incoming sample to the server.
        let requestUserData = codec.userDataString(typeHash: requestTypeHash)
        let requestReader: any DDSReaderHandle
        do {
            requestReader = try client.createRawReader(
                topicName: names.requestTopic,
                typeName: names.requestTypeName,
                qos: cfg,
                userData: requestUserData,
                handler: { [weak server] data, timestamp in
                    server?.handleIncomingRequest(data: data, timestamp: timestamp)
                }
            )
        } catch {
            client.destroyWriter(replyWriter)
            if let e = error as? DDSError {
                throw TransportError.subscriberCreationFailed(e.errorDescription ?? "\(e)")
            }
            throw error
        }
        server.attachRequestReader(requestReader)

        appendServiceServer(server)
        return server
    }

    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Service name cannot be empty")
        }
        guard !serviceTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Service type name cannot be empty")
        }

        lock.lock()
        guard isOpen else {
            lock.unlock()
            throw TransportError.notConnected
        }
        lock.unlock()

        let codec = DDSWireCodec()
        let names = codec.serviceTopicNames(serviceName: name, serviceTypeName: serviceTypeName)
        let cfg = bridgeQoS(from: qos)

        // Both client endpoints carry the same `clientid`, so an rmw_cyclonedds_cpp
        // server waits for its reply writer to match our reply reader before it
        // answers a request (see DDSClientServiceID).
        let clientId = DDSClientServiceID.make()

        // Request writer (client → server).
        let requestUserData = DDSClientServiceID.clientUserData(
            id: clientId, typeHashUserData: codec.userDataString(typeHash: requestTypeHash))
        let requestWriter = try client.createRawWriter(
            topicName: names.requestTopic,
            typeName: names.requestTypeName,
            qos: cfg,
            userData: requestUserData
        )

        // 8 random bytes: rmw_cyclonedds_cpp echoes `guid` verbatim and we only
        // use it to recognise our own replies.
        let writerGuid = Array(GIDManager().getOrCreateGid().prefix(RMWRequestId.guidByteCount))
        let serviceClient = DDSTransportServiceClientImpl(
            client: client,
            requestWriter: requestWriter,
            requestTopic: names.requestTopic,
            name: name,
            writerGuid: writerGuid
        )

        // Reply reader (server → client).
        let replyUserData = DDSClientServiceID.clientUserData(
            id: clientId, typeHashUserData: codec.userDataString(typeHash: responseTypeHash))
        let replyReader: any DDSReaderHandle
        do {
            replyReader = try client.createRawReader(
                topicName: names.replyTopic,
                typeName: names.replyTypeName,
                qos: cfg,
                userData: replyUserData,
                handler: { [weak serviceClient] data, timestamp in
                    serviceClient?.handleIncomingReply(data: data, timestamp: timestamp)
                }
            )
        } catch {
            client.destroyWriter(requestWriter)
            if let e = error as? DDSError {
                throw TransportError.subscriberCreationFailed(e.errorDescription ?? "\(e)")
            }
            throw error
        }
        serviceClient.attachReplyReader(replyReader)

        appendServiceClient(serviceClient)
        return serviceClient
    }

    private func appendServiceClient(_ serviceClient: DDSTransportServiceClientImpl) {
        lock.lock()
        serviceClients.append(serviceClient)
        lock.unlock()
    }

    // MARK: - Internal lock helpers

    private func appendServiceServer(_ server: DDSTransportServiceServerImpl) {
        lock.lock()
        serviceServers.append(server)
        lock.unlock()
    }

    func takeAllServiceServers() -> [DDSTransportServiceServerImpl] {
        lock.lock()
        let out = serviceServers
        serviceServers.removeAll()
        lock.unlock()
        return out
    }

    func takeAllServiceClients() -> [DDSTransportServiceClientImpl] {
        lock.lock()
        let out = serviceClients
        serviceClients.removeAll()
        lock.unlock()
        return out
    }
}

// MARK: - DDS Transport Service Server

final class DDSTransportServiceServerImpl: TransportService, @unchecked Sendable {
    private let client: any DDSClientProtocol
    private var replyWriter: (any DDSWriterHandle)?
    private var requestReader: (any DDSReaderHandle)?
    private let replyTopic: String
    package let name: String
    private let handler: @Sendable (Data) async throws -> Data
    private let lock = NSLock()
    private var closed = false

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        return (replyWriter?.isActive ?? false) && (requestReader?.isActive ?? false)
    }

    init(
        client: any DDSClientProtocol,
        replyWriter: any DDSWriterHandle,
        replyTopic: String,
        name: String,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.client = client
        self.replyWriter = replyWriter
        self.replyTopic = replyTopic
        self.name = name
        self.handler = handler
    }

    func attachRequestReader(_ reader: any DDSReaderHandle) {
        lock.lock()
        requestReader = reader
        lock.unlock()
    }

    /// Called from the DDS reader thread. Decodes the sample-identity prefix,
    /// hands the user CDR to the user handler, and writes the reply with the
    /// same `RMWRequestId`.
    func handleIncomingRequest(data: Data, timestamp: UInt64) {
        let parsedId: RMWRequestId
        let userRequestCDR: Data
        do {
            (parsedId, userRequestCDR) = try SampleIdentityPrefix.decode(wirePayload: data)
        } catch {
            // Drop malformed request silently; the wire layer is best-effort.
            return
        }

        let captured = (
            client: client, writer: replyWriterSnapshot(), topic: replyTopic, name: name,
            handler: handler
        )
        // Detached so the user handler runs on the global executor regardless
        // of the DDS reader thread's task-local context. Linux x86_64 / aarch64
        // under `swift test --parallel` had unstructured `Task { ... }`
        // starving here; detached scheduling clears the issue.
        Task.detached(priority: .userInitiated) { [captured, parsedId, userRequestCDR] in
            do {
                let userReplyCDR = try await captured.handler(userRequestCDR)
                let wire = SampleIdentityPrefix.encode(requestId: parsedId, userCDR: userReplyCDR)
                if let w = captured.writer {
                    try? captured.client.writeRawCDR(writer: w, data: wire, timestamp: 0)
                }
            } catch {
                // User handler threw — best-effort drop. Future enhancement: surface as a
                // negative-ack reply once the wire format is finalized.
                _ = captured.name
            }
        }
    }

    private func replyWriterSnapshot() -> (any DDSWriterHandle)? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : replyWriter
    }

    package func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let w = replyWriter
        let r = requestReader
        replyWriter = nil
        requestReader = nil
        lock.unlock()

        if let r = r {
            client.destroyReader(r)
        }
        if let w = w {
            client.destroyWriter(w)
        }
    }
}

// MARK: - DDS Transport Service Client

final class DDSTransportServiceClientImpl: TransportClient, @unchecked Sendable {
    private let client: any DDSClientProtocol
    private var requestWriter: (any DDSWriterHandle)?
    private var replyReader: (any DDSReaderHandle)?
    private let requestTopic: String
    package let name: String
    private let writerGuid: [UInt8]
    private let pending = ClientPendingTable()
    private let seqLock = NSLock()
    private var nextSeq: Int64 = 0
    private let lock = NSLock()
    private var closed = false

    package var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        return (requestWriter?.isActive ?? false) && (replyReader?.isActive ?? false)
    }

    init(
        client: any DDSClientProtocol,
        requestWriter: any DDSWriterHandle,
        requestTopic: String,
        name: String,
        writerGuid: [UInt8]
    ) {
        self.client = client
        self.requestWriter = requestWriter
        self.requestTopic = requestTopic
        self.name = name
        self.writerGuid = writerGuid
    }

    func attachReplyReader(_ reader: any DDSReaderHandle) {
        lock.lock()
        replyReader = reader
        lock.unlock()
    }

    /// Returns once the server is reachable both ways: our request writer has
    /// matched its request reader and our reply reader has matched its reply
    /// writer — the check rmw_cyclonedds_cpp's `rmw_service_server_is_available`
    /// makes. A request written before the request side matched is dropped by
    /// DDS, and a reply written before the reply side matched never arrives.
    package func waitForService(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            lock.lock()
            let writer = closed ? nil : requestWriter
            let reader = closed ? nil : replyReader
            lock.unlock()
            if let w = writer, let r = reader,
                client.isPublicationMatched(writer: w), client.isSubscriptionMatched(reader: r)
            {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
        }
        throw TransportError.requestTimeout(timeout)
    }

    package func call(requestCDR: Data, timeout: Duration) async throws -> Data {
        guard requestCDR.count >= 4 else {
            throw TransportError.invalidConfiguration("requestCDR missing 4-byte CDR encapsulation header")
        }

        lock.lock()
        let writerOpt = closed ? nil : requestWriter
        lock.unlock()
        guard let writer = writerOpt else {
            throw TransportError.sessionClosed
        }

        let seq: Int64 = {
            seqLock.lock()
            defer { seqLock.unlock() }
            nextSeq += 1
            return nextSeq
        }()

        let id = RMWRequestId(writerGuid: writerGuid, sequenceNumber: seq)
        let wire = SampleIdentityPrefix.encode(requestId: id, userCDR: requestCDR)

        // Spawn a detached timeout helper that resolves the pending entry with
        // `requestTimeout` when the deadline elapses. We keep a handle so we can
        // cancel it when the reply arrives first.
        let pendingTable = self.pending
        // If the sleep is cancelled (because the reply arrived first or the
        // parent Task was cancelled), `Task.sleep` throws CancellationError and
        // we exit *without* resolving the pending entry — otherwise we race
        // with the reply / cancel paths and may surface `requestTimeout`
        // instead of the actual outcome.
        // A caller-supplied timeout large enough to overflow `Task.sleep`'s
        // internal nanosecond conversion (e.g. `.seconds(Int.max)`, used as
        // "no timeout") must not be handed to `Task.sleep` — skip starting
        // the timeout task entirely and wait indefinitely instead.
        let timeoutTask: Task<Void, Never>? =
            isSafeSleepDuration(timeout)
            ? Task { [pendingTable] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await pendingTable.resolve(seq: seq, with: .failure(TransportError.requestTimeout(timeout)))
            } : nil

        return try await withTaskCancellationHandler {
            do {
                let body = try await pendingTable.insert(seq: seq) { _ in
                    // Continuation registered; issue the wire request immediately.
                    do {
                        try self.client.writeRawCDR(writer: writer, data: wire, timestamp: 0)
                    } catch {
                        // The actor still has the continuation; resolve it asynchronously.
                        Task { [pendingTable] in
                            await pendingTable.resolve(seq: seq, with: .failure(error))
                        }
                    }
                }
                timeoutTask?.cancel()
                return body
            } catch {
                timeoutTask?.cancel()
                throw error
            }
        } onCancel: {
            timeoutTask?.cancel()
            Task { [pendingTable] in
                await pendingTable.cancel(seq: seq)
            }
        }
    }

    /// Called from the DDS reader thread.
    func handleIncomingReply(data: Data, timestamp: UInt64) {
        let parsedId: RMWRequestId
        let userReplyCDR: Data
        do {
            (parsedId, userReplyCDR) = try SampleIdentityPrefix.decode(wirePayload: data)
        } catch {
            return
        }
        // Filter on writerGuid so this client only consumes its own replies.
        guard parsedId.writerGuid == writerGuid else { return }
        let seq = parsedId.sequenceNumber
        Task { [pending] in
            await pending.resolve(seq: seq, with: .success(userReplyCDR))
        }
    }

    package func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let w = requestWriter
        let r = replyReader
        requestWriter = nil
        replyReader = nil
        lock.unlock()

        Task { [pending] in
            await pending.failAll(TransportError.sessionClosed)
        }

        if let r = r {
            client.destroyReader(r)
        }
        if let w = w {
            client.destroyWriter(w)
        }
    }
}
