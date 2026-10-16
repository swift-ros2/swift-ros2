// TransportActionTypes.swift
// Transport-layer protocols and supporting types for ROS 2 Actions.
//
// The transport surface is raw CDR — typed encode / decode lives one layer
// up in the umbrella `ROS2ActionServer<H>` / `ROS2ActionClient<A>`. This file
// defines the shapes the two layers exchange. Everything here is `package`:
// only the package `TransportSession` produces or consumes these types.

import Foundation

// MARK: - Ack structs

/// Per-goal-id status filter result.
///
/// The wire-level `_action/status` topic carries `GoalStatusArray` — i.e. all
/// goals' statuses in one message. The transport client filters on goal_id and
/// emits one `ActionStatusUpdate` per matching `GoalStatus` entry into the
/// per-goal `AsyncStream<ActionStatusUpdate>`.
package struct ActionStatusUpdate: Sendable, Equatable {
    /// Raw `int8` status value (matches `action_msgs/msg/GoalStatus.STATUS_*` constants).
    package let status: Int8

    package init(status: Int8) {
        self.status = status
    }
}

/// Result of a successful `sendGoal` call: the server's accept/reject decision,
/// the acceptance stamp, and the two raw-CDR streams the umbrella API will
/// decode and surface as the typed `feedback` / `statusUpdates`.
///
/// `accepted == false` means the server rejected the goal — the streams
/// terminate immediately (already-finished). The umbrella API translates this
/// into `ActionError.goalRejected`.
package struct SendGoalAck: Sendable {
    package let accepted: Bool
    package let stampSec: Int32
    package let stampNanosec: UInt32
    package let feedback: AsyncStream<Data>
    package let status: AsyncStream<ActionStatusUpdate>

    package init(
        accepted: Bool,
        stampSec: Int32,
        stampNanosec: UInt32,
        feedback: AsyncStream<Data>,
        status: AsyncStream<ActionStatusUpdate>
    ) {
        self.accepted = accepted
        self.stampSec = stampSec
        self.stampNanosec = stampNanosec
        self.feedback = feedback
        self.status = status
    }
}

/// Result of a `getResult` call: the terminal `GoalStatus` value plus the
/// raw `Result` CDR. The umbrella API decodes the CDR.
///
/// `resultCDR` is the whole GetResult response, `[header | int8 status |
/// result]`, not the result alone: XCDR v1 aligns the result's fields from
/// the end of the header, so a result encoded from its own origin would be
/// misaligned after the status byte. Encode it with one `CDREncoder`
/// (`writeEncapsulationHeader()`, `writeInt8(status)`, then the result) and
/// decode it the same way (`readInt8()`, then the result).
///
/// A goal that ended without a result (canceled, aborted, or unknown to the
/// server) still carries a complete default result, as rcl's action server
/// sends: ROS 2 clients deserialize every response as the typed
/// `<Action>_GetResult_Response`. Empty `resultCDR` means no result could be
/// built at all; the transports then send the status alone, which only a
/// swift-ros2 client can read (and the `.rcl` bridge completes with a rosidl
/// default result).
package struct GetResultAck: Sendable {
    package let status: Int8
    package let resultCDR: Data

    package init(status: Int8, resultCDR: Data) {
        self.status = status
        self.resultCDR = resultCDR
    }
}

/// Result of a `cancelGoal` call: the server's return code plus the list of
/// goals that are now in the CANCELING state.
package struct CancelGoalAck: Sendable {
    /// 16-byte UUID + acceptance stamp components (matches `action_msgs/GoalInfo`).
    package typealias GoalEntry = (uuid: [UInt8], stampSec: Int32, stampNanosec: UInt32)

    package let returnCode: Int8
    package let goalsCanceling: [GoalEntry]

    package init(returnCode: Int8, goalsCanceling: [GoalEntry]) {
        self.returnCode = returnCode
        self.goalsCanceling = goalsCanceling
    }
}

