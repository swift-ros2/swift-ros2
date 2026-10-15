// RclLinuxRuntimeRmwEndToEndTests.swift
// End-to-end regression net for the Linux runtime-rmw arm: a `.dds`
// config must open an rcl-backed context (RMW_IMPLEMENTATION=
// rmw_cyclonedds_cpp, selected from the transport type) through the PUBLIC
// API. #163 shipped this path dead — RclTransportSession.open() rejected the
// very `.dds` config makeDefaultSession routed to it — a break only an
// end-to-end open catches. Runs on the ci-rcl Linux leg (system ROS 2
// sourced); rmw_cyclonedds needs no router, so this is loopback-safe in CI.
// The `.zenoh` counterpart needs a live rmw_zenohd and stays a manual /
// LAN-gated procedure (see docs/verification-runbook.md).

#if os(Linux) && SWIFT_ROS2_RCL
    import SwiftROS2
    import SwiftROS2TestFixtures
    import XCTest

    final class RclLinuxRuntimeRmwEndToEndTests: XCTestCase {
        func testDdsMulticastOpensRclBackedContextEndToEnd() async throws {
            let ctx = try await ROS2Context(transport: .ddsMulticast(domainId: 87), distro: .jazzy)
            let node = try await ctx.createNode(name: "mz5_dds_smoke")
            let pub = try await node.createPublisher(StringMsg.self, topic: "mz5_dds_smoke")
            try pub.publish(StringMsg(data: "mz5"))
            await ctx.shutdown()
        }
    }
#endif
