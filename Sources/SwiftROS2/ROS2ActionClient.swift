// ROS2ActionClient.swift
// Typed client wrapper around TransportActionClient.

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2Transport

/// Typed action client for a specific `ROS2Action`.
public final class ROS2ActionClient<A: ROS2Action>: @unchecked Sendable, ActionClientCloseable {
    private let transport: any TransportActionClient
    private let isLegacySchema: Bool
    private let lock = NSLock()
    private var closed = false

    public var name: String { transport.name }
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && transport.isActive
    }

    init(transport: any TransportActionClient, isLegacySchema: Bool) {
        self.transport = transport
        self.isLegacySchema = isLegacySchema
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
        let goalIdBytes = Self.uuidBytes(goalUUID)

        let encoder = CDREncoder(isLegacySchema: isLegacySchema)
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
        let isLegacy = isLegacySchema
        var fbCont: AsyncStream<A.Feedback>.Continuation!
        let typedFB = AsyncStream<A.Feedback> { fbCont = $0 }
        let fbContCap = fbCont!
        Task {
            for await raw in ack.feedback {
                do {
                    let dec = try CDRDecoder(
                        data: Self.prependHeaderIfMissing(raw),
                        isLegacySchema: isLegacy
                    )
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
                    let dec = try CDRDecoder(data: r.resultCDR, isLegacySchema: isLegacy)
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
            isLegacySchema: isLegacySchema,
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
            if ack.returnCode != 0 { throw ActionError.cancelRejected }
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
            Self.uuidFromBytes(entry.uuid)
        }
    }

    /// Cancel the client; close the underlying transport handle.
    public func cancel() {
        try? closeActionClient()
    }

    func closeActionClient() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        try? transport.close()
    }

    // MARK: - CDR helpers

    /// `CDRDecoder(data:)` requires the 4-byte encapsulation header. Every
    /// transport already hands over goal / feedback payloads with
    /// exactly one leading header (`ActionFrameDecoder.decode*` restores it
    /// unconditionally), so for them this is a no-op; it only prepends the
    /// header for a payload that doesn't start with `00 01 00 00`.
    static func prependHeaderIfMissing(_ data: Data) -> Data {
        if data.count >= 4 {
            let base = data.startIndex
            if data[base] == 0x00, data[base + 1] == 0x01,
                data[base + 2] == 0x00, data[base + 3] == 0x00
            {
                return data
            }
        }
        var out = Data(capacity: 4 + data.count)
        out.append(contentsOf: [0x00, 0x01, 0x00, 0x00])
        out.append(data)
        return out
    }

    // MARK: - UUID helpers

    static func uuidBytes(_ uuid: Foundation.UUID) -> [UInt8] {
        let t = uuid.uuid
        return [
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15,
        ]
    }

    static func uuidFromBytes(_ b: [UInt8]) -> Foundation.UUID {
        precondition(b.count == 16)
        return Foundation.UUID(
            uuid: (
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
            ))
    }
}

/// Internal protocol for type-erased action-client cleanup.
protocol ActionClientCloseable {
    func closeActionClient() throws
}
