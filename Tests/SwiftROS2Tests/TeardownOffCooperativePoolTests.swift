import Dispatch
import Foundation
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

/// `ROS2Context.shutdown()`, `ROS2Node.destroy()` and `ROS2ParameterClient.close()`
/// run their blocking transport calls off Swift's cooperative thread pool, and
/// keep their ordering and completion guarantees.
///
/// The tests that block a close are synchronous on purpose: the test thread
/// must not be a cooperative-pool thread, or a pool blocked by the code under
/// test would also block the test that is meant to detect it.
final class TeardownOffCooperativePoolTests: XCTestCase {
    /// More concurrent teardowns than the cooperative pool has threads.
    private var saturatingCount: Int { ProcessInfo.processInfo.activeProcessorCount + 2 }

    private let config = TransportConfig.zenoh(locator: "tcp/mock:7447")
    private let noParameterServices = ROS2NodeOptions(startParameterServices: false)

    // MARK: - The cooperative pool stays free

    func testShutdownsBlockedInCloseLeaveTheCooperativePoolFree() throws {
        let count = saturatingCount
        let gate = TeardownGate()
        let contexts = try (0..<count).map { _ in
            try makeContextWithPublisher(gate: gate, gated: [.publisher])
        }

        let finished = DispatchSemaphore(value: 0)
        for (ctx, _) in contexts {
            Task.detached {
                await ctx.shutdown()
                finished.signal()
            }
        }
        XCTAssertTrue(
            gate.waitForArrivals(count, timeout: 5),
            "only \(gate.arrivals) of \(count) shutdowns reached the blocked close")
        assertCooperativePoolRuns()

        gate.open()
        assertSignaled(finished, times: count, "a shutdown did not return once its close was released")
        for (_, session) in contexts {
            XCTAssertEqual(session.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
        }
    }

    /// Closing a publisher waits for a matched-subscriptions handler call that
    /// is running; that wait must not hold a cooperative-pool thread either.
    func testDestroysWaitingForAMatchedSubscriptionsHandlerLeaveTheCooperativePoolFree() throws {
        let count = saturatingCount
        let gate = TeardownGate()
        var setups: [(ROS2Node, GatedTeardownSession)] = []
        for _ in 0..<count {
            let session = GatedTeardownSession()
            let (node, publisher) = try blockingWait {
                [config = self.config, noParameterServices = self.noParameterServices] in
                let ctx = try await ROS2Context(transport: config, session: session)
                let node = try await ctx.createNode(name: "n", namespace: "/t", options: noParameterServices)
                return (node, try await node.createPublisher(StringMsg.self, topic: "a"))
            }
            // The first call reports `true`; the change to `false` blocks in the handler.
            publisher.onMatchedSubscriptionsChanged { matched in
                if !matched { gate.pass() }
            }
            try XCTUnwrap(session.entities.first).matched = false
            setups.append((node, session))
        }
        XCTAssertTrue(
            gate.waitForArrivals(count, timeout: 5),
            "only \(gate.arrivals) of \(count) handlers are running")

        let finished = DispatchSemaphore(value: 0)
        for (node, _) in setups {
            Task.detached {
                await node.destroy()
                finished.signal()
            }
        }
        // Give the destroys time to reach the wait for the running handler.
        Thread.sleep(forTimeInterval: 0.3)
        assertCooperativePoolRuns()
        XCTAssertEqual(
            finished.wait(timeout: .now() + 0.1), .timedOut,
            "destroy() must wait for the handler call that is running")

        gate.open()
        assertSignaled(finished, times: count, "a destroy did not return once the handler returned")
        for (_, session) in setups {
            XCTAssertEqual(session.log.events, ["publisher.close /t/a", "unregister n"])
        }
    }

    func testParameterClientClosesBlockedInCloseLeaveTheCooperativePoolFree() throws {
        let count = saturatingCount
        let gate = TeardownGate()
        var setups: [(ROS2ParameterClient, GatedTeardownSession)] = []
        for _ in 0..<count {
            let session = GatedTeardownSession(gate: gate, gated: [.client])
            let client = try blockingWait { [config = self.config, noParameterServices = self.noParameterServices] in
                let ctx = try await ROS2Context(transport: config, session: session)
                let node = try await ctx.createNode(name: "n", namespace: "/t", options: noParameterServices)
                return try await node.createParameterClient(remoteNode: "/remote")
            }
            setups.append((client, session))
        }

        let finished = DispatchSemaphore(value: 0)
        for (client, _) in setups {
            Task.detached {
                await client.close()
                finished.signal()
            }
        }
        XCTAssertTrue(
            gate.waitForArrivals(count, timeout: 5),
            "only \(gate.arrivals) of \(count) parameter-client closes reached the blocked close")
        assertCooperativePoolRuns()

        gate.open()
        assertSignaled(finished, times: count, "a parameter-client close did not return once released")
        for (_, session) in setups {
            XCTAssertEqual(session.log.events, Self.parameterClientCloses)
        }
    }

    // MARK: - Completion and ordering

    func testShutdownReturnsOnlyAfterABlockedCloseHasFinished() throws {
        let gate = TeardownGate()
        let (ctx, session) = try makeContextWithPublisher(gate: gate, gated: [.publisher])

        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await ctx.shutdown()
            finished.signal()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "shutdown never reached the close")
        XCTAssertEqual(
            finished.wait(timeout: .now() + 0.3), .timedOut,
            "shutdown() returned while a close was still running")
        XCTAssertEqual(session.log.events, [])

        gate.open()
        assertSignaled(finished, times: 1, "shutdown did not return once its close was released")
        XCTAssertEqual(session.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
    }

    func testShutdownClosesEveryEntityThenUnregistersEachNodeThenClosesTheSession() async throws {
        let session = GatedTeardownSession()
        let ctx = try await ROS2Context(transport: config, session: session)
        for name in ["first", "second"] {
            let node = try await ctx.createNode(name: name, namespace: "/t", options: noParameterServices)
            _ = try await node.createPublisher(StringMsg.self, topic: "\(name)_pub")
            _ = try await node.createSubscription(StringMsg.self, topic: "\(name)_sub")
            _ = try await node.createService(TriggerSrv.self, name: "\(name)_srv") { _ in
                TriggerSrv.Response(success: true, message: "")
            }
            _ = try await node.createClient(TriggerSrv.self, name: "\(name)_cli")
        }

        await ctx.shutdown()

        XCTAssertEqual(
            session.log.events,
            [
                "publisher.close /t/first_pub", "subscriber.close /t/first_sub",
                "service.close /t/first_srv", "client.close /t/first_cli", "unregister first",
                "publisher.close /t/second_pub", "subscriber.close /t/second_sub",
                "service.close /t/second_srv", "client.close /t/second_cli", "unregister second",
                "session.close",
            ])
    }

    func testDestroyReturnsAfterItsEntitiesAreClosedAndTheNodeIsUnregistered() async throws {
        let session = GatedTeardownSession()
        let ctx = try await ROS2Context(transport: config, session: session)
        let node = try await ctx.createNode(name: "n", namespace: "/t", options: noParameterServices)
        _ = try await node.createSubscription(StringMsg.self, topic: "b")
        _ = try await node.createPublisher(StringMsg.self, topic: "a")

        await node.destroy()

        XCTAssertEqual(session.log.events, ["publisher.close /t/a", "subscriber.close /t/b", "unregister n"])
        XCTAssertTrue(session.isConnected, "destroying a node must not close the session")
        await ctx.shutdown()
        XCTAssertEqual(session.log.events.last, "session.close")
    }

    /// Two shutdowns of one context both return only after the first one's
    /// closes have finished, and the session is closed after them.
    func testConcurrentShutdownsOfOneContextKeepTheOrder() throws {
        let gate = TeardownGate()
        let (ctx, session) = try makeContextWithPublisher(gate: gate, gated: [.publisher])

        let first = DispatchSemaphore(value: 0)
        Task.detached {
            await ctx.shutdown()
            first.signal()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "the first shutdown never reached the close")
        let second = DispatchSemaphore(value: 0)
        Task.detached {
            await ctx.shutdown()
            second.signal()
        }
        XCTAssertEqual(
            second.wait(timeout: .now() + 0.3), .timedOut,
            "the second shutdown returned while the first one's close was still running")

        gate.open()
        assertSignaled(first, times: 1, "the first shutdown did not return")
        assertSignaled(second, times: 1, "the second shutdown did not return")
        XCTAssertEqual(
            session.log.events, ["publisher.close /t/a", "unregister n", "session.close", "session.close"])
    }

    func testAContextBlockedInCloseDoesNotDelayAnotherContextsShutdown() throws {
        let gate = TeardownGate()
        let (stuck, stuckSession) = try makeContextWithPublisher(gate: gate, gated: [.publisher])
        let (other, otherSession) = try makeContextWithPublisher(gate: nil, gated: [])

        let stuckFinished = DispatchSemaphore(value: 0)
        Task.detached {
            await stuck.shutdown()
            stuckFinished.signal()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "the stuck shutdown never reached the close")

        let otherFinished = DispatchSemaphore(value: 0)
        Task.detached {
            await other.shutdown()
            otherFinished.signal()
        }
        XCTAssertEqual(
            otherFinished.wait(timeout: .now() + 1), .success,
            "a context's shutdown waited for another context's blocked close")
        XCTAssertEqual(otherSession.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
        XCTAssertEqual(stuckSession.log.events, [])

        gate.open()
        assertSignaled(stuckFinished, times: 1, "the stuck shutdown did not return once released")
        XCTAssertEqual(stuckSession.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
    }

    /// No regression for closes that do not block: shutdown completes at once
    /// and closes everything, parameter services included.
    func testShutdownOfAContextWhoseClosesDoNotBlockClosesEverything() async throws {
        let session = MockTransportSession()
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(transport: config, session: session)
        let node = try await ctx.createNode(name: "n", namespace: "/t")
        _ = try await node.createPublisher(StringMsg.self, topic: "a")
        _ = try await node.createSubscription(StringMsg.self, topic: "b")

        let started = Date()
        await ctx.shutdown()

        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a non-blocking shutdown took too long")
        XCTAssertEqual(session.closedCount, 1)
        XCTAssertFalse(ctx.isConnected)
        XCTAssertEqual(session.unregisteredNodes.map { $0.name }, ["n"])
        XCTAssertTrue(session.publishers.allSatisfy { !$0.isActive })
        XCTAssertTrue(session.subscribers.allSatisfy { !$0.isActive })
    }

    /// A node whose parameter services fail to register is destroyed before
    /// `createNode` rethrows: the services already created are closed and the
    /// node is unregistered.
    func testCreateNodeFailureDestroysThePartialNodeBeforeThrowing() async throws {
        let session = GatedTeardownSession()
        session.failServiceCreation(after: 2)
        let ctx = try await ROS2Context(transport: config, session: session)

        do {
            _ = try await ctx.createNode(name: "n", namespace: "/t")
            XCTFail("createNode should have thrown")
        } catch {}

        XCTAssertEqual(
            session.log.events,
            ["service.close /t/n/get_parameters", "service.close /t/n/set_parameters", "unregister n"])
    }

    func testParameterClientCloseReturnsAfterEveryClientIsClosed() async throws {
        let session = GatedTeardownSession()
        let ctx = try await ROS2Context(transport: config, session: session)
        let node = try await ctx.createNode(name: "n", namespace: "/t", options: noParameterServices)
        let client = try await node.createParameterClient(remoteNode: "/remote")

        await client.close()
        XCTAssertEqual(session.log.events, Self.parameterClientCloses)

        await client.close()
        XCTAssertEqual(session.log.events, Self.parameterClientCloses, "a second close must do nothing")
    }

    // MARK: - Helpers

    private static let parameterClientCloses = [
        "client.close /remote/get_parameters",
        "client.close /remote/set_parameters",
        "client.close /remote/set_parameters_atomically",
        "client.close /remote/list_parameters",
        "client.close /remote/describe_parameters",
        "client.close /remote/get_parameter_types",
    ]

    /// A context on a `GatedTeardownSession` with node `/t/n` and publisher `/t/a`.
    private func makeContextWithPublisher(
        gate: TeardownGate?, gated: Set<GatedTeardownSession.Step>
    ) throws -> (ROS2Context, GatedTeardownSession) {
        let session = GatedTeardownSession(gate: gate, gated: gated)
        let ctx = try blockingWait { [config = self.config, noParameterServices = self.noParameterServices] in
            let ctx = try await ROS2Context(transport: config, session: session)
            let node = try await ctx.createNode(name: "n", namespace: "/t", options: noParameterServices)
            _ = try await node.createPublisher(StringMsg.self, topic: "a")
            return ctx
        }
        return (ctx, session)
    }

    /// Asserts that a new, unrelated task runs within 1 s.
    private func assertCooperativePoolRuns(file: StaticString = #filePath, line: UInt = #line) {
        let ran = DispatchSemaphore(value: 0)
        Task.detached { ran.signal() }
        XCTAssertEqual(
            ran.wait(timeout: .now() + 1), .success,
            "an unrelated task did not run within 1 s: the cooperative thread pool is blocked",
            file: file, line: line)
    }

    private func assertSignaled(
        _ semaphore: DispatchSemaphore, times: Int, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<times {
            XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success, message, file: file, line: line)
        }
    }

    /// Runs `body` on the cooperative pool and blocks the calling (test) thread until it returns.
    private func blockingWait<T>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success, let result = box.result else {
            throw BlockingWaitTimeout()
        }
        return try result.get()
    }
}

private struct BlockingWaitTimeout: Error {}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<T, Error>?

    var result: Result<T, Error>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _result
        }
        set {
            lock.lock()
            _result = newValue
            lock.unlock()
        }
    }
}
