import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2TestSupport
import XCTest

/// A service or action server that is closed while a request is still being
/// handled: the late reply must be dropped instead of reaching a query the
/// close already freed (a heap-use-after-free before the fix). Wire Zenoh
/// through a real router; requires `ZENOH_ROUTER` (for example
/// `tcp/192.168.1.85:7447`) and skips otherwise.
///
/// Most telling under AddressSanitizer (`swift test --sanitize=address` with
/// `ASAN_OPTIONS=detect_leaks=0`).
final class ZenohReplyAfterCloseIntegrationTests: XCTestCase {
    /// Lets a handler wait until the test opens it.
    private final class Gate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream<Void>.makeStream()
        }

        func open() { continuation.finish() }

        func wait() async {
            for await _ in stream {}
        }
    }

    private struct Pair {
        let serverCtx: ROS2Context
        let clientCtx: ROS2Context
        let serverNode: ROS2Node
        let clientNode: ROS2Node

        func shutdown() async {
            await clientCtx.shutdown()
            await serverCtx.shutdown()
        }
    }

    /// Two contexts: zenoh-pico does not deliver a session's own queries to
    /// its queryables.
    private func makePair(namespace: String) async throws -> Pair {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        let serverCtx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
        let clientCtx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
        return Pair(
            serverCtx: serverCtx,
            clientCtx: clientCtx,
            serverNode: try await serverCtx.createNode(name: "server", namespace: namespace),
            clientNode: try await clientCtx.createNode(name: "client", namespace: namespace)
        )
    }

    /// Scenario 1: a handler is still running when `close` runs, and returns
    /// its response afterwards.
    private func runSlowHandler(
        namespace: String,
        close: @Sendable (Pair, ROS2Service<TriggerSrv>) async -> Void
    ) async throws {
        let pair = try await makePair(namespace: namespace)
        let entered = expectation(description: "handler entered")
        entered.assertForOverFulfill = false
        let returned = expectation(description: "handler returned")
        returned.assertForOverFulfill = false
        let gate = Gate()
        let service = try await pair.serverNode.createService(TriggerSrv.self, name: "slow") { _ in
            entered.fulfill()
            await gate.wait()
            returned.fulfill()
            return TriggerSrv.Response(success: true, message: "late")
        }
        let client = try await pair.clientNode.createClient(TriggerSrv.self, name: "slow")
        try await client.waitForService(timeout: .seconds(10))

        let call = Task { try await client.call(.init(), timeout: .seconds(5)) }
        await fulfillment(of: [entered], timeout: 10)

        await close(pair, service)
        gate.open()
        await fulfillment(of: [returned], timeout: 10)

        // The request was never answered: the call fails, it does not hang.
        do {
            _ = try await call.value
            XCTFail("the call was answered by a closed server")
        } catch {}
        // Give the reply task time to run into the closed query.
        try await Task.sleep(for: .milliseconds(200))
        await pair.shutdown()
    }

    func testSlowHandlerRepliesAfterServiceCancel() async throws {
        try await runSlowHandler(namespace: "/reply_after_close/cancel") { _, service in
            service.cancel()
        }
    }

    func testSlowHandlerRepliesAfterNodeDestroy() async throws {
        try await runSlowHandler(namespace: "/reply_after_close/destroy") { pair, _ in
            await pair.serverNode.destroy()
        }
    }

    func testSlowHandlerRepliesAfterContextShutdown() async throws {
        try await runSlowHandler(namespace: "/reply_after_close/shutdown") { pair, _ in
            await pair.serverCtx.shutdown()
        }
    }

    /// Scenario 2: a handler closes its own server and then returns.
    func testHandlerClosesItsOwnService() async throws {
        let pair = try await makePair(namespace: "/reply_after_close/self")
        let own = Box<ROS2Service<TriggerSrv>?>(nil)
        let returned = expectation(description: "handler returned")
        returned.assertForOverFulfill = false
        let service = try await pair.serverNode.createService(TriggerSrv.self, name: "once") { _ in
            // The test stores the service right after createService returns.
            await eventually { own.value != nil }
            own.value?.cancel()
            returned.fulfill()
            return TriggerSrv.Response(success: true, message: "closed myself")
        }
        own.value = service
        let client = try await pair.clientNode.createClient(TriggerSrv.self, name: "once")
        try await client.waitForService(timeout: .seconds(10))

        let call = Task { try await client.call(.init(), timeout: .seconds(5)) }
        await fulfillment(of: [returned], timeout: 10)
        _ = try? await call.value
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(service.isActive)
        own.value = nil
        await pair.shutdown()
    }

    private actor NeverFinishing: ActionServerHandler {
        typealias Action = FibonacciAction

        func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }

        func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .accept }

        func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
            try await Task.sleep(for: .seconds(60))
            return FibonacciAction.Result(sequence: [])
        }
    }

    /// Scenario 3: the server is destroyed while `get_result` requests wait.
    /// The close resumes every waiting request, and each resumed task replies
    /// on another thread while the close frees the same queries.
    ///
    /// The client context shuts down before the server closes, so the error
    /// replies have no receiver. That order dates from zenoh-pico 1.7, whose
    /// decoder could crash on an error reply that was not the first message
    /// of its frame (1.10 clears the message before it decodes one), and here
    /// the client runs in this process. The race on the server side does not
    /// need the client.
    func testActionServerClosedWhileGetResultRequestsWait() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        let serverCtx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
        let serverNode = try await serverCtx.createNode(name: "server", namespace: "/reply_after_close/action")

        for round in 0..<5 {
            let server = try await serverNode.createActionServer(
                FibonacciAction.self, name: "fibonacci", handler: NeverFinishing())
            let clientCtx = try await ROS2Context(transport: .zenoh(locator: router, domainId: 0), distro: .jazzy)
            let clientNode = try await clientCtx.createNode(name: "client", namespace: "/reply_after_close/action")
            let client = try await clientNode.createActionClient(FibonacciAction.self, name: "fibonacci")
            try await client.waitForActionServer(timeout: .seconds(10))

            // Several waiting requests per close widen the window of the race.
            var waiters: [Task<Void, Never>] = []
            for _ in 0..<4 {
                let handle = try await client.sendGoal(FibonacciAction.Goal(order: 3))
                waiters.append(Task { _ = try? await handle.result(timeout: .seconds(3)) })
            }
            // Let the get_result requests reach the server, then take the client away.
            try await Task.sleep(for: .milliseconds(300))
            await clientCtx.shutdown()

            server.cancel()

            for waiter in waiters { await waiter.value }
            // Give the resumed reply tasks time to run into the closed queries.
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(server.isActive, "round \(round)")
        }
        await serverCtx.shutdown()
    }
}
