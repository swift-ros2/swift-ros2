// ActionGoalHandle.swift
// Typed per-goal handle, shared between server and client sides.

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages

/// Handle for a single in-flight ROS 2 action goal.
///
/// Created by `ROS2ActionClient<A>.sendGoal(...)` (client side) or by the
/// internal accept path of `ROS2ActionServer<H>` (server side). Each side
/// gets a different subset of capabilities — calling `publishFeedback` on a
/// client-side handle, or `result(timeout:)` / `outcome(timeout:)` on a server-side handle, throws
/// `ActionError.wrongSide`.
public final class ActionGoalHandle<A: ROS2Action>: @unchecked Sendable {
    enum Side: Sendable {
        case server
        case client
    }

    public let goalId: Foundation.UUID
    public let acceptedAt: BuiltinInterfacesTime

    /// Per-goal feedback stream. Yields one decoded `A.Feedback` per
    /// `_action/feedback` arrival filtered to this goal. Finishes on
    /// terminal status.
    public let feedback: AsyncStream<A.Feedback>

    /// Per-goal status update stream (opt-in). Yields one `ActionGoalStatus`
    /// per filtered status entry. Finishes on terminal status.
    public let statusUpdates: AsyncStream<ActionGoalStatus>

    private let side: Side
    /// Threads the user's `outcome(timeout:)` / `result(timeout:)` value through to the
    /// underlying transport `getResult` call. `nil` means "wait forever" — the provider
    /// translates that into the transport's largest representable timeout. Both public
    /// methods read the reply through it, so they never decode it differently.
    private let outcomeProvider: @Sendable (Duration?) async throws -> ActionOutcome<A.Result>

    // Server-side mutable state (cancel-request flag + feedback publisher).
    private let stateLock = NSLock()
    private var _isCancelRequested: Bool = false
    private var _publishFeedback: (@Sendable (Data) throws -> Void)?
    private var _cancelClosure: (@Sendable (Duration) async throws -> Void)?
    /// The distribution whose message schemas the feedback encoder writes.
    private let distro: ROS2Distro

    init(
        side: Side,
        goalId: Foundation.UUID,
        acceptedAt: BuiltinInterfacesTime,
        feedbackStream: AsyncStream<A.Feedback>,
        statusStream: AsyncStream<ActionGoalStatus>,
        distro: ROS2Distro,
        outcomeProvider: @escaping @Sendable (Duration?) async throws -> ActionOutcome<A.Result>
    ) {
        self.side = side
        self.goalId = goalId
        self.acceptedAt = acceptedAt
        self.feedback = feedbackStream
        self.statusUpdates = statusStream
        self.distro = distro
        self.outcomeProvider = outcomeProvider
    }

    /// Server-side: install the closure that sends a typed `Feedback` over the wire.
    /// Internal — set by `ROS2ActionServer` immediately after construction.
    func _attachPublishFeedback(_ fn: @escaping @Sendable (Data) throws -> Void) {
        stateLock.lock()
        _publishFeedback = fn
        stateLock.unlock()
    }

    /// Client-side: install the closure that issues a `cancel_goal` request.
    func _attachCancelClosure(_ c: @escaping @Sendable (Duration) async throws -> Void) {
        stateLock.lock()
        _cancelClosure = c
        stateLock.unlock()
    }

    /// Server-side: latest cancel-request state. Toggled by the umbrella when
    /// the client requests cancellation and the handler accepts.
    public var isCancelRequested: Bool {
        get async {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCancelRequested
        }
    }

    /// Internal mutator used by the server's cancel path + tests.
    func _setCancelRequested(_ v: Bool) async {
        stateLock.lock()
        _isCancelRequested = v
        stateLock.unlock()
    }

    /// Server-side: publish a typed feedback message for this goal.
    ///
    /// Throws `ActionError.wrongSide` if called on a client-side handle.
    public func publishFeedback(_ fb: A.Feedback) async throws {
        guard side == .server else { throw ActionError.wrongSide }
        // The owning context's distribution: message shapes differ on Humble, and generated types
        // may differ among later distributions too.
        let encoder = CDREncoder(distro: distro)
        encoder.writeEncapsulationHeader()
        do {
            try fb.encode(to: encoder)
        } catch {
            throw ActionError.requestEncodingFailed(error.localizedDescription)
        }
        let cdr = encoder.getData()
        stateLock.lock()
        let publisher = _publishFeedback
        stateLock.unlock()
        guard let publisher = publisher else {
            throw ActionError.serverClosed
        }
        do {
            try publisher(cdr)
        } catch {
            throw ActionError.mapping(error)
        }
    }

    /// Client-side: wait for the goal's terminal state and decoded result.
    ///
    /// `timeout: nil` waits forever (the provider passes the transport's
    /// largest representable timeout downstream). Throws
    /// `ActionError.wrongSide` on the server side.
    ///
    /// The result of a canceled or aborted goal is not returned; await
    /// ``outcome(timeout:)`` to read it.
    public func result(timeout: Duration? = nil) async throws -> ActionResult<A.Result> {
        try await outcome(timeout: timeout).actionResult
    }

    /// Client-side: wait for the goal's terminal state and the result the server sent with
    /// it, for every terminal status.
    ///
    /// Waits and throws like ``result(timeout:)``: `timeout: nil` waits forever,
    /// ``ActionError/resultTimedOut`` when `timeout` passes first, ``ActionError/wrongSide``
    /// on the server side, ``ActionError/responseDecodingFailed(_:)`` when a succeeded goal's
    /// result cannot be decoded, and ``ActionError/mapping(_:)`` for a transport failure or a
    /// reply whose status is not terminal. Unlike ``result(timeout:)``, it also decodes the
    /// result of a canceled or aborted goal, where servers report why the goal failed (MoveIt's
    /// `move_group` sets `error_code`); ``ActionOutcome/result`` is `nil` when that reply
    /// carries no result that decodes.
    ///
    /// ```swift
    /// let outcome = try await handle.outcome(timeout: .seconds(30))
    /// if outcome.status == .aborted, let result = outcome.result {
    ///     print("Aborted: \(result)")
    /// }
    /// ```
    public func outcome(timeout: Duration? = nil) async throws -> ActionOutcome<A.Result> {
        guard side == .client else { throw ActionError.wrongSide }
        return try await outcomeProvider(timeout)
    }

    /// Client-side: cancel just this goal.
    ///
    /// Returns once the server accepted the request (the goal is canceling).
    /// Throws ``ActionError/cancelRejected(reason:)`` when the server refuses it;
    /// the reason tells a goal that had already reached a terminal state
    /// (``CancelRejection/goalTerminated``) from a refusal.
    public func cancel(timeout: Duration? = .seconds(5)) async throws {
        guard side == .client else { throw ActionError.wrongSide }
        stateLock.lock()
        let canceler = _cancelClosure
        stateLock.unlock()
        guard let canceler = canceler else {
            throw ActionError.clientClosed
        }
        try await canceler(timeout ?? .seconds(5))
    }

}
