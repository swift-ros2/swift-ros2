// DDSTransportSession+Action.swift
// Action Server / Client implementation for the DDS transport.
//
// rmw_cyclonedds_cpp materializes a single ROS 2 action under <ns>/<name>/_action/
// as 3 service pairs (send_goal, cancel_goal, get_result) plus 2 topics
// (feedback, status). Reuses the existing rq/rr/rt primitives — no new C-bridge.
// The service pairs carry the same 16-byte `RMWRequestId` (rmw_cyclonedds_cpp's
// `cdds_request_header_t`) as plain services; goal / feedback / result frames
// carry a single CDR encapsulation header (see `ActionFrameDecoder`).

import Foundation
import SwiftROS2Wire

extension DDSTransportSession {
    package func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Action name cannot be empty")
        }
        guard !actionTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Action type name cannot be empty")
        }

        lock.lock()
        guard isOpen else {
            lock.unlock()
            throw TransportError.notConnected
        }
        lock.unlock()

        let codec = DDSWireCodec()
        let names = codec.actionTopicNames(
            namespace: extractNamespace(from: name),
            actionName: extractTopicName(from: name),
            actionTypeName: actionTypeName
        )

        let cfg = bridgeQoS(from: qos)
        // status topic: transient_local depth 1 (matches rclcpp).
        let statusQoS = bridgeQoS(
            from: TransportQoS(
                reliability: qos.reliability,
                durability: .transientLocal,
                history: .keepLast(1)
            ))

        // Reply writers for the three services.
        // Build all writers + readers under a rollback guard so a partial
        // failure tears down every entity already created. Without this,
        // a throw on the last writer would leak the previous four (and a
        // throw mid-readers would leak readers in addition to the writers).
        var createdWriters: [any DDSWriterHandle] = []
        var createdReaders: [any DDSReaderHandle] = []

        func rollbackAndThrow(_ error: Error) throws -> Never {
            for r in createdReaders { client.destroyReader(r) }
            for w in createdWriters { client.destroyWriter(w) }
            if let e = error as? DDSError {
                throw TransportError.subscriberCreationFailed(e.errorDescription ?? "\(e)")
            }
            throw error
        }

        func makeWriter(
            topic: String, type: String, qosCfg: DDSBridgeQoSConfig, userData: String?
        ) throws -> any DDSWriterHandle {
            do {
                let w = try client.createRawWriter(
                    topicName: topic, typeName: type, qos: qosCfg, userData: userData
                )
                createdWriters.append(w)
                return w
            } catch {
                try rollbackAndThrow(error)
            }
        }

        func makeReader(
            topic: String, type: String, qosCfg: DDSBridgeQoSConfig, userData: String?,
            handler: @escaping @Sendable (Data, UInt64) -> Void
        ) throws -> any DDSReaderHandle {
            do {
                let r = try client.createRawReader(
                    topicName: topic, typeName: type, qos: qosCfg,
                    userData: userData, handler: handler
                )
                createdReaders.append(r)
                return r
            } catch {
                try rollbackAndThrow(error)
            }
        }

        let sendGoalReplyWriter = try makeWriter(
            topic: names.sendGoalReplyTopic, type: names.sendGoalReplyTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.sendGoalResponse)
        )
        let cancelGoalReplyWriter = try makeWriter(
            topic: names.cancelGoalReplyTopic, type: names.cancelGoalReplyTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.cancelGoalResponse)
        )
        let getResultReplyWriter = try makeWriter(
            topic: names.getResultReplyTopic, type: names.getResultReplyTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.getResultResponse)
        )
        let feedbackWriter = try makeWriter(
            topic: names.feedbackTopic, type: names.feedbackTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.feedbackMessage)
        )
        let statusWriter = try makeWriter(
            topic: names.statusTopic, type: names.statusTypeName,
            qosCfg: statusQoS, userData: codec.userDataString(typeHash: roleTypeHashes.statusArray)
        )

        let server = DDSTransportActionServerImpl(
            client: client,
            name: name,
            names: names,
            handlers: handlers,
            sendGoalReplyWriter: sendGoalReplyWriter,
            cancelGoalReplyWriter: cancelGoalReplyWriter,
            getResultReplyWriter: getResultReplyWriter,
            feedbackWriter: feedbackWriter,
            statusWriter: statusWriter
        )

        let sendGoalReader = try makeReader(
            topic: names.sendGoalRequestTopic, type: names.sendGoalRequestTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.sendGoalRequest),
            handler: { [weak server] data, _ in server?.handleSendGoal(data: data) }
        )
        let cancelGoalReader = try makeReader(
            topic: names.cancelGoalRequestTopic, type: names.cancelGoalRequestTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.cancelGoalRequest),
            handler: { [weak server] data, _ in server?.handleCancelGoal(data: data) }
        )
        let getResultReader = try makeReader(
            topic: names.getResultRequestTopic, type: names.getResultRequestTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.getResultRequest),
            handler: { [weak server] data, _ in server?.handleGetResult(data: data) }
        )
        server.attachReaders(
            sendGoal: sendGoalReader, cancelGoal: cancelGoalReader, getResult: getResultReader
        )

        appendActionServer(server)
        return server
    }

    package func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS
    ) throws -> any TransportActionClient {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Action name cannot be empty")
        }
        guard !actionTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Action type name cannot be empty")
        }
        lock.lock()
        guard isOpen else {
            lock.unlock()
            throw TransportError.notConnected
        }
        lock.unlock()

        let codec = DDSWireCodec()
        let names = codec.actionTopicNames(
            namespace: extractNamespace(from: name),
            actionName: extractTopicName(from: name),
            actionTypeName: actionTypeName
        )
        let cfg = bridgeQoS(from: qos)
        let statusQoS = bridgeQoS(
            from: TransportQoS(
                reliability: qos.reliability,
                durability: .transientLocal,
                history: .keepLast(1)
            ))

        // Same rollback guard as the server path: any partial creation
        // failure tears down every entity already created so we don't leak
        // DDS handles or callbacks for an action client that never returned.
        var createdWriters: [any DDSWriterHandle] = []
        var createdReaders: [any DDSReaderHandle] = []

        func rollbackAndThrow(_ error: Error) throws -> Never {
            for r in createdReaders { client.destroyReader(r) }
            for w in createdWriters { client.destroyWriter(w) }
            if let e = error as? DDSError {
                throw TransportError.subscriberCreationFailed(e.errorDescription ?? "\(e)")
            }
            throw error
        }

        func makeWriter(
            topic: String, type: String, qosCfg: DDSBridgeQoSConfig, userData: String?
        ) throws -> any DDSWriterHandle {
            do {
                let w = try client.createRawWriter(
                    topicName: topic, typeName: type, qos: qosCfg, userData: userData
                )
                createdWriters.append(w)
                return w
            } catch {
                try rollbackAndThrow(error)
            }
        }

        func makeReader(
            topic: String, type: String, qosCfg: DDSBridgeQoSConfig, userData: String?,
            handler: @escaping @Sendable (Data, UInt64) -> Void
        ) throws -> any DDSReaderHandle {
            do {
                let r = try client.createRawReader(
                    topicName: topic, typeName: type, qos: qosCfg,
                    userData: userData, handler: handler
                )
                createdReaders.append(r)
                return r
            } catch {
                try rollbackAndThrow(error)
            }
        }

        // Each of the three service pairs is its own rmw_cyclonedds_cpp client:
        // its request writer and reply reader share one `clientid`, so the
        // server waits for the reply path before it answers (see DDSClientServiceID).
        let sendGoalId = DDSClientServiceID.make()
        let cancelGoalId = DDSClientServiceID.make()
        let getResultId = DDSClientServiceID.make()
        func clientUserData(_ id: [UInt8], _ typeHash: String?) -> String {
            DDSClientServiceID.clientUserData(id: id, typeHashUserData: codec.userDataString(typeHash: typeHash))
        }

        let sendGoalWriter = try makeWriter(
            topic: names.sendGoalRequestTopic, type: names.sendGoalRequestTypeName,
            qosCfg: cfg, userData: clientUserData(sendGoalId, roleTypeHashes.sendGoalRequest)
        )
        let cancelGoalWriter = try makeWriter(
            topic: names.cancelGoalRequestTopic, type: names.cancelGoalRequestTypeName,
            qosCfg: cfg, userData: clientUserData(cancelGoalId, roleTypeHashes.cancelGoalRequest)
        )
        let getResultWriter = try makeWriter(
            topic: names.getResultRequestTopic, type: names.getResultRequestTypeName,
            qosCfg: cfg, userData: clientUserData(getResultId, roleTypeHashes.getResultRequest)
        )

        // 8 random bytes: rmw_cyclonedds_cpp echoes `guid` verbatim and we only
        // use it to recognise our own replies.
        let writerGuid = Array(GIDManager.randomGid().prefix(RMWRequestId.guidByteCount))
        let cli = DDSTransportActionClientImpl(
            client: client,
            name: name,
            names: names,
            writerGuid: writerGuid,
            sendGoalWriter: sendGoalWriter,
            cancelGoalWriter: cancelGoalWriter,
            getResultWriter: getResultWriter
        )

        let sendGoalReplyReader = try makeReader(
            topic: names.sendGoalReplyTopic, type: names.sendGoalReplyTypeName,
            qosCfg: cfg, userData: clientUserData(sendGoalId, roleTypeHashes.sendGoalResponse),
            handler: { [weak cli] data, _ in cli?.handleSendGoalReply(data: data) }
        )
        let cancelGoalReplyReader = try makeReader(
            topic: names.cancelGoalReplyTopic, type: names.cancelGoalReplyTypeName,
            qosCfg: cfg, userData: clientUserData(cancelGoalId, roleTypeHashes.cancelGoalResponse),
            handler: { [weak cli] data, _ in cli?.handleCancelGoalReply(data: data) }
        )
        let getResultReplyReader = try makeReader(
            topic: names.getResultReplyTopic, type: names.getResultReplyTypeName,
            qosCfg: cfg, userData: clientUserData(getResultId, roleTypeHashes.getResultResponse),
            handler: { [weak cli] data, _ in cli?.handleGetResultReply(data: data) }
        )
        let feedbackReader = try makeReader(
            topic: names.feedbackTopic, type: names.feedbackTypeName,
            qosCfg: cfg, userData: codec.userDataString(typeHash: roleTypeHashes.feedbackMessage),
            handler: { [weak cli] data, _ in cli?.handleFeedbackSample(data: data) }
        )
        let statusReader = try makeReader(
            topic: names.statusTopic, type: names.statusTypeName,
            qosCfg: statusQoS, userData: codec.userDataString(typeHash: roleTypeHashes.statusArray),
            handler: { [weak cli] data, _ in cli?.handleStatusSample(data: data) }
        )
        cli.attachReaders(
            sendGoalReply: sendGoalReplyReader,
            cancelGoalReply: cancelGoalReplyReader,
            getResultReply: getResultReplyReader,
            feedback: feedbackReader,
            status: statusReader
        )

        appendActionClient(cli)
        return cli
    }

    func appendActionServer(_ server: DDSTransportActionServerImpl) {
        lock.lock()
        actionServers.append(server)
        lock.unlock()
    }

    func takeAllActionServers() -> [DDSTransportActionServerImpl] {
        lock.lock()
        let out = actionServers
        actionServers.removeAll()
        lock.unlock()
        return out
    }

    func appendActionClient(_ cli: DDSTransportActionClientImpl) {
        lock.lock()
        actionClients.append(cli)
        lock.unlock()
    }

    func takeAllActionClients() -> [DDSTransportActionClientImpl] {
        lock.lock()
        let out = actionClients
        actionClients.removeAll()
        lock.unlock()
        return out
    }

    // namespace / topic helpers — local to the DDS action / service paths.
    func extractNamespace(from name: String) -> String {
        let stripped = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard let lastSlash = stripped.lastIndex(of: "/") else { return "" }
        return "/" + stripped[..<lastSlash]
    }

    func extractTopicName(from name: String) -> String {
        let stripped = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard let lastSlash = stripped.lastIndex(of: "/") else { return stripped }
        return String(stripped[stripped.index(after: lastSlash)...])
    }
}

