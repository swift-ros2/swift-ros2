import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import XCTest

/// Swift action server and Swift action client over wire Zenoh through a real
/// router. Requires `ZENOH_ROUTER` (for example `tcp/192.168.1.85:7447`).
/// Skips otherwise.
final class ZenohActionIntegrationTests: XCTestCase {
    private actor FibonacciServer: ActionServerHandler {
        typealias Action = FibonacciAction
        private var order: Int32 = 0

        func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse {
            order = goal.order
            return .accept
        }

        func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .accept }

        func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
            var sequence: [Int32] = [0, 1]
            for _ in 0..<max(0, Int(order) - 2) {
                sequence.append(sequence[sequence.count - 1] + sequence[sequence.count - 2])
                try await handle.publishFeedback(FibonacciAction.Feedback(sequence: sequence))
            }
            return FibonacciAction.Result(sequence: sequence)
        }
    }

    /// The first feedback of a goal goes out while the server is still sending
    /// the send_goal reply and the goal's status. It used to fail with
    /// `putFailed("Error code: -100")` in most goals, which aborted the goal.
    /// Once feedback carried attachments, the client's read task crashed on the
    /// next reply instead, until replies were no longer consolidated.
    func testEveryGoalSucceedsWithAllFeedback() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        // Two contexts: this zenoh-pico build delivers neither a session's own
        // queries to its queryables nor its own samples to its subscribers.
        let serverCtx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
        let clientCtx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
        let serverNode = try await serverCtx.createNode(name: "fib_server", namespace: "/zenoh_action_it")
        let clientNode = try await clientCtx.createNode(name: "fib_client", namespace: "/zenoh_action_it")
        let server = try await serverNode.createActionServer(
            FibonacciAction.self, name: "fibonacci", handler: FibonacciServer())
        let client = try await clientNode.createActionClient(FibonacciAction.self, name: "fibonacci")
        try await client.waitForActionServer(timeout: .seconds(10))

        for goal in 0..<20 {
            let handle = try await client.sendGoal(FibonacciAction.Goal(order: 6))
            let feedback = Task { () -> Int in
                var count = 0
                for await _ in handle.feedback { count += 1 }
                return count
            }
            let result = try await handle.result(timeout: .seconds(10))
            guard case .succeeded(let r) = result else {
                feedback.cancel()
                XCTFail("goal \(goal) ended \(result)")
                break
            }
            XCTAssertEqual(r.sequence, [0, 1, 1, 2, 3, 5], "goal \(goal)")
            try await Task.sleep(nanoseconds: 200_000_000)
            feedback.cancel()
            let feedbackCount = await feedback.value
            XCTAssertEqual(feedbackCount, 4, "goal \(goal) feedback")
        }

        _ = server
        await clientCtx.shutdown()
        await serverCtx.shutdown()
    }
}
