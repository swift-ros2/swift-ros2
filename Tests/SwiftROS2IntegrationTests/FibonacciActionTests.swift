// FibonacciActionTests.swift
// LAN-gated end-to-end Fibonacci round-trip against a real ROS 2 host.
//
// Requires:
// - `LINUX_IP` env var set to the host running `rmw_zenohd` (skipped if absent).
// - On the host:
//     ros2 run rmw_zenoh_cpp rmw_zenohd
//     RMW_IMPLEMENTATION=rmw_zenoh_cpp ros2 run action_tutorials_cpp fibonacci_action_server
//
// Skips gracefully when `LINUX_IP` is not set so CI stays deterministic.

import Foundation
import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Messages

final class FibonacciActionTests: XCTestCase {
    func testFibonacciRoundTripZenoh() async throws {
        guard let ip = ProcessInfo.processInfo.environment["LINUX_IP"], !ip.isEmpty else {
            throw XCTSkip("Set LINUX_IP to run this test (e.g., LINUX_IP=192.168.1.85)")
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/\(ip):7447", domainId: 0, wireMode: .jazzy),
            distro: .jazzy
        )
        let node = try await ctx.createNode(name: "fib_test")
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        try await cli.waitForActionServer(timeout: .seconds(5))
        let handle = try await cli.sendGoal(FibonacciAction.Goal(order: 5))
        let result = try await handle.result(timeout: .seconds(20))
        if case .succeeded(let r) = result {
            XCTAssertEqual(r.sequence, [0, 1, 1, 2, 3, 5])
        } else {
            XCTFail("non-success terminal: \(result)")
        }
        await ctx.shutdown()
    }
}