// MARK: - DDS Transport Action Server

final class DDSTransportActionServerImpl: TransportActionServer, @unchecked Sendable {
    let client: any DDSClientProtocol
    let name: String
    let names: DDSWireCodec.ActionTopicNames
    let handlers: TransportActionServerHandlers

    private var sendGoalReplyWriter: (any DDSWriterHandle)?
    private var cancelGoalReplyWriter: (any DDSWriterHandle)?
    private var getResultReplyWriter: (any DDSWriterHandle)?
    private var feedbackWriter: (any DDSWriterHandle)?
    private var statusWriter: (any DDSWriterHandle)?

    private var sendGoalReader: (any DDSReaderHandle)?
    private var cancelGoalReader: (any DDSReaderHandle)?
    private var getResultReader: (any DDSReaderHandle)?

    private let lock = NSLock()
    private var closed = false

    init(
        client: any DDSClientProtocol,
        name: String,
        names: DDSWireCodec.ActionTopicNames,
        handlers: TransportActionServerHandlers,
        sendGoalReplyWriter: any DDSWriterHandle,
        cancelGoalReplyWriter: any DDSWriterHandle,
        getResultReplyWriter: any DDSWriterHandle,
        feedbackWriter: any DDSWriterHandle,
        statusWriter: any DDSWriterHandle
    ) {
        self.client = client
        self.name = name
        self.names = names
        self.handlers = handlers
        self.sendGoalReplyWriter = sendGoalReplyWriter
        self.cancelGoalReplyWriter = cancelGoalReplyWriter
        self.getResultReplyWriter = getResultReplyWriter
        self.feedbackWriter = feedbackWriter
        self.statusWriter = statusWriter
    }

