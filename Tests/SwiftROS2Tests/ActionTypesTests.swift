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

    func testActionErrorPayloads() {
        XCTAssertNotNil(ActionError.actionServerUnavailable.errorDescription)
        XCTAssertNotNil(ActionError.goalRejected.errorDescription)
        XCTAssertNotNil(ActionError.cancelRejected.errorDescription)
        XCTAssertNotNil(ActionError.acceptanceTimedOut.errorDescription)
        XCTAssertNotNil(ActionError.wrongSide.errorDescription)
        XCTAssertNotNil(ActionError.requestEncodingFailed("x").errorDescription)
    }
}
