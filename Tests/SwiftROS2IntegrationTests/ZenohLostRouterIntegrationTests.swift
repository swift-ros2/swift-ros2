import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

#if canImport(SwiftROS2Zenoh)
    import SwiftROS2Zenoh
#endif

/// Wire Zenoh behavior when the router goes away under an open session.
///
/// zenoh-pico does not close a client session whose router is gone: the session
/// stays open and, without this check, keeps reporting the matching state it saw
/// last. A publisher without subscribers would report "no subscriber" forever, so
/// a caller that skips publishing without subscribers would never notice the
/// loss. These tests kill (or pause) a real router and check that matching turns
/// unknown (`hasMatchedSubscriptions` reports `true`) and the session reports
/// unhealthy.
///
/// Requires `ZENOH_ROUTER` (for example `tcp/127.0.0.1:7447`) and
/// `ZENOH_TEST_ROUTER_CONTAINER`, the name of the Docker container that runs that
/// router (`rmw_zenohd` or `zenohd`). The tests run `docker kill` / `docker pause`
/// on it and start / unpause it again afterwards. Skips otherwise; the Linux CI job
/// sets both, with a `zenohd` container. For example:
///
/// ```
/// docker run -d --name sr2-router -p 7447:7447 docker-ros-jazzy:latest \
///   bash -c "source /opt/ros/jazzy/setup.bash && exec ros2 run rmw_zenoh_cpp rmw_zenohd"
/// ZENOH_ROUTER=tcp/127.0.0.1:7447 ZENOH_TEST_ROUTER_CONTAINER=sr2-router \
///   swift test --filter ZenohLostRouterIntegrationTests
/// ```
final class ZenohLostRouterIntegrationTests: XCTestCase {
    /// A killed router closes the connection, but zenoh-pico does not treat the
    /// end of the stream as a failure: it notices the loss when the router's
    /// lease expires without traffic (one to two leases; rmw_zenohd advertises
    /// 60 s).
    func testKilledRouterReportsUnknownMatchingAndAnUnhealthySession() async throws {
        try await runLostRouterScenario(lose: "kill", restore: "start")
    }

    /// A paused router keeps the TCP connection open but stops answering, so
    /// again only the lease expiry reveals the loss.
    func testPausedRouterReportsUnknownMatchingAndAnUnhealthySession() async throws {
        try await runLostRouterScenario(lose: "pause", restore: "unpause")
    }

    // MARK: - Scenario

