// ZenohTransportSession+Action.swift
// Action Server / Client implementation for the Zenoh transport.
//
// Mirrors the DDS action transport (Phase 4) but layered on Zenoh's native
// queryable / get / put / subscribe primitives. Reuses `ActionFrameDecoder`
// from Phase 4 for frame layouts — Zenoh and DDS share the synthesized
// wrapper CDR shapes, each with a single CDR encapsulation header (DDS
// additionally prefixes a 16-byte `RMWRequestId` for the request/reply paths;
// Zenoh skips that since the queryable handles correlation natively).
//
// Server side declares 3 queryables (`send_goal` / `cancel_goal` /
// `get_result`), 2 publishers (`feedback` / `status`), and one `SA`
// liveliness token anchored on the `send_goal` request type.
//
// Client side declares 3 `get(...)` callers (one per service role), 2
// subscribers with goal-id filtering routed through `ActionPendingTable`,
// and one `CA` liveliness token announcement.

import Foundation
import SwiftROS2Wire

extension ZenohTransportSession {
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
        guard isConnected else { throw TransportError.notConnected }
        guard let cfg = config else { throw TransportError.notConnected }

        let codec = ZenohWireCodec(distro: resolvedWireMode ?? .jazzy)
        let ns = extractNamespace(from: name)
        let actionLeaf = extractTopicName(from: name)

        let sendGoalKey = codec.makeActionKeyExpr(
            role: .sendGoal, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.sendGoalRequest
        )
        let cancelGoalKey = codec.makeActionKeyExpr(
            role: .cancelGoal, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.cancelGoalRequest
        )
        let getResultKey = codec.makeActionKeyExpr(
            role: .getResult, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.getResultRequest
        )
        let feedbackKey = codec.makeActionKeyExpr(
            role: .feedback, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.feedbackMessage
        )
        let statusKey = codec.makeActionKeyExpr(
            role: .status, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.statusArray
        )

        let livelinessTokenKey = codec.makeActionLivelinessToken(
            entityKind: .actionServer,
            domainId: cfg.domainId,
            sessionId: sessionId,
            nodeId: "0",
            entityId: "0",
            namespace: ns,
            nodeName: "swift_ros2_action_server",
            actionName: actionLeaf,
            actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.sendGoalRequest,
            qos: TransportQoSMapper.toWireQoSPolicy(qos)
        )

        // Feedback and status go out through one declared publisher each,
        // reused for every sample. They block on congestion: the server sends
        // the send_goal reply, the accepted / executing status and the first
        // feedback from different threads at nearly the same time, and with
        // zenoh-pico's default (DROP) a put that meets another send in progress
        // on the session fails with -100 and aborts the goal.
        let sampleOptions = ZenohPublisherOptions(blockOnCongestion: true)
        let feedbackPublisher: any ZenohPublisherHandle
        let statusPublisher: any ZenohPublisherHandle
        do {
            feedbackPublisher = try client.declarePublisher(feedbackKey, options: sampleOptions)
        } catch let error as ZenohError {
            throw TransportError.publisherCreationFailed(error.localizedDescription ?? "\(error)")
        }
        do {
            statusPublisher = try client.declarePublisher(statusKey, options: sampleOptions)
        } catch let error as ZenohError {
            try? feedbackPublisher.close()
            throw TransportError.publisherCreationFailed(error.localizedDescription ?? "\(error)")
        } catch {
            try? feedbackPublisher.close()
            throw error
        }
        let gid = gidManager.getOrCreateGid()

        let server = ZenohTransportActionServerImpl(
            client: client,
            name: name,
            handlers: handlers,
            sendGoalKeyExpr: sendGoalKey,
            cancelGoalKeyExpr: cancelGoalKey,
            getResultKeyExpr: getResultKey,
            feedbackKeyExpr: feedbackKey,
            statusKeyExpr: statusKey,
            feedbackWriter: ZenohActionSampleWriter(publisher: feedbackPublisher, codec: codec, gid: gid),
            statusWriter: ZenohActionSampleWriter(publisher: statusPublisher, codec: codec, gid: gid)
        )

