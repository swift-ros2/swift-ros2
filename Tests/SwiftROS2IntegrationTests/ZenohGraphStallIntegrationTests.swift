import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2TestSupport
import SwiftROS2Transport
import XCTest

#if canImport(SwiftROS2Zenoh)
    import SwiftROS2Zenoh
#endif

/// The wire Zenoh topic graph against a router that stops answering.
///
/// zenoh-pico (at the pinned `vendor/zenoh-pico`) ignores a liveliness query's timeout:
/// the query finishes only when the router sends its final or the session is torn
/// down. The first test pins that against a paused router; if a zenoh-pico bump starts
/// honouring the timeout, it fails and the graph's stalled-query budget is revisited.
/// The second drives `topicGraph()` through that budget: a deadline, a call that fails
/// at once while the timed-out query is pending, new queries once the old ones are
/// abandoned, and the graph-stalled mark that turns `isConnected` false while
/// publishing keeps working.
///
/// Requires `ZENOH_ROUTER` and `ZENOH_TEST_ROUTER_CONTAINER`, the Docker container that
/// runs that router; the tests `docker pause` it for a few seconds (less than a lease,
/// so the session is not declared lost) and unpause it. Skips otherwise. For example:
///
/// ```
/// docker run -d --name sr2-router -p 127.0.0.1:7448:7447 eclipse/zenoh:1.10.1
/// ZENOH_ROUTER=tcp/127.0.0.1:7448 ZENOH_TEST_ROUTER_CONTAINER=sr2-router \
///   swift test --filter ZenohGraphStallIntegrationTests
/// ```
final class ZenohGraphStallIntegrationTests: XCTestCase {
    func testPausedRouterNeverFinishesALivelinessQueryUntilItResumes() async throws {
        #if canImport(SwiftROS2Zenoh) && (os(macOS) || os(Linux))
            let (router, container) = try Self.environment()
            let client = ZenohClient()
            try client.open(locator: router)
            defer { try? client.close() }

            // Healthy router: the query finishes.
            let healthy = QueryProbe()
            try client.livelinessGet(
                keyExpr: "@ros2_lv/74/**", timeoutMs: 500, handler: { _ in }, onFinish: { healthy.finish() })
            await waitUntil("a liveliness query on a healthy router finishes", timeout: 5) { healthy.finished }

            addTeardownBlock { Self.docker("unpause", container) }
            XCTAssertEqual(Self.docker("pause", container), 0)
            let paused = QueryProbe()
            try client.livelinessGet(
                keyExpr: "@ros2_lv/74/**", timeoutMs: 500, handler: { _ in }, onFinish: { paused.finish() })
            try await Task.sleep(for: .seconds(3))
            XCTAssertFalse(paused.finished, "zenoh-pico finished a liveliness query without the router's final")

            XCTAssertEqual(Self.docker("unpause", container), 0)
            await waitUntil("the final arrives once the router resumes", timeout: 10) { paused.finished }
        #else
            throw XCTSkip("Needs wire Zenoh (zenoh-pico) and a host that can run docker (macOS or Linux)")
        #endif
    }