// MARK: - Per-action role hashes

/// Per-role type-hash bag the transport needs to construct wire codecs.
///
/// Mirrors the synthesized-wrapper hashes carried by `ROS2ActionTypeInfo`. The
/// umbrella API extracts these from the user's `ROS2Action` conformance and
/// passes them down on `createActionServer` / `createActionClient`. All fields
/// are optional — `nil` means `TypeHashNotSupported` (Humble) or "omit the
/// segment" (Jazzy+).
package struct ActionRoleTypeHashes: Sendable, Equatable {
    package let sendGoalRequest: String?
    package let sendGoalResponse: String?
    package let cancelGoalRequest: String?
    package let cancelGoalResponse: String?
    package let getResultRequest: String?
    package let getResultResponse: String?
    package let feedbackMessage: String?
    package let statusArray: String?
    /// Hash of the `<Action>_SendGoal` service type, which rmw_zenoh_cpp keys the
    /// `send_goal` service with (`ROS2ActionTypeInfo.sendGoalServiceTypeHash`).
    package let sendGoalService: String?
    /// Hash of the `action_msgs/srv/CancelGoal` service type, which rmw_zenoh_cpp
    /// keys the `cancel_goal` service with.
    package let cancelGoalService: String?
    /// Hash of the `<Action>_GetResult` service type, which rmw_zenoh_cpp keys the
    /// `get_result` service with (`ROS2ActionTypeInfo.getResultServiceTypeHash`).
    package let getResultService: String?

    /// Creates the hashes without the service-level hashes. On the wire Zenoh
    /// transport, the three action services then fall back to the request-typed
    /// keys only swift-ros2 peers use.
    package init(
        sendGoalRequest: String?,
        sendGoalResponse: String?,
        cancelGoalRequest: String?,
        cancelGoalResponse: String?,
        getResultRequest: String?,
        getResultResponse: String?,
        feedbackMessage: String?,
        statusArray: String?
    ) {
        self.init(
            sendGoalRequest: sendGoalRequest,
            sendGoalResponse: sendGoalResponse,
            cancelGoalRequest: cancelGoalRequest,
            cancelGoalResponse: cancelGoalResponse,
            getResultRequest: getResultRequest,
            getResultResponse: getResultResponse,
            feedbackMessage: feedbackMessage,
            statusArray: statusArray,
            sendGoalService: nil,
            cancelGoalService: nil,
            getResultService: nil
        )
    }

    /// Creates the hashes, including the service-level hashes of the three action
    /// services.
    package init(
        sendGoalRequest: String?,
        sendGoalResponse: String?,
        cancelGoalRequest: String?,
        cancelGoalResponse: String?,
        getResultRequest: String?,
        getResultResponse: String?,
        feedbackMessage: String?,
        statusArray: String?,
        sendGoalService: String?,
        cancelGoalService: String?,
        getResultService: String?
    ) {
        self.sendGoalRequest = sendGoalRequest
        self.sendGoalResponse = sendGoalResponse
        self.cancelGoalRequest = cancelGoalRequest
        self.cancelGoalResponse = cancelGoalResponse
        self.getResultRequest = getResultRequest
        self.getResultResponse = getResultResponse
        self.feedbackMessage = feedbackMessage
        self.statusArray = statusArray
        self.sendGoalService = sendGoalService
        self.cancelGoalService = cancelGoalService
        self.getResultService = getResultService
    }
}

// MARK: - Server-side handler

