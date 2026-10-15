// ActionStatusOrderTests.swift
// The action server sends status snapshots in the order it reads them, so the
// last status array a client receives reflects the goals' latest states.

import Foundation
import SwiftROS2ExampleInterfaces
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Transport

final class ActionStatusOrderTests: XCTestCase {
    private final class SucceedingHandler: ActionServerHandler, @unchecked Sendable {
        typealias Action = FibonacciAction
        func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }
        func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .accept }
        func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
            FibonacciAction.Result(sequence: [0, 1])
        }
    }

    /// Delays the send of every snapshot that still shows a goal ACCEPTED while the
    /// goal runs to SUCCEEDED on another thread. A snapshot read earlier must not be
    /// sent after one read later, so the last snapshot shows every goal SUCCEEDED.
    func testADelayedEarlierSnapshotIsNotSentAfterALaterOne() async throws {
        let mock = MockTransportSession()
        let server = MockActionServer()
        let captured = Box<TransportActionServerHandlers?>(nil)
        mock.actionServerFactory = { _, _, _, _, handlers in
            captured.value = handlers
            return server
        }
        let accepted = ActionGoalStatus.accepted.rawValue
        server.beforeRecordingStatus = { entries in
            if entries.contains(where: { $0.status == accepted }) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        _ = try await node.createActionServer(FibonacciAction.self, name: "/fibonacci", handler: SucceedingHandler())
        let handlers = try XCTUnwrap(captured.value)

        let goalCount = 20
        for n in 1...goalCount {
            let encoder = CDREncoder(isLegacySchema: false)
            encoder.writeEncapsulationHeader()
            try FibonacciAction.Goal(order: 1).encode(to: encoder)
            let (ok, _, _) = try await handlers.onSendGoal([UInt8](repeating: UInt8(n), count: 16), encoder.getData())
            XCTAssertTrue(ok)
        }

        let succeeded = ActionGoalStatus.succeeded.rawValue
        func allSucceeded() -> Bool {
            guard let last = server.publishedStatuses.last, last.count == goalCount else { return false }
            return last.allSatisfy { $0.status == succeeded }
        }
        for _ in 0..<2000 where !allSucceeded() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Let any snapshot still being sent finish, then check the last one again.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(allSucceeded(), "last status snapshot: \(String(describing: server.publishedStatuses.last))")
        await ctx.shutdown()
    }
}
