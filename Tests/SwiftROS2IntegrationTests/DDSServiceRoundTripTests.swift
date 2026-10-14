import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

/// Round-trip integration test for Service Server / Client over CycloneDDS.
/// Requires:
/// - `LINUX_IP` env var set to the Linux host running ROS 2 (skipped if absent).
/// - The host runs `ros2 service call /test/trigger example_interfaces/srv/Trigger {}`
///   in parallel, with `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and
///   `ROS_DOMAIN_ID=99`.
///
/// Skips gracefully when `LINUX_IP` is not set so CI stays deterministic.
final class DDSServiceRoundTripTests: XCTestCase {
    #if canImport(SwiftROS2DDS)
        /// Same-process loopback round-trip — no LINUX_IP required. Verifies
        /// that a Service Server and Client wired up against the same
        /// DDSTransportSession round-trip a Trigger request without any
        /// external host.
        func testTriggerLoopbackOverDDS() async throws {
            let domain = 43
            let ctx = try await ROS2Context(
                transport: .ddsMulticast(domainId: domain),
                distro: .jazzy,
                domainId: domain
            )
            let node = try await ctx.createNode(name: "dds_srv_loopback", namespace: "/loopback")

            _ = try await node.createService(TriggerSrv.self, name: "trigger") { _ in
                TriggerSrv.Response(success: true, message: "loopback-ok")
            }
            let cli = try await node.createClient(TriggerSrv.self, name: "trigger")

            // SPDP/SEDP discovery is slower than Zenoh; give both endpoints
            // time to match before issuing the call.
            try await cli.waitForService(timeout: .seconds(5))

            let response = try await cli.call(.init(), timeout: .seconds(5))
            XCTAssertTrue(response.success)
            XCTAssertEqual(response.message, "loopback-ok")

            await ctx.shutdown()
        }
    #endif

    /// Round-trip against a remote Linux host running `rmw_cyclonedds_cpp`.
    /// Skipped unless `LINUX_IP` is set.
    func testTriggerCallToLinuxHost() async throws {
        guard let linuxIP = ProcessInfo.processInfo.environment["LINUX_IP"], !linuxIP.isEmpty else {
            throw XCTSkip("Set LINUX_IP to run this test (e.g., LINUX_IP=192.168.1.85)")
        }

        let domain = 99
        let ctx = try await ROS2Context(
            transport: .ddsUnicast(
                peers: [DDSPeer.peer(address: linuxIP, domainId: domain)],
                domainId: domain
            ),
            distro: .jazzy,
            domainId: domain
        )
        let node = try await ctx.createNode(name: "swift_ros2_it_dds_srv", namespace: "/test")
        let cli = try await node.createClient(TriggerSrv.self, name: "trigger")

        try await cli.waitForService(timeout: .seconds(10))
        let response = try await cli.call(.init(), timeout: .seconds(10))
        XCTAssertTrue(response.success || !response.message.isEmpty)

        await ctx.shutdown()
    }
}