/// Raw-CDR server-side handler bag the transport needs to dispatch each role.
///
/// All three closures (`onSendGoal`, `onCancelGoal`, `onGetResult`) take
/// pre-decoded inputs (a 16-byte goal_id where applicable, plus the user
/// request CDR) and return raw-CDR outputs. The umbrella API wraps the
/// user's typed `ActionServerHandler` into these closures.
package struct TransportActionServerHandlers: Sendable {
    /// Called for each `_action/send_goal` request. Returns `(accepted, stampSec, stampNanosec)`.
    /// Throw to make the server reply with a transport-level error.
    package let onSendGoal:
        @Sendable (_ goalId: [UInt8], _ goalCDR: Data) async throws -> (
            Bool, Int32, UInt32
        )

    /// Called for each `_action/cancel_goal` request. Returns the response CDR
    /// (already encapsulation-prefixed) — the umbrella API encodes it.
    package let onCancelGoal: @Sendable (_ requestCDR: Data) async throws -> Data

    /// Called for each `_action/get_result` request. Awaits the goal's terminal
    /// state and returns the response CDR. The umbrella API blocks on the
    /// goal Task's completion before encoding.
    package let onGetResult: @Sendable (_ goalId: [UInt8]) async throws -> GetResultAck

    package init(
        onSendGoal: @escaping @Sendable ([UInt8], Data) async throws -> (Bool, Int32, UInt32),
        onCancelGoal: @escaping @Sendable (Data) async throws -> Data,
        onGetResult: @escaping @Sendable ([UInt8]) async throws -> GetResultAck
    ) {
        self.onSendGoal = onSendGoal
        self.onCancelGoal = onCancelGoal
        self.onGetResult = onGetResult
    }
}

// MARK: - Server / Client protocols

/// Active action-server handle. The transport owns the queryables / readers /
/// writers for all 5 wire-level roles; the umbrella `ROS2ActionServer`
/// publishes per-goal feedback and the goal-status array through it.
package protocol TransportActionServer: AnyObject, Sendable {
    var name: String { get }
    var isActive: Bool { get }

    /// Publish one feedback frame for `goalId`. `feedbackCDR` is the umbrella's
    /// encoded feedback, with or without its encapsulation header.
    func publishFeedback(goalId: [UInt8], feedbackCDR: Data) throws

    /// Publish the status array: one entry per goal the server tracks.
    func publishStatus(entries: [ActionStatusEntry]) throws

    func close() throws
}

/// Active action-client handle. Callers issue goals / cancels / result waits
/// through this protocol; the per-goal feedback and status `AsyncStream`s come
/// back inside the `SendGoalAck`.
package protocol TransportActionClient: AnyObject, Sendable {
    var name: String { get }
    var isActive: Bool { get }

    /// Wait until both the `send_goal` server side and the `feedback` publisher
    /// side are observable. Resolves on first observation; throws
    /// `TransportError.actionServerUnavailable` on timeout.
    func waitForActionServer(timeout: Duration) async throws

    /// Send a goal. The 16-byte `goalId` is supplied by the umbrella API
    /// (typically `Foundation.UUID().uuid`-derived). `goalCDR` carries the
    /// user-supplied Goal payload, already CDR-encapsulated.
    ///
    /// On accept, the returned ack's two streams stay alive until the goal
    /// terminates (status `succeeded` / `canceled` / `aborted`) or the client
    /// closes. On reject, the streams are immediately finished and `accepted`
    /// is `false`.
    func sendGoal(
        goalId: [UInt8],
        goalCDR: Data,
        acceptanceTimeout: Duration
    ) async throws -> SendGoalAck

    /// Block until the result is available or `timeout` fires.
    func getResult(
        goalId: [UInt8],
        timeout: Duration
    ) async throws -> GetResultAck

    /// Cancel one goal, all goals before a stamp, or both.
    /// Pass `nil` for `goalId` to cancel by stamp only; pass `nil` for
    /// `beforeStampSec`/`Nanosec` to cancel a single goal.
    /// Passing `nil` for both cancels every active goal.
    func cancelGoal(
        goalId: [UInt8]?,
        beforeStampSec: Int32?,
        beforeStampNanosec: UInt32?,
        timeout: Duration
    ) async throws -> CancelGoalAck

    func close() throws
}

// MARK: - ActionStatusEntry

