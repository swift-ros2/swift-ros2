// ROS2ActionClient.swift
// Typed client wrapper around TransportActionClient.

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2Transport

/// Typed action client for a specific `ROS2Action`.
public final class ROS2ActionClient<A: ROS2Action>: @unchecked Sendable, NodeEntity {
    private let transport: any TransportActionClient
    /// The distribution whose message schemas the goal encoder and the feedback and result
    /// decoders use.
    private let distro: ROS2Distro
    private let lock = NSLock()
    private var closed = false

    public var name: String { transport.name }
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && transport.isActive
    }

    init(transport: any TransportActionClient, distro: ROS2Distro) {
        self.transport = transport
        self.distro = distro
    }

    /// Wait until the action server is reachable.
    public func waitForActionServer(timeout: Duration) async throws {
        do {
            try await transport.waitForActionServer(timeout: timeout)
        } catch let e as TransportError {
            if case .actionServerUnavailable = e {
                throw ActionError.actionServerUnavailable
            }
            throw ActionError.mapping(e)
        } catch {
            throw ActionError.mapping(error)
        }
    }

    /// Send a goal and return a typed `ActionGoalHandle`.
    public func sendGoal(
        _ goal: A.Goal,
        acceptanceTimeout: Duration = .seconds(5)
    ) async throws -> ActionGoalHandle<A> {
        let goalUUID = Foundation.UUID()
        let goalIdBytes = goalUUID.actionGoalIdBytes

        let encoder = CDREncoder(distro: distro)
        encoder.writeEncapsulationHeader()
        do {
            try goal.encode(to: encoder)
        } catch {
            throw ActionError.requestEncodingFailed(error.localizedDescription)
        }
        let goalCDR = encoder.getData()

        let ack: SendGoalAck
        do {
            ack = try await transport.sendGoal(
                goalId: goalIdBytes,
                goalCDR: goalCDR,
                acceptanceTimeout: acceptanceTimeout
            )
        } catch let e as TransportError {
            if case .requestTimeout = e { throw ActionError.acceptanceTimedOut }
            throw ActionError.mapping(e)
        } catch {
            throw ActionError.mapping(error)
        }

        guard ack.accepted else {
            throw ActionError.goalRejected
        }

        // Typed feedback stream.
        let schemaDistro = distro
        var fbCont: AsyncStream<A.Feedback>.Continuation!
        let typedFB = AsyncStream<A.Feedback> { fbCont = $0 }
        let fbContCap = fbCont!
        Task {
            for await raw in ack.feedback {
                do {
                    let dec = try CDRDecoder(data: raw, distro: schemaDistro)
                    let typed = try A.Feedback(from: dec)
                    fbContCap.yield(typed)
                } catch {
                    // Silent drop — feedback is best-effort.
                }
            }
            fbContCap.finish()
        }

        // Typed status stream.
        var stCont: AsyncStream<ActionGoalStatus>.Continuation!
        let typedST = AsyncStream<ActionGoalStatus> { stCont = $0 }
        let stContCap = stCont!
        Task {
            for await u in ack.status {
                stContCap.yield(ActionGoalStatus(rawValue: u.status) ?? .unknown)
            }
            stContCap.finish()
        }

        // Result provider — single-shot getResult call. The user's
        // `result(timeout:)` value is threaded all the way through; `nil`
        // is "wait forever" and translates to the transport's largest
        // representable timeout.
        let txn: any TransportActionClient = transport
        let provider: @Sendable (Duration?) async throws -> ActionResult<A.Result> = {
            userTimeout in
            let r: GetResultAck
            do {
                let effective = userTimeout ?? .seconds(Int.max)
                r = try await txn.getResult(goalId: goalIdBytes, timeout: effective)
            } catch let e as TransportError {
                if case .requestTimeout = e { throw ActionError.resultTimedOut }
                throw ActionError.mapping(e)
            } catch {
                throw ActionError.mapping(error)
            }
            switch ActionGoalStatus(rawValue: r.status) ?? .unknown {
            case .succeeded:
                do {
                    // `resultCDR` is the whole GetResult response; read the
                    // status first so the result keeps the frame's alignment origin.
                    let dec = try CDRDecoder(data: r.resultCDR, distro: schemaDistro)
                    _ = try dec.readInt8()
                    return .succeeded(try A.Result(from: dec))
                } catch {
                    throw ActionError.responseDecodingFailed(error.localizedDescription)
                }
            case .canceled: return .canceled
            case .aborted: return .aborted(reason: nil)
            default:
                throw ActionError.mapping(
                    TransportError.unsupportedFeature("unexpected terminal status \(r.status)")
                )
            }
        }

        // Build the client-side handle.
        let stamp = BuiltinInterfacesTime(sec: ack.stampSec, nanosec: ack.stampNanosec)
        let handle = ActionGoalHandle<A>(
            side: .client,
            goalId: goalUUID,
            acceptedAt: stamp,
            feedbackStream: typedFB,
            statusStream: typedST,
            distro: distro,
            resultProvider: provider
        )
        let cancelTransport: any TransportActionClient = transport
        handle._attachCancelClosure { timeout in
            let ack = try await cancelTransport.cancelGoal(
                goalId: goalIdBytes,
                beforeStampSec: nil,
                beforeStampNanosec: nil,
                timeout: timeout
            )
            // 0 is ERROR_NONE; every other code means the goal is not canceling.
            if ack.returnCode != 0 {
                throw ActionError.cancelRejected(reason: CancelRejection(returnCode: ack.returnCode))
            }
        }
        return handle
    }

    /// Cancel every active goal whose acceptance stamp is at or before `beforeStamp`.
    @discardableResult
    public func cancelGoals(
        beforeStamp: BuiltinInterfacesTime,
        timeout: Duration = .seconds(5)
    ) async throws -> [Foundation.UUID] {
        let ack: CancelGoalAck
        do {
            ack = try await transport.cancelGoal(
                goalId: nil,
                beforeStampSec: beforeStamp.sec,
                beforeStampNanosec: beforeStamp.nanosec,
                timeout: timeout
            )
        } catch {
            throw ActionError.mapping(error)
        }
        return ack.goalsCanceling.map { entry in
            Foundation.UUID(actionGoalIdBytes: entry.uuid)
        }
    }

    /// Cancel the client; close the underlying transport handle.
    public func cancel() {
        try? closeEntity()
    }

    var nodeEntityKind: NodeEntityKind { .actionClient }

    func closeEntity() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        try? transport.close()
    }
}
