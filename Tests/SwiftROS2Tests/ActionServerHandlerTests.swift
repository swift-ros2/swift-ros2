// ActionServerHandlerTests.swift
// Verify a sample actor conforms to ActionServerHandler.

import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Messages

actor _NoopHandler: ActionServerHandler {
    typealias Action = FibonacciAction
    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }
    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
        .accept
    }
    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
        return FibonacciAction.Result(sequence: [0, 1, 1])
    }
}

final class ActionServerHandlerTests: XCTestCase {
    func testActorCanConformToHandler() async {
        let handler: any ActionServerHandler = _NoopHandler()
        XCTAssertNotNil(handler)
    }
}