/// One status array entry on the wire — uuid (16 bytes) + acceptance stamp + status byte.
///
/// The umbrella `ROS2ActionServer` builds these snapshots and passes them to
/// `TransportActionServer.publishStatus(entries:)`; the transport clients
/// decode received status arrays into them.
package struct ActionStatusEntry: Sendable, Equatable {
    package let uuid: [UInt8]
    package let stampSec: Int32
    package let stampNanosec: UInt32
    package let status: Int8

    package init(uuid: [UInt8], stampSec: Int32, stampNanosec: UInt32, status: Int8) {
        self.uuid = uuid
        self.stampSec = stampSec
        self.stampNanosec = stampNanosec
        self.status = status
    }
}

// MARK: - ActionPendingTable

/// Per-action-client table of the per-goal feedback and status streams.
///
/// Each in-flight goal has two continuations registered here:
/// - feedback `AsyncStream<Data>.Continuation` (one yield per `_action/feedback` arrival filtered to this goal),
/// - status `AsyncStream<ActionStatusUpdate>.Continuation` (one yield per filtered `GoalStatus` entry).
///
/// On terminal status (4 / 5 / 6 = succeeded / canceled / aborted) the actor
/// finishes both streams and drops the goal. Results do not pass through the
/// table: `getResult` is a request / reply of its own.
package actor ActionPendingTable {
    /// 16-byte goal id encoded as a `[UInt8]`. Must always be 16 bytes — the
    /// table does not validate length but downstream wire writes assume it.
    package typealias GoalId = [UInt8]

    /// Registered continuations for one in-flight goal.
    private struct Entry {
        var feedback: AsyncStream<Data>.Continuation
        var status: AsyncStream<ActionStatusUpdate>.Continuation
    }

    private var pending: [GoalId: Entry] = [:]

    package init() {}

    /// Register the per-goal feedback / status streams for an accepted goal.
    /// Idempotent — replaces any existing slots.
    package func registerStreams(
        goalId: GoalId,
        feedback: AsyncStream<Data>.Continuation,
        status: AsyncStream<ActionStatusUpdate>.Continuation
    ) {
        pending[goalId] = Entry(feedback: feedback, status: status)
    }

    /// Yield one feedback frame to the per-goal stream. No-op if the goal is
    /// unknown (e.g. canceled and removed already).
    @discardableResult
    package func yieldFeedback(goalId: GoalId, cdr: Data) -> Bool {
        guard let entry = pending[goalId] else { return false }
        entry.feedback.yield(cdr)
        return true
    }

    /// Yield one status update. If `status` is terminal (4, 5, 6), finish the
    /// feedback + status streams and drop the goal. Returns true if the goal
    /// was known.
    @discardableResult
    package func yieldStatus(goalId: GoalId, status: Int8) -> Bool {
        guard let entry = pending[goalId] else { return false }
        entry.status.yield(ActionStatusUpdate(status: status))
        if Self.isTerminal(status) {
            entry.feedback.finish()
            entry.status.finish()
            pending.removeValue(forKey: goalId)
        }
        return true
    }

    /// Cancel a single goal: finish its streams and drop it. Returns true if
    /// the goal was known.
    @discardableResult
    package func cancel(goalId: GoalId) -> Bool {
        guard let entry = pending.removeValue(forKey: goalId) else { return false }
        entry.feedback.finish()
        entry.status.finish()
        return true
    }

    /// Finish the streams of every in-flight goal. Used during `close()`.
    package func finishAll() {
        let snapshot = pending
        pending.removeAll()
        for (_, entry) in snapshot {
            entry.feedback.finish()
            entry.status.finish()
        }
    }

    /// Test helper — number of currently-tracked goals.
    package var count: Int { pending.count }

    private static func isTerminal(_ status: Int8) -> Bool {
        // STATUS_SUCCEEDED = 4, STATUS_CANCELED = 5, STATUS_ABORTED = 6.
        return status == 4 || status == 5 || status == 6
    }
}