    private func runLostRouterScenario(lose: String, restore: String) async throws {
        // `Process` (to drive docker) exists only on macOS and Linux, not on
        // iOS or Mac Catalyst.
        #if canImport(SwiftROS2Zenoh) && (os(macOS) || os(Linux))
            let env = ProcessInfo.processInfo.environment
            guard let router = env["ZENOH_ROUTER"], !router.isEmpty,
                let container = env["ZENOH_TEST_ROUTER_CONTAINER"], !container.isEmpty
            else {
                throw XCTSkip(
                    "Set ZENOH_ROUTER and ZENOH_TEST_ROUTER_CONTAINER to run this test "
                        + "(it kills and restarts that Docker container)")
            }
            // Detection takes one to two router leases; allow a little more.
            let timeout = env["ZENOH_TEST_LOSS_TIMEOUT"].flatMap(TimeInterval.init) ?? 150

            let config = TransportConfig.zenoh(locator: router, domainId: 0, wireMode: .jazzy)
            let session = ZenohTransportSession(client: ZenohClient())
            let ctx = try await ROS2Context(transport: config, distro: .jazzy, session: session)
            let node = try await ctx.createNode(
                name: "lost_router", namespace: "/lost_router",
                options: ROS2NodeOptions(startParameterServices: false))

            // Public API: a plain and a TRANSIENT_LOCAL (advanced) publisher.
            let plain = try await node.createPublisher(StringMsg.self, topic: "plain")
            let latched = try await node.createPublisher(StringMsg.self, topic: "latched", qos: .latched)
            // Transport level, to read the internal tri-state directly.
            let rawPlain = try session.createPublisher(
                topic: "/lost_router/raw_plain", typeName: StringMsg.typeInfo.typeName,
                typeHash: StringMsg.typeInfo.typeHash, qos: .default)
            let rawLatched = try session.createPublisher(
                topic: "/lost_router/raw_latched", typeName: StringMsg.typeInfo.typeName,
                typeHash: StringMsg.typeInfo.typeHash,
                qos: TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1)))

            let reported = ReportedValues()
            plain.onMatchedSubscriptionsChanged { reported.append($0) }

            // Healthy session, no subscriber: a confident `false` and a healthy session.
            try await waitUntil(timeout: 5) {
                !plain.hasMatchedSubscriptions && !latched.hasMatchedSubscriptions
                    && rawPlain.matchedSubscriptions == false && rawLatched.matchedSubscriptions == false
            }
            XCTAssertTrue(session.checkHealth())
            XCTAssertTrue(ctx.isConnected)
            XCTAssertEqual(reported.items, [false])

            // Bring the router back even if an assertion below fails (a second
            // start / unpause is harmless).
            addTeardownBlock { Self.docker(restore, container) }

            XCTAssertEqual(Self.docker(lose, container), 0, "docker \(lose) \(container) failed")
            let lostAt = Date()

            // Until the lease expires the session still looks connected.
            let matchingUnknownAfter = try await waitUntil(timeout: timeout) {
                rawPlain.matchedSubscriptions == nil && rawLatched.matchedSubscriptions == nil
            }
            try await waitUntil(timeout: 1) { !session.checkHealth() }
            let unhealthyAfter = Date().timeIntervalSince(lostAt)
            print(
                "[ZenohLostRouter] docker \(lose): matching unknown after "
                    + String(format: "%.1f", matchingUnknownAfter) + " s, unhealthy after "
                    + String(format: "%.1f", unhealthyAfter) + " s")

            // Fail-open public view, and the monitor reports the change.
            XCTAssertTrue(plain.hasMatchedSubscriptions)
            XCTAssertTrue(latched.hasMatchedSubscriptions)
            XCTAssertFalse(ctx.isConnected)
            try await waitUntil(timeout: 2) { reported.items.last == true }
            XCTAssertEqual(reported.items, [false, true])

            // A caller that only publishes with subscribers publishes again: the
            // put fails with a recoverable error, which is what starts its
            // reconnect. The TRANSIENT_LOCAL publisher must fail too, rather
            // than cache the sample behind its frozen write filter.
            for publisher in [plain, latched] {
                XCTAssertThrowsError(try publisher.publish(StringMsg(data: "after loss"))) { error in
                    XCTAssertEqual((error as? TransportError)?.isRecoverable, true, "\(error)")
                }
            }
            // Creating entities on the lost session fails instead of crashing.
            XCTAssertThrowsError(
                try session.createPublisher(
                    topic: "/lost_router/late", typeName: StringMsg.typeInfo.typeName,
                    typeHash: StringMsg.typeInfo.typeHash, qos: .default))

            XCTAssertEqual(Self.docker(restore, container), 0, "docker \(restore) \(container) failed")

            // Reconnect: tear the lost session down (this must not crash) and
            // open a new one on the restored router.
            await ctx.shutdown()
            try await waitForRouter(router, timeout: 30)
            let freshCtx = try await ROS2Context(transport: config, distro: .jazzy)
            let freshNode = try await freshCtx.createNode(
                name: "lost_router_again", namespace: "/lost_router",
                options: ROS2NodeOptions(startParameterServices: false))
            let freshPub = try await freshNode.createPublisher(StringMsg.self, topic: "plain")
            XCTAssertTrue(freshCtx.isConnected)
            XCTAssertNoThrow(try freshPub.publish(StringMsg(data: "reconnected")))
            await freshCtx.shutdown()
        #else
            throw XCTSkip("Needs wire Zenoh (zenoh-pico) and a host that can run docker (macOS or Linux)")
        #endif
    }

    // MARK: - Helpers

    #if canImport(SwiftROS2Zenoh) && (os(macOS) || os(Linux))
        /// Runs `docker <verb> <container>` and returns its exit status.
        @discardableResult
        private static func docker(_ verb: String, _ container: String) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["docker", verb, container]
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return -1
            }
            process.waitUntilExit()
            return process.terminationStatus
        }

        /// Waits until a fresh session can open on `router`.
        private func waitForRouter(_ router: String, timeout: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let client = ZenohClient()
                if (try? client.open(locator: router)) != nil {
                    try? client.close()
                    return
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            XCTFail("router \(router) did not come back within \(timeout) s")
        }
    #endif

    /// Polls `condition` every 50 ms and returns how long it took to hold.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws -> TimeInterval {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout) s", line: line)
                return Date().timeIntervalSince(start)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return Date().timeIntervalSince(start)
    }
}

/// Thread-safe collector for the values a matched-subscriptions handler receives.
private final class ReportedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var items: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
