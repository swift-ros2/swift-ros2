import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

/// Receive-side integration test over CycloneDDS. Requires:
/// - `LINUX_IP` env var pointing at a host reachable from this machine.
/// - A running `ros2 run demo_nodes_cpp talker` on that host with
///   `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and `ROS_DOMAIN_ID=99`.
///
/// Uses unicast discovery so the test works across WiFi / Parallels /
/// environments where DDS multicast may be filtered.
final class DDSSubscriberTests: XCTestCase {
    func testChatterReceivedFromLinuxDDS() async throws {
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
        let node = try await ctx.createNode(name: "swift_ros2_it_sub")
        let sub = try await node.createSubscription(StringMsg.self, topic: "chatter")

        // Wait for SEDP + at least one publish cycle
        // (demo_nodes_cpp/talker publishes at 1 Hz).
        let expectation = XCTestExpectation(description: "receive at least one chatter message")
        let buf = SubscriberReceivedBuffer()
        let consumer = Task {
            for await msg in sub.messages {
                await buf.append(msg.data)
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 10.0)
        consumer.cancel()

        let items = await buf.items
        XCTAssertGreaterThanOrEqual(items.count, 1)
        XCTAssertTrue(
            items.first?.starts(with: "Hello World:") ?? false,
            "expected demo_nodes_cpp/talker phrasing, got \(items)"
        )

        await ctx.shutdown()
    }
}

private actor SubscriberReceivedBuffer {
    private(set) var items: [String] = []
    func append(_ s: String) { items.append(s) }
}
