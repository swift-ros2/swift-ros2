import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import XCTest

@testable import SwiftROS2

/// Serves example_interfaces/action/Fibonacci through the real rcl +
/// rmw_cyclonedds_cpp stack and asserts a goal from a real ROS 2 host was
/// accepted, fed back, and completed (actions verification: the
/// serialize-shim rcl_action server answers a real rclpy action client).
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable
/// Jazzy host (LINUX_IP). This is a runbook test — CI never runs it. Start
/// the test, then within 60 s issue the goal from the host:
///
///   ros2 action send_goal /swift_ros2_rcl/fibonacci \
///     example_interfaces/action/Fibonacci "{order: 5}" --feedback
///
/// The host must print per-step feedback and "Result: sequence: [0, 1, 1, 2,
/// 3, 5]" with status SUCCEEDED. If no goal arrives within 60 s the test
/// skips (the host side is manual), unless RCL_SVC_EXPECT_CALL=1 is set — in
/// which case the absence of a goal is a failure.
///
/// If the host's send_goal stays at "Waiting for an action server" the LAN
/// likely drops multicast (typical on Wi-Fi): set unicast peers on BOTH
/// sides via CYCLONEDDS_URI, each pointing at the other machine —
/// `<CycloneDDS><Domain><Discovery><Peers><Peer address="<other-ip>"/>
/// </Peers></Discovery></Domain></CycloneDDS>` (verified 2026-06-11:
/// multicast discovery failed Mac<->host, unicast peers round-tripped the
/// full goal/feedback/result exchange).
final class RclActionIntegrationTests: XCTestCase {
    func testServeFibonacciOverRcl() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip("LINUX_IP not set — skipping LAN integration test")
            }
            let expectCall = ProcessInfo.processInfo.environment["RCL_SVC_EXPECT_CALL"] == "1"

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_action_test", namespace: "/swift_ros2_rcl")

            // Capture the goals the handler executed so the test can assert
            // both that a goal arrived and what it computed.
            let handler = RecordingFibonacciHandler()
            _ = try await node.createActionServer(
                FibonacciAction.self, name: "fibonacci", handler: handler)

            // Wait up to 60 s for the operator to issue the documented goal,
            // then allow the executing Task time to finish (order=5 at 100 ms
            // per step completes well within the post-arrival window).
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while ContinuousClock.now < deadline, await handler.completedSequences.isEmpty {
                try await Task.sleep(for: .milliseconds(200))
            }

            let sequences = await handler.completedSequences
            guard let first = sequences.first else {
                await ctx.shutdown()
                if expectCall {
                    return XCTFail(
                        "no Fibonacci goal completed within 60 s with RCL_SVC_EXPECT_CALL=1 — "
                            + "did the host send the goal? (see the header of this file)")
                }
                throw XCTSkip(
                    "no Fibonacci goal completed within 60 s — run the host-side send_goal "
                        + "documented in the header of this file to exercise this test")
            }

            // The documented host command sends {order: 5}; the host-side
            // feedback lines + "SUCCEEDED" result are the real assertion that
            // the feedback topic and the GetResult service decoded.
            XCTAssertEqual(first, [0, 1, 1, 2, 3, 5])

            await ctx.shutdown()
        #endif
    }
}

#if SWIFT_ROS2_RCL
    /// Fibonacci handler that records every completed sequence — the goal
    /// executes on a detached task, the test polls from the test executor.
    private actor RecordingFibonacciHandler: ActionServerHandler {
        typealias Action = FibonacciAction

        private var pendingOrder: Int32 = 0
        private(set) var completedSequences: [[Int32]] = []

        func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse {
            guard goal.order > 0 else { return .reject }
            pendingOrder = goal.order
            return .accept
        }

        func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
            return .accept
        }

        func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws
            -> FibonacciAction.Result
        {
            let order = pendingOrder
            var sequence: [Int32] = [0, 1]
            for i in 1..<Int(order) {
                try Task.checkCancellation()
                if await handle.isCancelRequested {
                    throw CancellationError()
                }
                sequence.append(sequence[i] + sequence[i - 1])
                try await handle.publishFeedback(FibonacciAction.Feedback(sequence: sequence))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            completedSequences.append(sequence)
            return FibonacciAction.Result(sequence: sequence)
        }
    }
#endif
