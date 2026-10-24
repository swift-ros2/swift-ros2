// ROS2ActionServer.swift
// Typed server wrapper around TransportActionServer.

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2Transport

/// Typed action server for a specific `ROS2Action`.
public final class ROS2ActionServer<H: ActionServerHandler>: @unchecked Sendable, NodeEntity {
    private let transport: any TransportActionServer
    private let handler: H
    /// The distribution whose message schemas the goal decoder and the feedback and result
    /// encoders use.
    private let distro: ROS2Distro

    public var name: String { transport.name }
    public var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !closed && transport.isActive
    }

    // Per-goal state — tracked so cancel + status array publication can find it.
    private final class GoalEntry {
        let handle: ActionGoalHandle<H.Action>
        var task: Task<Void, Never>?
        var status: ActionGoalStatus
        var resultCache: GetResultAck?
        var resultWaiters: [CheckedContinuation<GetResultAck, Error>]
        var fbCont: AsyncStream<H.Action.Feedback>.Continuation
        var stCont: AsyncStream<ActionGoalStatus>.Continuation

        init(
            handle: ActionGoalHandle<H.Action>,
            status: ActionGoalStatus,
            fbCont: AsyncStream<H.Action.Feedback>.Continuation,
            stCont: AsyncStream<ActionGoalStatus>.Continuation
        ) {
            self.handle = handle
            self.status = status
            self.resultWaiters = []
            self.fbCont = fbCont
            self.stCont = stCont
        }
    }

    private let stateLock = NSLock()
    /// Held across building and sending a status snapshot, so snapshots go out in
    /// the order their states were read. Without it, a snapshot read before a
    /// transition could be sent after the one read after it, and the last status
    /// array a client sees would be stale (for example a finished goal still
    /// ACCEPTED). Never taken while `stateLock` is held.
    private let statusPublishLock = NSLock()
    private var goals: [Data: GoalEntry] = [:]  // key: 16-byte goal_id
    private var closed = false

    init(transport: any TransportActionServer, handler: H, distro: ROS2Distro) {
        self.transport = transport
        self.handler = handler
        self.distro = distro
    }

    /// Cancel the server; closes the underlying transport handle and cancels every running goal.
    public func cancel() {
        try? closeEntity()
    }

    var nodeEntityKind: NodeEntityKind { .actionServer }

    func closeEntity() throws {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let snapshot = Array(goals.values)
        goals.removeAll()
        stateLock.unlock()
        for entry in snapshot {
            entry.task?.cancel()
            for w in entry.resultWaiters {
                w.resume(throwing: ActionError.serverClosed)
            }
            entry.fbCont.finish()
            entry.stCont.finish()
        }
        try? transport.close()
    }

    // MARK: - Internal — handler bag the umbrella plugs into the transport

    static func makeHandlers(
        distro: ROS2Distro,
        for server: @escaping @Sendable () -> ROS2ActionServer<H>?
    ) -> TransportActionServerHandlers {
        return TransportActionServerHandlers(
            onSendGoal: { goalId, goalCDR in
                guard let s = server() else { return (false, 0, 0) }
                return await s.handleSendGoal(goalId: goalId, goalCDR: goalCDR)
            },
            onCancelGoal: { reqCDR in
                guard let s = server() else {
                    return ActionFrameDecoder.encodeCancelGoalResponse(returnCode: Self.cancelRejected, entries: [])
                }
                return await s.handleCancelGoal(requestCDR: reqCDR)
            },
            onGetResult: { goalId in
                guard let s = server() else {
                    // The server is gone, so no handler can supply a result.
                    return Self.resultlessAck(
                        .unknown, result: try? ZeroValuedResult.make(H.Action.Result.self, distro: distro),
                        distro: distro)
                }
                return try await s.handleGetResult(goalId: goalId)
            }
        )
    }

    private func handleSendGoal(goalId: [UInt8], goalCDR: Data) async -> (
        Bool, Int32, UInt32
    ) {
        let typedGoal: H.Action.Goal
        do {
            let dec = try CDRDecoder(data: goalCDR, distro: distro)
            typedGoal = try H.Action.Goal(from: dec)
        } catch {
            return (false, 0, 0)
        }
        let resp = await handler.handleGoal(typedGoal)
        guard resp == .accept else { return (false, 0, 0) }

        // Build the server-side handle.
        let now = Date()
        let secs = now.timeIntervalSince1970
        let stamp = BuiltinInterfacesTime(
            sec: Int32(secs),
            nanosec: UInt32(secs.truncatingRemainder(dividingBy: 1) * 1_000_000_000)
        )
        var fbCont: AsyncStream<H.Action.Feedback>.Continuation!
        let fbStream = AsyncStream<H.Action.Feedback> { fbCont = $0 }
        var stCont: AsyncStream<ActionGoalStatus>.Continuation!
        let stStream = AsyncStream<ActionGoalStatus> { stCont = $0 }
        let goalUUID = Foundation.UUID(actionGoalIdBytes: goalId)
        let key = Data(goalId)
        // Server-side handles never call `result()` — the umbrella server
        // owns the executing Task directly. The provider just throws
        // `wrongSide` if anyone reaches for it.
        let handle = ActionGoalHandle<H.Action>(
            side: .server,
            goalId: goalUUID,
            acceptedAt: stamp,
            feedbackStream: fbStream,
            statusStream: stStream,
            distro: distro,
            wrappedResultProvider: { _ in throw ActionError.wrongSide }
        )
        // Wire publishFeedback through the transport's feedback writer.
        let transportRef = transport
        let goalIdCopy = goalId
        handle._attachPublishFeedback { cdr in
            try transportRef.publishFeedback(goalId: goalIdCopy, feedbackCDR: cdr)
        }

        let entry = GoalEntry(
            handle: handle,
            status: .accepted,
            fbCont: fbCont!,
            stCont: stCont!
        )

        // Insert the entry into `goals` BEFORE spawning the executing Task.
        // Otherwise the Task can run immediately, hit `transitionStatus` /
        // `cacheResult`, find no entry, and silently drop the status / result
        // updates — which would make `getResult` hang forever for a goal
        // that actually completed.
        stateLock.lock()
        goals[key] = entry
        stateLock.unlock()

        let task: Task<Void, Never> = Task { [weak self, weak entry] in
            guard let self else { return }
            // A cancel request can win the race against this task's start;
            // the goal then stays CANCELING instead of going back to EXECUTING.
            if self.beginExecuting(key) {
                entry?.stCont.yield(.executing)
            }
            do {
                let result = try await self.handler.execute(handle)
                let resultCDR = try Self.encodeGetResultResponse(
                    status: .succeeded, result: result, distro: self.distro)
                self.cacheResult(
                    GetResultAck(
                        status: ActionGoalStatus.succeeded.rawValue, resultCDR: resultCDR
                    ), for: key)
                self.transitionStatus(.succeeded, for: key)
                entry?.stCont.yield(.succeeded)
            } catch is CancellationError {
                self.cacheResult(await self.resultlessAck(.canceled), for: key)
                self.transitionStatus(.canceled, for: key)
                entry?.stCont.yield(.canceled)
            } catch {
                self.cacheResult(await self.resultlessAck(.aborted), for: key)
                self.transitionStatus(.aborted, for: key)
                entry?.stCont.yield(.aborted)
            }
            entry?.fbCont.finish()
            entry?.stCont.finish()
        }
        entry.task = task

        // Eagerly publish the accepted status so a watching client sees it immediately.
        publishStatusSnapshot()

        return (true, stamp.sec, stamp.nanosec)
    }

    private func handleCancelGoal(requestCDR: Data) async -> Data {
        // Mirrors `rcl_action_process_cancel_request`. Only cancelable goals
        // (ACCEPTED or EXECUTING) are ever picked; goals that are already
        // CANCELING or in a terminal state are skipped.
        //   - `goal_id != 0` and `stamp == 0` → cancel exactly that goal:
        //     ERROR_UNKNOWN_GOAL_ID if it does not exist, ERROR_GOAL_TERMINATED
        //     if it is not cancelable.
        //   - `goal_id == 0` and `stamp == 0` → cancel ALL cancelable goals.
        //   - `goal_id == 0` and `stamp != 0` → cancel every cancelable goal
        //     accepted at-or-before `stamp`.
        //   - both set                         → cancel that goal AND every
        //     other cancelable goal accepted at-or-before `stamp`.
        // A sweep with nothing to cancel is ERROR_NONE with an empty list.
        guard let request = try? ActionFrameDecoder.decodeCancelGoalRequest(from: requestCDR) else {
            return ActionFrameDecoder.encodeCancelGoalResponse(returnCode: Self.cancelRejected, entries: [])
        }
        let (id, stampSec, stampNsec) = (request.goalId, request.stampSec, request.stampNanosec)
        let zeroId = id.allSatisfy { $0 == 0 }
        let zeroStamp = stampSec == 0 && stampNsec == 0

        // Pick the candidate set under the lock, then route every chosen
        // goal through the user's `handleCancel` outside the lock.
        stateLock.lock()
        var candidates: [(key: Data, entry: GoalEntry)] = []
        if !zeroId && zeroStamp {
            guard let entry = goals[Data(id)] else {
                stateLock.unlock()
                return ActionFrameDecoder.encodeCancelGoalResponse(returnCode: Self.cancelUnknownGoalId, entries: [])
            }
            guard Self.isCancelable(entry.status) else {
                stateLock.unlock()
                return ActionFrameDecoder.encodeCancelGoalResponse(returnCode: Self.cancelGoalTerminated, entries: [])
            }
            candidates = [(Data(id), entry)]
        } else {
            candidates = goals.compactMap { (k, v) in
                guard Self.isCancelable(v.status) else { return nil }
                let matchesId = !zeroId && k == Data(id)
                let matchesStamp =
                    !zeroStamp
                    && (v.handle.acceptedAt.sec < stampSec
                        || (v.handle.acceptedAt.sec == stampSec
                            && v.handle.acceptedAt.nanosec <= stampNsec))
                let matchesAll = zeroId && zeroStamp
                return (matchesId || matchesStamp || matchesAll) ? (k, v) : nil
            }
        }
        stateLock.unlock()

        if candidates.isEmpty {
            return ActionFrameDecoder.encodeCancelGoalResponse(returnCode: Self.cancelNone, entries: [])
        }

        var canceling: [CancelGoalAck.GoalEntry] = []
        for (key, entry) in candidates {
            let resp = await handler.handleCancel(entry.handle)
            guard resp == .accept else { continue }
            // The goal may have finished while `handleCancel` ran; only a
            // goal that is still cancelable moves to CANCELING.
            guard beginCanceling(key) else { continue }
            await entry.handle._setCancelRequested(true)
            // Per the action contract, an accepted cancel transitions the
            // goal to CANCELING immediately; the executing Task observes
            // `isCancelRequested` (or `Task.isCancelled`) and races to a
            // terminal state, after which `transitionStatus(.canceled)` /
            // `.aborted` runs in the goal task.
            entry.stCont.yield(.canceling)
            entry.task?.cancel()
            canceling.append(
                (
                    uuid: Array(key),
                    stampSec: entry.handle.acceptedAt.sec,
                    stampNanosec: entry.handle.acceptedAt.nanosec
                ))
        }
        // REJECTED: the handler declined every candidate.
        let code = canceling.isEmpty ? Self.cancelRejected : Self.cancelNone
        return ActionFrameDecoder.encodeCancelGoalResponse(returnCode: code, entries: canceling)
    }

    // `action_msgs/srv/CancelGoal` return codes.
    private static var cancelNone: Int8 { 0 }
    private static var cancelRejected: Int8 { 1 }
    private static var cancelUnknownGoalId: Int8 { 2 }
    private static var cancelGoalTerminated: Int8 { 3 }

    /// Whether a CancelGoal request can move a goal in this state to
    /// CANCELING (the `CANCEL_GOAL` event is valid only from ACCEPTED and
    /// EXECUTING, as in rcl_action).
    private static func isCancelable(_ status: ActionGoalStatus) -> Bool {
        status == .accepted || status == .executing
    }

    /// Moves an ACCEPTED goal to EXECUTING and publishes the status. Returns
    /// false, leaving the goal untouched, if a cancel request already moved it on.
    private func beginExecuting(_ key: Data) -> Bool {
        stateLock.lock()
        guard let entry = goals[key], entry.status == .accepted else {
            stateLock.unlock()
            return false
        }
        entry.status = .executing
        stateLock.unlock()
        publishStatusSnapshot()
        return true
    }

    /// Moves a still-cancelable goal to CANCELING and publishes the status.
    /// Returns false, leaving the goal untouched, if it already left
    /// ACCEPTED / EXECUTING.
    private func beginCanceling(_ key: Data) -> Bool {
        stateLock.lock()
        guard let entry = goals[key], Self.isCancelable(entry.status) else {
            stateLock.unlock()
            return false
        }
        entry.status = .canceling
        stateLock.unlock()
        publishStatusSnapshot()
        return true
    }

    private func handleGetResult(goalId: [UInt8]) async throws -> GetResultAck {
        let key = Data(goalId)
        stateLock.lock()
        let isClosed = closed
        let known = goals[key]
        let cached = known?.resultCache
        stateLock.unlock()
        if isClosed { throw ActionError.serverClosed }
        if let cached { return cached }
        // rclcpp and rclpy answer a goal they do not track with STATUS_UNKNOWN
        // and a default result instead of leaving the request unanswered.
        guard known != nil else { return await resultlessAck(.unknown) }

        return try await withCheckedThrowingContinuation { cont in
            stateLock.lock()
            if let entry = goals[key] {
                if let cached = entry.resultCache {
                    stateLock.unlock()
                    cont.resume(returning: cached)
                    return
                }
                entry.resultWaiters.append(cont)
                stateLock.unlock()
            } else {
                // Closed between the lookup above and here.
                stateLock.unlock()
                cont.resume(throwing: ActionError.serverClosed)
            }
        }
    }

    /// The response for a goal that ended without a result: `status` and the
    /// handler's ``ActionServerHandler/defaultResult()``.
    private func resultlessAck(_ status: ActionGoalStatus) async -> GetResultAck {
        Self.resultlessAck(
            status, result: try? await handler.defaultResult(), distro: distro)
    }

    /// A ROS 2 GetResult response always holds a complete result, so a goal
    /// without one is answered with a default result. Without any result,
    /// `resultCDR` stays empty and the transports send the status alone (see
    /// `GetResultAck`).
    static func resultlessAck(
        _ status: ActionGoalStatus, result: H.Action.Result?, distro: ROS2Distro
    ) -> GetResultAck {
        guard
            let result,
            let resultCDR = try? encodeGetResultResponse(
                status: status, result: result, distro: distro)
        else {
            return GetResultAck(status: status.rawValue, resultCDR: Data())
        }
        return GetResultAck(status: status.rawValue, resultCDR: resultCDR)
    }

    /// Encodes the whole GetResult response, `[header | int8 status | result]`,
    /// in one pass: XCDR v1 aligns the result's fields from the frame origin,
    /// after the status byte, not from the result's own start.
    static func encodeGetResultResponse(
        status: ActionGoalStatus, result: H.Action.Result, distro: ROS2Distro
    ) throws -> Data {
        let encoder = CDREncoder(distro: distro)
        encoder.writeEncapsulationHeader()
        encoder.writeInt8(status.rawValue)
        try result.encode(to: encoder)
        return encoder.getData()
    }

    private func cacheResult(_ ack: GetResultAck, for key: Data) {
        stateLock.lock()
        guard let entry = goals[key] else {
            stateLock.unlock()
            return
        }
        entry.resultCache = ack
        let waiters = entry.resultWaiters
        entry.resultWaiters = []
        stateLock.unlock()
        for w in waiters {
            w.resume(returning: ack)
        }
    }

    private func transitionStatus(_ s: ActionGoalStatus, for key: Data) {
        stateLock.lock()
        if let entry = goals[key] {
            entry.status = s
        }
        stateLock.unlock()
        publishStatusSnapshot()
    }

    private func publishStatusSnapshot() {
        statusPublishLock.lock()
        defer { statusPublishLock.unlock() }
        stateLock.lock()
        let snapshot: [ActionStatusEntry] = goals.map { (key, entry) in
            ActionStatusEntry(
                uuid: Array(key),
                stampSec: entry.handle.acceptedAt.sec,
                stampNanosec: entry.handle.acceptedAt.nanosec,
                status: entry.status.rawValue
            )
        }
        stateLock.unlock()
        try? transport.publishStatus(entries: snapshot)
    }
}