    func testStalledRouterDrivesTheGraphThroughItsBudget() async throws {
        #if canImport(SwiftROS2Zenoh) && (os(macOS) || os(Linux))
            let (router, container) = try Self.environment()
            let transport = TransportConfig.zenoh(locator: router, domainId: 74)
            let session = ZenohTransportSession(client: ZenohClient())
            session.graphLimits = ZenohGraphLimits(
                deadline: .milliseconds(300), abandonAfter: .milliseconds(800), stallCap: 3)
            let ctx = try await ROS2Context(transport: transport, distro: .jazzy, session: session)
            let node = try await ctx.createNode(
                name: "stall_node", namespace: "/graph_stall", options: ROS2NodeOptions(startParameterServices: false))
            let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")
            let healthy = try await ctx.topicGraph()
            XCTAssertEqual(healthy.map(\.name), ["/graph_stall/chatter"])

            addTeardownBlock { Self.docker("unpause", container) }
            XCTAssertEqual(Self.docker("pause", container), 0)

            // Three queries time out; the call between the first two fails at once.
            for round in 1...3 {
                let waited = await Self.sessionUnhealthy { _ = try await ctx.topicGraph() }
                XCTAssertGreaterThanOrEqual(waited, .milliseconds(300), "round \(round)")
                XCTAssertLessThan(waited, .seconds(2), "round \(round)")
                if round == 1 {
                    let atOnce = await Self.sessionUnhealthy { _ = try await ctx.topicGraph() }
                    XCTAssertLessThan(atOnce, .milliseconds(200))
                }
                XCTAssertTrue(ctx.isConnected, "round \(round)")
                try await Task.sleep(for: .milliseconds(900))
            }

            // Abandoning the third reaches the cap: graph-stalled.
            let atOnce = await Self.sessionUnhealthy { _ = try await ctx.topicGraph() }
            XCTAssertLessThan(atOnce, .milliseconds(200))
            XCTAssertFalse(ctx.isConnected)
            XCTAssertTrue(session.checkHealth(), "the router must not have been declared lost")
            // Publishing still works on a graph-stalled session.
            XCTAssertNoThrow(try pub.publish(StringMsg(data: "still publishing")))

            XCTAssertEqual(Self.docker("unpause", container), 0)
            // The mark is sticky: a late final does not clear it.
            try await Task.sleep(for: .seconds(1))
            XCTAssertFalse(ctx.isConnected)

            // Rebuilding the context recovers.
            await ctx.shutdown()
            let fresh = try await ROS2Context(transport: transport, distro: .jazzy)
            let freshNode = try await fresh.createNode(
                name: "stall_node", namespace: "/graph_stall", options: ROS2NodeOptions(startParameterServices: false))
            _ = try await freshNode.createPublisher(StringMsg.self, topic: "chatter")
            XCTAssertTrue(fresh.isConnected)
            let graph = try await fresh.topicGraph()
            XCTAssertEqual(graph.map(\.name), ["/graph_stall/chatter"])
            await fresh.shutdown()
        #else
            throw XCTSkip("Needs wire Zenoh (zenoh-pico) and a host that can run docker (macOS or Linux)")
        #endif
    }

    // MARK: - Helpers

    #if canImport(SwiftROS2Zenoh) && (os(macOS) || os(Linux))
        private static func environment() throws -> (router: String, container: String) {
            let env = ProcessInfo.processInfo.environment
            guard let router = env["ZENOH_ROUTER"], !router.isEmpty,
                let container = env["ZENOH_TEST_ROUTER_CONTAINER"], !container.isEmpty
            else {
                throw XCTSkip(
                    "Set ZENOH_ROUTER and ZENOH_TEST_ROUTER_CONTAINER to run this test "
                        + "(it pauses and unpauses that Docker container)")
            }
            return (router, container)
        }

        /// Runs `body`, which must throw `.sessionUnhealthy`, and returns how long it took.
        private static func sessionUnhealthy(
            file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
        ) async -> Duration {
            let start = ContinuousClock.now
            do {
                try await body()
                XCTFail("expected sessionUnhealthy", file: file, line: line)
            } catch TransportError.sessionUnhealthy {
            } catch {
                XCTFail("expected sessionUnhealthy, got \(error)", file: file, line: line)
            }
            return ContinuousClock.now - start
        }

        /// Runs `docker <verb> <container>` and returns its exit status.
        @discardableResult
        private static func docker(_ verb: String, _ container: String) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["docker", verb, container]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return -1
            }
            process.waitUntilExit()
            return process.terminationStatus
        }
    #endif
}

/// Whether a liveliness query's `onFinish` has fired.
private final class QueryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func finish() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}
