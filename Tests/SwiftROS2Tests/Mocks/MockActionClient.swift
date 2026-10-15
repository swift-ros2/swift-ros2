// MockActionClient.swift
// In-memory TransportActionClient for SwiftROS2 umbrella unit tests.

import Foundation
import SwiftROS2Transport

final class MockActionClient: TransportActionClient, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var closed = false

    /// Decision returned by `sendGoal`.
    enum Acceptance {
        case accept
        case reject
    }

    private let acceptance: Acceptance
    private let feedbackCDRs: [Data]
    private let statusUpdates: [Int8]
    private let getResultStatus: Int8
    private let getResultCDR: Data

    init(
        name: String = "/mock_action",
        acceptance: Acceptance = .accept,
        feedbackCDRs: [Data] = [],
        statusUpdates: [Int8] = [],
        getResultStatus: Int8 = 4,  // succeeded
        getResultCDR: Data = Data()
    ) {
        self.name = name
        self.acceptance = acceptance
        self.feedbackCDRs = feedbackCDRs
        self.statusUpdates = statusUpdates
        self.getResultStatus = getResultStatus
        self.getResultCDR = getResultCDR
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func waitForActionServer(timeout: Duration) async throws {}

    func sendGoal(
        goalId: [UInt8],
        goalCDR: Data,
        acceptanceTimeout: Duration
    ) async throws -> SendGoalAck {
        precondition(goalId.count == 16)
        var fbCont: AsyncStream<Data>.Continuation!
        let feedback = AsyncStream<Data> { fbCont = $0 }
        let fbContCap = fbCont!
        var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let status = AsyncStream<ActionStatusUpdate> { stCont = $0 }
        let stContCap = stCont!

        switch acceptance {
        case .accept:
            // Yield seeded feedback / status frames asynchronously.
            let fbs = feedbackCDRs
            let sts = statusUpdates
            Task {
                for f in fbs {
                    fbContCap.yield(f)
                }
                fbContCap.finish()
            }
            Task {
                for s in sts {
                    stContCap.yield(ActionStatusUpdate(status: s))
                }
                stContCap.finish()
            }
            return SendGoalAck(
                accepted: true, stampSec: 1, stampNanosec: 2,
                feedback: feedback, status: status
            )
        case .reject:
            fbContCap.finish()
            stContCap.finish()
            return SendGoalAck(
                accepted: false, stampSec: 0, stampNanosec: 0,
                feedback: feedback, status: status
            )
        }
    }

    func getResult(goalId: [UInt8], timeout: Duration) async throws -> GetResultAck {
        return GetResultAck(status: getResultStatus, resultCDR: getResultCDR)
    }

    func cancelGoal(
        goalId: [UInt8]?,
        beforeStampSec: Int32?,
        beforeStampNanosec: UInt32?,
        timeout: Duration
    ) async throws -> CancelGoalAck {
        return CancelGoalAck(returnCode: 0, goalsCanceling: [])
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    // MARK: - Convenience constructors used by tests

    static func makeAccepting(
        feedbackCDRs: [Data] = [],
        statusUpdates: [Int8] = [],
        getResultStatus: Int8 = 4,
        getResultCDR: Data = Data()
    ) -> MockActionClient {
        return MockActionClient(
            acceptance: .accept,
            feedbackCDRs: feedbackCDRs,
            statusUpdates: statusUpdates,
            getResultStatus: getResultStatus,
            getResultCDR: getResultCDR
        )
    }

    static func makeRejecting() -> MockActionClient {
        return MockActionClient(acceptance: .reject)
    }
}
