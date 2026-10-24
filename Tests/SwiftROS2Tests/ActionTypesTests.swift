// ActionTypesTests.swift
// Public-surface shape tests for action enums and ActionError.

import XCTest

@testable import SwiftROS2

final class ActionTypesTests: XCTestCase {
    func testGoalStatusRawValues() {
        XCTAssertEqual(ActionGoalStatus.unknown.rawValue, 0)
        XCTAssertEqual(ActionGoalStatus.accepted.rawValue, 1)
        XCTAssertEqual(ActionGoalStatus.executing.rawValue, 2)
        XCTAssertEqual(ActionGoalStatus.canceling.rawValue, 3)
        XCTAssertEqual(ActionGoalStatus.succeeded.rawValue, 4)
        XCTAssertEqual(ActionGoalStatus.canceled.rawValue, 5)
        XCTAssertEqual(ActionGoalStatus.aborted.rawValue, 6)
    }

    func testGoalStatusTerminalFlag() {
        XCTAssertTrue(ActionGoalStatus.succeeded.isTerminal)
        XCTAssertTrue(ActionGoalStatus.canceled.isTerminal)
        XCTAssertTrue(ActionGoalStatus.aborted.isTerminal)
        XCTAssertFalse(ActionGoalStatus.unknown.isTerminal)
        XCTAssertFalse(ActionGoalStatus.accepted.isTerminal)
        XCTAssertFalse(ActionGoalStatus.executing.isTerminal)
        XCTAssertFalse(ActionGoalStatus.canceling.isTerminal)
    }

    func testGoalResponseAndCancelResponseAreDecidable() {
        XCTAssertNotEqual(GoalResponse.accept, GoalResponse.reject)
        XCTAssertNotEqual(CancelResponse.accept, CancelResponse.reject)
    }

    func testActionResultCarriesPayload() {
        let r1: ActionResult<Int> = .succeeded(42)
        let r2: ActionResult<Int> = .aborted(reason: "nope")
        let r3: ActionResult<Int> = .canceled
        if case .succeeded(let v) = r1 {
            XCTAssertEqual(v, 42)
        } else {
            XCTFail("expected succeeded")
        }
        if case .aborted(let r) = r2 {
            XCTAssertEqual(r, "nope")
        } else {
            XCTFail("expected aborted")
        }
        if case .canceled = r3 {
        } else {
            XCTFail("expected canceled")
        }
    }

    func testActionWrappedResultConvertsToActionResult() {
        let succeeded = ActionWrappedResult<Int>(succeeded: 42)
        XCTAssertEqual(succeeded.status, .succeeded)
        XCTAssertEqual(succeeded.result, 42)
        guard case .succeeded(42) = succeeded.actionResult else {
            return XCTFail("expected succeeded(42), got \(succeeded.actionResult)")
        }
        let aborted = ActionWrappedResult<Int>(unsuccessful: .aborted, result: 7)
        XCTAssertEqual(aborted.result, 7)
        guard case .aborted(reason: nil) = aborted.actionResult else {
            return XCTFail("expected aborted, got \(aborted.actionResult)")
        }
        let canceled = ActionWrappedResult<Int>(unsuccessful: .canceled, result: nil)
        XCTAssertNil(canceled.result)
        guard case .canceled = canceled.actionResult else {
            return XCTFail("expected canceled, got \(canceled.actionResult)")
        }
    }

    func testActionWrappedResultEquality() {
        XCTAssertEqual(ActionWrappedResult<Int>(succeeded: 1), ActionWrappedResult<Int>(succeeded: 1))
        XCTAssertNotEqual(ActionWrappedResult<Int>(succeeded: 1), ActionWrappedResult<Int>(succeeded: 2))
        XCTAssertEqual(
            ActionWrappedResult<Int>(unsuccessful: .aborted, result: 1),
            ActionWrappedResult<Int>(unsuccessful: .aborted, result: 1)
        )
        XCTAssertNotEqual(
            ActionWrappedResult<Int>(unsuccessful: .aborted, result: 1),
            ActionWrappedResult<Int>(unsuccessful: .canceled, result: 1))
        XCTAssertNotEqual(
            ActionWrappedResult<Int>(unsuccessful: .aborted, result: 1),
            ActionWrappedResult<Int>(unsuccessful: .aborted, result: nil))
        XCTAssertNotEqual(
            ActionWrappedResult<Int>(succeeded: 1), ActionWrappedResult<Int>(unsuccessful: .aborted, result: 1))
    }

    func testActionErrorPayloads() {
        XCTAssertNotNil(ActionError.actionServerUnavailable.errorDescription)
        XCTAssertNotNil(ActionError.goalRejected.errorDescription)
        XCTAssertNotNil(ActionError.cancelRejected(reason: .goalTerminated).errorDescription)
        XCTAssertNotNil(ActionError.acceptanceTimedOut.errorDescription)
        XCTAssertNotNil(ActionError.wrongSide.errorDescription)
        XCTAssertNotNil(ActionError.requestEncodingFailed("x").errorDescription)
    }

    func testCancelRejectionMapsEveryReturnCode() {
        XCTAssertEqual(CancelRejection(returnCode: 1), .rejected)
        XCTAssertEqual(CancelRejection(returnCode: 2), .unknownGoal)
        XCTAssertEqual(CancelRejection(returnCode: 3), .goalTerminated)
        XCTAssertEqual(CancelRejection(returnCode: 7), .unknown(7))
        XCTAssertEqual(CancelRejection(returnCode: -128), .unknown(-128))
        XCTAssertNotEqual(CancelRejection.unknown(7), .unknown(8))
    }

    func testCancelRejectedDescriptionNamesTheReason() {
        let reasons: [CancelRejection] = [.rejected, .unknownGoal, .goalTerminated, .unknown(9)]
        let descriptions = reasons.map { ActionError.cancelRejected(reason: $0).errorDescription }
        XCTAssertEqual(Set(descriptions).count, reasons.count)
        XCTAssertTrue(descriptions.last??.contains("9") ?? false)
    }
}
