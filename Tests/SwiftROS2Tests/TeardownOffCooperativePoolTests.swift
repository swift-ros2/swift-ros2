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
/// test would also block the test that is meant to detect it. Each of them
/// opens its gate on exit, so a failed setup never leaves threads blocked.
final class TeardownOffCooperativePoolTests: XCTestCase {
    /// More concurrent teardowns than the cooperative pool has threads.
    private var saturatingCount: Int { ProcessInfo.processInfo.activeProcessorCount + 2 }

    private let config = TransportConfig.zenoh(locator: "tcp/mock:7447")
    private let noParameterServices = ROS2NodeOptions(startParameterServices: false)

    // MARK: - The cooperative pool stays free

    func testShutdownsBlockedInCloseLeaveTheCooperativePoolFree() throws {
        let count = saturatingCount
        let gate = TeardownGate()
        defer { gate.open() }
        let contexts = try (0..<count).map { _ in
            try makeContextWithPublisher(gate: gate, gated: [.publisher])
        }

        let finished = CompletionCounter()
        for (ctx, _) in contexts {
            Task.detached {
                await ctx.shutdown()
                finished.increment()
            }
        }
        XCTAssertTrue(
            gate.waitForArrivals(count, timeout: 5),
            "only \(gate.arrivals) of \(count) shutdowns reached the blocked close")
        assertCooperativePoolRuns()

        gate.open()
        assertFinished(finished, count, "not every shutdown returned once its close was released")
        for (_, session) in contexts {
            XCTAssertEqual(session.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
        }
    }

    /// Closing a publisher waits for a matched-subscriptions handler call that
    /// is running; that wait must not hold a cooperative-pool thread either.
    func testDestroysWaitingForAMatchedSubscriptionsHandlerLeaveTheCooperativePoolFree() throws {
        let count = saturatingCount
        let gate = TeardownGate()
        defer { gate.open() }
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

        let finished = CompletionCounter()
        for (node, _) in setups {
            Task.detached {
                await node.destroy()
                finished.increment()
            }
        }
        // Give the destroys time to reach the wait for the running handler.
        Thread.sleep(forTimeInterval: 0.3)
        assertCooperativePoolRuns()
        XCTAssertEqual(finished.count, 0, "destroy() must wait for the handler call that is running")

        gate.open()
        assertFinished(finished, count, "not every destroy returned once the handler returned")
        for (_, session) in setups {
            XCTAssertEqual(session.log.events, ["publisher.close /t/a", "unregister n"])
        }
    }

    func testParameterClientClosesBlockedInCloseLeaveTheCooperativePoolFree() throws {
        let count = saturatingCount
        let gate = TeardownGate()
        defer { gate.open() }
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

        let finished = CompletionCounter()
        for (client, _) in setups {
            Task.detached {
                await client.close()
                finished.increment()
            }
        }
        XCTAssertTrue(
            gate.waitForArrivals(count, timeout: 5),
            "only \(gate.arrivals) of \(count) parameter-client closes reached the blocked close")
        assertCooperativePoolRuns()

        gate.open()
        assertFinished(finished, count, "not every parameter-client close returned once released")
        for (_, session) in setups {
            XCTAssertEqual(session.log.events, Self.parameterClientCloses)
        }
    }

    // MARK: - Completion and ordering

    func testShutdownReturnsOnlyAfterABlockedCloseHasFinished() throws {
        let gate = TeardownGate()
        defer { gate.open() }
        let (ctx, session) = try makeContextWithPublisher(gate: gate, gated: [.publisher])

        let finished = CompletionCounter()
        Task.detached {
            await ctx.shutdown()
            finished.increment()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "shutdown never reached the close")
        assertStillRunning(finished, "shutdown() returned while a close was still running")
        XCTAssertEqual(session.log.events, [])

        gate.open()
        assertFinished(finished, 1, "shutdown did not return once its close was released")
        XCTAssertEqual(session.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
    }

    func testShutdownClosesEveryEntityThenUnregistersEachNodeThenClosesTheSession() async throws {
        let session = GatedTeardownSession()
        let ctx = try await ROS2Context(transport: config, session: session)
        for name in ["first", "second"] {
            let node = try await ctx.createNode(name: name, namespace: "/t", options: noParameterServices)
            // Created in reverse of the close order, which must not depend on it.
            _ = try await node.createActionClient(FibonacciAction.self, name: "\(name)_act_cli")
            _ = try await node.createActionServer(
                FibonacciAction.self, name: "\(name)_act", handler: _AcceptingHandler())
            _ = try await node.createClient(TriggerSrv.self, name: "\(name)_cli")
            _ = try await node.createService(TriggerSrv.self, name: "\(name)_srv") { _ in
                TriggerSrv.Response(success: true, message: "")
            }
            _ = try await node.createSubscription(StringMsg.self, topic: "\(name)_sub")
            _ = try await node.createPublisher(StringMsg.self, topic: "\(name)_pub")
        }

        await ctx.shutdown()

        XCTAssertEqual(
            session.log.events,
            [
                "publisher.close /t/first_pub", "subscriber.close /t/first_sub",
                "service.close /t/first_srv", "client.close /t/first_cli",
                "actionServer.close /t/first_act", "actionClient.close /t/first_act_cli",
                "unregister first",
                "publisher.close /t/second_pub", "subscriber.close /t/second_sub",
                "service.close /t/second_srv", "client.close /t/second_cli",
                "actionServer.close /t/second_act", "actionClient.close /t/second_act_cli",
                "unregister second",
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

    /// A node's `destroy()` runs after a teardown of the same context that
    /// started earlier, even when that one is stuck in a close.
    func testDestroyWaitsBehindAStuckTeardownOfTheSameContext() throws {
        let gate = TeardownGate()
        defer { gate.open() }
        let session = GatedTeardownSession(gate: gate, gated: [.service])
        let (stuckNode, otherNode) = try blockingWait {
            [config = self.config, noParameterServices = self.noParameterServices] in
            let ctx = try await ROS2Context(transport: config, session: session)
            let stuck = try await ctx.createNode(name: "stuck", namespace: "/t", options: noParameterServices)
            _ = try await stuck.createService(TriggerSrv.self, name: "srv") { _ in
                TriggerSrv.Response(success: true, message: "")
            }
            let other = try await ctx.createNode(name: "other", namespace: "/t", options: noParameterServices)
            _ = try await other.createPublisher(StringMsg.self, topic: "pub")
            return (stuck, other)
        }

        let stuckFinished = CompletionCounter()
        Task.detached {
            await stuckNode.destroy()
            stuckFinished.increment()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "the first destroy never reached the close")
        let otherFinished = CompletionCounter()
        Task.detached {
            await otherNode.destroy()
            otherFinished.increment()
        }
        assertStillRunning(otherFinished, "a destroy did not wait for an earlier, stuck teardown of the same context")
        XCTAssertEqual(session.log.events, [])

        gate.open()
        assertFinished(stuckFinished, 1, "the stuck destroy did not return once released")
        assertFinished(otherFinished, 1, "the queued destroy did not return")
        XCTAssertEqual(
            session.log.events,
            ["service.close /t/srv", "unregister stuck", "publisher.close /t/pub", "unregister other"])
    }

    /// A shutdown takes the context's nodes when it runs, not when it is
    /// called, so a node created while the shutdown waits behind a stuck
    /// teardown is closed by it too.
    func testANodeCreatedWhileAShutdownIsQueuedIsClosedByIt() throws {
        let gate = TeardownGate()
        defer { gate.open() }
        let session = GatedTeardownSession(gate: gate, gated: [.client])
        let (ctx, parameterClient) = try blockingWait {
            [config = self.config, noParameterServices = self.noParameterServices] in
            let ctx = try await ROS2Context(transport: config, session: session)
            let node = try await ctx.createNode(name: "first", namespace: "/t", options: noParameterServices)
            return (ctx, try await node.createParameterClient(remoteNode: "/remote"))
        }

        // The parameter-client close blocks in its first client close and holds the queue.
        let closeFinished = CompletionCounter()
        Task.detached {
            await parameterClient.close()
            closeFinished.increment()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "the parameter-client close never reached the close")
        let shutdownFinished = CompletionCounter()
        Task.detached {
            await ctx.shutdown()
            shutdownFinished.increment()
        }
        // Let the shutdown queue up behind the blocked close, then create a node.
        Thread.sleep(forTimeInterval: 0.3)
        try blockingWait { [noParameterServices = self.noParameterServices] in
            let late = try await ctx.createNode(name: "late", namespace: "/t", options: noParameterServices)
            _ = try await late.createPublisher(StringMsg.self, topic: "late_pub")
        }
        XCTAssertEqual(shutdownFinished.count, 0, "shutdown() returned while a close was still running")

        gate.open()
        assertFinished(closeFinished, 1, "the parameter-client close did not return once released")
        assertFinished(shutdownFinished, 1, "the queued shutdown did not return")
        XCTAssertEqual(
            session.log.events,
            Self.parameterClientCloses + [
                "unregister first", "publisher.close /t/late_pub", "unregister late", "session.close",
            ])
    }

    /// Two shutdowns of one context both return only after the first one's
    /// closes have finished, and the session is closed after them.
    func testConcurrentShutdownsOfOneContextKeepTheOrder() throws {
        let gate = TeardownGate()
        defer { gate.open() }
        let (ctx, session) = try makeContextWithPublisher(gate: gate, gated: [.publisher])

        let first = CompletionCounter()
        Task.detached {
            await ctx.shutdown()
            first.increment()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "the first shutdown never reached the close")
        let second = CompletionCounter()
        Task.detached {
            await ctx.shutdown()
            second.increment()
        }
        assertStillRunning(second, "the second shutdown returned while the first one's close was still running")

        gate.open()
        assertFinished(first, 1, "the first shutdown did not return")
        assertFinished(second, 1, "the second shutdown did not return")
        XCTAssertEqual(
            session.log.events, ["publisher.close /t/a", "unregister n", "session.close", "session.close"])
    }

    func testAContextBlockedInCloseDoesNotDelayAnotherContextsShutdown() throws {
        let gate = TeardownGate()
        defer { gate.open() }
        let (stuck, stuckSession) = try makeContextWithPublisher(gate: gate, gated: [.publisher])
        let (other, otherSession) = try makeContextWithPublisher(gate: nil, gated: [])

        let stuckFinished = CompletionCounter()
        Task.detached {
            await stuck.shutdown()
            stuckFinished.increment()
        }
        XCTAssertTrue(gate.waitForArrivals(1, timeout: 5), "the stuck shutdown never reached the close")

        let otherFinished = CompletionCounter()
        Task.detached {
            await other.shutdown()
            otherFinished.increment()
        }
        XCTAssertTrue(
            otherFinished.waitFor(1, timeout: 1),
            "a context's shutdown waited for another context's blocked close")
        XCTAssertEqual(otherSession.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
        XCTAssertEqual(stuckSession.log.events, [])

        gate.open()
        assertFinished(stuckFinished, 1, "the stuck shutdown did not return once released")
        XCTAssertEqual(stuckSession.log.events, ["publisher.close /t/a", "unregister n", "session.close"])
    }

    func testEachContextHasItsOwnTeardownQueue() async throws {
        let first = try await ROS2Context(transport: config, session: GatedTeardownSession())
        let second = try await ROS2Context(transport: config, session: GatedTeardownSession())
        XCTAssertFalse(first.teardownQueue === second.teardownQueue)
        XCTAssertNotEqual(
            first.teardownQueue.label, second.teardownQueue.label,
            "each context's queue needs its own label to be told apart in a hang report")
    }

    /// The check behind `assertOnQueue()` (a debug-only assertion) sees its
    /// own queue and only its own queue.
    func testTeardownQueueKnowsWhetherItRunsTheCaller() async {
        let queue = TeardownQueue(prefix: "test")
        let other = TeardownQueue(prefix: "test")
        XCTAssertFalse(queue.isCurrent)

        let seen = FlagsBox()
        await queue.run {
            seen.set(own: queue.isCurrent, other: other.isCurrent)
            queue.assertOnQueue()
        }
        XCTAssertEqual(seen.own, true, "a block of the queue must see the queue as current")
        XCTAssertEqual(seen.other, false, "a block of one queue must not see another queue as current")
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

    /// Asserts that `target` calls finish within 10 s.
    private func assertFinished(
        _ counter: CompletionCounter, _ target: Int, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            counter.waitFor(target, timeout: 10), "\(message) (\(counter.count) of \(target) returned)",
            file: file, line: line)
    }

    /// Asserts that the one call `counter` tracks is still running 0.3 s later.
    private func assertStillRunning(
        _ counter: CompletionCounter, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(counter.waitFor(1, timeout: 0.3), message, file: file, line: line)
    }

    /// Runs `body` on the cooperative pool and blocks the calling (test) thread until it returns.
    @discardableResult
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

private final class FlagsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _own: Bool?
    private var _other: Bool?

    var own: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _own
    }

    var other: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _other
    }

    func set(own: Bool, other: Bool) {
        lock.lock()
        _own = own
        _other = other
        lock.unlock()
    }
}
