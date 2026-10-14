import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

/// Round-trip integration test for Service Server / Client over Zenoh.
/// Requires:
/// - `LINUX_IP` env var set to the host running `rmw_zenohd` (skipped if absent).
/// - On the host: `ros2 run rmw_zenoh_cpp rmw_zenohd` listening on
///   `tcp/<LINUX_IP>:7447`.
/// - On the host: `ros2 service call /test/trigger example_interfaces/srv/Trigger {}`
///   running with `RMW_IMPLEMENTATION=rmw_zenoh_cpp` (the swift-ros2 client
///   side acts as the service server in this scenario).
///
/// Skips gracefully when `LINUX_IP` is not set so CI stays deterministic.
final class ZenohServiceRoundTripTests: XCTestCase {
    /// Calls a remote service hosted on the Linux host. The remote service
    /// is expected to be a stock `example_interfaces/srv/Trigger` server (e.g. the
    /// `srv-server` example running on the host, or any rmw_zenoh_cpp
    /// node serving `/test/trigger`).
    func testTriggerCallOverZenoh() async throws {
        guard let linuxIP = ProcessInfo.processInfo.environment["LINUX_IP"], !linuxIP.isEmpty else {
            throw XCTSkip("Set LINUX_IP to run this test (e.g., LINUX_IP=192.168.1.85)")
        }

        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/\(linuxIP):7447", domainId: 0, wireMode: .jazzy),
            distro: .jazzy
        )
        let node = try await ctx.createNode(name: "swift_ros2_it_zenoh_srv", namespace: "/test")
        let cli = try await node.createClient(TriggerSrv.self, name: "trigger")

        // Zenoh discovery is effectively instant via the admin space; a
        // small explicit wait still matches what rmw_zenoh_cpp does.
        try await Task.sleep(nanoseconds: 500_000_000)

        let response = try await cli.call(.init(), timeout: .seconds(5))
        // A live ROS 2 Trigger server typically replies success=true; the
        // message field is implementation-dependent. Accept any non-empty
        // reply as "round-trip succeeded".
        XCTAssertTrue(response.success || !response.message.isEmpty)

        await ctx.shutdown()
    }

    /// Hosts a Trigger service from this Swift process and waits for a
    /// remote `ros2 service call` to invoke it. This exercises the
    /// queryable / server side of the Zenoh service implementation that
    /// the round-trip-from-here test (above) cannot reach.
    func testTriggerHostOverZenoh() async throws {
        guard let linuxIP = ProcessInfo.processInfo.environment["LINUX_IP"], !linuxIP.isEmpty else {
            throw XCTSkip("Set LINUX_IP to run this test (e.g., LINUX_IP=192.168.1.85)")
        }

        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/\(linuxIP):7447", domainId: 0, wireMode: .jazzy),
            distro: .jazzy
        )
        let node = try await ctx.createNode(name: "swift_ros2_it_zenoh_host", namespace: "/test")

        let invoked = expectation(description: "remote ros2 service call invoked the Swift handler")
        invoked.assertForOverFulfill = false
        _ = try await node.createService(TriggerSrv.self, name: "swift_zenoh_trigger") { _ in
            invoked.fulfill()
            return TriggerSrv.Response(success: true, message: "hi from swift over zenoh")
        }

        // Run an external `ros2 service call /test/swift_zenoh_trigger
        // example_interfaces/srv/Trigger` against `rmw_zenoh_cpp` while this test is
        // waiting. CI gates this entire test on LINUX_IP, so the runner
        // never blocks on the wait when the env var is unset.
        await fulfillment(of: [invoked], timeout: 60)

        await ctx.shutdown()
    }
}