        // Track every queryable / token created so a partial failure tears
        // them all down before rethrowing — otherwise we leak Zenoh handles
        // and live callbacks for a server that was never returned.
        var createdQueryables: [any ZenohQueryableHandle] = []
        var createdToken: (any ZenohLivelinessTokenHandle)?
        func rollbackAndThrow(_ error: Error) throws -> Never {
            try? createdToken?.close()
            for q in createdQueryables { try? q.close() }
            server.closeSampleWriters()
            if let e = error as? ZenohError {
                throw TransportError.subscriberCreationFailed(e.localizedDescription ?? "\(e)")
            }
            throw error
        }
        func declareQ(
            _ key: String, _ handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
        ) throws -> any ZenohQueryableHandle {
            do {
                let q = try client.declareQueryable(key, handler: handler)
                createdQueryables.append(q)
                return q
            } catch {
                try rollbackAndThrow(error)
            }
        }

        let q1 = try declareQ(sendGoalKey) { [weak server] q in
            server?.handleSendGoalQuery(q)
        }
        let q2 = try declareQ(cancelGoalKey) { [weak server] q in
            server?.handleCancelGoalQuery(q)
        }
        let q3 = try declareQ(getResultKey) { [weak server] q in
            server?.handleGetResultQuery(q)
        }
        let token: any ZenohLivelinessTokenHandle
        do {
            token = try client.declareLivelinessToken(livelinessTokenKey)
            createdToken = token
        } catch {
            try rollbackAndThrow(error)
        }
        server.attach(queryables: [q1, q2, q3], livelinessToken: token)

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
        guard isConnected else { throw TransportError.notConnected }
        guard let cfg = config else { throw TransportError.notConnected }

        let codec = ZenohWireCodec(distro: resolvedWireMode ?? .jazzy)
        let ns = extractNamespace(from: name)
        let actionLeaf = extractTopicName(from: name)

        let sendGoalKey = codec.makeActionKeyExpr(
            role: .sendGoal, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.sendGoalRequest
        )
        let cancelGoalKey = codec.makeActionKeyExpr(
            role: .cancelGoal, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.cancelGoalRequest
        )
        let getResultKey = codec.makeActionKeyExpr(
            role: .getResult, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.getResultRequest
        )
        let feedbackKey = codec.makeActionKeyExpr(
            role: .feedback, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.feedbackMessage
        )
        let statusKey = codec.makeActionKeyExpr(
            role: .status, domainId: cfg.domainId, namespace: ns,
            actionName: actionLeaf, actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.statusArray
        )

        let livelinessTokenKey = codec.makeActionLivelinessToken(
            entityKind: .actionClient,
            domainId: cfg.domainId,
            sessionId: sessionId,
            nodeId: "0",
            entityId: "0",
            namespace: ns,
            nodeName: "swift_ros2_action_client",
            actionName: actionLeaf,
            actionTypeName: actionTypeName,
            roleTypeHash: roleTypeHashes.sendGoalRequest,
            qos: TransportQoSMapper.toWireQoSPolicy(qos)
        )

        let cli = ZenohTransportActionClientImpl(
            client: client,
            name: name,
            sendGoalKeyExpr: sendGoalKey,
            cancelGoalKeyExpr: cancelGoalKey,
            getResultKeyExpr: getResultKey,
            feedbackKeyExpr: feedbackKey,
            statusKeyExpr: statusKey
        )

        // Same rollback pattern as the server path — clean up any
        // already-created subscriber/token if a later call throws.
        var createdSubs: [any ZenohSubscriberHandle] = []
        var createdToken: (any ZenohLivelinessTokenHandle)?
        func rollbackAndThrow(_ error: Error) throws -> Never {
            try? createdToken?.close()
            for s in createdSubs { try? s.close() }
            if let e = error as? ZenohError {
                throw TransportError.subscriberCreationFailed(e.localizedDescription ?? "\(e)")
            }
            throw error
        }
        func subscribeKey(
            _ key: String, _ handler: @escaping @Sendable (ZenohSample) -> Void
        ) throws -> any ZenohSubscriberHandle {
            do {
                let s = try client.subscribe(keyExpr: key, handler: handler)
                createdSubs.append(s)
                return s
            } catch {
                try rollbackAndThrow(error)
            }
        }

