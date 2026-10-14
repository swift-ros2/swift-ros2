import SwiftROS2
import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import SwiftROS2TestFixtures
import SwiftROS2Transport
import XCTest

// Exec's the `ros2` CLI via Process — native-host only; unavailable on Mac Catalyst.
#if !targetEnvironment(macCatalyst)
    /// Round-trip integration test over CycloneDDS. Requires:
    /// - `LINUX_IP` env var (the host running a matching-domain ros2 topic echo)
    /// - A running `ros2 topic echo /test/imu` on that host with
    ///   `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and `ROS_DOMAIN_ID=99`
    ///
    /// Uses unicast discovery so the test works across WiFi / Parallels /
    /// environments where DDS multicast may be filtered.
    final class DDSRoundTripTests: XCTestCase {
        func testImuPublishReceivedByLinuxDDS() async throws {
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
            let node = try await ctx.createNode(name: "swift_ros2_it_dds", namespace: "/test")
            let pub = try await node.createPublisher(Imu.self, topic: "imu")

            // DDS endpoint discovery through SPDP/SEDP is slower than Zenoh.
            try await Task.sleep(nanoseconds: 3_000_000_000)

            for i in 0..<10 {
                try pub.publish(
                    Imu(
                        header: Header(stamp: Time.now(), frameId: "imu_link"),
                        linearAcceleration: Vector3(x: 0.0, y: 0.0, z: 9.81 + Double(i) * 0.01)
                    ))
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            try await Task.sleep(nanoseconds: 500_000_000)
            await ctx.shutdown()
        }

        #if canImport(SwiftROS2DDS)
            /// Same-process publisher to subscriber over DDS multicast on the loopback
            /// interface. No LINUX_IP required — runs anywhere CycloneDDS loopback
            /// works, which is every Darwin / Linux machine. Uses domain 42 (distinct
            /// from the remote-host test at domain 99 so the two cannot interfere if
            /// both run).
            func testLoopbackPubSubSameProcess() async throws {
                let domain = 42
                let ctx = try await ROS2Context(
                    transport: .ddsMulticast(domainId: domain),
                    distro: .jazzy,
                    domainId: domain
                )
                let node = try await ctx.createNode(name: "dds_loopback", namespace: "/loopback")

                // Bind the subscriber first so SEDP can advertise the reader before
                // the writer starts sending.
                let sub = try await node.createSubscription(SwiftROS2ExampleInterfaces.StringMsg.self, topic: "chatter")
                let pub = try await node.createPublisher(SwiftROS2ExampleInterfaces.StringMsg.self, topic: "chatter")

                // DDS endpoint discovery (SPDP/SEDP) is slower than Zenoh; give both
                // sides time to match before the first publish.
                try await Task.sleep(nanoseconds: 2_000_000_000)

                let expectation = XCTestExpectation(description: "receive at least 3 chatter messages")
                expectation.expectedFulfillmentCount = 3
                expectation.assertForOverFulfill = false

                let buf = LoopbackReceivedBuffer()
                let consumer = Task {
                    for await msg in sub.messages {
                        await buf.append(msg.data)
                        expectation.fulfill()
                    }
                }

                for i in 0..<5 {
                    try pub.publish(SwiftROS2ExampleInterfaces.StringMsg(data: "hello-\(i)"))
                    // 200 ms between publishes gives RTPS reliability acknowledgements
                    // time to fire on the loopback interface.
                    try await Task.sleep(nanoseconds: 200_000_000)
                }

                await fulfillment(of: [expectation], timeout: 10.0)
                consumer.cancel()

                let items = await buf.items
                XCTAssertGreaterThanOrEqual(
                    items.count, 3, "expected at least 3 messages; got \(items)")
                for item in items {
                    XCTAssertTrue(item.starts(with: "hello-"), "unexpected payload: \(item)")
                }

                await ctx.shutdown()
            }

            /// The writer's matched state follows a same-process reader appearing and leaving.
            func testMatchedSubscriptionsLoopback() async throws {
                let domain = 43
                let ctx = try await ROS2Context(
                    transport: .ddsMulticast(domainId: domain), distro: .jazzy, domainId: domain)
                let node = try await ctx.createNode(name: "dds_matched", namespace: "/loopback")
                let pub = try await node.createPublisher(
                    SwiftROS2ExampleInterfaces.StringMsg.self, topic: "matched_probe")
                XCTAssertFalse(pub.hasMatchedSubscriptions)

                let sub = try await node.createSubscription(
                    SwiftROS2ExampleInterfaces.StringMsg.self, topic: "matched_probe")
                try await waitUntil(timeout: 5) { pub.hasMatchedSubscriptions }
                sub.cancel()
                try await waitUntil(timeout: 5) { !pub.hasMatchedSubscriptions }
                await ctx.shutdown()
            }

            private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(timeout)
                while !condition() {
                    if Date() > deadline {
                        XCTFail("condition not met within \(timeout) s")
                        return
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        #endif
    }

    private actor LoopbackReceivedBuffer {
        private(set) var items: [String] = []
        func append(_ s: String) { items.append(s) }
    }
#endif
