// NodeActionTests.swift
// ROS2Node.createActionServer / createActionClient integration.

import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

final class NodeActionTests: XCTestCase {
    func testNodeDestroyClosesActionEntities() async throws {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in MockActionClient.makeAccepting() }
        mock.actionServerFactory = { _, _, _, _, _ in MockActionServer() }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let server = try await node.createActionServer(
            FibonacciAction.self, name: "/fibonacci",
            handler: _AcceptingHandler()
        )
        let client = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        XCTAssertTrue(server.isActive)
        XCTAssertTrue(client.isActive)
        await node.destroy()
        XCTAssertFalse(server.isActive)
        XCTAssertFalse(client.isActive)
        await ctx.shutdown()
    }

    func testCreateActionClientEmitsConfiguredEntity() async throws {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in MockActionClient.makeAccepting() }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        XCTAssertTrue(cli.isActive)
        await ctx.shutdown()
    }
}
