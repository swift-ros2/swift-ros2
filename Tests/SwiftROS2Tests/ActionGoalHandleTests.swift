// ActionGoalHandleTests.swift
// Per-side capability gating.

import Foundation
import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Messages

final class ActionGoalHandleTests: XCTestCase {
    func testClientHandlePublishFeedbackThrowsWrongSide() async throws {
        let handle = ActionGoalHandle<FibonacciAction>(
            side: .client,
            goalId: Foundation.UUID(),
            acceptedAt: BuiltinInterfacesTime(),
            feedbackStream: AsyncStream { _ in },
            statusStream: AsyncStream { _ in },
            distro: .jazzy,
            outcomeProvider: { _ in throw ActionError.clientClosed }
        )
        do {
            try await handle.publishFeedback(
                FibonacciAction.Feedback(sequence: [])
            )
            XCTFail("expected wrongSide")
        } catch let e as ActionError {
            if case .wrongSide = e { return }
            XCTFail("got \(e)")
        }
    }

    func testServerHandleResultThrowsWrongSide() async throws {
        let handle = ActionGoalHandle<FibonacciAction>(
            side: .server,
            goalId: Foundation.UUID(),
            acceptedAt: BuiltinInterfacesTime(),
            feedbackStream: AsyncStream { _ in },
            statusStream: AsyncStream { _ in },
            distro: .jazzy,
            outcomeProvider: { _ in throw ActionError.serverClosed }
        )
        do {
            _ = try await handle.result(timeout: nil)
            XCTFail("expected wrongSide")
        } catch let e as ActionError {
            if case .wrongSide = e { return }
            XCTFail("got \(e)")
        }
    }

    func testServerHandleOutcomeThrowsWrongSide() async throws {
        let handle = ActionGoalHandle<FibonacciAction>(
            side: .server,
            goalId: Foundation.UUID(),
            acceptedAt: BuiltinInterfacesTime(),
            feedbackStream: AsyncStream { _ in },
            statusStream: AsyncStream { _ in },
            distro: .jazzy,
            outcomeProvider: { _ in throw ActionError.serverClosed }
        )
        do {
            _ = try await handle.outcome(timeout: nil)
            XCTFail("expected wrongSide")
        } catch let e as ActionError {
            if case .wrongSide = e { return }
            XCTFail("got \(e)")
        }
    }

    func testServerHandleIsCancelRequestedReturnsLatest() async {
        let handle = ActionGoalHandle<FibonacciAction>(
            side: .server,
            goalId: Foundation.UUID(),
            acceptedAt: BuiltinInterfacesTime(),
            feedbackStream: AsyncStream { _ in },
            statusStream: AsyncStream { _ in },
            distro: .jazzy,
            outcomeProvider: { _ in throw ActionError.serverClosed }
        )
        let initial = await handle.isCancelRequested
        XCTAssertFalse(initial)
        await handle._setCancelRequested(true)
        let after = await handle.isCancelRequested
        XCTAssertTrue(after)
    }
}
