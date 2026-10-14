// ActionServerTests.swift
// Mock-session-driven tests for ROS2ActionServer.

import Foundation
import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

actor _AcceptingHandler: ActionServerHandler {
    typealias Action = FibonacciAction
    private(set) var lastGoal: FibonacciAction.Goal?

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse {
        lastGoal = goal
        return .accept
    }

    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
        .accept
    }

    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws
        -> FibonacciAction.Result
    {
        return FibonacciAction.Result(sequence: [0, 1, 1, 2, 3])
    }
}

actor _RejectingHandler: ActionServerHandler {
    typealias Action = FibonacciAction
    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .reject }
    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
        .reject
    }
    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws
        -> FibonacciAction.Result
    {
        XCTFail("should never execute on reject")
        throw ActionError.goalRejected
    }
}

final class ActionServerTests: XCTestCase {
    func testAcceptPathRunsExecuteAndCachesResult() async throws {
        let mock = MockTransportSession()
        let captured = MockActionServer.Box()
        mock.actionServerFactory = { _, _, _, _, handlers in
            captured.handlers = handlers
            return MockActionServer()
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        _ = try await node.createActionServer(
            FibonacciAction.self,
            name: "/fibonacci",
            handler: _AcceptingHandler()
        )

        // Drive a goal through the captured handlers.
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let encoder = CDREncoder(isLegacySchema: false)
        encoder.writeEncapsulationHeader()
        try FibonacciAction.Goal(order: 5).encode(to: encoder)
        let goalCDR = encoder.getData()

        let (accepted, _, _) = try await captured.handlers!.onSendGoal(goalId, goalCDR)
        XCTAssertTrue(accepted)

        // Wait for the goal Task to complete by polling getResult.
        var ack: GetResultAck?
        for _ in 0..<40 {
            if let r = try? await captured.handlers!.onGetResult(goalId) {
                if r.status == ActionGoalStatus.succeeded.rawValue {
                    ack = r
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(ack?.status, ActionGoalStatus.succeeded.rawValue)
        await ctx.shutdown()
    }

    func testRejectPathReturnsAcceptedFalse() async throws {
        let mock = MockTransportSession()
        let captured = MockActionServer.Box()
        mock.actionServerFactory = { _, _, _, _, handlers in
            captured.handlers = handlers
            return MockActionServer()
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        _ = try await node.createActionServer(
            FibonacciAction.self,
            name: "/fibonacci",
            handler: _RejectingHandler()
        )
        let goalId = [UInt8](repeating: 0xBB, count: 16)
        let encoder = CDREncoder(isLegacySchema: false)
        encoder.writeEncapsulationHeader()
        try FibonacciAction.Goal(order: 5).encode(to: encoder)
        let (accepted, _, _) = try await captured.handlers!.onSendGoal(goalId, encoder.getData())
        XCTAssertFalse(accepted)
        await ctx.shutdown()
    }
}
