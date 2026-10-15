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
/// client-side handle, or `result(timeout:)` on a server-side handle, throws
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
    /// Threaded the user's `result(timeout:)` value through to the underlying
    /// transport `getResult` call. `nil` means "wait forever" — the provider
    /// translates that into the transport's largest representable timeout.
    private let resultProvider: @Sendable (Duration?) async throws -> ActionResult<A.Result>

    // Server-side mutable state (cancel-request flag + feedback publisher).
    private let stateLock = NSLock()
    private var _isCancelRequested: Bool = false
    private var _publishFeedback: (@Sendable (Data) throws -> Void)?
    private var _cancelClosure: (@Sendable (Duration) async throws -> Void)?
    private let isLegacySchema: Bool

    init(
        side: Side,
        goalId: Foundation.UUID,
        acceptedAt: BuiltinInterfacesTime,
        feedbackStream: AsyncStream<A.Feedback>,
        statusStream: AsyncStream<ActionGoalStatus>,
        isLegacySchema: Bool,
        resultProvider: @escaping @Sendable (Duration?) async throws -> ActionResult<A.Result>
    ) {
        self.side = side
        self.goalId = goalId
        self.acceptedAt = acceptedAt
        self.feedback = feedbackStream
        self.statusUpdates = statusStream
        self.isLegacySchema = isLegacySchema
        self.resultProvider = resultProvider
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
        // Use the schema choice that the owning context registered with us
        // — `false` is wrong on Humble where some message shapes differ.
        let encoder = CDREncoder(isLegacySchema: isLegacySchema)
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
    public func result(timeout: Duration? = nil) async throws -> ActionResult<A.Result> {
        guard side == .client else { throw ActionError.wrongSide }
        return try await resultProvider(timeout)
    }

    /// Client-side: cancel just this goal.
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