    func attachReaders(
        sendGoal: any DDSReaderHandle,
        cancelGoal: any DDSReaderHandle,
        getResult: any DDSReaderHandle
    ) {
        lock.lock()
        sendGoalReader = sendGoal
        cancelGoalReader = cancelGoal
        getResultReader = getResult
        lock.unlock()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        // Every wire-level entity must still be live for the server to be
        // considered active — `isActive == true` should mean the full action
        // surface (3 services × {request reader, reply writer} + feedback +
        // status writers) is operational.
        let writers: [(any DDSWriterHandle)?] = [
            sendGoalReplyWriter, cancelGoalReplyWriter, getResultReplyWriter,
            feedbackWriter, statusWriter,
        ]
        let readers: [(any DDSReaderHandle)?] = [
            sendGoalReader, cancelGoalReader, getResultReader,
        ]
        for w in writers where !(w?.isActive ?? false) { return false }
        for r in readers where !(r?.isActive ?? false) { return false }
        return true
    }

    // Test-helper accessors for the topic strings — used by the unit tests.
    var sendGoalRequestTopic: String { names.sendGoalRequestTopic }
    var sendGoalReplyTopic: String { names.sendGoalReplyTopic }
    var cancelGoalRequestTopic: String { names.cancelGoalRequestTopic }
    var cancelGoalReplyTopic: String { names.cancelGoalReplyTopic }
    var feedbackTopic: String { names.feedbackTopic }
    var statusTopic: String { names.statusTopic }