        let fbSub = try subscribeKey(feedbackKey) { [weak cli] sample in
            cli?.handleFeedbackSample(payload: sample.payload)
        }
        let stSub = try subscribeKey(statusKey) { [weak cli] sample in
            cli?.handleStatusSample(payload: sample.payload)
        }
        let token: any ZenohLivelinessTokenHandle
        do {
            token = try client.declareLivelinessToken(livelinessTokenKey)
            createdToken = token
        } catch {
            try rollbackAndThrow(error)
        }
        cli.attach(feedbackSub: fbSub, statusSub: stSub, livelinessToken: token)

        appendActionClient(cli)
        return cli
    }

    // MARK: - Internal lock helpers

    func appendActionServer(_ s: ZenohTransportActionServerImpl) {
        publishersLock.lock()
        actionServers.append(s)
        publishersLock.unlock()
    }

    func appendActionClient(_ c: ZenohTransportActionClientImpl) {
        publishersLock.lock()
        actionClients.append(c)
        publishersLock.unlock()
    }

    func takeAllActionServers() -> [ZenohTransportActionServerImpl] {
        publishersLock.lock()
        let out = actionServers
        actionServers.removeAll()
        publishersLock.unlock()
        return out
    }

    func takeAllActionClients() -> [ZenohTransportActionClientImpl] {
        publishersLock.lock()
        let out = actionClients
        actionClients.removeAll()
        publishersLock.unlock()
        return out
    }
}

// MARK: - Zenoh Transport Action Server

final class ZenohTransportActionServerImpl: TransportActionServer, @unchecked Sendable {
    let client: any ZenohClientProtocol
    let name: String
    let handlers: TransportActionServerHandlers
    let sendGoalKeyExpr: String
    let cancelGoalKeyExpr: String
    let getResultKeyExpr: String
    let feedbackKeyExpr: String
    let statusKeyExpr: String
    private let feedbackWriter: ZenohActionSampleWriter
    private let statusWriter: ZenohActionSampleWriter

    private var queryables: [any ZenohQueryableHandle] = []
    private var livelinessToken: (any ZenohLivelinessTokenHandle)?
    private let lock = NSLock()
    private var closed = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && !queryables.isEmpty
    }

    init(
        client: any ZenohClientProtocol,
        name: String,
        handlers: TransportActionServerHandlers,
        sendGoalKeyExpr: String,
        cancelGoalKeyExpr: String,
        getResultKeyExpr: String,
        feedbackKeyExpr: String,
        statusKeyExpr: String,
        feedbackWriter: ZenohActionSampleWriter,
        statusWriter: ZenohActionSampleWriter
    ) {
        self.client = client
        self.name = name
        self.handlers = handlers
        self.sendGoalKeyExpr = sendGoalKeyExpr
        self.cancelGoalKeyExpr = cancelGoalKeyExpr
        self.getResultKeyExpr = getResultKeyExpr
        self.feedbackKeyExpr = feedbackKeyExpr
        self.statusKeyExpr = statusKeyExpr
        self.feedbackWriter = feedbackWriter
        self.statusWriter = statusWriter
    }

    func attach(
        queryables: [any ZenohQueryableHandle],
        livelinessToken: any ZenohLivelinessTokenHandle
    ) {
        lock.lock()
        self.queryables = queryables
        self.livelinessToken = livelinessToken
        lock.unlock()
    }

    func handleSendGoalQuery(_ query: any ZenohQueryHandle) {
        let payload = query.payload
        let captured = handlers
        Task {
            do {
                let (goalId, goalCDR) = try ActionFrameDecoder.decodeSendGoalRequest(from: payload)
                let (accepted, sec, nsec) = try await captured.onSendGoal(goalId, goalCDR)
                let reply = ActionFrameDecoder.encodeSendGoalResponse(
                    accepted: accepted, stampSec: sec, stampNanosec: nsec
                )
                try? query.reply(payload: reply, attachment: nil)
            } catch {
                try? query.replyError(message: error.localizedDescription)
            }
        }
    }

    func handleCancelGoalQuery(_ query: any ZenohQueryHandle) {
        let payload = query.payload
        let captured = handlers
        Task {
            do {
                let response = try await captured.onCancelGoal(payload)
                try? query.reply(payload: response, attachment: nil)
            } catch {
                try? query.replyError(message: error.localizedDescription)
            }
        }
    }

    func handleGetResultQuery(_ query: any ZenohQueryHandle) {
        let payload = query.payload
        let captured = handlers
        Task {
            do {
                let goalId = try ActionFrameDecoder.decodeGetResultRequest(from: payload)
                let ack = try await captured.onGetResult(goalId)
                let reply = ActionFrameDecoder.encodeGetResultResponse(
                    status: ack.status, resultCDR: ack.resultCDR
                )
                try? query.reply(payload: reply, attachment: nil)
            } catch {
                try? query.replyError(message: error.localizedDescription)
            }
        }
    }

    func publishFeedback(goalId: [UInt8], feedbackCDR: Data) throws {
        let frame = ActionFrameDecoder.encodeFeedbackMessage(
            goalId: goalId, feedbackCDR: feedbackCDR
        )
        try feedbackWriter.put(frame)
    }

    func publishStatus(entries: [ActionFrameDecoder.StatusEntry]) throws {
        let frame = ActionFrameDecoder.encodeStatusArray(entries: entries)
        try statusWriter.put(frame)
    }

    /// Public-protocol witness called by the umbrella `ROS2ActionServer`.
    func publishStatus(entries: [ActionStatusEntry]) throws {
        let tuples: [ActionFrameDecoder.StatusEntry] = entries.map {
            (uuid: $0.uuid, stampSec: $0.stampSec, stampNanosec: $0.stampNanosec, status: $0.status)
        }
        try publishStatus(entries: tuples)
    }

    func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let qs = queryables
        let token = livelinessToken
        queryables.removeAll()
        livelinessToken = nil
        lock.unlock()

        for q in qs {
            try? q.close()
        }
        try? token?.close()
        closeSampleWriters()
    }

    func closeSampleWriters() {
        feedbackWriter.close()
        statusWriter.close()
    }
}

