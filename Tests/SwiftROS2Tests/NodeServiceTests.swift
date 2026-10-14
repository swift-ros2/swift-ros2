import Foundation
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import XCTest

@testable import SwiftROS2

final class NodeServiceTests: XCTestCase {
    func testCreateServiceAndCallThroughMockTransport() async throws {
        let mock = MockTransportSession()
        mock.installEchoServiceTransport()

        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/127.0.0.1:7447"), session: mock)
        let node = try await ctx.createNode(name: "n")

        _ = try await node.createService(TriggerSrv.self, name: "/trigger") { _ in
            TriggerSrv.Response(success: true, message: "ok")
        }
        let cli = try await node.createClient(TriggerSrv.self, name: "/trigger")
        try await cli.waitForService(timeout: .milliseconds(100))
        let resp = try await cli.call(.init(), timeout: .seconds(1))
        XCTAssertTrue(resp.success)
        XCTAssertEqual(resp.message, "ok")
        await node.destroy()
        await ctx.shutdown()
    }

    func testCallTimeoutSurfaces() async throws {
        let mock = MockTransportSession()
        mock.installNeverRespondingServiceTransport()

        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/127.0.0.1:7447"), session: mock)
        let node = try await ctx.createNode(name: "n")
        let cli = try await node.createClient(TriggerSrv.self, name: "/trigger")
        do {
            _ = try await cli.call(.init(), timeout: .milliseconds(50))
            XCTFail("should time out")
        } catch ServiceError.timeout {
            // expected
        }
    }
}