    func handleSendGoal(data: Data) {
        serve(data, replyWriter: \.sendGoalReplyWriter) { request, handlers in
            let (goalId, goalCDR) = try ActionFrameDecoder.decodeSendGoalRequest(from: request)
            let (accepted, sec, nsec) = try await handlers.onSendGoal(goalId, goalCDR)
            return ActionFrameDecoder.encodeSendGoalResponse(accepted: accepted, stampSec: sec, stampNanosec: nsec)
        }
    }

    func handleCancelGoal(data: Data) {
        serve(data, replyWriter: \.cancelGoalReplyWriter) { request, handlers in
            try await handlers.onCancelGoal(request)
        }
    }

    func handleGetResult(data: Data) {
        serve(data, replyWriter: \.getResultReplyWriter) { request, handlers in
            let goalId = try ActionFrameDecoder.decodeGetResultRequest(from: request)
            let ack = try await handlers.onGetResult(goalId)
            return ActionFrameDecoder.encodeGetResultResponse(status: ack.status, resultCDR: ack.resultCDR)
        }
    }

    /// Answers one request sample: strips its sample-identity prefix, runs
    /// `respond` on the request CDR off the DDS reader thread, and writes the
    /// response under the same `RMWRequestId` on the reply writer at
    /// `replyWriter`. A malformed sample or a throwing `respond` gets no reply.
    private func serve(
        _ data: Data,
        replyWriter: ReferenceWritableKeyPath<DDSTransportActionServerImpl, (any DDSWriterHandle)?>,
        respond: @escaping @Sendable (_ request: Data, _ handlers: TransportActionServerHandlers) async throws -> Data
    ) {
        guard let (requestId, request) = try? SampleIdentityPrefix.decode(wirePayload: data) else { return }
        let handlers = self.handlers
        let writer = replyWriterSnapshot(replyWriter)
        let client = self.client
        Task.detached(priority: .userInitiated) { [requestId, request, handlers, writer, client] in
            guard let response = try? await respond(request, handlers), let writer else { return }
            let wire = SampleIdentityPrefix.encode(requestId: requestId, userCDR: response)
            try? client.writeRawCDR(writer: writer, data: wire, timestamp: 0)
        }
    }