// MARK: - Action Sample Writer

/// Sends the samples of one action server topic (feedback or status) through a
/// declared publisher. Every sample carries the 33-byte rmw_zenoh attachment
/// (sequence number, source timestamp, GID) that topic publishers send:
/// rmw_zenoh_cpp drops a sample without one.
final class ZenohActionSampleWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var publisher: (any ZenohPublisherHandle)?
    private let codec: ZenohWireCodec
    private let gid: [UInt8]
    private var sequenceNumber: Int64 = 0

    init(publisher: any ZenohPublisherHandle, codec: ZenohWireCodec, gid: [UInt8]) {
        self.publisher = publisher
        self.codec = codec
        self.gid = gid
    }

    /// Sends under the lock so that sequence numbers go out in order.
    func put(_ payload: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let publisher else { throw TransportError.publisherClosed }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let attachment = codec.buildAttachment(seq: sequenceNumber, tsNsec: timestamp, gid: gid)
        sequenceNumber += 1
        try publisher.put(payload: payload, attachment: attachment)
    }

    func close() {
        lock.lock()
        let p = publisher
        publisher = nil
        lock.unlock()
        try? p?.close()
    }
}

// MARK: - Zenoh Transport Action Client

final class ZenohTransportActionClientImpl: TransportActionClient, @unchecked Sendable {
    private let client: any ZenohClientProtocol
    let name: String
    let sendGoalKeyExpr: String
    let cancelGoalKeyExpr: String
    let getResultKeyExpr: String
    let feedbackKeyExpr: String
    let statusKeyExpr: String

    private var feedbackSub: (any ZenohSubscriberHandle)?
    private var statusSub: (any ZenohSubscriberHandle)?
    private var livelinessToken: (any ZenohLivelinessTokenHandle)?
    private let lock = NSLock()
    private var closed = false

    let pending = ActionPendingTable()

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    init(
        client: any ZenohClientProtocol,
        name: String,
        sendGoalKeyExpr: String,
        cancelGoalKeyExpr: String,
        getResultKeyExpr: String,
        feedbackKeyExpr: String,
        statusKeyExpr: String
    ) {
        self.client = client
        self.name = name
        self.sendGoalKeyExpr = sendGoalKeyExpr
        self.cancelGoalKeyExpr = cancelGoalKeyExpr
        self.getResultKeyExpr = getResultKeyExpr
        self.feedbackKeyExpr = feedbackKeyExpr
        self.statusKeyExpr = statusKeyExpr
    }

    func attach(
        feedbackSub: any ZenohSubscriberHandle,
        statusSub: any ZenohSubscriberHandle,
        livelinessToken: any ZenohLivelinessTokenHandle
    ) {
        lock.lock()
        self.feedbackSub = feedbackSub
        self.statusSub = statusSub
        self.livelinessToken = livelinessToken
        lock.unlock()
    }

