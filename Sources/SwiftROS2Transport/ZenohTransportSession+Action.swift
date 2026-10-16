// ZenohTransportSession+Action.swift
// Action Server / Client implementation for the Zenoh transport.
//
// Mirrors the DDS action transport but layered on Zenoh's native
// queryable / get / put / subscribe primitives. Reuses `ActionFrameDecoder`
// for frame layouts — Zenoh and DDS share the synthesized
// wrapper CDR shapes, each with a single CDR encapsulation header (DDS
// additionally prefixes a 16-byte `RMWRequestId` for the request/reply paths;
// Zenoh skips that since the queryable handles correlation natively).
//
// rmw_zenoh_cpp has no action entity: an action is three services
// (`send_goal`, `cancel_goal`, `get_result`, keyed by their service types and
// service type hashes) and two topics (`feedback`, `status`). The server
// declares 3 queryables, announces them with `SS` tokens and its two topics
// with `MP` tokens; the client sends `get`s with the 33-byte attachment,
// subscribes to the two topics, and announces `SC` and `MS` tokens. Requests
// and replies carry the 33-byte attachment, as on plain services.

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
        try createActionServer(
            name: name, actionTypeName: actionTypeName, roleTypeHashes: roleTypeHashes, qos: qos,
            nodeName: nil, nodeNamespace: nil, handlers: handlers)
    }

    package func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer {
        let endpoints = try makeActionEndpoints(
            name: name, actionTypeName: actionTypeName, roleTypeHashes: roleTypeHashes)
        let node = nodeIdentity(name: nodeName, namespace: nodeNamespace)

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
            feedbackPublisher = try client.declarePublisher(endpoints.keyExpr(.feedback), options: sampleOptions)
        } catch let error as ZenohError {
            throw TransportError.publisherCreationFailed(error.localizedDescription ?? "\(error)")
        }
        do {
            statusPublisher = try client.declarePublisher(endpoints.keyExpr(.status), options: sampleOptions)
        } catch let error as ZenohError {
            try? feedbackPublisher.close()
            throw TransportError.publisherCreationFailed(error.localizedDescription ?? "\(error)")
        } catch {
            try? feedbackPublisher.close()
            throw error
        }
        // Every entity is announced with its own token; the feedback and status
        // publishers send the GIDs rmw_zenoh_cpp derives from theirs.
        let tokenKeyExprs = makeActionTokens(
            endpoints: endpoints, serviceKind: .serviceServer, topicKind: "MP", qos: qos, node: node)
        func publisherGid(_ role: ZenohWireCodec.ActionRole) -> [UInt8] {
            gidManager?.getOrCreateGid() ?? ZenohWireCodec.entityGid(livelinessToken: tokenKeyExprs[role]!)
        }

        let server = ZenohTransportActionServerImpl(
            client: client,
            name: name,
            handlers: handlers,
            sendGoalKeyExpr: endpoints.keyExpr(.sendGoal),
            cancelGoalKeyExpr: endpoints.keyExpr(.cancelGoal),
            getResultKeyExpr: endpoints.keyExpr(.getResult),
            feedbackKeyExpr: endpoints.keyExpr(.feedback),
            statusKeyExpr: endpoints.keyExpr(.status),
            replyCodec: endpoints.codec,
            feedbackWriter: ZenohActionSampleWriter(
                publisher: feedbackPublisher, codec: endpoints.codec, gid: publisherGid(.feedback)),
            statusWriter: ZenohActionSampleWriter(
                publisher: statusPublisher, codec: endpoints.codec, gid: publisherGid(.status))
        )

        // Track every queryable / token created so a partial failure tears
        // them all down before rethrowing — otherwise we leak Zenoh handles
        // and live callbacks for a server that was never returned.
        var createdQueryables: [any ZenohQueryableHandle] = []
        var createdTokens: [any ZenohLivelinessTokenHandle] = []
        func rollbackAndThrow(_ error: Error) throws -> Never {
            for t in createdTokens { try? t.close() }
            for q in createdQueryables { try? q.close() }
            server.closeSampleWriters()
            if let e = error as? ZenohError {
                throw TransportError.subscriberCreationFailed(e.localizedDescription ?? "\(e)")
            }
            throw error
        }
        func declareQ(
            _ key: String, _ handler: @escaping @Sendable (any ZenohQueryHandle) -> Void
        ) throws {
            do {
                createdQueryables.append(try client.declareQueryable(key, handler: handler))
            } catch {
                try rollbackAndThrow(error)
            }
        }

        try declareQ(endpoints.keyExpr(.sendGoal)) { [weak server] q in
            server?.handleSendGoalQuery(q)
        }
        try declareQ(endpoints.keyExpr(.cancelGoal)) { [weak server] q in
            server?.handleCancelGoalQuery(q)
        }
        try declareQ(endpoints.keyExpr(.getResult)) { [weak server] q in
            server?.handleGetResultQuery(q)
        }
        // Announce the services only once all three queryables exist, then the two
        // publishers: rcl_action_server_is_available needs all five.
        do {
            createdTokens = try declareActionTokens(tokenKeyExprs, endpoints: endpoints)
        } catch {
            try rollbackAndThrow(error)
        }
        server.attach(queryables: createdQueryables, livelinessTokens: createdTokens)

        appendActionServer(server)
        return server
    }

    package func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS
    ) throws -> any TransportActionClient {
        try createActionClient(
            name: name, actionTypeName: actionTypeName, roleTypeHashes: roleTypeHashes, qos: qos,
            nodeName: nil, nodeNamespace: nil)
    }

    package func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportActionClient {
        let endpoints = try makeActionEndpoints(
            name: name, actionTypeName: actionTypeName, roleTypeHashes: roleTypeHashes)
        let node = nodeIdentity(name: nodeName, namespace: nodeNamespace)
        let tokenKeyExprs = makeActionTokens(
            endpoints: endpoints, serviceKind: .serviceClient, topicKind: "MS", qos: qos, node: node)

        let cli = ZenohTransportActionClientImpl(
            client: client,
            name: name,
            sendGoalKeyExpr: endpoints.keyExpr(.sendGoal),
            cancelGoalKeyExpr: endpoints.keyExpr(.cancelGoal),
            getResultKeyExpr: endpoints.keyExpr(.getResult),
            feedbackKeyExpr: endpoints.keyExpr(.feedback),
            statusKeyExpr: endpoints.keyExpr(.status),
            codec: endpoints.codec,
            // Its requests go out under the GID of its send_goal client.
            gid: ZenohWireCodec.entityGid(livelinessToken: tokenKeyExprs[.sendGoal]!),
            serverQueryKeyExprs: endpoints.serviceRoles.map { role in
                endpoints.codec.makeServiceServerLivelinessQuery(
                    domainId: endpoints.domainId, name: endpoints.name(role),
                    ddsTypeName: endpoints.ddsTypeName(role))
            }
        )

        // Same rollback pattern as the server path — clean up any
        // already-created subscriber/token if a later call throws.
        var createdSubs: [any ZenohSubscriberHandle] = []
        var createdTokens: [any ZenohLivelinessTokenHandle] = []
        func rollbackAndThrow(_ error: Error) throws -> Never {
            for t in createdTokens { try? t.close() }
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

        let fbSub = try subscribeKey(endpoints.keyExpr(.feedback)) { [weak cli] sample in
            cli?.handleFeedbackSample(payload: sample.payload)
        }
        let stSub = try subscribeKey(endpoints.keyExpr(.status)) { [weak cli] sample in
            cli?.handleStatusSample(payload: sample.payload)
        }
        do {
            createdTokens = try declareActionTokens(tokenKeyExprs, endpoints: endpoints)
        } catch {
            try rollbackAndThrow(error)
        }
        cli.attach(feedbackSub: fbSub, statusSub: stSub, livelinessTokens: createdTokens)

        appendActionClient(cli)
        return cli
    }

    // MARK: - Naming helpers

    /// The key expressions and types of the five entities of one action.
    struct ActionEndpoints {
        let codec: ZenohWireCodec
        let domainId: Int
        let actionName: String
        let actionTypeName: String
        /// DDS type name and hash of each role.
        let namings: [ZenohWireCodec.ActionRole: ZenohServiceNaming]

        let serviceRoles: [ZenohWireCodec.ActionRole] = [.sendGoal, .cancelGoal, .getResult]

        func name(_ role: ZenohWireCodec.ActionRole) -> String {
            ZenohWireCodec.actionRoleName(namespace: "", actionName: actionName, role: role)
        }

        func ddsTypeName(_ role: ZenohWireCodec.ActionRole) -> String {
            namings[role]!.ddsTypeName
        }

        func typeHash(_ role: ZenohWireCodec.ActionRole) -> String? {
            namings[role]!.typeHash
        }

        func keyExpr(_ role: ZenohWireCodec.ActionRole) -> String {
            codec.makeEntityKeyExpr(
                domainId: domainId, name: name(role), ddsTypeName: ddsTypeName(role), typeHash: typeHash(role))
        }
    }

    func makeActionEndpoints(
        name: String,
        actionTypeName: String,
        roleTypeHashes h: ActionRoleTypeHashes
    ) throws -> ActionEndpoints {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Action name cannot be empty")
        }
        guard !actionTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Action type name cannot be empty")
        }
        let (cfg, codec) = try openState()
        let distro = codec.distro
        func service(
            _ role: ZenohWireCodec.ActionRole, serviceHash: String?, requestHash: String?
        ) -> ZenohServiceNaming {
            ZenohServiceNaming.resolve(
                distro: distro,
                serviceDDSTypeName: ZenohWireCodec.ddsTypeName(forRole: role, actionTypeName: actionTypeName),
                serviceTypeHash: serviceHash,
                requestDDSTypeName: ZenohWireCodec.legacyRequestDDSTypeName(
                    forRole: role, actionTypeName: actionTypeName) ?? "",
                requestTypeHash: requestHash
            )
        }
        func topic(_ role: ZenohWireCodec.ActionRole, hash: String?) -> ZenohServiceNaming {
            ZenohServiceNaming(
                ddsTypeName: ZenohWireCodec.ddsTypeName(forRole: role, actionTypeName: actionTypeName),
                typeHash: distro.supportsTypeHash ? hash : nil,
                isLegacy: false
            )
        }
        let namings: [ZenohWireCodec.ActionRole: ZenohServiceNaming] = [
            .sendGoal: service(.sendGoal, serviceHash: h.sendGoalService, requestHash: h.sendGoalRequest),
            .cancelGoal: service(.cancelGoal, serviceHash: h.cancelGoalService, requestHash: h.cancelGoalRequest),
            .getResult: service(.getResult, serviceHash: h.getResultService, requestHash: h.getResultRequest),
            .feedback: topic(.feedback, hash: h.feedbackMessage),
            .status: topic(.status, hash: h.statusArray),
        ]
        if namings.values.contains(where: \.isLegacy) {
            ZenohServiceHashFallbackLog.shared.reportOnce(typeName: actionTypeName)
        }
        return ActionEndpoints(
            codec: codec, domainId: cfg.domainId, actionName: name, actionTypeName: actionTypeName,
            namings: namings)
    }

    /// The tokens of an action, each with a new entity id: `serviceKind` (`SS` / `SC`)
    /// for its three services, `topicKind` (`MP` / `MS`) for its feedback and status.
    func makeActionTokens(
        endpoints: ActionEndpoints,
        serviceKind: ZenohWireCodec.ServiceEntityKind,
        topicKind: String,
        qos: TransportQoS,
        node: ZenohNodeIdentity
    ) -> [ZenohWireCodec.ActionRole: String] {
        // rcl_action's status topic is reliable, transient-local, keep-last 1.
        let statusQoS = TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1))
        var tokens: [ZenohWireCodec.ActionRole: String] = [:]
        for role in endpoints.serviceRoles + [.feedback, .status] {
            tokens[role] = makeEntityToken(
                kind: role.isService ? serviceKind.rawValue : topicKind, codec: endpoints.codec,
                domainId: endpoints.domainId, name: endpoints.name(role), ddsTypeName: endpoints.ddsTypeName(role),
                typeHash: endpoints.typeHash(role), qos: role == .status ? statusQoS : qos, node: node)
        }
        return tokens
    }

    /// Declare the tokens of an action, its three services first, then its feedback
    /// and status topics. On a failure, closes the tokens already declared and rethrows.
    func declareActionTokens(
        _ tokens: [ZenohWireCodec.ActionRole: String],
        endpoints: ActionEndpoints
    ) throws -> [any ZenohLivelinessTokenHandle] {
        var handles: [any ZenohLivelinessTokenHandle] = []
        do {
            for role in endpoints.serviceRoles + [.feedback, .status] {
                handles.append(try declareToken(tokens[role]!))
            }
        } catch {
            for handle in handles { try? handle.close() }
            throw error
        }
        return handles
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
    private var livelinessTokens: [any ZenohLivelinessTokenHandle] = []
    private let lock = NSLock()
    private var closed = false
    /// Builds the 33-byte attachment of the query replies.
    let replyCodec: ZenohWireCodec

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
        replyCodec: ZenohWireCodec,
        feedbackWriter: ZenohActionSampleWriter,
        statusWriter: ZenohActionSampleWriter
    ) {
        self.client = client
        self.name = name
        self.handlers = handlers
        self.replyCodec = replyCodec
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
        livelinessTokens: [any ZenohLivelinessTokenHandle]
    ) {
        lock.lock()
        self.queryables = queryables
        self.livelinessTokens = livelinessTokens
        lock.unlock()
    }

    func handleSendGoalQuery(_ query: any ZenohQueryHandle) {
        let payload = query.payload
        let replyAttachment = ZenohServiceAttachment.reply(to: query.attachment, codec: replyCodec)
        let captured = handlers
        Task {
            do {
                let (goalId, goalCDR) = try ActionFrameDecoder.decodeSendGoalRequest(from: payload)
                let (accepted, sec, nsec) = try await captured.onSendGoal(goalId, goalCDR)
                let reply = ActionFrameDecoder.encodeSendGoalResponse(
                    accepted: accepted, stampSec: sec, stampNanosec: nsec
                )
                try? query.reply(payload: reply, attachment: replyAttachment)
            } catch {
                try? query.replyError(message: error.localizedDescription)
            }
        }
    }

    func handleCancelGoalQuery(_ query: any ZenohQueryHandle) {
        let payload = query.payload
        let replyAttachment = ZenohServiceAttachment.reply(to: query.attachment, codec: replyCodec)
        let captured = handlers
        Task {
            do {
                let response = try await captured.onCancelGoal(payload)
                try? query.reply(payload: response, attachment: replyAttachment)
            } catch {
                try? query.replyError(message: error.localizedDescription)
            }
        }
    }

    func handleGetResultQuery(_ query: any ZenohQueryHandle) {
        let payload = query.payload
        let replyAttachment = ZenohServiceAttachment.reply(to: query.attachment, codec: replyCodec)
        let captured = handlers
        Task {
            do {
                let goalId = try ActionFrameDecoder.decodeGetResultRequest(from: payload)
                let ack = try await captured.onGetResult(goalId)
                let reply = ActionFrameDecoder.encodeGetResultResponse(
                    status: ack.status, resultCDR: ack.resultCDR
                )
                try? query.reply(payload: reply, attachment: replyAttachment)
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
        let tokens = livelinessTokens
        queryables.removeAll()
        livelinessTokens.removeAll()
        lock.unlock()

        for token in tokens {
            try? token.close()
        }
        for q in qs {
            try? q.close()
        }
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

    private let codec: ZenohWireCodec
    private let gid: [UInt8]
    /// Liveliness queries matching the `SS` tokens of the three action services.
    private let serverQueryKeyExprs: [String]

    private var feedbackSub: (any ZenohSubscriberHandle)?
    private var statusSub: (any ZenohSubscriberHandle)?
    private var livelinessTokens: [any ZenohLivelinessTokenHandle] = []
    private let lock = NSLock()
    private var closed = false
    private var nextSeq: Int64 = 0

    let pending = ActionPendingTable()

    /// What the subscriber callbacks hand to `pending`, in arrival order.
    /// zenoh-pico delivers samples one at a time, but a task per sample let a
    /// later sample reach `pending` first: a terminal status that overtakes
    /// feedback received before it ends the feedback stream and drops that
    /// feedback. One task applies the events in order instead.
    private enum InboundEvent: Sendable {
        case feedback(goalId: [UInt8], cdr: Data)
        case status([ActionFrameDecoder.StatusEntry])
        /// Resumed once every event received before it has reached `pending`.
        case barrier(CheckedContinuation<Void, Never>)
    }
    private let inbound: AsyncStream<InboundEvent>.Continuation

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
        statusKeyExpr: String,
        codec: ZenohWireCodec,
        gid: [UInt8],
        serverQueryKeyExprs: [String]
    ) {
        self.client = client
        self.name = name
        self.sendGoalKeyExpr = sendGoalKeyExpr
        self.cancelGoalKeyExpr = cancelGoalKeyExpr
        self.getResultKeyExpr = getResultKeyExpr
        self.feedbackKeyExpr = feedbackKeyExpr
        self.statusKeyExpr = statusKeyExpr
        self.codec = codec
        self.gid = gid
        self.serverQueryKeyExprs = serverQueryKeyExprs
        var cont: AsyncStream<InboundEvent>.Continuation!
        let events = AsyncStream<InboundEvent> { cont = $0 }
        self.inbound = cont
        // The pump captures only the table (not self), and ends when `close()`
        // finishes the stream, after the events already queued.
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

    func attach(
        feedbackSub: any ZenohSubscriberHandle,
        statusSub: any ZenohSubscriberHandle,
        livelinessTokens: [any ZenohLivelinessTokenHandle]
    ) {
        lock.lock()
        self.feedbackSub = feedbackSub
        self.statusSub = statusSub
        self.livelinessTokens = livelinessTokens
        lock.unlock()
    }

    /// Wait until a server announces all three action services (`SS` tokens), as
    /// rcl_action_server_is_available does. Probing a queryable with a `get` instead
    /// would hand rmw_zenoh_cpp servers a request without an attachment.
    func waitForActionServer(timeout: Duration) async throws {
        if await ZenohServiceDiscovery.waitForServers(
            client: client, queryKeyExprs: serverQueryKeyExprs, timeout: timeout)
        {
            return
        }
        throw TransportError.actionServerUnavailable
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
        // client. (Parallel to the DDS transport's behavior.) The server can
        // send the reply right behind its last feedback, so first let the
        // samples received before the reply reach `pending`.
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
        let tokens = livelinessTokens
        feedbackSub = nil
        statusSub = nil
        livelinessTokens.removeAll()
        lock.unlock()
        inbound.finish()
        Task { [pending] in
            await pending.failAll(TransportError.sessionClosed)
        }
        try? fb?.close()
        try? st?.close()
        for token in tokens {
            try? token.close()
        }
    }

    func handleFeedbackSample(payload: Data) {
        guard let (goalId, fb) = try? ActionFrameDecoder.decodeFeedbackMessage(from: payload) else {
            return
        }
        inbound.yield(.feedback(goalId: goalId, cdr: fb))
    }

    func handleStatusSample(payload: Data) {
        guard let entries = try? ActionFrameDecoder.decodeStatusArray(from: payload) else { return }
        inbound.yield(.status(entries))
    }

    /// Wait until every sample received so far has reached `pending`.
    private func drainInbound() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if case .terminated = inbound.yield(.barrier(done)) {
                done.resume()
            }
        }
    }

    /// The 33-byte attachment of the next request: rmw_zenoh_cpp servers reject a
    /// request without one, and tell pending requests apart by GID and sequence
    /// number.
    private func nextRequestAttachment() -> Data {
        lock.lock()
        nextSeq += 1
        let seq = nextSeq
        lock.unlock()
        return codec.buildAttachment(seq: seq, tsNsec: ZenohServiceAttachment.nowNsec(), gid: gid)
    }

    private func getOnce(keyExpr: String, payload: Data, timeout: Duration) async throws -> Data {
        let timeoutMs = timeout.zenohQueryTimeoutMs
        let attachment = nextRequestAttachment()
        return try await withCheckedThrowingContinuation { cont in
            let state = ActionGetOnceState()
            do {
                try client.get(
                    keyExpr: keyExpr,
                    payload: payload,
                    attachment: attachment,
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
}

// MARK: - Internal helpers

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