    /// Server-side: publish a feedback frame for a specific goal.
    func publishFeedback(goalId: [UInt8], feedbackCDR: Data) throws {
        lock.lock()
        let writer = closed ? nil : feedbackWriter
        lock.unlock()
        guard let writer = writer else { throw TransportError.publisherClosed }
        let frame = ActionFrameDecoder.encodeFeedbackMessage(
            goalId: goalId, feedbackCDR: feedbackCDR
        )
        try client.writeRawCDR(writer: writer, data: frame, timestamp: 0)
    }

    /// Server-side: publish a full status array (one entry per active goal).
    func publishStatus(entries: [ActionStatusEntry]) throws {
        lock.lock()
        let writer = closed ? nil : statusWriter
        lock.unlock()
        guard let writer = writer else { throw TransportError.publisherClosed }
        let frame = ActionFrameDecoder.encodeStatusArray(entries: entries)
        try client.writeRawCDR(writer: writer, data: frame, timestamp: 0)
    }

    private func replyWriterSnapshot(
        _ keyPath: ReferenceWritableKeyPath<DDSTransportActionServerImpl, (any DDSWriterHandle)?>
    ) -> (any DDSWriterHandle)? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : self[keyPath: keyPath]
    }

    func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let writers: [any DDSWriterHandle] = [
            sendGoalReplyWriter, cancelGoalReplyWriter, getResultReplyWriter,
            feedbackWriter, statusWriter,
        ].compactMap { $0 }
        let readers: [any DDSReaderHandle] = [
            sendGoalReader, cancelGoalReader, getResultReader,
        ].compactMap { $0 }
        sendGoalReplyWriter = nil
        cancelGoalReplyWriter = nil
        getResultReplyWriter = nil
        feedbackWriter = nil
        statusWriter = nil
        sendGoalReader = nil
        cancelGoalReader = nil
        getResultReader = nil
        lock.unlock()

        for r in readers {
            client.destroyReader(r)
        }
        for w in writers {
            client.destroyWriter(w)
        }
    }
}

// MARK: - DDS Transport Action Client

final class DDSTransportActionClientImpl: TransportActionClient, @unchecked Sendable {
    private let client: any DDSClientProtocol
    let name: String
    let names: DDSWireCodec.ActionTopicNames
    private let writerGuid: [UInt8]

    private var sendGoalWriter: (any DDSWriterHandle)?
    private var cancelGoalWriter: (any DDSWriterHandle)?
    private var getResultWriter: (any DDSWriterHandle)?
    private var sendGoalReplyReader: (any DDSReaderHandle)?
    private var cancelGoalReplyReader: (any DDSReaderHandle)?
    private var getResultReplyReader: (any DDSReaderHandle)?
    private var feedbackReader: (any DDSReaderHandle)?
    private var statusReader: (any DDSReaderHandle)?

    private let lock = NSLock()
    private var closed = false

    private let seqLock = NSLock()
    private var nextSeq: Int64 = 0