    func waitForActionServer(timeout: Duration) async throws {
        let probeMs: UInt32 = 200
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let remaining = ZenohTransportActionClientImpl.durationToMillis(
                deadline - ContinuousClock.now
            )
            if remaining == 0 { break }
            let attempt = min(probeMs, remaining)
            if await probeOnce(timeoutMs: attempt) {
                return
            }
        }
        throw TransportError.actionServerUnavailable
    }

    private func probeOnce(timeoutMs: UInt32) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = ActionOnceFlag()
            do {
                try client.get(
                    keyExpr: sendGoalKeyExpr,
                    payload: nil,
                    attachment: nil,
                    timeoutMs: timeoutMs,
                    handler: { _ in
                        if resumed.set() {
                            cont.resume(returning: true)
                        }
                    },
                    onFinish: {
                        if resumed.set() {
                            cont.resume(returning: false)
                        }
                    }
                )
            } catch {
                if resumed.set() {
                    cont.resume(returning: false)
                }
            }
        }
    }

    func sendGoal(
        goalId: [UInt8],
        goalCDR: Data,
        acceptanceTimeout: Duration
    ) async throws -> SendGoalAck {
        precondition(goalId.count == 16, "goalId must be 16 bytes")
        var fbCont: AsyncStream<Data>.Continuation!
        let feedback = AsyncStream<Data> { fbCont = $0 }
        var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let status = AsyncStream<ActionStatusUpdate> { stCont = $0 }
        await pending.registerStreams(goalId: goalId, feedback: fbCont, status: stCont)

        let frame = ActionFrameDecoder.encodeSendGoalRequest(goalId: goalId, goalCDR: goalCDR)
        let replyCDR: Data
        do {
            replyCDR = try await getOnce(
                keyExpr: sendGoalKeyExpr,
                payload: frame,
                timeout: acceptanceTimeout
            )
        } catch {
            // The request never completed (timeout / decode failure / get
            // throw), so the caller never received a handle for this goal.
            // Drop the pending entry to avoid misrouting future feedback /
            // status samples to a handle that doesn't exist.
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
        let frame = ActionFrameDecoder.encodeGetResultRequest(goalId: goalId)
        let replyCDR = try await getOnce(
            keyExpr: getResultKeyExpr,
            payload: frame,
            timeout: timeout
        )
        let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(from: replyCDR)
        // Drain the per-goal entry from `pending` once the result is in
        // hand — any future feedback / status samples for this goal are
        // stale, and without this the entry leaks for the lifetime of the
        // client. (Parallel to the DDS transport's behavior.)
        await pending.cancel(goalId: goalId)
        return GetResultAck(status: status, resultCDR: resultCDR)
    }

    func cancelGoal(
        goalId: [UInt8]?,
        beforeStampSec: Int32?,
        beforeStampNanosec: UInt32?,
        timeout: Duration
    ) async throws -> CancelGoalAck {
        // Build CancelGoal_Request CDR by hand: action_msgs/srv/CancelGoal_Request
        // is `GoalInfo goal_info { uuid[16], builtin_interfaces/Time stamp }`.
        var frame = ActionFrameDecoder.cdrHeader
        let id = goalId ?? [UInt8](repeating: 0, count: 16)
        precondition(id.count == 16, "goalId must be 16 bytes")
        frame.append(contentsOf: id)
        var sec = (beforeStampSec ?? 0).littleEndian
        var nsec = (beforeStampNanosec ?? 0).littleEndian
        withUnsafeBytes(of: &sec) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &nsec) { frame.append(contentsOf: $0) }

        let replyCDR = try await getOnce(
            keyExpr: cancelGoalKeyExpr,
            payload: frame,
            timeout: timeout
        )
        // CancelGoal_Response CDR: `int8 return_code; GoalInfo[] goals_canceling`.
        // Layout: [header (4) | code (1) | pad (3) | count (u32) | { uuid[16] | sec | nsec } * count ]
        guard replyCDR.count >= 4 + 1 + 3 + 4 else {
            throw ActionFrameDecoderError.payloadTooShort
        }
        let code = Int8(bitPattern: replyCDR[replyCDR.startIndex + 4])
        let count = replyCDR.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        }
        let needed = 4 + 1 + 3 + 4 + Int(count) * (16 + 4 + 4)
        guard replyCDR.count >= needed else { throw ActionFrameDecoderError.payloadTooShort }
        var out: [CancelGoalAck.GoalEntry] = []
        out.reserveCapacity(Int(count))
        var off = replyCDR.startIndex + 12
        for _ in 0..<Int(count) {
            let uuid = Array(replyCDR[off..<(off + 16)])
            off += 16
            let s = replyCDR.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: off - replyCDR.startIndex, as: Int32.self)
                    .littleEndian
            }
            off += 4
            let ns = replyCDR.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: off - replyCDR.startIndex, as: UInt32.self)
                    .littleEndian
            }
            off += 4
            out.append((uuid: uuid, stampSec: s, stampNanosec: ns))
        }
        return CancelGoalAck(returnCode: code, goalsCanceling: out)
    }

    func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let fb = feedbackSub
        let st = statusSub
        let token = livelinessToken
        feedbackSub = nil
        statusSub = nil
        livelinessToken = nil
        lock.unlock()
        Task { [pending] in
            await pending.failAll(TransportError.sessionClosed)
        }
        try? fb?.close()
        try? st?.close()
        try? token?.close()
    }

    func handleFeedbackSample(payload: Data) {
        guard let (goalId, fb) = try? ActionFrameDecoder.decodeFeedbackMessage(from: payload) else {
            return
        }
        Task { [pending] in
            await pending.yieldFeedback(goalId: goalId, cdr: fb)
        }
    }

    func handleStatusSample(payload: Data) {
        guard let entries = try? ActionFrameDecoder.decodeStatusArray(from: payload) else { return }
        Task { [pending] in
            for e in entries {
                await pending.yieldStatus(goalId: e.uuid, status: e.status)
            }
        }
    }

    private func getOnce(keyExpr: String, payload: Data, timeout: Duration) async throws -> Data {
        let timeoutMs = ZenohTransportActionClientImpl.durationToMillis(timeout)
        return try await withCheckedThrowingContinuation { cont in
            let state = ActionGetOnceState()
            do {
                try client.get(
                    keyExpr: keyExpr,
                    payload: payload,
                    attachment: nil,
                    timeoutMs: timeoutMs,
                    handler: { result in
                        if case .success(let sample) = result {
                            state.captureReply(sample.payload)
                        }
                    },
                    onFinish: {
                        state.finish(continuation: cont, timeout: timeout)
                    }
                )
            } catch {
                state.fail(continuation: cont, error: error)
            }
        }
    }

    static func durationToMillis(_ d: Duration) -> UInt32 {
        let comps = d.components
        let seconds = max(0, Int64(comps.seconds))
        let attoseconds = Int64(comps.attoseconds)
        let ms = seconds.multipliedReportingOverflow(by: 1_000)
        if ms.overflow { return UInt32.max }
        let total = ms.partialValue + attoseconds / 1_000_000_000_000_000
        if total < 0 { return 0 }
        if total > Int64(UInt32.max) { return UInt32.max }
        return UInt32(total)
    }
}

// MARK: - Internal helpers

/// One-shot resume guard for the `waitForActionServer` probe — `set()` returns
/// true exactly once, false on every later call.
private final class ActionOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Coordinates a single in-flight `getOnce` call so the reply / finish / fail
/// paths only resume the continuation once. The first reply payload is
/// captured; `onFinish` resumes with it (or with `requestTimeout` if no reply
/// was captured). `fail` is invoked when `client.get` itself throws — it
/// races against `onFinish` only if the bridge calls `onFinish` on the same
/// thread before the throw propagates, which the lock guards against.
private final class ActionGetOnceState: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedPayload: Data?
    private var resolved = false

    func captureReply(_ payload: Data) {
        lock.lock()
        if receivedPayload == nil {
            receivedPayload = payload
        }
        lock.unlock()
    }

    func finish(continuation cont: CheckedContinuation<Data, Error>, timeout: Duration) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let payload = receivedPayload
        lock.unlock()
        if let payload = payload {
            cont.resume(returning: payload)
        } else {
            cont.resume(throwing: TransportError.requestTimeout(timeout))
        }
    }

    func fail(continuation cont: CheckedContinuation<Data, Error>, error: Error) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}

extension ZenohTransportActionServerImpl: PublishesActionFeedback {}