    private let sendGoalPending = ClientPendingTable()
    private let cancelGoalPending = ClientPendingTable()
    private let getResultPending = ClientPendingTable()

    /// Shared per-goal stream / continuation tracker.
    let pending = ActionPendingTable()

    /// What the feedback / status reader callbacks hand to `pending`, in
    /// arrival order. A task per sample let a later sample reach `pending`
    /// first: a terminal status that overtakes feedback received before it
    /// ends the feedback stream and drops that feedback. One task applies the
    /// events in order instead.
    private enum InboundEvent: Sendable {
        case feedback(goalId: [UInt8], cdr: Data)
        case status([ActionStatusEntry])
        /// Resumed once every event received before it has reached `pending`.
        case barrier(CheckedContinuation<Void, Never>)
    }
    private let inbound: AsyncStream<InboundEvent>.Continuation

    var feedbackTopic: String { names.feedbackTopic }
    var statusTopic: String { names.statusTopic }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        // Mirror the server's stricter check — every wire-level entity must
        // still be live, otherwise callers get a misleading green light.
        let writers: [(any DDSWriterHandle)?] = [
            sendGoalWriter, cancelGoalWriter, getResultWriter,
        ]
        let readers: [(any DDSReaderHandle)?] = [
            sendGoalReplyReader, cancelGoalReplyReader, getResultReplyReader,
            feedbackReader, statusReader,
        ]
        for w in writers where !(w?.isActive ?? false) { return false }
        for r in readers where !(r?.isActive ?? false) { return false }
        return true
    }

    init(
        client: any DDSClientProtocol,
        name: String,
        names: DDSWireCodec.ActionTopicNames,
        writerGuid: [UInt8],
        sendGoalWriter: any DDSWriterHandle,
        cancelGoalWriter: any DDSWriterHandle,
        getResultWriter: any DDSWriterHandle
    ) {
        self.client = client
        self.name = name
        self.names = names
        self.writerGuid = writerGuid
        self.sendGoalWriter = sendGoalWriter
        self.cancelGoalWriter = cancelGoalWriter
        self.getResultWriter = getResultWriter
        var cont: AsyncStream<InboundEvent>.Continuation!
        let events = AsyncStream<InboundEvent> { cont = $0 }
        self.inbound = cont
        // The pump captures only the table (not self), and ends when `close()`
        // or `deinit` finishes the stream, after the events already queued.
        Task { [pending] in
            for await event in events {
                switch event {
                case .feedback(let goalId, let cdr):
                    await pending.yieldFeedback(goalId: goalId, cdr: cdr)
                case .status(let entries):
                    for e in entries {
                        await pending.yieldStatus(goalId: e.uuid, status: e.status)
                    }
                case .barrier(let done):
                    done.resume()
                }
            }
        }
    }

    deinit {
        inbound.finish()
    }

    func attachReaders(
        sendGoalReply: any DDSReaderHandle,
        cancelGoalReply: any DDSReaderHandle,
        getResultReply: any DDSReaderHandle,
        feedback: any DDSReaderHandle,
        status: any DDSReaderHandle
    ) {
        lock.lock()
        sendGoalReplyReader = sendGoalReply
        cancelGoalReplyReader = cancelGoalReply
        getResultReplyReader = getResultReply
        feedbackReader = feedback
        statusReader = status
        lock.unlock()
    }

    func waitForActionServer(timeout: Duration) async throws {
        // Per the protocol contract a client should only see "available" once
        // the full action surface is reachable on the other side. Each of the
        // three service pairs — `send_goal`, `cancel_goal`, and `get_result` —
        // must be matched both ways: the request writer to the server's
        // request reader, and the reply reader to the server's reply writer
        // (rmw_cyclonedds_cpp's `rmw_service_server_is_available` check). A
        // request written before the first match is dropped, and a reply
        // written before the second never arrives.
        // The server creates all 5 entities (3 service pairs + feedback +
        // status writers) atomically inside `createActionServer`, so seeing
        // matches on every service pair implies the feedback and status
        // publishers are co-live; the client's feedback / status readers
        // will pick them up on the next discovery tick.
        let matched = try await client.waitUntilMatched(timeout: timeout) {
            lock.lock()
            defer { lock.unlock() }
            guard !closed,
                let sendGoal = sendGoalWriter, let cancelGoal = cancelGoalWriter,
                let getResult = getResultWriter, let sendGoalReply = sendGoalReplyReader,
                let cancelGoalReply = cancelGoalReplyReader, let getResultReply = getResultReplyReader
            else { return nil }
            return ([sendGoal, cancelGoal, getResult], [sendGoalReply, cancelGoalReply, getResultReply])
        }
        if matched { return }
        throw TransportError.actionServerUnavailable
    }

    func sendGoal(
        goalId: [UInt8],
        goalCDR: Data,
        acceptanceTimeout: Duration
    ) async throws -> SendGoalAck {
        precondition(goalId.count == 16, "goalId must be 16 bytes")

        // Pre-register the per-goal feedback / status streams before we issue
        // the request — the server may publish a status update the instant it
        // accepts, and we'd lose it otherwise.
        var fbCont: AsyncStream<Data>.Continuation!
        let feedback = AsyncStream<Data> { fbCont = $0 }
        var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let status = AsyncStream<ActionStatusUpdate> { stCont = $0 }
        await pending.registerStreams(goalId: goalId, feedback: fbCont, status: stCont)

        lock.lock()
        let writer = closed ? nil : sendGoalWriter
        lock.unlock()
        guard let writer = writer else {
            // Roll back the streams we just registered — otherwise this goal
            // id sits in `pending` forever and any feedback/status sample
            // racing in (e.g. on a server still alive on the network) would
            // be routed to a goal the caller never received a handle for.
            await pending.cancel(goalId: goalId)
            throw TransportError.sessionClosed
        }

        let frame = ActionFrameDecoder.encodeSendGoalRequest(goalId: goalId, goalCDR: goalCDR)
        let seq = nextSequence()
        let id = RMWRequestId(writerGuid: writerGuid, sequenceNumber: seq)
        let wire = SampleIdentityPrefix.encode(requestId: id, userCDR: frame)

        let replyCDR: Data
        do {
            replyCDR = try await sendGoalPending.awaitReply(seq: seq, timeout: acceptanceTimeout) {
                try self.client.writeRawCDR(writer: writer, data: wire, timestamp: 0)
            }
        } catch {
            // Same rationale as the writer-nil path above — the request
            // never actually completed (timeout / cancel / write failure),
            // so the goal id has no live handle on the caller side. Drop
            // the pending entry to avoid the same misrouting hazard.
            await pending.cancel(goalId: goalId)
            throw error
        }

        let resp: (accepted: Bool, stampSec: Int32, stampNanosec: UInt32)
        do {
            resp = try ActionFrameDecoder.decodeSendGoalResponse(from: replyCDR)
        } catch {
            await pending.cancel(goalId: goalId)
            throw error
        }
        if !resp.accepted {
            await pending.cancel(goalId: goalId)
        }
        return SendGoalAck(
            accepted: resp.accepted,
            stampSec: resp.stampSec,
            stampNanosec: resp.stampNanosec,
            feedback: feedback,
            status: status
        )
    }

    func getResult(goalId: [UInt8], timeout: Duration) async throws -> GetResultAck {
        precondition(goalId.count == 16, "goalId must be 16 bytes")
        lock.lock()
        let writer = closed ? nil : getResultWriter
        lock.unlock()
        guard let writer = writer else { throw TransportError.sessionClosed }

        let frame = ActionFrameDecoder.encodeGetResultRequest(goalId: goalId)
        let seq = nextSequence()
        let id = RMWRequestId(writerGuid: writerGuid, sequenceNumber: seq)
        let wire = SampleIdentityPrefix.encode(requestId: id, userCDR: frame)

        let replyCDR = try await getResultPending.awaitReply(seq: seq, timeout: timeout) {
            try self.client.writeRawCDR(writer: writer, data: wire, timestamp: 0)
        }
        let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(from: replyCDR)
        // Drain the per-goal entry from `pending` — the result has been
        // delivered to the caller and any future feedback / status samples
        // for this goal are stale. Without this, every accepted goal leaks
        // a slot in the pending table for the lifetime of the client. The
        // server can send the reply right behind its last feedback, so first
        // let the samples received before the reply reach `pending`.
        await drainInbound()
        await pending.cancel(goalId: goalId)
        return GetResultAck(status: status, resultCDR: resultCDR)
    }

    func cancelGoal(
        goalId: [UInt8]?,
        beforeStampSec: Int32?,
        beforeStampNanosec: UInt32?,
        timeout: Duration
    ) async throws -> CancelGoalAck {
        lock.lock()
        let writer = closed ? nil : cancelGoalWriter
        lock.unlock()
        guard let writer = writer else { throw TransportError.sessionClosed }

        let frame = ActionFrameDecoder.encodeCancelGoalRequest(
            goalId: goalId, stampSec: beforeStampSec, stampNanosec: beforeStampNanosec)

        let seq = nextSequence()
        let rid = RMWRequestId(writerGuid: writerGuid, sequenceNumber: seq)
        let wire = SampleIdentityPrefix.encode(requestId: rid, userCDR: frame)

        let replyCDR = try await cancelGoalPending.awaitReply(seq: seq, timeout: timeout) {
            try self.client.writeRawCDR(writer: writer, data: wire, timestamp: 0)
        }
        return try ActionFrameDecoder.decodeCancelGoalResponse(from: replyCDR)
    }

    func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let writers: [any DDSWriterHandle] = [
            sendGoalWriter, cancelGoalWriter, getResultWriter,
        ].compactMap { $0 }
        let readers: [any DDSReaderHandle] = [
            sendGoalReplyReader, cancelGoalReplyReader, getResultReplyReader,
            feedbackReader, statusReader,
        ].compactMap { $0 }
        sendGoalWriter = nil
        cancelGoalWriter = nil
        getResultWriter = nil
        sendGoalReplyReader = nil
        cancelGoalReplyReader = nil
        getResultReplyReader = nil
        feedbackReader = nil
        statusReader = nil
        lock.unlock()

        inbound.finish()
        Task { [pending] in
            await pending.finishAll()
        }
        for r in readers {
            client.destroyReader(r)
        }
        for w in writers {
            client.destroyWriter(w)
        }
    }

    // MARK: Internal — reply / sample handlers

    func handleSendGoalReply(data: Data) {
        guard let (rid, body) = try? SampleIdentityPrefix.decode(wirePayload: data),
            rid.writerGuid == writerGuid
        else { return }
        Task { [sendGoalPending] in
            await sendGoalPending.resolve(seq: rid.sequenceNumber, with: .success(body))
        }
    }

    func handleCancelGoalReply(data: Data) {
        guard let (rid, body) = try? SampleIdentityPrefix.decode(wirePayload: data),
            rid.writerGuid == writerGuid
        else { return }
        Task { [cancelGoalPending] in
            await cancelGoalPending.resolve(seq: rid.sequenceNumber, with: .success(body))
        }
    }

    func handleGetResultReply(data: Data) {
        guard let (rid, body) = try? SampleIdentityPrefix.decode(wirePayload: data),
            rid.writerGuid == writerGuid
        else { return }
        Task { [getResultPending] in
            await getResultPending.resolve(seq: rid.sequenceNumber, with: .success(body))
        }
    }

    func handleFeedbackSample(data: Data) {
        guard let (goalId, fbCDR) = try? ActionFrameDecoder.decodeFeedbackMessage(from: data) else {
            return
        }
        inbound.yield(.feedback(goalId: goalId, cdr: fbCDR))
    }

    func handleStatusSample(data: Data) {
        guard let entries = try? ActionFrameDecoder.decodeStatusArray(from: data) else { return }
        inbound.yield(.status(entries))
    }

    /// Wait until every sample received so far has reached `pending`. Returns
    /// at once when the stream is finished (the client is closed), since the
    /// pump no longer applies events.
    func drainInbound() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if case .terminated = inbound.yield(.barrier(done)) {
                done.resume()
            }
        }
    }

    // MARK: Internal — helpers

    private func nextSequence() -> Int64 {
        seqLock.lock()
        defer { seqLock.unlock() }
        nextSeq += 1
        return nextSeq
    }
}
